#!/bin/bash
# 폰 스피커 끄기 — 더블클릭 한 번. Mac 소리가 원래 스피커(또는 이어폰)로 돌아옵니다.
#  - 폰은 그대로 두면 됩니다(다음에 켜면 알아서 다시 붙음).
cd "$(dirname "$0")" || exit 1
if ! pgrep -x sysbridge >/dev/null && ! pgrep -x snapserver >/dev/null; then
  echo "이미 꺼져 있어요."
else
  pkill -INT -x sysbridge 2>/dev/null          # INT로 끝내야 Mac 출력 장치를 원래대로 돌려놓음
  for i in $(seq 1 25); do pgrep -x sysbridge >/dev/null || break; sleep 0.2; done
  pkill -KILL -x sysbridge 2>/dev/null
  pkill -x snapserver 2>/dev/null
  for i in $(seq 1 25); do pgrep -x snapserver >/dev/null || break; sleep 0.2; done
  pkill -KILL -x snapserver 2>/dev/null
  echo "껐어요. Mac 소리는 원래 스피커로 나와요."
fi
read -r -t 10 -p "이 창은 닫아도 됩니다" _ || true
