"""녹음에서 chirp 도착 시각 검출 (matched filter + 포락선 peak).

해석적(analytic) 템플릿과의 상관 크기 = 상관 포락선이다. 위상 응답이 다른
스피커(기종·DSP 차이)여도 peak 위치가 흔들리지 않게 raw 상관이 아닌 포락선을 쓴다.
긴 녹음(30분 이상)도 메모리를 적게 쓰도록 overlap-save 블록 처리한다.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class Detection:
    time: float      # 녹음 기준 도착 시각 (s), sub-sample 보간
    strength: float  # 포락선 peak 값
    snr: float       # peak / 잡음 바닥(중앙값)


def analytic(x: np.ndarray) -> np.ndarray:
    n = len(x)
    X = np.fft.fft(x)
    h = np.zeros(n)
    h[0] = 1
    if n % 2 == 0:
        h[n // 2] = 1
        h[1:n // 2] = 2
    else:
        h[1:(n + 1) // 2] = 2
    return np.fft.ifft(X * h)


def _envelope_blocks(x: np.ndarray, template: np.ndarray, block: int = 1 << 18):
    """|x ⋆ analytic(template)| 를 블록 단위로 (시작 인덱스, 포락선) 생성.

    포락선 인덱스 i = 템플릿 시작이 x[i]에 있을 때. 전체 배열을 만들지 않아
    30분 이상 녹음도 메모리를 적게 쓴다.
    """
    m = len(template)
    tmpl = analytic(template)[::-1].conj()
    nfft = 1
    while nfft < block + m:
        nfft <<= 1
    step = nfft - m + 1
    H = np.fft.fft(tmpl, nfft)
    for s in range(0, len(x), step):
        seg = np.asarray(x[s:s + nfft], dtype=np.float64)
        if len(seg) < nfft:
            seg = np.concatenate([seg, np.zeros(nfft - len(seg))])
        y = np.fft.ifft(np.fft.fft(seg) * H)
        n = min(step, len(x) - s)
        yield s, np.abs(y[m - 1:m - 1 + n])


def envelope_correlation(x: np.ndarray, template: np.ndarray, block: int = 1 << 18) -> np.ndarray:
    out = np.empty(len(x))
    for s, env in _envelope_blocks(x, template, block):
        out[s:s + len(env)] = env
    return out


def _parabolic(y: np.ndarray, i: int) -> float:
    if i <= 0 or i >= len(y) - 1:
        return float(i)
    a, b, c = y[i - 1], y[i], y[i + 1]
    den = a - 2 * b + c
    if den == 0:
        return float(i)
    return i + 0.5 * (a - c) / den


def _peaks_in(env: np.ndarray, thr: float, sep: int) -> list[int]:
    cand = np.flatnonzero((env[1:-1] > thr) & (env[1:-1] >= env[:-2]) & (env[1:-1] > env[2:])) + 1
    if cand.size == 0:
        return []
    order = cand[np.argsort(env[cand])[::-1]]
    taken = np.zeros(len(env), dtype=bool)
    keep = []
    for i in order:
        lo, hi = max(0, i - sep), min(len(env), i + sep + 1)
        if taken[lo:hi].any():
            continue
        taken[i] = True
        keep.append(int(i))
    return sorted(keep)


def detect(x: np.ndarray, rate: int, template: np.ndarray, min_sep: float,
           snr_min: float = 12.0, block_seconds: float = 20.0) -> list[Detection]:
    """잡음 바닥(블록 중앙값) 대비 snr_min 이상인 peak를 min_sep 간격 이상으로 고른다.

    min_sep 안에서는 가장 강한 peak 하나만 남긴다(직후 반사음 제거).
    블록 끝의 tail 구간은 확정하지 않고 다음 블록과 이어서 다시 본다.
    """
    sep = int(min_sep * rate)
    tail = 2 * sep + 2
    blk = max(int(block_seconds * rate), 4 * tail)
    dets: list[Detection] = []
    carry = np.zeros(0)
    for s, env in _envelope_blocks(x, template, blk):
        work = np.concatenate([carry, env])
        w0 = s - len(carry)
        floor = float(np.median(env)) + 1e-12
        last = s + len(env) >= len(x)
        limit = len(work) if last else len(work) - tail
        for i in _peaks_in(work, floor * snr_min, sep):
            if i >= limit:
                continue  # 다음 블록에서 다시 판단
            d = Detection((w0 + _parabolic(work, i)) / rate, float(work[i]), float(work[i] / floor))
            if dets and d.time - dets[-1].time < min_sep:
                if d.strength > dets[-1].strength:
                    dets[-1] = d
                continue
            dets.append(d)
        carry = work[limit:]
    return dets
