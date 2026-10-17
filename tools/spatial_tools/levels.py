"""폰별 음량 보정: 폰을 하나씩 울려 청취 위치 마이크로 크기를 잰다 (2026-10-08).

chirp 세기로 잰 음량은 폰 스피커 리미터(추정) 때문에 보정을 넣어도 거의 안 변했다 → 여기서는
- 넓은 대역(200 Hz~8 kHz)의 부드러운 '쉬익' 소리(분홍 잡음, 앞뒤 페이드)를 모든 폰에 똑같이,
- 두 단계 크기(-26, -16 dBFS RMS; 7대·XR 마이크에서 -22는 잡음 바닥과 몇 dB 차이뿐이라 2026-10-09 6 dB 올림)로 내서 폰이 선형으로(10 dB 차이 그대로) 내는지도 확인하고,
- 녹음의 같은 대역 RMS에서 잡음 바닥을 빼서 폰별 dB를 낸다.
한 주기를 반복 재생(fanout --loop)하고, 녹음과 주기의 위치는 포락선 상관으로 찾는다.
"""
from __future__ import annotations

import numpy as np

BAND = (200.0, 8000.0)
FRAME = 0.01          # 포락선 프레임 (s)


def _bandpass(x: np.ndarray, rate: int) -> np.ndarray:
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / rate)
    X[(f < BAND[0]) | (f > BAND[1])] = 0
    return np.fft.irfft(X, len(x))


def pink(n: int, rate: int, seed: int = 7) -> np.ndarray:
    rng = np.random.default_rng(seed)
    X = np.fft.rfft(rng.normal(size=n))
    f = np.fft.rfftfreq(n, 1 / rate)
    X[1:] /= np.sqrt(f[1:])
    X[0] = 0
    x = _bandpass(np.fft.irfft(X, n), rate)
    return x / np.sqrt(np.mean(x ** 2))


def make_cycle(names: list[str], active: list[str], rate: int = 48_000, levels_db=(-26.0, -16.0),
               burst: float = 0.8, gap: float = 0.4, lead: float = 1.0):
    """한 주기 7채널 신호와 burst 목록 [(시작 s, 끝 s, 채널이름, dBFS)]."""
    nb = int(burst * rate)
    fade = int(0.1 * rate)
    env = np.ones(nb)
    env[:fade] = np.sin(np.linspace(0, np.pi / 2, fade)) ** 2
    env[-fade:] = env[:fade][::-1]
    shape = pink(nb, rate) * env
    bursts = []
    t = lead
    for lv in levels_db:
        for n in active:
            bursts.append((t, t + burst, n, lv))
            t += burst + gap
    total = t + lead
    audio = np.zeros((int(total * rate), len(names)))
    for s, e, n, lv in bursts:
        i = int(s * rate)
        audio[i:i + nb, names.index(n)] += shape * 10 ** (lv / 20)
    return audio, bursts, total


def analyze(rec: np.ndarray, rate: int, bursts, period: float) -> dict:
    """반환: {'levels': {채널: {dBFS: 녹음 dB}}, 'noise_db', 'offset_s', 'cycles'}."""
    y = _bandpass(np.asarray(rec, dtype=np.float64), rate)
    hop = int(FRAME * rate)
    nfr = len(y) // hop
    pw = np.mean(y[:nfr * hop].reshape(nfr, hop) ** 2, axis=1)
    pf = int(round(period / FRAME))
    # 기대 포락선(주기)과 녹음 포락선의 순환 상관으로 주기 시작 위치를 찾는다
    tmpl = np.zeros(pf)
    for s, e, _, lv in bursts:
        tmpl[int(s / FRAME):int(e / FRAME)] += 10 ** (lv / 10)
    folded = np.zeros(pf)
    for k in range(pf):
        folded[k] = np.mean(pw[k::pf][: nfr // pf]) if nfr >= pf else 0
    score = np.real(np.fft.ifft(np.fft.fft(folded) * np.conj(np.fft.fft(tmpl))))
    off = int(np.argmax(score))          # 녹음 프레임 off = 주기 프레임 0
    cycles = (nfr - off) // pf
    if cycles < 1:
        raise ValueError("녹음이 한 주기보다 짧습니다")
    # 잡음 바닥: 모든 burst 밖, 경계에서 0.15 s 떨어진 프레임
    busy = np.zeros(pf, dtype=bool)
    for s, e, _, _ in bursts:
        busy[max(0, int((s - 0.15) / FRAME)):int((e + 0.15) / FRAME)] = True
    quiet = [off + c * pf + k for c in range(cycles) for k in np.nonzero(~busy)[0] if off + c * pf + k < nfr]
    noise = float(np.mean(pw[quiet])) if quiet else 0.0
    levels: dict[str, dict[float, float]] = {}
    for s, e, n, lv in bursts:
        a, b = int((s + 0.15) / FRAME), int((e - 0.15) / FRAME)   # 페이드 빼고 가운데
        idx = [off + c * pf + k for c in range(cycles) for k in range(a, b) if off + c * pf + k < nfr]
        p = max(float(np.mean(pw[idx])) - noise, 1e-20)
        levels.setdefault(n, {})[lv] = 10 * np.log10(p)
    return {"levels": levels, "noise_db": 10 * np.log10(noise + 1e-20), "offset_s": off * FRAME, "cycles": cycles}


def gains_from(levels: dict, level_db: float, base: dict | None = None) -> dict[str, float]:
    """가장 작은 폰에 맞춰 나머지를 줄이는 gain_db (base에 누적, 최대값 0으로)."""
    base = base or {}
    lv = {n: v[level_db] for n, v in levels.items()}
    m = min(lv.values())
    tot = {n: base.get(n, 0.0) + (m - v) for n, v in lv.items()}
    top = max(tot.values())
    return {n: round(v - top, 2) for n, v in tot.items()}
