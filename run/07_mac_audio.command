#!/bin/bash
# 7단계: Mac에서 나는 소리(음악·영상)를 폰 스피커로 — 7채널 스트림 하나(FL FR C SL SR HL HR)
#  - 드라이버 설치 없이 Core Audio process tap으로 Mac 전체 출력을 받습니다 (macOS 14.2+).
#  - 켜져 있는 동안 Mac 스피커는 조용하고, 소리는 폰에서 납니다 (지연 약 1.2초: snapserver 버퍼 1 s + 여유).
#  - 스테레오 → FL/FR = 왼/오, C = 가운데 합, SL·SR·HL·HR = 좌우 차이 성분(공간감)을 12.5 ms 늦춰서.
#  - presets/desk.json(6단계 보정 결과)이 있으면 채널별 지연·음량을 적용합니다. 끄기: PRESET= run/07_mac_audio.command
#  - 처음 실행하면 macOS가 "터미널이 시스템 오디오를 녹음"하도록 허용할지 묻습니다 → 허용.
#  - 전체 음량 = Mac 볼륨 키(음소거 포함). 폰별 음량은 run/08_phone_volume.command (재생 중 바로 반영).
#  - 멈추기: 이 창에서 Ctrl-C 또는 창 닫기 → Mac 스피커 소리 복구.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
. run/phones.sh
ACTIVE=${ACTIVE:-$PH_ACTIVE}          # 지금 있는 폰 (run/phones.txt)
PRESET=${PRESET-presets/desk.json}
mkdir -p run/logs
LOG="run/logs/mac_audio_$(date +%Y%m%d_%H%M%S)"

BR="$ROOT/tools/sysaudio/sysbridge"
if [ ! -x "$BR" ] || [ "$ROOT/tools/sysaudio/sysbridge.swift" -nt "$BR" ]; then
  echo "sysbridge 빌드 중..."
  swiftc -O -o "$BR" "$ROOT/tools/sysaudio/sysbridge.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/tools/sysaudio/Info.plist" \
    || { echo "빌드 실패"; read -r _; exit 1; }
fi

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done; sleep 1; for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done; }
trap cleanup EXIT

pkill -x snapserver 2>/dev/null && { echo "이미 실행 중이던 snapserver를 종료했습니다"; sleep 1; }
SNAPSERVER="$ROOT/tools/snapserver/snapserver"; [ -x "$SNAPSERVER" ] || SNAPSERVER=snapserver
"$SNAPSERVER" -c tools/config/snapserver_7ch_one.conf > "$LOG.snapserver.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 50); do [ -p /tmp/snap_7ch ] && break; sleep 0.2; done
[ -p /tmp/snap_7ch ] || { echo "snapserver가 FIFO를 만들지 못했습니다"; tail -20 "$LOG.snapserver.log"; read -r _; exit 1; }

ARGS=(--out /tmp/snap_7ch --active "$ACTIVE")
if [ -n "$PRESET" ] && [ -f "$PRESET" ]; then ARGS+=(--preset "$PRESET"); else echo "보정 프리셋 없음 (지연·음량 보정 없이)"; fi
echo
echo "음악이나 영상을 틀어 보세요. 10초마다 상태 줄이 나옵니다."
echo "  '최대 -120 dBFS'가 계속되면 소리가 안 들어오는 것 → 시스템 설정 > 개인정보 보호 및 보안 >"
echo "  화면 및 시스템 오디오 녹음 > '시스템 오디오 녹음만'에서 터미널을 켜고 이 창을 다시 여세요."
echo
"$BR" "${ARGS[@]}" > >(tee "$LOG.bridge.log") 2>&1 &
PIDS+=($!)
wait "${PIDS[1]}"
echo; read -r -p "엔터를 누르면 닫습니다" _
