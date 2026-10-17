"""청취 위치 보정(6단계): 녹음 → 채널별 지연·음량 프리셋, 프리셋을 적용한 재생.

청취 위치(마이크)에서 잰 도착 시각 차이를 그대로 쓴다. 폰마다 다른 출력 지연과 거리(음속) 차이가
함께 들어 있으므로 줄자 거리 없이도 '그 자리에서 같은 순간에 들리게' 맞출 수 있다.

프리셋 JSON (sysbridge.swift와 같은 형식):
  {"delay_ms": {"FL": 0.42, ...}, "gain_db": {"FL": -1.5, ...}, ...메모}
지연은 0 이상(일찍 도착하는 채널을 늦춤), 음량은 0 이하(가장 작은 채널에 맞춰 줄임 → 클리핑 여유 유지).
적용은 Mac 쪽 7채널 PCM에서 샘플 단위(20.8 µs)로 한다. 폰 설정·Snapcast latency(1 ms 단위)는 건드리지 않는다.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import numpy as np

from . import analysis
from .detect import Detection
from .signals import Schedule


def load_preset(path: str | Path) -> dict:
    j = json.loads(Path(path).read_text())
    return {"delay_ms": dict(j.get("delay_ms", {})), "gain_db": dict(j.get("gain_db", {}))}


class PresetRenderer:
    """block(start, end)를 가진 렌더러(ScheduleRenderer) 또는 배열에 채널별 지연·음량을 적용한다."""

    def __init__(self, audio, rate: int, names: list[str], preset: dict | None = None, path: str | None = None):
        """path를 주면 재생 중에 그 파일이 바뀔 때 다시 읽는다 (보정 전/후 녹음 사이에 서버·폰 재접속 없이 적용).
        폰은 재접속하면 시계 동기화가 다시 수렴할 때까지 수 ms 흔들려 측정을 망친다(2026-10-08 실측)."""
        self.audio = audio
        self.rate = rate
        self.shape = audio.shape
        self.names = names
        self._get = audio.block if hasattr(audio, "block") else self._slice
        self.path = path
        self._mtime = None
        self._apply(preset or (load_preset(path) if path and os.path.exists(path) else {"delay_ms": {}, "gain_db": {}}))
        if path and os.path.exists(path):
            self._mtime = os.stat(path).st_mtime

    def _apply(self, preset: dict) -> None:
        self.delay = [int(round(max(0.0, preset["delay_ms"].get(n, 0.0)) * self.rate / 1000)) for n in self.names]
        self.gain = [10 ** (preset["gain_db"].get(n, 0.0) / 20) for n in self.names]

    def _reload(self) -> None:
        try:
            m = os.stat(self.path).st_mtime
            if m != self._mtime:
                self._apply(load_preset(self.path))
                self._mtime = m
                print(f"프리셋 다시 읽음: 지연 {self.delay} 샘플", flush=True)
        except (OSError, ValueError):
            pass

    def __len__(self) -> int:
        return len(self.audio)

    def _slice(self, a: int, b: int) -> np.ndarray:
        out = np.zeros((b - a, self.audio.shape[1]))
        lo, hi = max(a, 0), min(b, len(self.audio))
        if lo < hi:
            out[lo - a:hi - a] = self.audio[lo:hi]
        return out

    def block(self, start: int, end: int) -> np.ndarray:
        if self.path:
            self._reload()
        out = np.zeros((end - start, self.shape[1]))
        for c in range(self.shape[1]):
            d = self.delay[c] if c < len(self.delay) else 0
            out[:, c] = self._get(start - d, end - d)[:, c] * (self.gain[c] if c < len(self.gain) else 1.0)
        return out


def levels_db(dets: list[Detection], sched: Schedule) -> dict[str, float]:
    """채널별 chirp 검출 세기(정합 필터 peak)의 중앙값, dB. 3~12 kHz 대역 기준 음량."""
    labels, names = analysis._labels_for(sched, None)
    tol = sched.slot * 0.4
    per: dict[str, list[float]] = {}
    for di, ei in analysis.match(dets, sched, tol):
        per.setdefault(names[labels[ei]], []).append(dets[di].strength)
    return {n: float(20 * np.log10(np.median(v))) for n, v in per.items() if v}


def make_preset(offsets_ms: dict[str, float], levels: dict[str, float], base: dict | None = None) -> dict:
    """측정값 → 프리셋. base(측정할 때 이미 적용돼 있던 프리셋)가 있으면 그 위에 누적한다."""
    base = base or {"delay_ms": {}, "gain_db": {}}
    names = list(offsets_ms)
    # 도착이 늦은 채널(+)에 맞춰 나머지를 늦춘다
    total_d = {n: base["delay_ms"].get(n, 0.0) + (max(offsets_ms.values()) - offsets_ms[n]) for n in names}
    m = min(total_d.values())
    delay = {n: round(v - m, 3) for n, v in total_d.items()}
    lv = {n: levels[n] for n in names if n in levels}
    total_g = {n: base["gain_db"].get(n, 0.0) + (min(lv.values()) - lv[n]) for n in lv}
    top = max(total_g.values()) if total_g else 0.0
    gain = {n: round(v - top, 2) for n, v in total_g.items()}
    return {"delay_ms": delay, "gain_db": gain}
