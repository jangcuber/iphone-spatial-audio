"""합성 '녹음' 생성기 — 분석기를 실제 기기 없이 검증하기 위한 가짜 측정 환경.

기기마다 지연·음량·clock 오차·스피커 특성·방 반사를 다르게 주고,
녹음 장치의 clock 오차와 배경 잡음까지 넣어 마이크 하나로 녹음한 것처럼 만든다.
정답(진짜 offset/drift)을 알고 있으므로 분석기 결과와 비교할 수 있다.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class SimDevice:
    delay: float = 0.0          # s, 기준 대비 출력 지연 (skew 정답)
    distance: float = 1.0       # m, 마이크까지 거리 (음향 전파 지연)
    gain: float = 1.0
    clock_ppm: float = 0.0      # 기기 재생 clock 오차 → 시간에 따라 벌어짐 (drift 정답)
    tilt: float = 0.0           # 스피커 음색 차이 (-1~1, 고역 강조/감쇠)
    reflection: float = 0.4     # 첫 반사음 크기 (직접음 대비)
    reflection_delay: float = 0.004  # s
    jitter: float = 0.0         # s, 이벤트마다 무작위 출력 시각 흔들림 (표준편차)


def _speaker_fir(tilt: float, taps: int = 31) -> np.ndarray:
    """선형 위상 FIR (그룹 지연은 모든 기기에서 (taps-1)/2 로 같다)."""
    n = np.arange(taps) - (taps - 1) / 2
    lp = np.sinc(n * 0.5) * np.hanning(taps)
    lp /= lp.sum()
    delta = np.zeros(taps)
    delta[(taps - 1) // 2] = 1.0
    hp = delta - lp
    return delta + tilt * (hp - lp) * 0.5


def _fftconv(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    n = len(a) + len(b) - 1
    nfft = 1 << (n - 1).bit_length()
    return np.fft.irfft(np.fft.rfft(a, nfft) * np.fft.rfft(b, nfft), nfft)[:n]


def _frac_place(buf: np.ndarray, t: float, rate: int, kernel: np.ndarray) -> None:
    """kernel을 시각 t(초)에 sub-sample 정밀도로 더한다 (FFT 위상 이동)."""
    pos = t * rate
    i0 = int(np.floor(pos))
    frac = pos - i0
    pad = 64
    n = 1
    while n < len(kernel) + 2 * pad:
        n <<= 1
    k = np.zeros(n)
    k[pad:pad + len(kernel)] = kernel
    f = np.fft.rfftfreq(n)
    shifted = np.fft.irfft(np.fft.rfft(k) * np.exp(-2j * np.pi * f * frac), n)
    start = i0 - pad
    lo, hi = max(0, start), min(len(buf), start + n)
    if lo < hi:
        buf[lo:hi] += shifted[lo - start:hi - start]


def simulate(events: list[tuple[int, float]], devices: list[SimDevice], template: np.ndarray,
             rate: int, duration: float, *, common_latency: float = 0.35,
             recorder_ppm: float = 0.0, noise: float = 0.002, seed: int = 0,
             room_tail: float = 0.03, active=None, speed_of_sound: float = 343.0) -> np.ndarray:
    """events: (기기 index 또는 -1=전체, 소스 시각). active(dev, s) -> bool 로 mute 구간을 흉내낸다.

    template: 모든 이벤트에 같은 파형(배열), 또는 signals.voices()가 돌려주는
    (파형 목록, 이벤트별 파형 index) — chime처럼 이벤트마다 음이 다를 때.
    """
    rng = np.random.default_rng(seed)
    rec = np.zeros(int(duration * rate))
    waves, vidx = template if isinstance(template, tuple) else ([template], np.zeros(len(events), dtype=int))
    kernels = []   # kernels[기기][파형]
    tail_n = int(room_tail * rate)
    for d in devices:
        ir = np.zeros(int(d.reflection_delay * rate) + tail_n + 1)
        ir[0] = 1.0
        ir[int(d.reflection_delay * rate)] += d.reflection
        decay = np.exp(-np.arange(tail_n) / (0.008 * rate))
        ir[-tail_n:] += rng.normal(0, 0.05, tail_n) * decay
        kernels.append([_fftconv(_fftconv(w, _speaker_fir(d.tilt)) * d.gain, ir) for w in waves])
    group_delay = (31 - 1) / 2 / rate
    for e, (ch, s) in enumerate(events):
        targets = range(len(devices)) if ch < 0 else [ch]
        for k in targets:
            if active is not None and not active(k, s):
                continue
            d = devices[k]
            true_t = (common_latency + d.delay + s * (1 + d.clock_ppm * 1e-6)
                      + d.distance / speed_of_sound)
            if d.jitter:
                true_t += rng.normal(0, d.jitter)
            rec_t = true_t * (1 + recorder_ppm * 1e-6) - group_delay
            _frac_place(rec, rec_t, rate, kernels[k][vidx[e]])
    rec += rng.normal(0, noise, len(rec))
    return rec
