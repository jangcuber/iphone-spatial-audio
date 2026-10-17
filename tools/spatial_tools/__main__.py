"""명령줄 진입점:  python3 -m spatial_tools <명령> ...

  gen       테스트 신호(WAV)와 스케줄(JSON) 생성
  analyze   녹음에서 기기별 offset/drift/skew 계산
  probe     짧은 녹음 점검 (마이크 권한, chirp가 들리는지)
  demo      가짜 기기로 합성 녹음을 만들어 분석기 동작 확인
  snap      Snapcast 서버 조회/solo 순환/스트림 배정/지연 설정
  fanout    WAV를 실시간으로 FIFO들에 나눠 쓰기 (snapserver pipe 입력)
  calib     청취 위치 녹음 → 채널별 지연·음량 프리셋 (6단계)
  levels    폰을 하나씩 울려 청취 위치 음량 맞추기 (gen / analyze)
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from dataclasses import asdict
from pathlib import Path

import numpy as np

from . import analysis, calib, detect, fanout, levels, phonelog, signals, simulate, wavio


def _kv(text: str | None, cast=float) -> dict:
    if not text:
        return {}
    out = {}
    for part in text.split(","):
        k, _, v = part.partition("=")
        out[k.strip()] = cast(v)
    return out


def _names(text: str) -> list[str]:
    return [x.strip() for x in text.split(",") if x.strip()]


# ------------------------------------------------------------------- gen
def cmd_gen(a) -> int:
    out = Path(a.out)
    if a.voice == "chime":
        spec, tone = signals.STRIKE, signals.ToneSpec()
        if a.amplitude is not None:
            spec = signals.ChirpSpec(**{**asdict(spec), "amplitude": a.amplitude})
    else:
        spec, tone = signals.ChirpSpec(amplitude=a.amplitude or 0.5), None
    dur = a.minutes * 60 + 2.0
    if a.kind == "train":
        audio, sched = signals.make_train(dur, a.period, a.outputs, spec, a.rate, tone_spec=tone)
    elif a.kind == "slots":
        names = signals.CHANNEL_NAMES_7 if a.channels == "7" else _names(a.channels)
        active = [names.index(n) for n in _names(a.active)] if a.active else None
        audio, sched = signals.make_slots(dur, names, a.slot, spec, a.rate, tone_spec=tone,
                                          active=active, render=a.wav)
    else:
        names = signals.CHANNEL_NAMES_7 if a.channels == "7" else _names(a.channels)
        audio = signals.make_identify(names, a.rate)
        wavio.write_wav(out.with_suffix(".wav"), audio, a.rate)
        print(f"식별 신호: {out.with_suffix('.wav')}  (채널 k에서 그 채널의 벨 음이 k+1번)")
        return 0
    js = out.with_suffix(".schedule.json")
    js.parent.mkdir(parents=True, exist_ok=True)
    js.write_text(json.dumps(sched.to_json(), ensure_ascii=False))
    print(f"스케줄: {js}  ({audio.shape[1]}채널, {audio.shape[0] / a.rate / 60:.1f}분, {a.rate} Hz, "
          f"이벤트 {len(sched.events)}개) — 재생(fanout)과 분석에 모두 이 파일을 씁니다")
    if a.wav:
        wav = out.with_suffix(".wav")
        wavio.write_wav(wav, audio, a.rate)
        print(f"WAV: {wav}  (다른 플레이어로 재생할 때만 필요)")
    if a.wav and a.split and audio.shape[1] > 1:
        for k, name in enumerate(sched.channels):
            p = out.parent / f"{out.name}.{name}.wav"
            wavio.write_wav(p, audio[:, k], a.rate)
            print(f"  채널 {k} ({name}): {p}")
    return 0


# ------------------------------------------------------------------- analyze
def _load_recording(path: Path, channel: int) -> tuple[np.ndarray, int]:
    if path.suffix.lower() in (".wav", ".wave"):
        return wavio.read_wav(path, channel)
    if not shutil.which("ffmpeg"):
        raise SystemExit(f"{path.suffix} 파일은 ffmpeg가 있어야 읽을 수 있습니다 (brew install ffmpeg), 또는 WAV로 녹음하세요")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / "rec.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-c:a", "pcm_f32le", str(tmp)], check=True)
        return wavio.read_wav(tmp, channel)


def cmd_analyze(a) -> int:
    sched = signals.Schedule.from_json(json.loads(Path(a.schedule).read_text()))
    x, rate = _load_recording(Path(a.recording), a.channel)
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), rate)
    min_sep = min(0.1, (sched.slot or sched.period) * 0.4)
    dets = detect.detect(x, rate, tmpl, min_sep=min_sep, snr_min=a.snr)
    print(f"녹음 {len(x) / rate / 60:.1f}분 @ {rate} Hz, 검출 {len(dets)}개", file=sys.stderr)
    rep = analysis.analyze(
        dets, sched, solo_order=_names(a.solo_order) if a.solo_order else None,
        solo=a.solo, solo_step=a.solo_step, reference=a.reference, distances=_kv(a.distance) or None, window=a.window)
    print(analysis.format_report(rep))
    if a.json:
        Path(a.json).write_text(json.dumps(asdict(rep), ensure_ascii=False, indent=2))
        print(f"\nJSON: {a.json}")
    if a.detections:
        with open(a.detections, "w") as f:
            f.write("time_s,strength,snr\n")
            for d in dets:
                f.write(f"{d.time:.7f},{d.strength:.6g},{d.snr:.1f}\n")
    return 0


# ------------------------------------------------------------------- probe
def cmd_probe(a) -> int:
    """짧은 시험 녹음 점검: 마이크가 실제 소리를 받는지, chirp가 들리는지."""
    x, rate = _load_recording(Path(a.recording), a.channel)
    x = np.asarray(x, dtype=np.float64)
    rms = float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    db = 20 * np.log10(max(rms, 1e-12))
    if a.schedule:
        specs = [signals.ChirpSpec(**json.loads(Path(a.schedule).read_text())["chirp"])]
    else:   # 스케줄을 안 주면 chime·예전 chirp 둘 다 찾아 SNR이 높은 쪽 (맞는 템플릿이 훨씬 날카롭게 잡힘)
        specs = [signals.STRIKE, signals.ChirpSpec()]
    dets = max((detect.detect(x, rate, signals.chirp(sp, rate), min_sep=0.1, snr_min=a.snr) for sp in specs),
               key=lambda d: float(np.median([e.snr for e in d])) if d else 0.0)
    print(f"길이 {len(x) / rate:.1f}s  RMS {db:.1f} dBFS  peak {peak:.3f}  chirp 검출 {len(dets)}개")
    ok = True
    if rms < 1e-5:
        print("문제: 녹음이 완전히 무음입니다 → 시스템 설정 > 개인정보 보호 및 보안 > 마이크 에서 터미널을 허용하세요")
        ok = False
    elif len(dets) < a.min_chirps:
        print("문제: chirp가 거의 안 들립니다 → 폰이 Snapcast에 연결돼 재생 중인지, 볼륨/거리, mute 상태를 확인하세요")
        ok = False
    if peak > 0.98:
        print("주의: 녹음이 클리핑됩니다 → 폰 볼륨을 낮추거나 마이크에서 조금 떨어뜨리세요")
    print("점검 통과" if ok else "점검 실패")
    return 0 if ok else 1


# ------------------------------------------------------------------- demo
def solo_schedule(n: int, solo: float, step: float, gap: float, start: float = 0.0):
    """snap solo와 같은 순환을 흉내내는 active(k, t) 함수. start 전에는 모두 재생 중(순환 시작 전)."""
    durs = [solo + k * step for k in range(n)]
    cycle = sum(d + gap for d in durs)

    def active(k, t):
        if t < start:
            return True
        ph = (t - start - gap) % cycle   # 순환은 '전체 mute + gap'으로 시작
        for j, d in enumerate(durs):
            if ph < d:
                return j == k
            ph -= d
            if ph < gap:
                return False
            ph -= gap
        return False
    return active


def cmd_demo(a) -> int:
    rate = 48_000
    if a.kind == "slots":
        names = signals.CHANNEL_NAMES_7 if a.devices == 7 else [f"P{i + 1}" for i in range(a.devices)]
        _, sched = signals.make_slots(a.minutes * 60 + 2, names, 0.25, signals.STRIKE, rate, tone_spec=signals.ToneSpec())
        active = None
    else:
        names = [f"P{i + 1}" for i in range(a.devices)]
        _, sched = signals.make_train(a.minutes * 60 + 2, 0.5, 1, signals.STRIKE, rate, tone_spec=signals.ToneSpec())
        active = solo_schedule(len(names), 20.0, 5.0, 3.0, start=7.3)
    rng = np.random.default_rng(a.seed)
    devs = [simulate.SimDevice(
        delay=0.0 if k == 0 else float(rng.uniform(-3e-3, 3e-3)),
        distance=float(rng.uniform(0.8, 2.0)), gain=float(rng.uniform(0.3, 1.0)),
        clock_ppm=float(rng.normal(0, 3)), tilt=float(rng.uniform(-0.8, 0.8)),
        reflection=float(rng.uniform(0.3, 0.8)), jitter=a.jitter_us * 1e-6) for k in range(len(names))]
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), rate)
    rec = simulate.simulate(sched.events, devs, signals.voices(sched), rate, a.minutes * 60 + 3,
                            recorder_ppm=float(rng.normal(0, 30)), noise=a.noise, active=active)
    dets = detect.detect(rec, rate, tmpl, min_sep=0.1)
    cycle = sum(20.0 + 5.0 * k + 3.0 for k in range(len(names)))
    rep = analysis.analyze(dets, sched, solo_order=names if a.kind == "train" else None,
                           distances={n: d.distance for n, d in zip(names, devs)},
                           window=cycle * 2 if a.kind == "train" else 60)
    print(analysis.format_report(rep))
    s_mid = float(np.median([s for _, s in sched.events]))
    print("\n정답과 비교 (offset ms / drift ppm):")
    worst = 0.0
    for n, d in zip(names, devs):
        if n not in rep.offsets_ms:
            continue
        true_off = (d.delay - devs[0].delay + (d.clock_ppm - devs[0].clock_ppm) * 1e-6 * s_mid) * 1e3
        true_ppm = d.clock_ppm - devs[0].clock_ppm
        err = rep.offsets_ms[n] - true_off
        worst = max(worst, abs(err))
        print(f"  {n:<4} 정답 {true_off:+.4f} / {true_ppm:+.2f}   측정 {rep.offsets_ms[n]:+.4f} / {rep.drift_ppm[n]:+.2f}   오차 {err * 1e3:+.1f} µs")
    print(f"최대 offset 오차: {worst * 1e3:.1f} µs")
    return 0


# ------------------------------------------------------------------- snap
def cmd_snap(a) -> int:
    from .snapcast_rpc import SnapcastRPC, assign_streams, solo_rotation
    try:
        rpc_conn = SnapcastRPC(a.host, a.port)
    except OSError as e:
        print(f"Snapcast 서버({a.host}:{a.port})에 연결하지 못했습니다: {e}\n"
              "snapserver가 실행 중인지, 제어 포트(기본 1705)가 맞는지 확인하세요", file=sys.stderr)
        return 2
    with rpc_conn as rpc:
        if a.action == "status":
            st = rpc.status()
            print("스트림:", ", ".join(f"{s['id']}({s.get('status', '?')})" for s in st.get("streams", [])))
            for c in rpc.clients():
                print(f"  {c.name:<16} id={c.id:<20} 연결={'O' if c.connected else 'X'} "
                      f"mute={'O' if c.muted else 'X'} 볼륨={c.percent:>3} latency={c.latency}ms "
                      f"group={c.group_id[:8]} stream={c.stream_id}")
        elif a.action == "solo":
            names = _names(a.clients)
            log = open(a.log, "a") if a.log else None
            durs = ", ".join(f"{n} {a.solo + k * a.solo_step:g}s" for k, n in enumerate(names))
            print(f"solo 순환 시작: {durs} / gap {a.gap}s  (Ctrl-C로 종료, mute 원복)")
            print(f"분석할 때: --solo-order {','.join(names)} --solo {a.solo:g} --solo-step {a.solo_step:g}")
            try:
                solo_rotation(rpc, names, a.solo, a.gap, a.cycles, log, step=a.solo_step)
            except KeyboardInterrupt:
                print("\n중단 — mute 상태를 원래대로 돌렸습니다")
            finally:
                if log:
                    log.close()
        elif a.action == "ids":
            for c in rpc.clients():
                if c.connected:
                    print(f"{c.id}\t{c.name}")
        elif a.action == "assign":
            assign_streams(rpc, _kv(a.map, str))
            print("배정 완료. 'snap status'로 확인하세요")
        elif a.action == "latency":
            clients = rpc.clients()
            for name, ms in _kv(a.set, int).items():
                rpc.set_latency(rpc.find(name, clients).id, ms)
                print(f"  {name}: latency {ms} ms")
        elif a.action in ("mute-all", "unmute-all"):
            for c in rpc.clients():
                if c.connected:
                    rpc.set_mute(c.id, a.action == "mute-all")
                    print(f"  {c.name}: {'mute' if a.action == 'mute-all' else 'mute 해제'}")
        elif a.action == "rename":
            clients = rpc.clients()
            for old, new in _kv(a.set, str).items():
                rpc.set_name(rpc.find(old, clients).id, new)
                print(f"  {old} → {new}")
    return 0


# ------------------------------------------------------------------- fanout
def cmd_fanout(a) -> int:
    src = a.source
    if src.endswith(".json"):
        audio = signals.ScheduleRenderer(signals.Schedule.from_json(json.loads(Path(src).read_text())))
        rate = audio.rate
    else:
        audio, rate = wavio.read_wav(src)
    if a.preset:
        names = list(audio.sched.channels) if hasattr(audio, "sched") else signals.CHANNEL_NAMES_7[:audio.shape[1]]
        audio = calib.PresetRenderer(audio, rate, names, path=a.preset)
        print(f"프리셋 {a.preset}: 지연 {audio.delay} 샘플, 음량 {[round(20 * np.log10(g), 2) for g in audio.gain]} dB")
    outs = fanout.parse_outputs(a.out)
    print(f"{src}: {audio.shape[1]}채널 {audio.shape[0] / rate:.1f}s → " +
          ", ".join(f"{o.path}[{'multi' if o.multi else 'all' if o.channel is None else o.channel}]" for o in outs))
    nch = audio.shape[1] if any(o.multi for o in outs) else 2
    print(f"snapserver의 sampleformat은 {rate}:16:{nch} 이어야 합니다. Ctrl-C로 종료")
    try:
        n = fanout.run(audio, rate, outs, a.chunk_ms, a.loop, a.lead_silence, ahead_ms=a.ahead_ms)
        print(f"완료: {n} chunk")
    except KeyboardInterrupt:
        print("\n중단")
    return 0


# ------------------------------------------------------------------- calib
def cmd_calib(a) -> int:
    sched = signals.Schedule.from_json(json.loads(Path(a.schedule).read_text()))
    if sched.mode != "slots":
        raise SystemExit("calib는 slots 신호 녹음만 받습니다")
    x, rate = _load_recording(Path(a.recording), 0)
    tmpl = signals.chirp(signals.ChirpSpec(**sched.chirp), rate)
    dets = detect.detect(x, rate, tmpl, min_sep=min(0.1, sched.slot * 0.4), snr_min=a.snr)
    rep = analysis.analyze(dets, sched)
    lv = calib.levels_db(dets, sched)
    base = calib.load_preset(a.base) if a.base else None
    pre = calib.make_preset(rep.offsets_ms, lv, base)
    ref_lv = max(lv.values())
    print(f"청취 위치 측정 ({len(x) / rate:.0f} s, 적용돼 있던 프리셋: {a.base or '없음'})")
    print(f"{'채널':<6}{'도착(ms)':>10}{'±1σ(µs)':>9}{'음량(dB)':>10}  →{'지연(ms)':>10}{'음량(dB)':>10}")
    for n in rep.offsets_ms:
        print(f"{n:<6}{rep.offsets_ms[n]:>+10.3f}{rep.offsets_se_ms[n] * 1e3:>9.0f}{lv.get(n, float('nan')) - ref_lv:>+10.1f}"
              f"  →{pre['delay_ms'][n]:>10.3f}{pre['gain_db'].get(n, 0.0):>+10.1f}")
    spread_t = max(rep.offsets_ms.values()) - min(rep.offsets_ms.values())
    spread_l = max(lv.values()) - min(lv.values())
    print(f"도착 차이 최대 {spread_t:.3f} ms, 음량 차이 최대 {spread_l:.1f} dB  (목표: 0.5 ms, ±1 dB)")
    for k, v in rep.pairwise.items():
        print(f"  {k}: 사이클별 |p95| {v['abs_p95_ms']:.2f} ms")
    if a.out:
        doc = {**pre, "measured": {"offsets_ms": rep.offsets_ms, "levels_db": lv, "recording": str(a.recording),
                                   "base": a.base}, "note": "calib가 만든 청취 위치 프리셋. 지연은 Mac 쪽 PCM에서 샘플 단위로 적용"}
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(json.dumps(doc, ensure_ascii=False, indent=2))
        print(f"프리셋 저장: {a.out}")
    if a.json:
        Path(a.json).write_text(json.dumps({"offsets_ms": rep.offsets_ms, "levels_db": lv, "preset": pre,
                                            "spread_ms": spread_t, "spread_db": spread_l}, ensure_ascii=False, indent=2))
    return 0


# ------------------------------------------------------------------- levels
def cmd_levels(a) -> int:
    names = signals.CHANNEL_NAMES_7
    if a.action == "gen":
        audio, bursts, period = levels.make_cycle(names, _names(a.active))
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        wavio.write_wav(out.with_suffix(".wav"), audio, 48_000, floating=True)
        out.with_suffix(".json").write_text(json.dumps({"bursts": bursts, "period": period}, ensure_ascii=False))
        print(f"음량 측정 신호: {out.with_suffix('.wav')} (한 주기 {period:.1f} s, fanout --loop로 반복)")
        return 0
    plan = json.loads(Path(a.plan).read_text())
    bursts = [tuple(b) for b in plan["bursts"]]
    x, rate = _load_recording(Path(a.recording), 0)
    r = levels.analyze(x, rate, bursts, plan["period"])
    lvls = sorted({b[3] for b in bursts})
    ref = max(lvls)
    act = list(r["levels"])
    top = max(r["levels"][n][ref] for n in act)
    print(f"녹음 {len(x) / rate:.0f} s, {r['cycles']}주기, 잡음 바닥 {r['noise_db']:.1f} dB")
    print(f"{'채널':<6}" + "".join(f"{f'{lv:g} dBFS':>12}" for lv in lvls) + f"{'차이(dB)':>10}{'직선성':>8}")
    for n in act:
        v = r["levels"][n]
        lin = v[max(lvls)] - v[min(lvls)] - (max(lvls) - min(lvls))
        print(f"{n:<6}" + "".join(f"{v[lv]:>12.1f}" for lv in lvls) + f"{v[ref] - top:>+10.1f}{lin:>+8.1f}")
    spread = max(r["levels"][n][ref] for n in act) - min(r["levels"][n][ref] for n in act)
    print(f"폰 사이 음량 차이 최대 {spread:.1f} dB (목표 ±1 dB, 직선성: 두 크기 차이가 10 dB에서 벗어난 양)")
    base = calib.load_preset(a.base)["gain_db"] if a.base else {}
    gains = levels.gains_from(r["levels"], ref, base)
    print("새 음량(dB): " + ", ".join(f"{n} {g:+.1f}" for n, g in gains.items()))
    if a.out:
        j = json.loads(Path(a.base).read_text()) if a.base else {"delay_ms": {}}
        j["gain_db"] = {**j.get("gain_db", {}), **gains}
        j["gain_note"] = f"levels(폰 하나씩 분홍 잡음, 200 Hz~8 kHz) {a.recording}"
        Path(a.out).write_text(json.dumps(j, ensure_ascii=False, indent=2))
        print(f"저장: {a.out}")
    if a.json:
        Path(a.json).write_text(json.dumps({**r, "levels": {n: {str(k): v for k, v in d.items()} for n, d in r["levels"].items()},
                                            "spread_db": spread, "gains": gains}, ensure_ascii=False, indent=2))
    return 0


def _sigterm_as_interrupt() -> None:
    """스크립트가 백그라운드 프로세스를 kill(TERM)로 끝낼 때도 Ctrl-C처럼 정리(mute 원복 등)하게 한다."""
    import signal

    def handler(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, handler)


# -------------------------------------------------------------- phonelog
def cmd_phonelog(a) -> int:
    since = phonelog._time(a.since + (".0" if "." not in a.since else "")) if a.since else None
    logs = []
    for item in a.logs:
        name, _, path = item.rpartition("=")
        logs.append(phonelog.parse(Path(path).read_text(errors="replace"), name or Path(path).stem, since))
    print(phonelog.summary(logs))
    return 0


def main(argv: list[str] | None = None) -> int:
    _sigterm_as_interrupt()
    p = argparse.ArgumentParser(prog="spatial_tools", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen", help="테스트 신호 생성")
    g.add_argument("kind", choices=["train", "slots", "identify"],
                   help="train=같은 신호 반복(시험 A), slots=채널별 시간 슬롯(시험 B/7채널), identify=귀로 확인용 벨 소리")
    g.add_argument("--out", required=True, help="출력 경로 (확장자 제외), 예: signals/test_a")
    g.add_argument("--minutes", type=float, default=35.0)
    g.add_argument("--rate", type=int, default=48_000)
    g.add_argument("--voice", choices=["chime", "chirp"], default="chime",
                   help="chime=벨 음 + 작은 '팅' chirp(기본, 듣기 편함) / chirp=예전 1.5–12 kHz chirp만(잡음이 큰 곳에서 여유 +4 dB)")
    g.add_argument("--amplitude", type=float, help="측정 chirp 진폭 0~1 (기본 chime 0.25, chirp 0.5)")
    g.add_argument("--period", type=float, default=0.5, help="train: chirp 간격(s)")
    g.add_argument("--outputs", type=int, default=1, help="train: 출력 채널 수 (같은 신호 복제, 재생 시 L/R은 자동 복제)")
    g.add_argument("--channels", default="L,R", help="slots/identify: 채널 이름 목록 또는 '7' (FL..HR). chime이면 채널마다 C D E G A C D 음")
    g.add_argument("--active", help="slots: 실제로 울릴 채널만, 예: FL,FR,C,SL (스트림 채널 수는 --channels 그대로)")
    g.add_argument("--slot", type=float, default=0.25, help="slots: 슬롯 간격(s). 기기 간 skew는 이 값의 절반보다 작아야 구분 가능")
    g.add_argument("--wav", action="store_true", help="WAV 파일도 저장 (35분 7채널은 1.4 GB). fanout은 스케줄만으로 재생 가능")
    g.add_argument("--split", action="store_true", help="--wav와 함께: 채널별 모노 WAV도 따로 저장")
    g.set_defaults(fn=cmd_gen)

    an = sub.add_parser("analyze", help="녹음 분석")
    an.add_argument("recording", help="녹음 파일 (WAV, ffmpeg가 있으면 m4a 등도 가능)")
    an.add_argument("--schedule", required=True, help="gen이 만든 .schedule.json")
    an.add_argument("--channel", type=int, default=0, help="녹음 파일에서 쓸 채널 (기본 0)")
    an.add_argument("--solo-order", help="train(시험 A): solo 순환 순서, 예: P1,P2")
    an.add_argument("--solo", type=float, default=20.0, help="train: 첫 기기 solo 길이(s), snap solo와 같게")
    an.add_argument("--solo-step", type=float, default=5.0, help="train: 기기마다 늘어나는 solo 길이(s)")
    an.add_argument("--reference", help="기준 기기 이름 (기본: 첫 기기)")
    an.add_argument("--distance", help="마이크까지 거리(m), 예: P1=1.02,P2=0.98 → 출력 시각 기준 skew")
    an.add_argument("--window", type=float, default=60.0, help="시간창 길이(s). train 모드는 solo 한 바퀴보다 길게")
    an.add_argument("--snr", type=float, default=12.0, help="검출 임계값 (잡음 바닥 대비 배수)")
    an.add_argument("--json", help="결과 JSON 저장 경로")
    an.add_argument("--detections", help="검출 목록 CSV 저장 경로 (디버깅용)")
    an.set_defaults(fn=cmd_analyze)

    pr = sub.add_parser("probe", help="짧은 녹음 점검 (마이크 권한·폰 소리 확인)")
    pr.add_argument("recording")
    pr.add_argument("--channel", type=int, default=0)
    pr.add_argument("--snr", type=float, default=12.0)
    pr.add_argument("--min-chirps", type=int, default=4)
    pr.add_argument("--schedule", help="재생 중인 신호의 .schedule.json (없으면 chime/chirp 둘 다 찾음)")
    pr.set_defaults(fn=cmd_probe)

    d = sub.add_parser("demo", help="합성 녹음으로 분석기 확인")
    d.add_argument("kind", choices=["train", "slots"])
    d.add_argument("--devices", type=int, default=2)
    d.add_argument("--minutes", type=float, default=5.0)
    d.add_argument("--noise", type=float, default=0.005)
    d.add_argument("--jitter-us", type=float, default=50.0)
    d.add_argument("--seed", type=int, default=1)
    d.set_defaults(fn=cmd_demo)

    s = sub.add_parser("snap", help="Snapcast 서버 제어")
    s.add_argument("action", choices=["status", "ids", "solo", "assign", "latency", "rename", "mute-all", "unmute-all"],
                   help="ids = 연결된 클라이언트의 'id<TAB>이름' 목록 (스크립트용)")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=1705)
    s.add_argument("--clients", help="solo: 순환할 클라이언트 이름/ID 목록")
    s.add_argument("--solo", type=float, default=20.0, help="solo: 첫 기기 재생 시간(s)")
    s.add_argument("--solo-step", type=float, default=5.0, help="solo: 기기마다 늘리는 재생 시간(s). 분석기가 이 길이로 기기를 구분")
    s.add_argument("--gap", type=float, default=3.0, help="solo: 전체 mute 간격(s), 신호 period의 2배 이상")
    s.add_argument("--cycles", type=int, default=0, help="solo: 반복 횟수 (0=무한)")
    s.add_argument("--log", help="solo: 이벤트 로그(JSONL) 경로")
    s.add_argument("--map", help="assign: 클라이언트=스트림, 예: P1=chL,P2=chR")
    s.add_argument("--set", help="latency: 이름=ms / rename: 기존=새이름")
    s.set_defaults(fn=cmd_snap)

    f = sub.add_parser("fanout", help="스케줄(.schedule.json) 또는 WAV → FIFO 실시간 출력")
    f.add_argument("source", help="gen이 만든 .schedule.json (권장) 또는 WAV")
    f.add_argument("--out", action="append", required=True, help="FIFO경로:채널 (채널=0.., all=앞 두 채널, multi=모든 채널), 여러 번 지정")
    f.add_argument("--chunk-ms", type=float, default=20.0)
    f.add_argument("--loop", action="store_true")
    f.add_argument("--lead-silence", type=float, default=0.0)
    f.add_argument("--ahead-ms", type=float, default=150.0,
                   help="실시간보다 앞서 써 둘 양(ms). pipe가 비어 snapserver가 재동기화(onResync)하는 것을 막음. macOS pipe 64 KiB ≈ 340 ms(48k/16/2)")
    f.add_argument("--preset", help="채널별 지연·음량 프리셋 JSON (calib 결과). 재생 중 파일이 바뀌면 다시 읽음")
    f.set_defaults(fn=cmd_fanout)

    c = sub.add_parser("calib", help="청취 위치 녹음 → 채널별 지연·음량 프리셋")
    c.add_argument("recording")
    c.add_argument("--schedule", required=True)
    c.add_argument("--base", help="녹음할 때 이미 적용돼 있던 프리셋 (있으면 그 위에 누적)")
    c.add_argument("--out", help="새 프리셋 저장 경로, 예: ../presets/desk.json")
    c.add_argument("--json", help="측정 요약 JSON")
    c.add_argument("--snr", type=float, default=12.0)
    c.set_defaults(fn=cmd_calib)

    lv = sub.add_parser("levels", help="폰별 음량 맞추기: gen(신호) / analyze(녹음 → gain_db)")
    lv.add_argument("action", choices=["gen", "analyze"])
    lv.add_argument("recording", nargs="?", help="analyze: 녹음 WAV")
    lv.add_argument("--out", help="gen: 출력 경로(확장자 제외) / analyze: 새 프리셋 경로")
    lv.add_argument("--active", default="FL,FR,C,SL")
    lv.add_argument("--plan", help="analyze: gen이 만든 .json")
    lv.add_argument("--base", help="analyze: 녹음할 때 적용돼 있던 프리셋 (지연은 그대로, 음량은 누적)")
    lv.add_argument("--json")
    lv.set_defaults(fn=cmd_levels)

    pl = sub.add_parser("phonelog", help="폰 snapclient 로그 요약")
    pl.add_argument("logs", nargs="+", help="이름=경로 (예: node-04=logs/node-04.log)")
    pl.add_argument("--since", help="이 시각 이후만, 예: '2026-10-09 01-10-00'")
    pl.set_defaults(fn=cmd_phonelog)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
