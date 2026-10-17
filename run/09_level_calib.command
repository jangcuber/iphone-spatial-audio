#!/bin/bash
# 폰별 음량 보정: 폰을 하나씩 부드러운 '쉬익' 소리로 울려 청취 위치에서 크기를 재고 같게 맞춥니다.
#  - 1차 약 35초 녹음 → 음량 계산 → 재생 중 바로 적용 → 2차 약 35초 확인 → 차이가 1.5 dB 안이면 presets/desk.json에 저장
#  - 지연(시간 보정)은 그대로 둡니다. 마이크 폰: MIC_PHONE=192.168.1.65 run/09_level_calib.command
#  - Mac 소리 재생(run/07)은 끄고 시작합니다. 끝난 뒤 run/07을 다시 여세요.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)" && break; done
export PYTHONPATH="$ROOT/tools" PYTHONDONTWRITEBYTECODE=1
PY="$ROOT/tools/.venv/bin/python"
ST="$PY -m spatial_tools"
OUT="recordings/levels_$(date +%Y%m%d_%H%M%S)"
. run/phones.sh
ACTIVE=${ACTIVE:-$PH_ACTIVE}
NPHONES=${NPHONES:-$PH_N}
MIC_PHONE=${MIC_PHONE-$PH_MIC}   # 비우면(MIC_PHONE=) Mac 내장 마이크
PRESET=presets/desk.json
REC_S=${REC_S:-35}
mkdir -p "$OUT"
exec > >(tee "$OUT/console.log") 2>&1
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done; sleep 1; for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done; }
trap cleanup EXIT
pkill -INT -x sysbridge 2>/dev/null && { echo "Mac 소리 재생(sysbridge)을 껐습니다"; sleep 1; }
pkill -x snapserver 2>/dev/null && sleep 1

$ST levels gen --out "$OUT/signal" --active "$ACTIVE" || exit 1
# 지연은 지금 프리셋 그대로, 음량은 0 dB에서 시작
LIVE="$OUT/live_preset.json"
"$PY" -c "import json,sys; j=json.load(open('$PRESET')) if __import__('os').path.exists('$PRESET') else {'delay_ms':{}}; j['gain_db']={}; json.dump(j,open('$LIVE','w'))"

SNAPSERVER="$ROOT/tools/snapserver/snapserver"; [ -x "$SNAPSERVER" ] || SNAPSERVER=snapserver
"$SNAPSERVER" -c tools/config/snapserver_7ch_one.conf > "$OUT/snapserver.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 50); do [ -p /tmp/snap_7ch ] && break; sleep 0.2; done
$ST fanout "$OUT/signal.wav" --loop --out /tmp/snap_7ch:multi --ahead-ms 60 --preset "$LIVE" > "$OUT/fanout.log" 2>&1 &
PIDS+=($!)
echo " 아이폰 ${NPHONES}대가 붙기를 기다립니다"
while true; do
  N=$($ST snap ids 2>/dev/null | wc -l | tr -d ' ')
  printf "\r연결된 클라이언트: %s대   " "$N"
  [ "$N" -ge $NPHONES ] && break
  sleep 2
done
echo
# 이전 solo 시험이 중단되면 mute가 남을 수 있음(2026-10-08 node-02) → 모두 해제
"$PY" - <<'PYEOF'
import json, socket
s = socket.create_connection(("127.0.0.1", 1705))
def rpc(m, p, i):
    s.sendall((json.dumps({"id": i, "jsonrpc": "2.0", "method": m, "params": p}) + "\r\n").encode())
    buf = b""
    while b"\r\n" not in buf: buf += s.recv(65536)
    return json.loads(buf.split(b"\r\n")[0])
st = rpc("Server.GetStatus", {}, 1)["result"]["server"]
for g in st["groups"]:
    for c in g["clients"]:
        if c["connected"] and c["config"]["volume"]["muted"]:
            rpc("Client.SetVolume", {"id": c["id"], "volume": {"muted": False, "percent": 100}}, 2)
            print("mute 해제:", c["id"])
PYEOF
sleep 10
MACREC="$ROOT/tools/recorder/macrec"
if [ -n "$MIC_PHONE" ]; then
  SSHO=(-i "${SSH_KEY:-$HOME/.ssh/spatial_phones_ed25519}" -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=mic-$MIC_PHONE -o StrictHostKeyChecking=accept-new)
  ssh "${SSHO[@]}" "mobile@$MIC_PHONE" "test -x /var/mobile/iosrec" || { echo "마이크 폰($MIC_PHONE)에 /var/mobile/iosrec가 없습니다"; read -r _; exit 1; }
  echo "마이크: 탈옥 폰 $MIC_PHONE"
else
  [ -x "$MACREC" ] && [ "$MACREC" -nt "$ROOT/tools/recorder/macrec.swift" ] || swiftc -O -o "$MACREC" "$ROOT/tools/recorder/macrec.swift" || { echo "녹음기 빌드 실패"; read -r _; exit 1; }
fi
rec() {   # rec <출력.wav> <초>
  if [ -n "$MIC_PHONE" ]; then
    ssh "${SSHO[@]}" "mobile@$MIC_PHONE" "/var/mobile/iosrec /var/mobile/calib_rec.wav $2" && scp -q "${SSHO[@]}" "mobile@$MIC_PHONE:/var/mobile/calib_rec.wav" "$1"
  else
    "$MACREC" "$1" "$2"
  fi
}


echo "==== 1차 녹음 ${REC_S}초"
rec "$OUT/rec1.wav" $REC_S || exit 1
$ST levels analyze "$OUT/rec1.wav" --plan "$OUT/signal.json" --base "$LIVE" --out "$OUT/next.json" --json "$OUT/levels1.json" | tee "$OUT/levels1.txt" || exit 1
cp "$OUT/next.json" "$LIVE"
sleep 3
echo "==== 2차 녹음 ${REC_S}초 (적용 후 확인)"
rec "$OUT/rec2.wav" $REC_S || exit 1
$ST levels analyze "$OUT/rec2.wav" --plan "$OUT/signal.json" --base "$LIVE" --out "$OUT/next2.json" --json "$OUT/levels2.json" | tee "$OUT/levels2.txt"
OK=$("$PY" -c "import json; print(1 if json.load(open('$OUT/levels2.json'))['spread_db'] < 1.5 else 0)" 2>/dev/null)
if [ "$OK" = 1 ]; then
  [ -f "$PRESET" ] && cp "$PRESET" "$OUT/desk.previous.json"
  "$PY" -c "import json; j=json.load(open('$PRESET')); g=json.load(open('$LIVE'))['gain_db']; j['gain_db']=g; j.pop('gain_db_measured',None); json.dump(j,open('$PRESET','w'),ensure_ascii=False,indent=2)"
  echo "음량 채택: $PRESET"
else
  echo "확인 녹음의 음량 차이가 1.5 dB를 넘어 $PRESET 은 바꾸지 않았습니다"
fi
echo "결과: $OUT/levels1.txt, levels2.txt"
read -r -p "엔터를 누르면 닫습니다" _ || true
