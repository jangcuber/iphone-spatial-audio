#!/bin/bash
# 자동 전환(에어팟처럼) 설치/끄기 — 폰 7대가 Mac과 윈도우 PC 중 소리가 나는 쪽으로 알아서 붙습니다. 소리 없음.
#  사용:  run/21_auto_switch.command [PC_IP]      설치·켜기 (PC_IP를 안 주면 폰이 지금 보고 있는 Mac 아닌 서버)
#         OFF=1 run/21_auto_switch.command        끄기 (폰은 지금 서버에 그대로 남음)
#  폰 쪽: 패키지 io.github.jangcuber.snapswitch = /var/jb/usr/bin/snapswitch (LaunchDaemon, mobile 권한), 설정 /var/mobile/Library/Preferences/snapswitch.conf,
#         로그 /var/mobile/Library/Logs/snapswitch.log. 동작 설명은 ios_client/snapswitch/snapswitch 맨 위.
#  양쪽 컴퓨터 모두 제어 포트 1705(Snapcast JSON-RPC Server.GetStatus)에서 스트림 상태 playing/idle을 알려야 함.
#  Mac IP가 바뀌면(DHCP) 이 스크립트를 다시 실행.
cd "$(dirname "$0")/.." || exit 1
. run/phones.sh
KEY="${SSH_KEY:-$HOME/.ssh/spatial_phones_ed25519}"
MACIP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
PCIP=${1:-}
sshp() { ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias="spk-$1" -o StrictHostKeyChecking=accept-new "mobile@$2" "${@:3}"; }
scpp() { scp -q -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias="spk-$1" "${@:3}" "mobile@$2:/tmp/"; }

if [ -z "$PCIP" ] && [ -z "${OFF:-}" ]; then
  for nv in $PH_PHONES; do
    s=$(sshp "${nv%%=*}" "${nv#*=}" ". /var/jb/etc/snapclient.conf; echo \$SERVER" </dev/null 2>/dev/null)
    [ -n "$s" ] && [ "$s" != "$MACIP" ] && { PCIP=$s; break; }
  done
fi
if [ -z "${OFF:-}" ]; then
  [ -n "$MACIP" ] && [ -n "$PCIP" ] || { echo "Mac IP($MACIP) 또는 PC IP($PCIP)를 모르겠어요. PC IP를 붙여 다시: run/21_auto_switch.command 192.168.1.x"; read -r -t 30 _; exit 1; }
  echo "자동 전환 설치: Mac $MACIP, PC $PCIP (동시에 시작하면 Mac 우선)"
  printf 'SOURCES="mac=%s pc=%s"\nENABLED=1\n' "$MACIP" "$PCIP" > /tmp/snapswitch.conf
fi
# 패키지(.deb)로 설치: 폰의 무비밀번호 sudo는 snapclient-ctl·launchctl·dpkg만 허용 (run/04)
DEB=/tmp/snapswitch.deb
if [ -z "${OFF:-}" ]; then
  D=ios_client/snapswitch/deb; mkdir -p $D/var/jb/usr/bin $D/var/jb/Library/LaunchDaemons
  install -m 755 ios_client/snapswitch/snapswitch $D/var/jb/usr/bin/snapswitch
  install -m 644 ios_client/snapswitch/io.github.jangcuber.snapswitch.plist $D/var/jb/Library/LaunchDaemons/
  dpkg-deb --root-owner-group -Zgzip -b $D "$DEB" >/dev/null || { echo "패키지 만들기 실패"; exit 1; }
fi
one() {   # one <이름> <IP>
  local n=$1 ip=$2 out
  if [ -n "${OFF:-}" ]; then
    out=$(sshp "$n" "$ip" "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
      sudo -n launchctl unload -w /var/jb/Library/LaunchDaemons/io.github.jangcuber.snapswitch.plist 2>/dev/null; echo 꺼짐" </dev/null 2>&1)
  else
    scpp "$n" "$ip" "$DEB" /tmp/snapswitch.conf 2>/dev/null || { echo "  $n: 복사 실패"; return; }
    out=$(sshp "$n" "$ip" "export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
      mkdir -p /var/mobile/Library/Preferences && mv -f /tmp/snapswitch.conf /var/mobile/Library/Preferences/snapswitch.conf
      sudo -n dpkg -i /tmp/snapswitch.deb >/dev/null 2>&1; rm -f /tmp/snapswitch.deb; sleep 2
      ps -ax -o command= | grep -q '[b]ash /var/jb/usr/bin/snapswitch' && echo 켜짐 || echo '실행 안 됨'" </dev/null 2>&1 | tail -1)
  fi
  echo "  $n: $out"
}
for nv in $PH_PHONES; do one "${nv%%=*}" "${nv#*=}" & done
wait
rm -f /tmp/snapswitch.conf "$DEB"
echo "끝. 폰 로그: ssh로 /var/mobile/Library/Logs/snapswitch.log"
read -r -t 30 -p "이 창은 닫아도 됩니다" _ || true
