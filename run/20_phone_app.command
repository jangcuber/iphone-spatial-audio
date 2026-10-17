#!/bin/bash
# 폰 스피커 앱 만들기 — 더블클릭 한 번이면 프로젝트 폴더에 "폰 스피커.app"이 생기고 열립니다.
#  - 앱: 폰 7대 + 마이크 폰의 Wi-Fi·서버 연결·배터리를 15초마다 보여 주고, 켜기/끄기 버튼(창 없이 앱 안에서 켜기.command / 끄기.command 실행, 처음 켤 때 마이크 권한 1번)
#  - 다음부터는 "폰 스피커.app"을 바로 더블클릭 (Dock에 끌어 두면 편함). 소스: tools/statusapp/PhoneStatus.swift
cd "$(dirname "$0")/.." || exit 1
APP="폰 스피커.app"
SRC=tools/statusapp/PhoneStatus.swift
if [ ! -x "$APP/Contents/MacOS/PhoneStatus" ] || [ "$SRC" -nt "$APP/Contents/MacOS/PhoneStatus" ]; then
  echo "앱 만드는 중..."
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.jangcuber.phonestatus</string>
<key>CFBundleName</key><string>폰 스피커</string>
<key>CFBundleExecutable</key><string>PhoneStatus</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Mac 소리를 받는 가상 장치(SpatialPhones)의 입력을 읽어 아이폰 스피커로 보냅니다. 권한이 없으면 폰이 조용해요.</string>
<key>NSAudioCaptureUsageDescription</key><string>Mac 소리를 아이폰 스피커로 보내기 위해 시스템 오디오를 받습니다.</string>
</dict></plist>
PL
  swiftc -O -parse-as-library -o "$APP/Contents/MacOS/PhoneStatus" "$SRC" \
    || { echo "앱 만들기 실패 — 로그를 확인하세요"; read -r _; exit 1; }
  codesign -s - --force "$APP" 2>/dev/null
fi
open "$APP"
