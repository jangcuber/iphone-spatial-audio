#!/bin/bash
# 돌비 공간음향이 제자리 폰에서 나는지 귀로 확인 (약 30초 + 원하면 예고편 98초)
#  1) 채널 확인: 벨 한 번 + 목소리로 "왼쪽 앞", "가운데" ... 11개. 그 이름의 자리 폰에서 들리면 맞음.
#     7.1.4 채널 → 폰: 왼쪽 옆·왼쪽 뒤 → 4번(SL), 오른쪽 옆·뒤 → 5번(SR),
#     왼쪽 위·왼쪽 위 뒤 → 6번(HL), 오른쪽 위·오른쪽 위 뒤 → 7번(HR)
#  2) (선택) Apple 공식 돌비 애트모스 예고편을 QuickTime으로 재생
#  먼저 켜기.command로 폰 스피커를 켜 두세요.
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
F="$ROOT/recordings/atmos_demo/channel_check_714.caf"
TRAILER="$ROOT/recordings/atmos_demo/apple_tv_trailer_atmos.mp4"

if ! pgrep -x sysbridge >/dev/null; then
  echo "폰 스피커가 꺼져 있어요. 켜기.command를 먼저 더블클릭한 뒤 이 창을 다시 여세요."
  read -r -p "엔터를 누르면 닫습니다" _; exit 1
fi
[ -f "$F" ] || tools/.venv/bin/python tools/sysaudio/make_channel_check.py "$F" || { echo "시험 음원을 못 만들었어요"; read -r _; exit 1; }
BLOG=$(ls -t run/logs/on_*.bridge.log run/logs/atmos_*.bridge.log 2>/dev/null | head -1)

echo "== 1) 채널 확인 (27초) =="
echo "  의자에 앉아서 들으세요. 목소리가 말한 자리의 폰에서 소리가 나야 합니다."
echo "    왼쪽 앞=1번  가운데=3번  오른쪽 앞=2번  왼쪽 옆·왼쪽 뒤=4번  오른쪽 옆·오른쪽 뒤=5번"
echo "    왼쪽 위·왼쪽 위 뒤=6번(모니터 위 왼쪽)  오른쪽 위·오른쪽 위 뒤=7번(모니터 위 오른쪽)"
read -r -p "  준비되면 엔터 (소리가 납니다)" _
afplay "$F"
sleep 11   # sysbridge 상태 줄(10초마다) 한 번 더 기다림
echo
echo "  Mac이 받은 채널(최근 상태 줄):"
grep "입력 최대 dBFS" "$BLOG" | tail -3 | sed 's/^ */    /'
echo "  → '[다채널]'이고 L R C Ls Rs Rls Rrs Vhl Vhr Ltr Rtr에 숫자가 있으면 Mac 쪽은 정상."
echo

read -r -p "== 2) 돌비 애트모스 예고편(98초)도 들어볼까요? 엔터=재생, n=끝 " A
if [ "$A" != n ] && [ -f "$TRAILER" ]; then
  open -a "QuickTime Player" "$TRAILER"
  echo "  QuickTime에서 재생(스페이스바)하세요. 끝나면 이 창에서 엔터."
  read -r _
  grep "입력 최대 dBFS" "$BLOG" | tail -10 | sed 's/^ */    /'
fi
echo "로그: $BLOG"
read -r -p "엔터를 누르면 닫습니다" _
