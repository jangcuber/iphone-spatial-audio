"""신호 생성 → 합성 녹음 → 검출 → 분석 이 정답을 되찾는지 확인한다."""
import numpy as np
import pytest

from spatial_tools import analysis, detect, signals, simulate, wavio

RATE = 48_000


def _offsets_truth(devs, sched, ref=0):
    s_mid = float(np.median([s for _, s in sched.events]))
    return [(d.delay - devs[ref].delay + (d.clock_ppm - devs[ref].clock_ppm) * 1e-6 * s_mid) * 1e3
            for d in devs]


def test_wav_roundtrip(tmp_path):
    x = np.random.default_rng(0).uniform(-0.9, 0.9, (1000, 3))
    for bits in (16, 24):
        wavio.write_wav(tmp_path / f"a{bits}.wav", x, RATE, bits=bits)
        y, r = wavio.read_wav(tmp_path / f"a{bits}.wav")
        assert r == RATE and y.shape == x.shape
        assert np.max(np.abs(y - x)) < 2 / 2 ** (bits - 1)
    wavio.write_wav(tmp_path / "f.wav", x, RATE, floating=True)
    y, _ = wavio.read_wav(tmp_path / "f.wav", channel=2)
    assert np.allclose(y, x[:, 2], atol=1e-6)


def test_wav_rejects_clipping(tmp_path):
    with pytest.raises(ValueError):
        wavio.write_wav(tmp_path / "c.wav", np.array([1.5]), RATE)


def test_detect_finds_every_chirp_across_block_boundaries():
    tmpl = signals.chirp(rate=RATE)
    x = np.zeros(RATE * 30)
    truth = np.arange(0.5, 29.5, 0.37) + 0.0000123
    for t in truth:
        simulate._frac_place(x, t, RATE, tmpl)
    x += np.random.default_rng(1).normal(0, 0.01, len(x))
    dets = detect.detect(x, RATE, tmpl, min_sep=0.1, block_seconds=2.0)  # 일부러 작은 블록
    got = np.array([d.time for d in dets])
    assert len(got) == len(truth)
    assert np.max(np.abs(got - truth)) < 5e-6


def test_slots_two_devices_offset_and_drift():
    _, sched = signals.make_slots(180, ["L", "R"], slot=0.25, rate=RATE)
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    devs = [simulate.SimDevice(distance=1.0, jitter=40e-6, tilt=-0.4),
            simulate.SimDevice(delay=2.5e-3, distance=1.6, clock_ppm=4.0, gain=0.5, tilt=0.7, jitter=40e-6)]
    rec = simulate.simulate(sched.events, devs, tmpl, RATE, 182, recorder_ppm=-30, noise=0.005)
    dets = detect.detect(rec, RATE, tmpl, min_sep=0.1)
    rep = analysis.analyze(dets, sched, distances={"L": 1.0, "R": 1.6})
    truth = _offsets_truth(devs, sched)
    assert rep.n_matched == len(sched.events)
    assert abs(rep.offsets_ms["R"] - truth[1]) < 0.02          # 20 µs 이내
    assert abs(rep.drift_ppm["R"] - 4.0) < 0.5
    assert rep.pairwise["L-R"]["n"] > 200  # 180 s / 0.75 s cycle


def test_slots_without_distance_reports_acoustic_skew():
    _, sched = signals.make_slots(60, ["L", "R"], rate=RATE)
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    devs = [simulate.SimDevice(distance=1.0), simulate.SimDevice(distance=2.0)]
    rec = simulate.simulate(sched.events, devs, tmpl, RATE, 62)
    rep = analysis.analyze(detect.detect(rec, RATE, tmpl, 0.1), sched)
    assert abs(rep.offsets_ms["R"] - 1.0 / 343 * 1e3) < 0.02   # 거리 1 m 차이 ≈ 2.92 ms


def test_seven_channels_with_dropout_and_large_skew():
    names = signals.CHANNEL_NAMES_7
    _, sched = signals.make_slots(150, names, slot=0.25, rate=RATE)
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    rng = np.random.default_rng(7)
    delays = [0, 1e-3, -2e-3, 5e-3, 0.06, 0.3e-3, -0.2e-3]
    devs = [simulate.SimDevice(delay=dl, distance=float(rng.uniform(0.8, 2.5)), gain=float(rng.uniform(0.3, 1)),
                               clock_ppm=float(rng.normal(0, 2)), tilt=float(rng.uniform(-.8, .8)), jitter=60e-6,
                               reflection=float(rng.uniform(.3, .9)), reflection_delay=float(rng.uniform(.0015, .01)))
            for dl in delays]
    rec = simulate.simulate(sched.events, devs, tmpl, RATE, 152, recorder_ppm=50, noise=0.01,
                            active=lambda k, s: not (k == 6 and 60 < s < 80))
    rep = analysis.analyze(detect.detect(rec, RATE, tmpl, 0.1), sched,
                           distances={n: d.distance for n, d in zip(names, devs)})
    truth = _offsets_truth(devs, sched)
    for n, t in zip(names, truth):
        # 지터(60 µs)로 인한 통계 오차 + 반사음 바이어스 여유
        assert abs(rep.offsets_ms[n] - t) < 4 * rep.offsets_se_ms[n] + 0.02, n
    assert rep.counts["HR"] < rep.counts["FL"]  # 탈락 구간이 반영됨


@pytest.mark.parametrize("start", [0.0, 9.7])
def test_train_solo_rotation(start):
    """녹음이 순환 도중/이전에 시작돼도 solo 길이로 기기를 맞게 구분한다."""
    from spatial_tools.__main__ import solo_schedule
    _, sched = signals.make_train(500, period=0.5, n_out=1, rate=RATE)
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    active = solo_schedule(3, 20.0, 5.0, 3.0, start=start)
    # 녹음 시작이 순환 중간인 경우를 흉내: 앞부분 이벤트를 잘라낸다
    events = [e for e in sched.events if e[1] > 40.0] if start == 0.0 else sched.events
    devs = [simulate.SimDevice(jitter=50e-6),
            simulate.SimDevice(delay=-1.7e-3, clock_ppm=-3, gain=0.6, jitter=80e-6),
            simulate.SimDevice(delay=2.2e-3, clock_ppm=1.5, gain=0.8, jitter=60e-6)]
    rec = simulate.simulate(events, devs, tmpl, RATE, 502, recorder_ppm=20, noise=0.004, active=active)
    rep = analysis.analyze(detect.detect(rec, RATE, tmpl, 0.1), sched, solo_order=["A", "B", "C"],
                           solo=20, solo_step=5, window=200)
    truth = _offsets_truth(devs, sched)
    for n, t in zip("ABC", truth):
        assert abs(rep.offsets_ms[n] - t) < 4 * rep.offsets_se_ms[n] + 0.02, n
    assert abs(rep.drift_ppm["B"] + 3) < 0.5


def test_train_requires_solo_order():
    _, sched = signals.make_train(20, rate=RATE)
    with pytest.raises(ValueError):
        analysis.analyze([detect.Detection(1.0, 1, 100)] * 5, sched)


def test_schedule_json_roundtrip():
    _, sched = signals.make_slots(10, ["A", "B"], rate=RATE)
    again = signals.Schedule.from_json(sched.to_json())
    assert again.events == sched.events and again.channels == ["A", "B"]


def test_renderer_matches_full_signal():
    audio, sched = signals.make_slots(20, ["A", "B", "C"], rate=RATE)
    r = signals.ScheduleRenderer(sched)
    blk = np.concatenate([r.block(i, min(i + 1234, len(r))) for i in range(0, len(r), 1234)])
    assert blk.shape == audio.shape and np.allclose(blk, audio)
    audio, sched = signals.make_train(10, n_out=1, rate=RATE)
    assert np.allclose(signals.ScheduleRenderer(sched).block(0, len(audio)), audio)


def test_cli_end_to_end(tmp_path, capsys):
    """gen → (합성) 녹음 WAV → analyze 명령이 파일만으로 동작하는지."""
    import json
    from spatial_tools.__main__ import main
    out = tmp_path / "sig" / "tb"
    assert main(["gen", "slots", "--channels", "L,R", "--minutes", "1", "--out", str(out)]) == 0
    sched = signals.Schedule.from_json(json.loads(out.with_suffix(".schedule.json").read_text()))
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    devs = [simulate.SimDevice(distance=1.2), simulate.SimDevice(delay=0.8e-3, distance=1.2)]
    rec = simulate.simulate(sched.events, devs, tmpl, RATE, 64, common_latency=1.1)
    wavio.write_wav(tmp_path / "rec.wav", rec / max(1.0, np.abs(rec).max()), RATE, bits=24)
    js = tmp_path / "rep.json"
    assert main(["analyze", str(tmp_path / "rec.wav"), "--schedule", str(out.with_suffix(".schedule.json")),
                 "--json", str(js)]) == 0
    rep = json.loads(js.read_text())
    assert abs(rep["offsets_ms"]["R"] - 0.8) < 0.02
    assert "offset(ms)" in capsys.readouterr().out


# ------------------------------------------------------------------- chime (듣기 좋은 신호)
def _chime_slots(seconds, names):
    return signals.make_slots(seconds, names, slot=0.25, spec=signals.STRIKE, rate=RATE,
                              tone_spec=signals.ToneSpec())


def test_chime_bell_does_not_leak_into_detector():
    """벨 음(모든 음)만 있을 때 chirp 정합 필터 반응이 chirp 자체보다 60 dB 이상 작다."""
    tmpl = signals.chirp(signals.STRIKE, RATE)
    ref = detect.envelope_correlation(np.pad(tmpl, (1000, RATE)), tmpl).max()
    for f in signals.PENTATONIC:
        x = np.zeros(RATE)
        bell = signals.tone(f, rate=RATE)
        x[1000:1000 + len(bell)] = bell
        assert detect.envelope_correlation(x, tmpl).max() < ref * 1e-3, f


def test_chime_is_musical_with_headroom():
    audio, sched = _chime_slots(20, signals.CHANNEL_NAMES_7)
    waves, idx = signals.voices(sched)
    assert len(waves) == len(signals.PENTATONIC) and set(idx) == set(range(7))  # 채널마다 다른 음
    assert np.abs(audio).max() < 0.6          # 클리핑 여유 (-4.4 dBFS 이하)
    _, tr = signals.make_train(10, spec=signals.STRIKE, rate=RATE, tone_spec=signals.ToneSpec())
    assert list(signals.voices(tr)[1][:8]) == list(signals.MELODY)


def test_chime_seven_channels_accuracy():
    names = signals.CHANNEL_NAMES_7
    _, sched = _chime_slots(150, names)
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    rng = np.random.default_rng(11)
    devs = [simulate.SimDevice(delay=float(rng.uniform(-3e-3, 3e-3)), distance=float(rng.uniform(0.8, 2.5)),
                               gain=float(rng.uniform(0.3, 1)), clock_ppm=float(rng.normal(0, 2)),
                               tilt=float(rng.uniform(-.8, .8)), jitter=60e-6,
                               reflection=float(rng.uniform(.3, .9)), reflection_delay=float(rng.uniform(.0015, .01)))
            for _ in names]
    rec = simulate.simulate(sched.events, devs, signals.voices(sched), RATE, 152, recorder_ppm=50, noise=0.01)
    rep = analysis.analyze(detect.detect(rec, RATE, tmpl, 0.1), sched,
                           distances={n: d.distance for n, d in zip(names, devs)})
    assert rep.n_matched == len(sched.events)
    for n, t in zip(names, _offsets_truth(devs, sched)):
        assert abs(rep.offsets_ms[n] - t) < 4 * rep.offsets_se_ms[n] + 0.02, n


def test_chime_train_solo_rotation():
    from spatial_tools.__main__ import solo_schedule
    _, sched = signals.make_train(300, period=0.5, n_out=1, spec=signals.STRIKE, rate=RATE,
                                  tone_spec=signals.ToneSpec())
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    devs = [simulate.SimDevice(jitter=50e-6), simulate.SimDevice(delay=1.3e-3, clock_ppm=2, gain=0.6, jitter=50e-6)]
    rec = simulate.simulate(sched.events, devs, signals.voices(sched), RATE, 302, recorder_ppm=-20, noise=0.004,
                            active=solo_schedule(2, 20.0, 5.0, 3.0, start=4.1))
    rep = analysis.analyze(detect.detect(rec, RATE, tmpl, 0.1), sched, solo_order=["P1", "P2"],
                           solo=20, solo_step=5, window=102)
    t = _offsets_truth(devs, sched)[1]
    assert abs(rep.offsets_ms["P2"] - t) < 4 * rep.offsets_se_ms["P2"] + 0.02


def test_old_schedule_without_tone_still_renders_chirp():
    _, sched = signals.make_train(5, rate=RATE)
    d = sched.to_json()
    d.pop("tone")                       # 예전 gen이 만든 JSON
    r = signals.ScheduleRenderer(signals.Schedule.from_json(d))
    c = signals.chirp(signals.ChirpSpec(), RATE)
    st = int(round(sched.events[0][1] * RATE))
    assert np.allclose(r.block(st, st + len(c))[:, 0], c)


def test_seven_channel_stream_with_four_active_phones():
    # 7채널 스트림을 폰 4대(FL FR C SL)로만 잴 때: 빈 채널은 슬롯도 이벤트도 없고, 결과는 4대만
    names = signals.CHANNEL_NAMES_7
    _, sched = signals.make_slots(90, names, slot=0.5, rate=RATE, active=[0, 1, 2, 3], render=False)
    assert sched.period == 2.5 and {c for c, _ in sched.events} == {0, 1, 2, 3}
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    devs = [simulate.SimDevice(delay=dl, jitter=50e-6) for dl in (0, 0.4e-3, -0.3e-3, 1e-3, 0, 0, 0)]
    rec = simulate.simulate(sched.events, devs, tmpl, RATE, 92, noise=0.005)
    rep = analysis.analyze(detect.detect(rec, RATE, tmpl, 0.1), sched)
    assert rep.devices == ["FL", "FR", "C", "SL"]
    truth = _offsets_truth(devs, sched)
    for k, n in enumerate(rep.devices):
        assert abs(rep.offsets_ms[n] - truth[k]) < 0.02, n
