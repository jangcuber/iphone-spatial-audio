#!/bin/bash
# 폰별 음량 조절 (귀로 맞추기). run/07_mac_audio.command로 음악을 듣는 중에 쓰면 바로 반영됩니다.
#  - 전체 음량은 Mac 볼륨 키로 조절합니다 (run/07이 Mac 볼륨을 따라갑니다).
#  - 여기서는 폰 하나씩 상대 음량(dB)만 바꿉니다. 값은 presets/desk.json의 gain_db에 저장됩니다.
cd "$(dirname "$0")/.." || exit 1
PRESET=${PRESET:-presets/desk.json}
PY=tools/.venv/bin/python; [ -x "$PY" ] || PY=python3
# 스크립트를 stdin으로 넘기면 input()이 키보드를 못 읽으므로 -c로 넘긴다
SCRIPT=$(cat <<'PYEOF'
import json, os, sys
path = sys.argv[1]
PHONES = [("1", "FL", "1번 (앞 왼쪽)"), ("2", "FR", "2번 (앞 오른쪽)"), ("3", "C", "3번 (가운데)"), ("4", "SL", "4번 (왼쪽 뒤)"),
          ("5", "SR", "5번 (오른쪽 뒤)"), ("6", "HL", "6번 (높은 곳 왼쪽)"), ("7", "HR", "7번 (높은 곳 오른쪽)")]

def load():
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {"delay_ms": {}, "gain_db": {}}

def save(j):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(j, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)      # 한 번에 바꿔서 재생 중인 프로그램이 반쯤 쓴 파일을 읽지 않게

print("폰별 음량 조절. 예: '2 -3' = 2번을 3 dB 줄이기, '4 +2' = 4번을 2 dB 키우기, '0' = 모두 0 dB, 엔터 = 끝")
while True:
    j = load()
    g = j.setdefault("gain_db", {})
    print("  " + "   ".join(f"{label} {g.get(ch, 0.0):+.1f} dB" for _, ch, label in PHONES))
    try:
        line = input("> ").strip()
    except EOFError:
        break
    if not line:
        break
    if line == "0":
        for _, ch, _ in PHONES:
            g[ch] = 0.0
        save(j); continue
    parts = line.split()
    num = {n: ch for n, ch, _ in PHONES}
    if len(parts) != 2 or parts[0] not in num:
        print("형식: 폰번호 변화량 (예: 2 -3)"); continue
    try:
        d = float(parts[1])
    except ValueError:
        print("변화량은 숫자로 (예: -3, +2)"); continue
    ch = num[parts[0]]
    g[ch] = max(-30.0, min(12.0, round(g.get(ch, 0.0) + d, 1)))
    save(j)
PYEOF
)
exec "$PY" -c "$SCRIPT" "$PRESET"
