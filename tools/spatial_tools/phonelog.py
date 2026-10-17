"""폰 snapclient 로그 요약: 재동기화·재접속·잠든 구간·동기 상태(Stats).

snapclient.log 한 줄:  2026-10-09 00-32-18.541 [Info] (Stream) pMiniBuffer->full() ... : 490806
STATS=1이면 1초마다:   ... [Debug] (Stats) Chunk: <age>\t<mini>\t<short>\t<median>\t<size>\t<dac ms>\t<frame_delta>
  age·중앙값은 0.1 ms 단위(µs/100). age > 0 = 늦게 재생 중.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime

import numpy as np

_TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d-\d\d-\d\d\.\d+) \[(\w+)\] \(([^)]*)\) (.*)$")
_RESYNC = re.compile(r"(pBuffer|pShortBuffer|pMiniBuffer)->full\(\).*?: (-?\d+)|abs\(age > 500\): (-?\d+)")


@dataclass
class PhoneLog:
    name: str
    lines: int = 0
    connects: list = field(default_factory=list)      # 연결 성공 시각
    drops: list = field(default_factory=list)         # 연결이 끊긴 시각 (서버 종료 포함)
    resyncs: list = field(default_factory=list)       # (시각, ms) 하드 재동기화
    stalls: list = field(default_factory=list)        # (시각, s) 재접속 재시도 중 멈춘 구간 = 폰이 잠듦
    no_chunks: int = 0
    stats_age_ms: list = field(default_factory=list)  # Stats age (ms)
    stats_short_ms: list = field(default_factory=list)


def _time(s: str) -> datetime:
    return datetime.strptime(s, "%Y-%m-%d %H-%M-%S.%f")


def parse(text: str, name: str = "", since: datetime | None = None, stall_s: float = 8.0) -> PhoneLog:
    log = PhoneLog(name)
    prev_t, prev_retry = None, False
    for line in text.splitlines():
        m = _TS.match(line)
        if not m:
            continue
        t = _time(m.group(1))
        if since and t < since:
            continue
        log.lines += 1
        tag, msg = m.group(3), m.group(4)
        # 재접속 재시도는 1초 간격. 그 사이가 길면 프로세스가 멈춘 것(폰이 잠듦)
        if prev_t is not None and prev_retry and (t - prev_t).total_seconds() > stall_s:
            log.stalls.append((prev_t, (t - prev_t).total_seconds()))
        retry = tag in ("Controller", "Connection") and (
            "Reconnecting" in msg or "Connecting to host" in msg or "Resolving host" in msg or "refused" in msg
            or "socket shutdown" in msg)
        if tag == "Connection" and msg.startswith("Connected to"):
            log.connects.append(t)
        elif tag == "Controller" and msg.startswith("Error receiving next message"):
            log.drops.append(t)
        elif tag == "Stream":
            r = _RESYNC.search(msg)
            if r:
                us = int(r.group(2) if r.group(2) is not None else r.group(3))
                log.resyncs.append((t, us / 1000.0))
            elif "No chunks available" in msg:
                log.no_chunks += 1
        elif tag == "Stats" and msg.startswith("Chunk:"):
            parts = msg[len("Chunk:"):].split()
            try:
                log.stats_age_ms.append(int(parts[0]) / 10.0)
                log.stats_short_ms.append(int(parts[2]) / 10.0)
            except (IndexError, ValueError):
                pass
        prev_t, prev_retry = t, retry
    return log


def summary(logs: list[PhoneLog]) -> str:
    out = ["폰        재동기화  연결끊김  잠든구간(최장 s)  Stats n  |age| 중앙/p95/최대(ms)  short 중앙값 σ(ms)"]
    for lg in logs:
        stall = f"{len(lg.stalls)} ({max(s for _, s in lg.stalls):.0f})" if lg.stalls else "0"
        if lg.stats_age_ms:
            a = np.abs(np.asarray(lg.stats_age_ms))
            sh = np.asarray(lg.stats_short_ms)
            st = f"{len(a):7d}  {np.median(a):5.2f} / {np.percentile(a, 95):5.2f} / {a.max():7.2f}   {np.std(sh):6.2f}"
        else:
            st = "      -  (STATS 꺼짐)"
        out.append(f"{lg.name:8s} {len(lg.resyncs):8d}  {len(lg.drops):8d}  {stall:>16s}  {st}")
    for lg in logs:
        for t, ms in lg.resyncs:
            out.append(f"  {lg.name} 재동기화 {t:%H:%M:%S}  {ms:+.1f} ms")
        for t, s in lg.stalls:
            out.append(f"  {lg.name} 잠듦     {t:%H:%M:%S}  {s:.0f} s 동안 재접속 시도 멈춤")
    return "\n".join(out)
