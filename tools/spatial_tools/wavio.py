"""WAV 입출력 (numpy만 사용).

읽기: PCM 16/24/32-bit 정수, IEEE float 32/64, WAVE_FORMAT_EXTENSIBLE.
쓰기: PCM 16/24-bit 정수 또는 float32.
읽기 결과는 float32 (frames, channels), 쓰기 입력은 [-1, 1] 범위 배열.
"""
from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

_PCM = 1
_FLOAT = 3
_EXTENSIBLE = 0xFFFE


def read_wav(path: str | Path, channel: int | None = None) -> tuple[np.ndarray, int]:
    """channel을 주면 그 채널만 1차원 float32로 반환 (긴 녹음의 메모리 절약)."""
    data = Path(path).read_bytes()
    if len(data) < 12 or data[0:4] not in (b"RIFF", b"RF64") or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: WAV(RIFF/WAVE) 파일이 아닙니다")

    pos = 12
    fmt = None
    pcm = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = body
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)

    if fmt is None or pcm is None:
        raise ValueError(f"{path}: fmt/data chunk가 없습니다")

    tag, channels, rate, _, block_align, bits = struct.unpack("<HHIIHH", fmt[:16])
    if tag == _EXTENSIBLE and len(fmt) >= 26:
        tag = struct.unpack("<H", fmt[24:26])[0]

    usable = len(pcm) - len(pcm) % block_align
    raw = pcm[:usable]

    if channel is not None and not 0 <= channel < channels:
        raise ValueError(f"{path}: 채널 {channel} 없음 (채널 수 {channels})")

    def pick(a: np.ndarray) -> np.ndarray:
        a = a.reshape(-1, channels)
        return a[:, channel] if channel is not None else a

    if tag == _FLOAT and bits in (32, 64):
        arr = pick(np.frombuffer(raw, dtype="<f4" if bits == 32 else "<f8")).astype(np.float32)
    elif tag == _PCM and bits == 16:
        arr = pick(np.frombuffer(raw, dtype="<i2")).astype(np.float32) / np.float32(32768.0)
    elif tag == _PCM and bits == 32:
        arr = (pick(np.frombuffer(raw, dtype="<i4")).astype(np.float64) / 2147483648.0).astype(np.float32)
    elif tag == _PCM and bits == 24:
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, channels, 3)
        if channel is not None:
            b = b[:, channel:channel + 1, :]
        b = b.astype(np.int32)
        v = b[..., 0] | (b[..., 1] << 8) | (b[..., 2] << 16)
        v = np.where(v & 0x800000, v - 0x1000000, v)
        arr = v.astype(np.float32) / np.float32(8388608.0)
        if channel is not None:
            arr = arr[:, 0]
    elif tag == _PCM and bits == 8:
        arr = (pick(np.frombuffer(raw, dtype=np.uint8)).astype(np.float32) - 128.0) / np.float32(128.0)
    else:
        raise ValueError(f"{path}: 지원하지 않는 형식 (tag={tag}, bits={bits})")

    return arr, rate


def write_wav(path: str | Path, audio: np.ndarray, rate: int, bits: int = 16, floating: bool = False) -> None:
    a = np.asarray(audio, dtype=np.float64)
    if a.ndim == 1:
        a = a[:, None]
    channels = a.shape[1]

    if floating:
        payload = a.astype("<f4").tobytes()
        tag, bits = _FLOAT, 32
    else:
        if bits not in (16, 24):
            raise ValueError("정수 PCM은 16 또는 24 bit만 지원합니다")
        peak = np.max(np.abs(a)) if a.size else 0.0
        if peak > 1.0:
            raise ValueError(f"클리핑: 최대 진폭 {peak:.3f} > 1.0")
        tag = _PCM
        if bits == 16:
            payload = np.round(a * 32767.0).astype("<i2").tobytes()
        else:
            v = np.round(a * 8388607.0).astype(np.int32).reshape(-1)
            b = np.empty((v.size, 3), dtype=np.uint8)
            b[:, 0] = v & 0xFF
            b[:, 1] = (v >> 8) & 0xFF
            b[:, 2] = (v >> 16) & 0xFF
            payload = b.tobytes()

    block_align = channels * bits // 8
    fmt = struct.pack("<HHIIHH", tag, channels, rate, rate * block_align, block_align, bits)
    out = bytearray()
    out += b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(payload) + (len(payload) & 1)) + b"WAVE"
    out += b"fmt " + struct.pack("<I", len(fmt)) + fmt
    out += b"data" + struct.pack("<I", len(payload)) + payload
    if len(payload) & 1:
        out += b"\x00"
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(bytes(out))
