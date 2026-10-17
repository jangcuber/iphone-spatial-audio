"""7.1.4 채널 확인 음원: 채널마다 벨 한 번 + 한국어 음성으로 채널 이름.

SpatialPhones 12ch 장치 배치(L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr) 그대로 12채널 CAF를 만든다.
LFE에는 들리지 않는 아주 작은 잡음(-100 dBFS)을 계속 넣어, L·R만 소리 날 때도 sysbridge가
'스테레오 업믹스'로 바뀌지 않고 채널별 매핑을 유지하게 한다 (LFE는 폰으로 안 보냄).

사용: tools/.venv/bin/python tools/sysaudio/make_channel_check.py recordings/atmos_demo/channel_check_714.caf
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from spatial_tools.signals import ToneSpec, tone  # noqa: E402

RATE = 48000
LABELS = ["L", "R", "C", "LFE", "Ls", "Rs", "Rls", "Rrs", "Vhl", "Vhr", "Ltr", "Rtr"]
# (입력 채널, 읽을 이름, 벨 음 Hz). 순서 = 앞 → 옆 → 뒤 → 위
STEPS = [
    ("L", "왼쪽 앞", 523.25), ("C", "가운데", 587.33), ("R", "오른쪽 앞", 659.26),
    ("Ls", "왼쪽 옆", 783.99), ("Rs", "오른쪽 옆", 880.00),
    ("Rls", "왼쪽 뒤", 783.99), ("Rrs", "오른쪽 뒤", 880.00),
    ("Vhl", "왼쪽 위", 1046.50), ("Vhr", "오른쪽 위", 1174.66),
    ("Ltr", "왼쪽 위 뒤", 1046.50), ("Rtr", "오른쪽 위 뒤", 1174.66),
]


def speak(text: str, tmp: Path) -> np.ndarray:
    wav = tmp / "v.wav"
    subprocess.run(["say", "-v", "Yuna", "-o", str(wav), "--file-format=WAVE", f"--data-format=LEF32@{RATE}", text],
                   check=True)
    raw = wav.read_bytes()
    i = raw.index(b"data") + 8
    x = np.frombuffer(raw[i:], dtype="<f4").astype(np.float64)
    return 0.35 * x / max(1e-9, np.abs(x).max())


def main(out: str) -> None:
    spec = ToneSpec(amplitude=0.25)
    segs = []
    with tempfile.TemporaryDirectory() as d:
        for label, name, hz in STEPS:
            bell, voice = tone(hz, spec, RATE), speak(name, Path(d))
            n = int(0.3 * RATE) + len(bell) + int(0.1 * RATE) + len(voice) + int(0.9 * RATE)
            blk = np.zeros((n, len(LABELS)))
            c, p = LABELS.index(label), int(0.3 * RATE)
            blk[p:p + len(bell), c] += bell
            p += len(bell) + int(0.1 * RATE)
            blk[p:p + len(voice), c] += voice
            segs.append(blk)
    x = np.concatenate(segs)
    x[:, LABELS.index("LFE")] = 1e-5 * np.random.default_rng(0).standard_normal(len(x))
    with tempfile.TemporaryDirectory() as d:
        raw = Path(d) / "raw.wav"
        _write_wav_f32(raw, x)
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEF32", "-l", "Atmos_7_1_4", str(raw), out], check=True)
    print(f"{out}: {len(x) / RATE:.1f} s, 12채널 ({' '.join(LABELS)})")


def _write_wav_f32(path: Path, x: np.ndarray) -> None:
    import struct
    data = x.astype("<f4").tobytes()
    nch = x.shape[1]
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 3, nch, RATE, RATE * nch * 4, nch * 4, 32) + b"data" + struct.pack("<I", len(data))
    path.write_bytes(hdr + data)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "recordings/atmos_demo/channel_check_714.caf")
