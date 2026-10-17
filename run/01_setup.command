#!/bin/bash
# 1단계: Mac 환경 확인 + snapserver/ffmpeg 설치 + 측정 도구 테스트
# Finder에서 더블클릭하면 터미널이 열리고 실행됩니다. 결과는 run/logs/ 에 저장됩니다.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
mkdir -p run/logs
LOG="run/logs/01_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1

for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)" && break; done

echo "==== 1. Mac 환경"
sw_vers
echo "arch: $(uname -m)"
system_profiler SPHardwareDataType 2>/dev/null | grep -E "Model Name|Model Identifier|Chip|Processor Name|Memory"
echo "Wi-Fi IP(en0): $(ipconfig getifaddr en0 2>/dev/null || echo 없음)"
echo "유선/기타 IP: $(ipconfig getifaddr en1 2>/dev/null || echo 없음)"

echo
echo "==== 2. Homebrew / snapserver / ffmpeg"
if ! command -v brew >/dev/null; then
  echo "Homebrew가 없습니다. https://brew.sh 의 설치 명령을 터미널에 붙여 넣어 설치한 뒤 이 파일을 다시 실행하세요."
  read -r -p "엔터를 누르면 닫힙니다" _; exit 1
fi
brew --version | head -1
brew list snapcast >/dev/null 2>&1 || brew install snapcast
brew list ffmpeg   >/dev/null 2>&1 || brew install ffmpeg
echo "snapserver: $(snapserver --version 2>&1 | head -1)"
echo "ffmpeg: $(ffmpeg -version 2>&1 | head -1)"

echo
echo "==== 3. Python 가상환경 + 테스트"
PY3=$(command -v python3)
echo "python3: $PY3 ($($PY3 --version 2>&1))"
[ -x tools/.venv/bin/python ] || "$PY3" -m venv tools/.venv
tools/.venv/bin/pip install -q --upgrade pip numpy pytest
(cd tools && .venv/bin/python -m pytest -q -p no:cacheprovider tests)
TEST_RC=$?

echo
echo "==== 4. 마이크(오디오 입력) 장치 목록"
ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/audio devices/,$p'

echo
if [ $TEST_RC -eq 0 ]; then echo "==== 완료: 준비가 끝났습니다. 다음은 폰마다 run/14_add_phone.command (README 참고)"; else echo "==== 테스트 실패: 로그를 확인하세요 ($LOG)"; fi
read -r -p "엔터를 누르면 닫힙니다" _
