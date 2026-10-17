#!/bin/bash
# 폰 스피커 켜기 — 더블클릭 한 번. Mac 소리(음악·영상·Apple Music 돌비)가 폰 7대로 나갑니다.
#  - 창은 닫아도 계속 켜져 있습니다. 끄기: 끄기.command
#  - 하는 일: run/10_atmos.command와 같음(12채널 가상 장치로 출력 전환 + 보정 프리셋), 다만 창 없이 뒤에서 돎.
#  - 처음 한 번은 가상 장치 설치가 필요해서 run/10_atmos.command를 먼저 여세요(Mac 암호 1번).
cd "$(dirname "$0")" || exit 1
ROOT="$PWD"
. run/phones.sh
DEV_NAME=SpatialPhones
mkdir -p run/logs
LOG="$ROOT/run/logs/on_$(date +%Y%m%d_%H%M%S)"
detach() { perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' -- "$@"; }   # 창을 닫아도 안 꺼지게 (HUP 안 받음)
bye() { echo; read -r -t 30 -p "이 창은 닫아도 됩니다 (30초 뒤 자동으로 끝남)" _ || true; exit "${1:-0}"; }

# 가상 장치 입력을 읽는 권한은 '터미널' 앱에 있다. 다른 곳((다른 앱의 셸 등))에서 띄우면 입력이 전부 0이라 폰이 조용함
# (2026-10-09 확인) → 터미널 창에서 다시 연다.
if [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ]; then
  osascript -e "tell application \"Terminal\" to do script quoted form of \"$ROOT/켜기.command\"" >/dev/null \
    && echo "터미널 창에서 켭니다." || echo "터미널을 열지 못했어요. 켜기.command를 Finder에서 더블클릭하세요."
  exit 0
fi
if pgrep -x sysbridge >/dev/null; then
  echo "이미 켜져 있어요. 끄려면 끄기.command"; bye 0
fi
if [ ! -d /Library/Audio/Plug-Ins/HAL/SpatialPhones.driver ]; then
  echo "가상 장치가 아직 없어요. run/10_atmos.command를 한 번 열어 설치한 뒤 다시 켜세요."; bye 1
fi
BR="$ROOT/tools/sysaudio/sysbridge"
if [ ! -x "$BR" ] || [ "$ROOT/tools/sysaudio/sysbridge.swift" -nt "$BR" ]; then
  echo "준비 중(처음 한 번)..."
  swiftc -O -o "$BR" "$ROOT/tools/sysaudio/sysbridge.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/tools/sysaudio/Info.plist" \
    || { echo "준비 실패 — 로그를 확인하세요"; bye 1; }
fi

# 폰이 다른 서버(윈도우 PC 등)를 보고 있으면 이 Mac으로 되돌린다. 시계 맞춤 바닥값(rttfloor)은 경로마다 달라 지우고 재시작.
MACIP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
fix_server() {   # fix_server <이름> <IP>
  local out
  out=$(ssh -i "${SSH_KEY:-$HOME/.ssh/spatial_phones_ed25519}" -o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias="spk-$1" -o StrictHostKeyChecking=accept-new \
    "mobile@$2" "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin; . /var/jb/etc/snapclient.conf
      [ \"\$SERVER\" = '$MACIP' ] && exit 0
      rm -f /var/mobile/Library/Caches/snapclient_rttfloor
      sudo -n snapclient-ctl set SERVER=$MACIP >/dev/null && sudo -n snapclient-ctl restart >/dev/null && echo \"\$SERVER\"" </dev/null 2>/dev/null)
  [ -n "$out" ] && echo "  $1: 서버 $out → 이 Mac($MACIP)으로 되돌림"
}
if [ -n "$MACIP" ]; then
  for nv in $PH_PHONES; do fix_server "${nv%%=*}" "${nv#*=}" & done
  wait
fi

pkill -x snapserver 2>/dev/null && sleep 1
rm -f /tmp/snap_7ch
SNAPSERVER="$ROOT/tools/snapserver/snapserver"; [ -x "$SNAPSERVER" ] || SNAPSERVER=snapserver
detach "$SNAPSERVER" -c tools/config/snapserver_7ch_one.conf > "$LOG.snapserver.log" 2>&1 < /dev/null &
for i in $(seq 1 50); do [ -p /tmp/snap_7ch ] && break; sleep 0.2; done
[ -p /tmp/snap_7ch ] || { echo "서버를 못 켰어요 — 로그를 확인하세요 ($LOG.snapserver.log)"; bye 1; }

ARGS=(--out /tmp/snap_7ch --active "$PH_ACTIVE" --device "$DEV_NAME")
[ -f presets/desk.json ] && ARGS+=(--preset presets/desk.json)
detach "$BR" "${ARGS[@]}" > "$LOG.bridge.log" 2>&1 < /dev/null &
sleep 3
pgrep -x sysbridge >/dev/null || { echo "소리 연결을 못 켰어요 — 로그를 확인하세요"; tail -5 "$LOG.bridge.log"; pkill -x snapserver; bye 1; }

printf "폰 연결 기다리는 중"
N=0
for i in $(seq 1 20); do
  N=$(PYTHONPATH=tools tools/.venv/bin/python -m spatial_tools snap ids 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" -ge "$PH_N" ] && break
  printf "."; sleep 1
done
echo
echo "켜졌어요. 폰 $N/${PH_N}대 연결. Mac 볼륨 키로 전체 음량을 조절하세요."
[ "$N" -lt "$PH_N" ] && echo "  (늦게 붙는 폰은 화면을 한 번 눌러 깨우면 곧 붙어요)"
echo "끄려면 끄기.command"
bye 0
