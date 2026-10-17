"""6단계 청취 위치 보정: 측정 → 프리셋 → 프리셋 적용 후 재측정이 맞춰지는지 (합성)."""
import numpy as np

from spatial_tools import analysis, calib, detect, signals, simulate

RATE = 48_000
NAMES = ["FL", "FR", "C", "SL"]


def _measure(devs, sched, seed):
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), RATE)
    rec = simulate.simulate(sched.events, devs, signals.voices(sched), RATE, 63, noise=0.003, seed=seed)
    dets = detect.detect(rec, RATE, tmpl, min_sep=0.1)
    return analysis.analyze(dets, sched).offsets_ms, calib.levels_db(dets, sched)


def test_calibration_aligns_arrival_and_level():
    _, sched = signals.make_slots(62, signals.CHANNEL_NAMES_7, 0.5, signals.STRIKE, RATE,
                                  tone_spec=signals.ToneSpec(), active=[0, 1, 2, 3], render=False)
    # 폰마다 출력 지연·거리·음량이 다른 책상 자리
    devs = [simulate.SimDevice(delay=dl, distance=ds, gain=g, jitter=50e-6)
            for dl, ds, g in [(0.0, 1.2, 0.8), (-0.4e-3, 1.0, 0.5), (0.1e-3, 0.9, 1.0), (-0.7e-3, 1.6, 0.35)]]
    off, lv = _measure(devs, sched, seed=1)
    pre = calib.make_preset(off, lv)
    assert min(pre["delay_ms"].values()) == 0 and max(pre["gain_db"].values()) == 0
    # 프리셋 적용 = 채널 지연·음량을 더한 것과 같다
    after = [simulate.SimDevice(delay=d.delay + pre["delay_ms"][n] / 1000, distance=d.distance,
                                gain=d.gain * 10 ** (pre["gain_db"][n] / 20), jitter=50e-6)
             for d, n in zip(devs, NAMES)]
    off2, lv2 = _measure(after, sched, seed=2)
    assert max(off.values()) - min(off.values()) > 1.0          # 보정 전 1 ms 넘게 어긋남
    assert max(off2.values()) - min(off2.values()) < 0.1        # 보정 후 0.1 ms 안
    assert max(lv2.values()) - min(lv2.values()) < 0.5          # 음량 0.5 dB 안
    # 누적: 보정 후 측정을 base 위에 다시 계산해도 거의 같은 프리셋
    pre2 = calib.make_preset(off2, lv2, base=pre)
    for n in NAMES:
        assert abs(pre2["delay_ms"][n] - pre["delay_ms"][n]) < 0.1
        assert abs(pre2["gain_db"][n] - pre["gain_db"][n]) < 0.5


def test_preset_renderer_delays_and_scales():
    x = np.zeros((1000, 3)); x[100, :] = 1.0
    r = calib.PresetRenderer(x, RATE, ["FL", "FR", "C"], {"delay_ms": {"FR": 1.0}, "gain_db": {"C": -6.0}})
    y = r.block(0, 1000)
    assert y[100, 0] == 1.0 and y[148, 1] == 1.0 and y[100, 1] == 0.0
    assert abs(y[100, 2] - 10 ** (-6 / 20)) < 1e-12
    # 렌더러(block)도 같은 결과, 음수 시작 구간은 0
    r2 = calib.PresetRenderer(r, RATE, ["FL", "FR", "C"], {"delay_ms": {}, "gain_db": {}})
    assert np.array_equal(r2.block(0, 1000), y) and not r.block(-50, 0).any()


def test_preset_renderer_reloads_file(tmp_path):
    import json, os
    x = np.zeros((1000, 2)); x[100, :] = 1.0
    p = tmp_path / "live.json"
    p.write_text(json.dumps({"delay_ms": {}, "gain_db": {}}))
    r = calib.PresetRenderer(x, RATE, ["FL", "FR"], path=str(p))
    assert r.block(0, 1000)[100, 1] == 1.0
    p.write_text(json.dumps({"delay_ms": {"FR": 1.0}, "gain_db": {}}))
    os.utime(p, (1, 1))
    assert r.block(0, 1000)[148, 1] == 1.0
