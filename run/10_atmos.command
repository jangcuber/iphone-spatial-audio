#!/bin/bash
# 8단계: Apple Music 돌비 공간음향(Atmos)을 채널마다 따로 폰 스피커로
#  - 처음 한 번: 12채널 가상 출력 장치 'SpatialPhones 12ch'를 만들어 설치합니다 (Mac 암호 1번).
#    BlackHole 0.7.2 소스(무료, GPL) + 7.1.4 스피커 배치 수정(tools/sysaudio/blackhole_7_1_4.patch).
#    16채널 장치는 Music이 5.1로 줄여 버린다는 보고가 있어 딱 12채널(7.1.4)로 만듭니다.
#  - 켜는 동안 Mac 소리 출력이 이 장치로 바뀝니다 → Music이 Atmos를 7.1.4로 렌더링해 보내고,
#    sysbridge가 채널 이름대로 폰에 나눕니다 (뒤 서라운드 → SL/SR, 천장 4개 → HL/HR, LFE는 버림).
#    아직 없는 폰(SR, HL, HR) 소리는 같은 쪽 앞 폰에 섞습니다. 7대가 되면 ACTIVE=FL,FR,C,SL,SR,HL,HR.
#  - 일반 스테레오 곡·유튜브는 L/R만 오므로 run/07처럼 넓게 펼쳐서 냅니다 (자동 전환).
#  - 전체 음량 = Mac 볼륨 키. 폰별 음량·지연 = presets/desk.json (run/08로 조절, 재생 중 반영).
#  - 멈추기: Ctrl-C 또는 창 닫기 → Mac 출력이 원래 장치로 돌아갑니다.
#  - 다시 설치: REINSTALL=1 run/10_atmos.command
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
. run/phones.sh
ACTIVE=${ACTIVE:-$PH_ACTIVE}          # 지금 있는 폰 (run/phones.txt)
PRESET=${PRESET-presets/desk.json}
DEV_NAME="SpatialPhones"
DRV=/Library/Audio/Plug-Ins/HAL/SpatialPhones.driver
BH_URL=https://github.com/ExistentialAudio/BlackHole.git
BH_COMMIT=561d934c77a1fa64987e01ccabe890fed30e181f   # v0.7.2
mkdir -p run/logs
LOG="$ROOT/run/logs/atmos_$(date +%Y%m%d_%H%M%S)"
exec > >(tee "$LOG.console.log") 2>&1

# 1) 가상 장치 (처음 한 번)
if [ ! -d "$DRV" ] || [ "${REINSTALL:-0}" = 1 ]; then
  echo "== 12채널 가상 출력 장치 만들기 (처음 한 번, 1~2분) =="
  B="$ROOT/tools/sysaudio/build"
  mkdir -p "$B"
  [ -d "$B/BlackHole/.git" ] || git clone -q "$BH_URL" "$B/BlackHole" || { echo "BlackHole 소스 받기 실패 (인터넷 확인)"; read -r _; exit 1; }
  ( cd "$B/BlackHole" && git fetch -q origin 2>/dev/null; git checkout -q -f "$BH_COMMIT" && git clean -qfdx \
      && git apply "$ROOT/tools/sysaudio/blackhole_7_1_4.patch" ) || { echo "소스 준비 실패"; read -r _; exit 1; }
  ( cd "$B/BlackHole" && xcodebuild -project BlackHole.xcodeproj -configuration Release -target BlackHole \
      CONFIGURATION_BUILD_DIR="$B/out" PRODUCT_BUNDLE_IDENTIFIER=io.github.jangcuber.SpatialPhones \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
      GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kNumber_Of_Channels=12 kSampleRates=48000 kAtmos_7_1_4_Layout=1 kDriver_Name=\"SpatialPhones\" kPlugIn_BundleID=\"io.github.jangcuber.SpatialPhones\"' \
      > "$LOG.driver_build.log" 2>&1 ) || { echo "빌드 실패 → $LOG.driver_build.log"; tail -20 "$LOG.driver_build.log"; read -r _; exit 1; }
  codesign --force --sign - "$B/out/BlackHole.driver" >/dev/null 2>&1
  echo
  echo "Mac 로그인 암호를 물으면 입력하세요 (화면에 안 보여도 입력됩니다)."
  echo "가상 장치를 시스템 오디오 폴더에 넣고, Mac 오디오를 잠깐 다시 시작합니다(소리가 1~2초 끊김)."
  sudo rm -rf "$DRV" && sudo cp -R "$B/out/BlackHole.driver" "$DRV" && sudo killall coreaudiod \
    || { echo "설치 실패"; read -r _; exit 1; }
  for i in $(seq 1 30); do system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEV_NAME" && break; sleep 1; done
  system_profiler SPAudioDataType 2>/dev/null | grep -q "$DEV_NAME" || { echo "설치했지만 장치가 안 보입니다. Mac을 재시동한 뒤 다시 여세요."; read -r _; exit 1; }
  echo "가상 장치 설치 완료: $DEV_NAME 12ch"
  echo
fi

# 2) sysbridge
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

pkill -INT -x sysbridge 2>/dev/null && { echo "켜져 있던 Mac 소리 재생(run/07)을 껐습니다"; sleep 1; }
pkill -x snapserver 2>/dev/null && { echo "이미 실행 중이던 snapserver를 종료했습니다"; sleep 1; }
SNAPSERVER="$ROOT/tools/snapserver/snapserver"; [ -x "$SNAPSERVER" ] || SNAPSERVER=snapserver
"$SNAPSERVER" -c tools/config/snapserver_7ch_one.conf > "$LOG.snapserver.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 50); do [ -p /tmp/snap_7ch ] && break; sleep 0.2; done
[ -p /tmp/snap_7ch ] || { echo "snapserver가 FIFO를 만들지 못했습니다"; tail -20 "$LOG.snapserver.log"; read -r _; exit 1; }

ARGS=(--out /tmp/snap_7ch --active "$ACTIVE" --device "$DEV_NAME")
if [ -n "$PRESET" ] && [ -f "$PRESET" ]; then ARGS+=(--preset "$PRESET"); else echo "보정 프리셋 없음 (지연·음량 보정 없이)"; fi
echo
echo "== Music 앱에서 한 번만 =="
echo "  Music > 설정 > 재생 > '돌비 애트모스'를 '항상 켬'으로."
echo "  돌비 애트모스 곡을 틀면(곡 정보에 'Dolby Atmos' 표시) 아래에 '입력: 다채널'이 나오고,"
echo "  10초마다 나오는 '입력 최대 dBFS' 줄에서 Ls Rs Vhl Vhr 등에 숫자가 보이면 공간음향이 채널별로 오는 것입니다."
echo "  '입력: 스테레오'만 나오면 Music을 껐다 켜고 곡을 다시 트세요."
echo "  처음엔 macOS가 '터미널이 마이크에 접근'을 물을 수 있습니다 → 허용 (가상 장치 입력을 읽는 것, 실제 마이크 아님)."
echo "  '최대 -120 dBFS'가 계속되면: 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 터미널을 켜고 이 창을 다시 여세요."
echo
"$BR" "${ARGS[@]}" > >(tee "$LOG.bridge.log") 2>&1 &
PIDS+=($!)
wait "${PIDS[1]}"
echo; read -r -p "엔터를 누르면 닫습니다" _
