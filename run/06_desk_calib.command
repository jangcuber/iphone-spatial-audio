#!/bin/bash
# 6단계: Desk(책상 의자) 청취 위치 보정 — run/phones.txt의 폰 전부
#  - Mac 내장 마이크가 귀 자리에서 듣고, 폰마다 도착 시각·음량 차이를 잽니다 (줄자 거리 필요 없음).
#  - 1차 1분 녹음 → presets/desk.json(채널별 지연 ms·음량 dB) 저장 → 2차 1분 녹음은 프리셋을 적용해 확인.
#  - 프리셋은 Mac 쪽 PCM에서 샘플 단위로 적용(폰 설정 그대로). 7단계 run/07_mac_audio.command가 자동으로 씁니다.
#  - 결과: recordings/desk_<시각>/calib1.txt, calib2.txt
#  - 마이크를 탈옥 폰으로(MacBook을 옮기지 않을 때): MIC_PHONE=192.168.1.65 run/06_desk_calib.command
#    폰에 tools/recorder/iosrec(build_iosrec.sh)를 /var/mobile/iosrec로 넣어 두고, 폰을 의자 머리 자리에 둔다.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)" && break; done
export PYTHONPATH="$ROOT/tools" PYTHONDONTWRITEBYTECODE=1
PY="$ROOT/tools/.venv/bin/python"
[ -x "$PY" ] || { echo "먼저 run/01_setup.command 를 실행하세요"; read -r _; exit 1; }
ST="$PY -m spatial_tools"
SECONDS_REC=${SECONDS_REC:-60}
OUT="recordings/desk_$(date +%Y%m%d_%H%M%S)"
. run/phones.sh
ACTIVE=${ACTIVE:-$PH_ACTIVE}
NPHONES=${NPHONES:-$PH_N}
MIC_PHONE=${MIC_PHONE-$PH_MIC}   # 비우면(MIC_PHONE=) Mac 내장 마이크
PRESET=presets/desk.json
mkdir -p "$OUT" presets
exec > >(tee "$OUT/console.log") 2>&1

PIDS=()
cleanup() {
  echo; echo "정리 중..."
  for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done
  sleep 1
  for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done
}
trap cleanup EXIT

pkill -x snapserver 2>/dev/null && { echo "이미 실행 중이던 snapserver를 종료했습니다"; sleep 1; }
pkill -x sysbridge 2>/dev/null

echo "==== 1. 신호 생성 (7채널 중 $ACTIVE, 슬롯 0.5초)"
$ST gen slots --channels 7 --active $ACTIVE --slot 0.5 --minutes 30 --out "$OUT/signal" || exit 1

echo "==== 2. snapserver 시작"
SNAPSERVER="$ROOT/tools/snapserver/snapserver"; [ -x "$SNAPSERVER" ] || SNAPSERVER=snapserver
"$SNAPSERVER" -c tools/config/snapserver_7ch_one.conf > "$OUT/snapserver.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 50); do [ -p /tmp/snap_7ch ] && break; sleep 0.2; done
[ -p /tmp/snap_7ch ] || { echo "snapserver가 FIFO를 만들지 못했습니다"; tail -20 "$OUT/snapserver.log"; read -r _; exit 1; }
# 프리셋은 재생 중에 바꾼다(LIVE 파일). 서버를 다시 켜면 폰이 재접속하고 시계 동기화가 수렴할 때까지
# 수 ms씩 흔들려 측정을 망친다(2026-10-08 실측: 재접속 직후 폰 간 drift 10~60 ppm).
LIVE="$OUT/live_preset.json"
echo '{"delay_ms": {}, "gain_db": {}}' > "$LIVE"
$ST fanout "$OUT/signal.schedule.json" --out /tmp/snap_7ch:multi --ahead-ms 150 --preset "$LIVE" > "$OUT/fanout.log" 2>&1 &
FAN=$!
PIDS+=($FAN)

echo " 아이폰 ${NPHONES}대가 붙기를 기다립니다"
while true; do
  N=$($ST snap ids 2>/dev/null | wc -l | tr -d ' ')
  printf "\r연결된 클라이언트: %s대   " "$N"
  [ "$N" -ge $NPHONES ] && break
  sleep 2
done
echo
SETTLE=${SETTLE:-45}
echo "폰 시계 동기화가 자리 잡도록 ${SETTLE}초 기다립니다 (종소리는 계속 납니다)"
sleep $SETTLE
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
$ST snap status | tee "$OUT/devices.txt"

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

echo
echo "==== 3. 점검 녹음 (8초)"
while true; do
  rec "$OUT/probe.wav" 8
  if $ST probe "$OUT/probe.wav" --schedule "$OUT/signal.schedule.json"; then break; fi
  read -r -p "고친 뒤 엔터 = 다시 점검, q = 종료: " ans || exit 1
  [ "$ans" = "q" ] && exit 1
done

echo
echo "==== 4. 1차 녹음 ${SECONDS_REC}초 (보정 전) — 의자 근처에서 조용히"
rec "$OUT/rec1.wav" $SECONDS_REC || exit 1
$ST calib "$OUT/rec1.wav" --schedule "$OUT/signal.schedule.json" --out "$OUT/desk.json" --json "$OUT/calib1.json" | tee "$OUT/calib1.txt" \
  || { echo "1차 분석 실패"; read -r _; exit 1; }

echo
echo "==== 5. 프리셋 적용 후 2차 녹음 ${SECONDS_REC}초 (확인)"
cp "$OUT/desk.json" "$LIVE"
# NO_GAIN=1: 확인 녹음에 지연만 적용 (음량을 크게 줄이면 폰 스피커 처리 때문에 도착 시각이 달라지는지 확인용)
[ "${NO_GAIN:-0}" = 1 ] && "$PY" -c "import json; p='$LIVE'; j=json.load(open(p)); j['gain_db']={k: 0.0 for k in j.get('gain_db', {})}; json.dump(j, open(p,'w'))" && echo "  (확인 녹음은 지연만 적용)"
sleep 3
rec "$OUT/rec2.wav" $SECONDS_REC || exit 1
$ST calib "$OUT/rec2.wav" --schedule "$OUT/signal.schedule.json" --base "$OUT/desk.json" --out "$OUT/desk.next.json" --json "$OUT/calib2.json" | tee "$OUT/calib2.txt"
# 확인 녹음에서 도착 차이가 1 ms 안이면 프리셋으로 채택, 아니면 기존 것을 유지
OK=$("$PY" -c "import json,sys; print(1 if json.load(open('$OUT/calib2.json'))['spread_ms'] < 1.0 else 0)" 2>/dev/null)
if [ "$OK" = 1 ]; then
  [ -f "$PRESET" ] && cp "$PRESET" "$OUT/desk.previous.json"
  cp "$OUT/desk.json" "$PRESET"; echo "프리셋 채택: $PRESET"
else
  echo "확인 녹음의 도착 차이가 1 ms를 넘어 $PRESET 은 바꾸지 않았습니다 (측정값: $OUT/desk.json)"
fi

grep -E "No data since|onResync" "$OUT/snapserver.log" && echo "주의: 서버 입력이 끊기거나 재조정됐습니다 (위 줄)"
echo
echo "결과: $OUT/calib1.txt(보정 전), calib2.txt(보정 후). 프리셋: $PRESET"
echo "측정 끝."
read -r -p "엔터를 누르면 서버를 끄고 닫습니다" _ || true
