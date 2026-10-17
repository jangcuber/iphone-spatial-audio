#!/bin/bash
# 영상 싱크 맞추기 — 유튜브 등 영상에서 소리가 늦게 나오는 것 고치기 (처음 한 번)
#  - 원인: 폰 소리는 Mac보다 약 1.2초 늦게 나는데(서버 버퍼 1초 + 여유), 가상 장치가 앱에 '지연 0'이라고 알려서
#    브라우저가 영상을 바로 보여 줌. → 가상 장치가 실제 지연을 알리게 고친 드라이버로 다시 설치하면,
#    블루투스 이어폰·AirPlay처럼 브라우저·QuickTime이 화면을 그만큼 늦춰 맞춥니다.
#  - 하는 일: 1) 고친 가상 장치 빌드  2) 폰 스피커 끄기  3) 설치(Mac 암호 1번, Mac 소리 1~2초 끊김)
#            4) 폰 스피커 다시 켜기  5) 실제 지연 재기(폰에서 '띵' 4번, 약 10초, Mac 내장 마이크) → 장치에 넣기
#  - 재기를 건너뛰면 기본값 1119 ms가 들어갑니다. 다시 재기만: MEASURE_ONLY=1 run/16_video_sync.command
#  - 끝나면 웨일/크롬에서 유튜브 페이지를 새로고침하세요 (재생 시작할 때 지연 값을 읽음).
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
DEV_NAME=SpatialPhones
DRV=/Library/Audio/Plug-Ins/HAL/SpatialPhones.driver
BH_URL=https://github.com/ExistentialAudio/BlackHole.git
BH_COMMIT=561d934c77a1fa64987e01ccabe890fed30e181f   # v0.7.2 (run/10과 같음)
mkdir -p run/logs
LOG="$ROOT/run/logs/video_sync_$(date +%Y%m%d_%H%M%S)"
exec > >(tee "$LOG.console.log") 2>&1
bye() { echo; read -r -p "엔터를 누르면 닫습니다" _; exit "${1:-0}"; }

AV="$ROOT/tools/sysaudio/avlatency"
if [ ! -x "$AV" ] || [ "$ROOT/tools/sysaudio/avlatency.swift" -nt "$AV" ]; then
  swiftc -O -o "$AV" "$ROOT/tools/sysaudio/avlatency.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/tools/sysaudio/Info.plist" \
    > "$LOG.avlatency_build.log" 2>&1 || { echo "지연 재기 도구 빌드 실패 → $LOG.avlatency_build.log"; bye 1; }
fi

if [ "${MEASURE_ONLY:-0}" != 1 ]; then
  echo "== 1) 고친 가상 장치 빌드 =="
  B="$ROOT/tools/sysaudio/build"
  mkdir -p "$B"
  [ -d "$B/BlackHole/.git" ] || git clone -q "$BH_URL" "$B/BlackHole" || { echo "BlackHole 소스 받기 실패 (인터넷 확인)"; bye 1; }
  ( cd "$B/BlackHole" && git checkout -q -f "$BH_COMMIT" && git clean -qfdx \
      && git apply "$ROOT/tools/sysaudio/blackhole_7_1_4.patch" ) || { echo "소스 준비 실패"; bye 1; }
  ( cd "$B/BlackHole" && xcodebuild -project BlackHole.xcodeproj -configuration Release -target BlackHole \
      CONFIGURATION_BUILD_DIR="$B/out" PRODUCT_BUNDLE_IDENTIFIER=io.github.jangcuber.SpatialPhones \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
      GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kNumber_Of_Channels=12 kSampleRates=48000 kAtmos_7_1_4_Layout=1 kDriver_Name=\"SpatialPhones\" kPlugIn_BundleID=\"io.github.jangcuber.SpatialPhones\"' \
      > "$LOG.driver_build.log" 2>&1 ) || { echo "빌드 실패 → $LOG.driver_build.log"; tail -20 "$LOG.driver_build.log"; bye 1; }
  codesign --force --sign - "$B/out/BlackHole.driver" >/dev/null 2>&1
  echo "빌드 OK"

  WAS_ON=0
  pgrep -x sysbridge >/dev/null && WAS_ON=1
  echo
  echo "== 2) 폰 스피커 잠깐 끄기 =="
  ./끄기.command < /dev/null | grep -v "닫아도"

  echo
  echo "== 3) 설치 =="
  echo "Mac 로그인 암호를 물으면 입력하세요 (화면에 안 보여도 입력됩니다). Mac 소리가 1~2초 끊깁니다."
  sudo rm -rf "$DRV" && sudo cp -R "$B/out/BlackHole.driver" "$DRV" && sudo killall coreaudiod \
    || { echo "설치 실패"; bye 1; }
  for i in $(seq 1 30); do "$AV" --get >/dev/null 2>&1 && break; sleep 1; done
  "$AV" --get || { echo "설치했지만 장치가 안 보입니다. Mac을 재시동한 뒤 다시 여세요."; bye 1; }

  echo
  echo "== 4) 폰 스피커 다시 켜기 =="
  ./켜기.command < /dev/null | grep -v "닫아도"
  for i in $(seq 1 40); do pgrep -x sysbridge >/dev/null && break; sleep 1; done   # 켜기가 새 창에서 돌 수도 있음
  pgrep -x sysbridge >/dev/null || { echo "폰 스피커가 안 켜졌어요 — 로그를 확인하세요"; bye 1; }
  [ "$WAS_ON" = 1 ] || echo "(원래 꺼져 있었지만 재기 위해 켰어요. 끄려면 끄기.command)"
fi

echo
echo "== 5) 실제 지연 재기 =="
pgrep -x sysbridge >/dev/null || { echo "폰 스피커가 꺼져 있어요. 켜기.command로 켠 뒤 다시 여세요."; bye 1; }
echo "유튜브·음악을 멈추고, Mac 볼륨을 평소 듣는 크기로 두세요."
echo "폰에서 '띵' 소리가 4번(약 10초) 납니다. 조용히 기다려 주세요."
read -r -p "준비되면 엔터 (건너뛰려면 s 엔터 → 기본값 1119 ms) " ans
if [ "$ans" = s ]; then
  "$AV" --get
else
  sleep 1
  "$AV" --gain-db -9 --set --out "$LOG.result.json"
  rc=$?
  if [ $rc = 2 ]; then
    echo "소리가 작거나 주변이 시끄러워 잘 못 쟀어요. Mac 볼륨을 조금 올리고 MEASURE_ONLY=1로 다시 재거나, 그대로 두면 기본값을 씁니다."
  elif [ $rc = 3 ]; then
    echo "잰 값은 기록만 했어요 — macOS가 지연 값을 실행 중에 바꾸는 걸 막아서, 장치에 빌드된 값(1119 ms)을 씁니다."
    echo "잰 값이 1119 ms와 30 ms 넘게 다르면 GitHub 이슈로 알려 주세요 (드라이버 기본값을 고쳐 다시 설치)."
  fi
fi
echo
echo "끝. 웨일/크롬에서 유튜브 페이지를 새로고침하고 입 모양과 소리가 맞는지 보세요."
echo "아직 어긋나면 어느 쪽이 먼저인지(소리가 늦다/빠르다) GitHub 이슈로 알려 주세요."
bye 0
