"""WAV를 실시간 속도로 여러 FIFO(named pipe)에 같은 frame 단위로 나눠 쓴다.

snapserver의 pipe 소스는 들어온 시점에 타임스탬프를 붙이므로, 채널별 FIFO에
'같은 sample을 같은 순간'에 써 주는 것이 공통 시간축의 출발점이다.
(그래도 서버가 각 pipe를 읽는 시점 차이가 남을 수 있다 → 시험 B에서 실측한다.)

출력은 snapserver 기본 형식에 맞춰 16-bit little-endian 정수, 2채널.
모노 채널을 지정하면 L/R에 똑같이 복제한다 (한 폰 = 한 채널을 양쪽 스피커로).
"""
from __future__ import annotations

import os
import stat
import time
from dataclasses import dataclass

import numpy as np


@dataclass
class Output:
    path: str
    channel: int | None   # None = 입력의 처음 두 채널을 그대로 (시험 A 스테레오)
    multi: bool = False   # True = 입력의 모든 채널을 그대로 (7채널 한 스트림 + 폰별 --channel)


def parse_outputs(specs: list[str]) -> list[Output]:
    """'경로:채널' 형식. 채널은 0부터, 'all'(처음 두 채널) 또는 'multi'(모든 채널)."""
    outs = []
    for spec in specs:
        path, _, ch = spec.rpartition(":")
        if not path:
            raise ValueError(f"출력 지정 형식은 경로:채널 입니다: {spec}")
        if ch == "multi":
            outs.append(Output(path, None, multi=True))
        else:
            outs.append(Output(path, None if ch == "all" else int(ch)))
    return outs


def _frames_for(blk: np.ndarray, out: Output) -> bytes:
    if out.multi:
        pair = blk
    elif out.channel is None:
        pair = blk[:, :2] if blk.shape[1] >= 2 else np.repeat(blk[:, :1], 2, axis=1)
    else:
        mono = blk[:, out.channel]
        pair = np.stack([mono, mono], axis=1)
    return (np.clip(pair, -1, 1) * 32767).round().astype("<i2").tobytes()


# macOS pipe에 한 번에 큰 블록(7채널 20 ms = 13440 B)을 쓰면, 쓰는 쪽이 공간을 기다리는 동안
# snapserver(kqueue)가 읽기 가능 알림을 못 받아 둘 다 멈추는 일이 있었다 (2026-10-08 실측: 7채널에서
# 5~35 s 뒤 "No data since 5020 ms", 2채널 5376 B 쓰기에서는 없음). 작은 조각으로 나눠 쓴다.
PIPE_PIECE = 4096


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        n = os.write(fd, view[:PIPE_PIECE])
        view = view[n:]


def _open(path: str) -> int:
    if os.path.exists(path) and stat.S_ISFIFO(os.stat(path).st_mode):
        # O_RDWR: 읽는 쪽(snapserver)이 아직 안 열었어도 막히지 않는다 (macOS/Linux)
        return os.open(path, os.O_RDWR)
    return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)


def run(audio, rate: int, outputs: list[Output], chunk_ms: float = 20.0,
        loop: bool = False, lead_silence: float = 0.0, clock=time.monotonic,
        sleep=time.sleep, max_chunks: int | None = None, ahead_ms: float = 0.0) -> int:
    """실시간 속도로 출력. 반환값 = 쓴 chunk 수. 모든 출력에 같은 chunk를 같은 회차에 쓴다.

    audio: (frames, channels) 배열 또는 block(start, end)를 가진 렌더러(ScheduleRenderer).
    ahead_ms: 실시간보다 이만큼 앞서 써서 pipe에 여유분을 둔다. snapserver는 pipe를 자기 시계로
      chunk_ms마다 읽는데, 쓰는 쪽이 조금이라도 늦으면 타임스탬프를 다시 맞추고(onResync)
      그때마다 모든 폰이 하드 재동기화한다 (2026-10-08 실측: onResync 14회 ↔ 폰 재동기화 동시 발생).
    """
    get = audio.block if hasattr(audio, "block") else (lambda a, b: audio[a:b])
    for o in outputs:
        if o.channel is not None and o.channel >= audio.shape[1]:
            raise ValueError(f"입력에 채널 {o.channel} 이 없습니다 (채널 수 {audio.shape[1]})")
    lead = int(lead_silence * rate)
    total = lead + len(audio)
    fds = [_open(o.path) for o in outputs]
    step = max(1, int(rate * chunk_ms / 1000))
    t0 = clock()
    written = 0
    pos = 0
    try:
        while True:
            if pos >= total:
                if not loop:
                    break
                pos = 0
            end = min(total, pos + step)
            blk = np.zeros((end - pos, audio.shape[1]))
            a, b = max(pos, lead), end
            if a < b:
                blk[a - pos:] = get(a - lead, b - lead)
            payloads = [_frames_for(blk, o) for o in outputs]
            for fd, p in zip(fds, payloads):
                _write_all(fd, p)
            written += 1
            pos = end
            if max_chunks is not None and written >= max_chunks:
                break
            # 다음 chunk의 목표 시각까지 대기 (누적 오차 없이 절대 시각 기준)
            target = t0 + written * step / rate - ahead_ms / 1000.0
            delay = target - clock()
            if delay > 0:
                sleep(delay)
    finally:
        for fd in fds:
            os.close(fd)
    return written
