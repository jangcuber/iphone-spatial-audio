#!/bin/bash
# 새 탈옥 아이폰을 스피커로 추가 — 한 대씩, 약 1~2분, 소리는 내지 않습니다
#  준비(폰에서 손으로): Dopamine 탈옥, Sileo에서 OpenSSH 설치, mobile 비밀번호 설정, Mac과 같은 Wi-Fi (README 참고)
#  1) 새 폰을 USB로 Mac에 꽂고 잠금 해제 → "이 컴퓨터를 신뢰" 2) 이 파일 더블클릭 3) 자리 번호 확인(엔터)
#  4) mobile 비밀번호를 1~2번 입력 (Dopamine에서 정한 비밀번호, 이 폰에선 이번이 마지막)
#  Wi-Fi로 할 때: run/14_add_phone.command 192.168.1.x [1-7]
#  보정용 마이크 폰: 자리 번호 대신 m 입력 (또는 run/14_add_phone.command <IP> m) → 녹음기(iosrec)만 넣음, 스피커 아님
#  하는 일: Mac 공개키 + 관리 명령만 비밀번호 없는 sudo(run/04와 같음) → 기존 폰과 같은 snapclient 버전·설정
#          → 자기 채널(1 FL, 2 FR, 3 C, 4 SL, 5 SR, 6 HL, 7 HR) → 자동 실행 → 로그로 확인 → run/phones.txt에 IP 기록
#  이미 목록에 있는 다른 폰은 버전·설정을 읽기만 합니다. CHECK_ONLY=1이면 아무것도 바꾸지 않고 연결·준비 상태만 봅니다.
#  패키지: ios_client/dist/*.deb (ios_client/build.sh로 빌드하거나 GitHub Releases에서 받기)
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)" && break; done
mkdir -p run/logs
LOG="run/logs/14_add_phone_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "$LOG") 2>&1
CHECK_ONLY=${CHECK_ONLY:-0}
. run/phones.sh
KEY="$SSH_KEY"
# 키가 없으면 새로 만든다 (비밀번호 없는 ed25519, 이 Mac에서만 씀)
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C spatial-phones -f "$KEY"
PHONES_TXT=run/phones.txt
CHS=(FL FR C SL SR HL HR)
WHERE=("앞 왼쪽" "앞 오른쪽" "가운데" "왼쪽 뒤" "오른쪽 뒤" "높은 곳 왼쪽" "높은 곳 오른쪽")
RP='export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin;'
done_wait() { echo; echo "로그: $LOG"; read -r -p "엔터를 누르면 닫힙니다" _ || true; exit "${1:-0}"; }
command -v iproxy >/dev/null || brew install libimobiledevice

IPX=""
cleanup() { [ -n "$IPX" ] && kill "$IPX" 2>/dev/null; [ -n "$CTL" ] && ssh -O exit -o ControlPath="$CTL" x 2>/dev/null; }
trap cleanup EXIT
field() { awk -v n="$1" -v c="$2" '$1==n {print $c}' "$PHONES_TXT"; }

# ---- 1. 대상 폰
TARGET=${1:-}; SLOT=${2:-}; UDID=""; IOS=""
case "$TARGET" in usb:*) UDID=${TARGET#usb:}; TARGET=usb;; esac   # run/14_add_phone.command usb:<UDID> 5
if [ -z "$TARGET" ]; then
  LIST=()
  for u in $(idevice_id -l 2>/dev/null | sort -u); do
    awk -v u="$u" '$4==u && ($1~/^node-0[1-7]$/ || $1=="mic")' "$PHONES_TXT" | grep -q . && continue   # 이미 목록에 있는 폰·마이크 폰은 빼고
    LIST+=("$u")
  done
  if [ ${#LIST[@]} -eq 0 ]; then
    echo "USB로 연결된 새 폰이 안 보입니다. 폰 잠금을 풀고 '이 컴퓨터를 신뢰'를 눌렀는지 확인하세요."
    read -r -p "Wi-Fi IP로 하려면 입력 (설정 > Wi-Fi > (i), 엔터 = 끝): " TARGET
    [ -n "$TARGET" ] || done_wait 1
  elif [ ${#LIST[@]} -eq 1 ]; then
    UDID=${LIST[0]}
  else
    echo "USB로 연결된 폰:"
    for i in "${!LIST[@]}"; do
      echo "  $((i+1))) $(ideviceinfo -u "${LIST[$i]}" -k DeviceName 2>/dev/null) / iOS $(ideviceinfo -u "${LIST[$i]}" -k ProductVersion 2>/dev/null) / ${LIST[$i]}"
    done
    read -r -p "몇 번 폰? " k; UDID=${LIST[$((k-1))]}
    [ -n "$UDID" ] || done_wait 1
  fi
fi

SSHO=(-i "$KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=10)
if [ -n "$UDID" ]; then
  IOS=$(ideviceinfo -u "$UDID" -k ProductVersion 2>/dev/null)
  echo "USB 폰: $(ideviceinfo -u "$UDID" -k DeviceName 2>/dev/null) / iOS $IOS / $UDID"
  LPORT=$((22000 + RANDOM % 1000))
  iproxy "$LPORT" 22 -u "$UDID" >/dev/null 2>&1 & IPX=$!
  sleep 1.5
  HOST=127.0.0.1; SSHO+=(-o Port=$LPORT -o HostKeyAlias=sa-$UDID)
else
  HOST=$TARGET; SSHO+=(-o HostKeyAlias=new-$TARGET)
fi
CTL="/tmp/sa13-$$-%C"
SSHO+=(-o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=300)
rsh() { ssh "${SSHO[@]}" "mobile@$HOST" "$RP $1" </dev/null; }

# ---- 2. 첫 접속: 공개키 + sudo 규칙 (비밀번호는 여기서만)
echo
echo "==== 1. 접속 (mobile 비밀번호를 물으면 입력)"
PUB=$(cat "$KEY.pub")
RULE='mobile ALL=(root) NOPASSWD: /var/jb/usr/bin/snapclient-ctl, /var/jb/usr/bin/launchctl, /var/jb/usr/bin/dpkg'
if [ "$CHECK_ONLY" = 1 ]; then
  ssh "${SSHO[@]}" -o BatchMode=yes "mobile@$HOST" true </dev/null || { echo "키로 접속 안 됨 (CHECK_ONLY라 비밀번호 접속·키 등록은 건너뜀)"; done_wait 1; }
else
  ssh -t "${SSHO[@]}" "mobile@$HOST" "$RP
    [ -d /var/jb/usr/bin ] || { echo 'NOJB'; exit 3; }
    mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    grep -qF '$PUB' ~/.ssh/authorized_keys || { echo '$PUB' >> ~/.ssh/authorized_keys; echo '  Mac 공개키 등록'; }
    if sudo -n /var/jb/usr/bin/launchctl list >/dev/null 2>&1; then echo '  비밀번호 없는 sudo: 이미 됨'; exit 0; fi
    echo '  sudo 규칙 설치 (비밀번호를 한 번 더 물을 수 있어요)'
    sudo -v || exit 4
    echo '$RULE' > /tmp/sa_sudoers
    sudo /var/jb/bin/sh -c 'install -o root -g wheel -m 440 /tmp/sa_sudoers /var/jb/etc/sudoers.d/snapclient &&
      if /var/jb/usr/bin/sudo -l -U mobile >/dev/null 2>&1; then echo \"  sudo 규칙 설치\"; else rm -f /var/jb/etc/sudoers.d/snapclient; echo \"  규칙 오류: 되돌림\"; fi'
    rm -f /tmp/sa_sudoers; sudo -k
    sudo -n /var/jb/usr/bin/launchctl list >/dev/null"
  RC=$?
  case $RC in
    0) ;;
    3) echo "탈옥 상태가 아닙니다: 폰에서 Dopamine 앱을 열어 Jailbreak를 누른 뒤 다시 실행하세요"; done_wait 1;;
    *) echo "접속·sudo 설정 실패(코드 $RC): OpenSSH 설치, 비밀번호, 같은 Wi-Fi(또는 USB 신뢰)를 확인하세요"; done_wait 1;;
  esac
fi

# ---- 3. 폰 정보: 이미 스피커인지, iOS, Wi-Fi IP
INFO=$(rsh '. /var/jb/etc/snapclient.conf 2>/dev/null; echo "OLDNAME=$NAME";
  echo "VER=$(dpkg-query -W -f="\${Version}" io.github.jangcuber.snapclient 2>/dev/null)";
  echo "IOS=$(sw_vers -productVersion 2>/dev/null)";
  echo "WIFI=$(ifconfig en0 2>/dev/null | sed -n "s/.*inet \([0-9.]*\) .*/\1/p" | head -1)"')
eval "$(echo "$INFO" | grep -E '^(OLDNAME|VER|IOS|WIFI)=[A-Za-z0-9._~:-]*$')"
MACIP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
if [ -z "$WIFI" ] && [ -n "$UDID" ]; then   # ifconfig 없는 iOS(16·17): 폰이 Wi-Fi로 Mac에 한 번 접속 → 보낸 주소가 폰 IP
  PORT=$((47000 + RANDOM % 1000)); TMPIP=$(mktemp)
  python3 - "$PORT" > "$TMPIP" 2>/dev/null <<'PYEOF' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(1); s.settimeout(10)
try:
    c, a = s.accept(); print(a[0]); c.close()
except OSError:
    pass
PYEOF
  LPID=$!; sleep 0.5
  rsh "[ -x /var/jb/bin/bash ] && /var/jb/bin/bash -c 'exec 3<>/dev/tcp/$MACIP/$PORT' 2>/dev/null"
  wait $LPID; WIFI=$(head -1 "$TMPIP"); rm -f "$TMPIP"
fi
[ -z "$WIFI" ] && [ -z "$UDID" ] && WIFI=$TARGET
case "$OLDNAME" in node-0[1-7])   # 이미 목록에 같은 IP/UDID로 있는 폰이면 멈춤 (다시 하려면 phones.txt에서 그 줄 IP를 "-"로)
  if [ -n "$WIFI" ] && [ "$WIFI" = "$(field "$OLDNAME" 3)" ] || [ -n "$UDID" ] && [ "$UDID" = "$(field "$OLDNAME" 4)" ]; then
    echo "이 폰은 이미 $OLDNAME(${WHERE[${OLDNAME#node-0}-1]})입니다. 다시 설치하려면 run/phones.txt의 그 줄 IP를 '-'로 바꾸세요."; done_wait 1
  fi;;
esac
echo "  iOS ${IOS:-?}, Wi-Fi IP ${WIFI:-못 찾음}, snapclient ${VER:-없음}"
if [ -z "$WIFI" ]; then
  read -r -p "  폰의 Wi-Fi IP를 입력하세요 (설정 > Wi-Fi > 연결된 이름 옆 (i)): " WIFI
fi

# ---- 4. 자리 번호 (1 FL ~ 7 HR)
if [ -z "$SLOT" ]; then
  case "$OLDNAME" in node-0[1-7]) DEF=${OLDNAME#node-0};; *)
    DEF=""; for n in 1 2 3 4 5 6 7; do [ "$(field node-0$n 3)" = "-" ] && { DEF=$n; break; }; done
    [ -n "$DEF" ] || DEF=1;; esac
  echo
  for n in 1 2 3 4 5 6 7; do echo "  $n번 = ${WHERE[$n-1]} (${CHS[$n-1]})   $( [ "$(field node-0$n 3)" != "-" ] && echo "이미 있음: $(field node-0$n 3)")"; done
  echo "  m  = 보정용 마이크 폰 (스피커 아님)   지금: $(field mic 3)"
  read -r -p "이 폰은 몇 번? [엔터 = $DEF]: " SLOT
  SLOT=${SLOT:-$DEF}
fi
case "$SLOT" in [1-7]|m) ;; *) echo "1~7 또는 m 이어야 합니다"; done_wait 1;; esac
if [ "$SLOT" = m ]; then   # 마이크 폰: 녹음기만 넣고 목록의 mic 줄을 이 폰으로
  [ "$CHECK_ONLY" = 1 ] && { echo "CHECK_ONLY: 마이크 폰 설치는 건너뜀"; done_wait 0; }
  [ -x tools/recorder/iosrec ] || { echo "tools/recorder/iosrec가 없습니다 (tools/recorder/build_iosrec.sh)"; done_wait 1; }
  scp -q "${SSHO[@]}" tools/recorder/iosrec "mobile@$HOST:/var/mobile/iosrec" </dev/null && rsh "chmod 755 /var/mobile/iosrec && test -x /var/mobile/iosrec" \
    || { echo "녹음기 복사 실패"; done_wait 1; }
  awk -v ip="$WIFI" -v u="${UDID:--}" -v v="${IOS:--}" '$1=="mic" {printf "%-9s %-5s %-15s %-28s %s\n", "mic", "-", ip, u, v; next} {print}' "$PHONES_TXT" > "$PHONES_TXT.new" && mv "$PHONES_TXT.new" "$PHONES_TXT"
  echo; echo "완료: 마이크 폰 = $WIFI (녹음기 설치). 보정 때 의자 머리 자리에 둡니다. 소리 녹음은 허락받은 뒤에만 해요."
  done_wait 0
fi
NAME=node-0$SLOT; IDX=$((SLOT-1)); CH=${CHS[$IDX]}

# ---- 5. 이미 설치된 다른 폰과 같은 버전·설정 (읽기만)
echo
echo "==== 2. 기존 폰 설정 읽기 (바꾸지 않음)"
REF_VER=""; REF_CONF=""
for n in 1 2 3 4 5 6 7; do
  [ "node-0$n" = "$NAME" ] && continue
  IP=$(field node-0$n 3); [ -n "$IP" ] && [ "$IP" != "-" ] || continue
  OUT=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=6 -o HostKeyAlias=spk-node-0$n -o StrictHostKeyChecking=accept-new "mobile@$IP" \
    "$RP dpkg-query -W -f='VER=\${Version}\n' io.github.jangcuber.snapclient; . /var/jb/etc/snapclient.conf; echo \"EXTRA_ARGS=\$EXTRA_ARGS\"; echo \"KEEPAWAKE=\${KEEPAWAKE:-1}\"; echo \"STATS=\${STATS:-0}\"; echo \"SERVER=\$SERVER\"" </dev/null 2>/dev/null)
  V=$(echo "$OUT" | sed -n 's/^VER=//p')
  [ -n "$V" ] || { echo "  node-0$n($IP): 응답 없음 (괜찮아요)"; continue; }
  echo "  node-0$n: $V"
  [ -z "$REF_VER" ] && { REF_VER=$V; REF_CONF=$OUT; }
done
DEB=""
[ -n "$REF_VER" ] && DEB="ios_client/dist/io.github.jangcuber.snapclient_${REF_VER}_iphoneos-arm64.deb"
if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
  DEB=$(ls ios_client/dist/io.github.jangcuber.snapclient_*_iphoneos-arm64.deb | sort -V | tail -1)
  echo "  기존 폰 버전 패키지를 못 찾아 가장 새 것 사용: $(basename "$DEB")"
fi
getc() { echo "$REF_CONF" | sed -n "s/^$1=//p"; }
EXTRA=$(getc EXTRA_ARGS); [ -n "$REF_CONF" ] || EXTRA='--speaker 2 --dac-mode 2'
KA=$(getc KEEPAWAKE); KA=${KA:-1}
STATS=$(getc STATS); STATS=${STATS:-0}
REF_SERVER=$(getc SERVER)
[ -n "$REF_SERVER" ] && [ "$REF_SERVER" != "$MACIP" ] && echo "  주의: 기존 폰 서버 주소 $REF_SERVER ≠ 지금 Mac IP $MACIP (Mac IP가 바뀌었나요?) → 새 폰은 $MACIP"
echo "  새 폰: $NAME = ${WHERE[$IDX]}($CH, 채널 $IDX), $(basename "$DEB"), EXTRA_ARGS='$EXTRA' KEEPAWAKE=$KA STATS=$STATS, 서버 $MACIP"

if [ "$CHECK_ONLY" = 1 ]; then echo; echo "CHECK_ONLY: 여기까지 확인만 했습니다 (설치 안 함)"; done_wait 0; fi

# ---- 6. 설치·설정·자동 실행
echo
echo "==== 3. 설치"
scp -q "${SSHO[@]}" "$DEB" "mobile@$HOST:/var/mobile/Documents/snapclient_new.deb" </dev/null || { echo "복사 실패"; done_wait 1; }
rsh "sudo -n dpkg -i --force-confold /var/mobile/Documents/snapclient_new.deb >/dev/null 2>&1 || { echo DPKGFAIL; exit 1; }
  sudo -n snapclient-ctl set NAME=$NAME SERVER=$MACIP CHANNEL=$IDX LATENCY=0 'EXTRA_ARGS=$EXTRA' KEEPAWAKE=$KA STATS=$STATS >/dev/null || exit 2
  sudo -n snapclient-ctl disable >/dev/null 2>&1; sudo -n snapclient-ctl enable >/dev/null || exit 3
  rm -f /var/mobile/Documents/snapclient_new.deb" || { echo "설치 실패 (코드 $?) — 이 창 내용을 확인하세요"; done_wait 1; }

# ---- 7. 확인 (소리 없이: 프로세스·잠들지 않기·로그)
sleep 8
CHK=$(rsh "grep -v '^#' /var/jb/etc/snapclient.conf;
  echo PROC=\$(ps -ax -o command= | grep -c '[/]var/jb/usr/bin/snapclient ');
  echo KA=\$(ps -ax -o command= | grep -c '[k]eepawake');
  tail -n 40 /var/mobile/Library/Logs/snapclient.log | grep -iE 'AVAudioSession|RemoteIO|connected|error|exception' | tail -5")
echo "$CHK"
PROC=$(echo "$CHK" | sed -n 's/^PROC=//p'); KAP=$(echo "$CHK" | sed -n 's/^KA=//p')
OK=1
[ "${PROC:-0}" -ge 1 ] || { echo "  ✗ snapclient가 실행 중이 아닙니다"; OK=0; }
[ "$KA" = 0 ] || [ "${KAP:-0}" -ge 1 ] || { echo "  ✗ 잠들지 않기(keepawake)가 실행 중이 아닙니다"; OK=0; }
if pgrep -x snapserver >/dev/null; then
  PY=tools/.venv/bin/python
  for i in $(seq 1 15); do
    PYTHONPATH=tools "$PY" -m spatial_tools snap ids 2>/dev/null | grep -q "$NAME" && { echo "  ✓ Mac 서버에 붙음 (지금 Mac 소리가 켜져 있으면 이 폰에서도 납니다)"; break; }
    sleep 1
  done
else
  echo "  Mac 소리 서버가 꺼져 있어 재생은 나중에(7대 점검 때) 확인합니다. 폰은 서버가 켜지면 알아서 붙어요."
fi

# ---- 8. 목록에 기록
awk -v n="$NAME" -v ch="$CH" -v ip="$WIFI" -v u="${UDID:--}" -v v="${IOS:--}" \
  '$1==n {printf "%-9s %-5s %-15s %-28s %s\n", n, ch, ip, u, v; next}
   $1=="mic" && $3==ip {printf "%-9s %-5s %-15s %-28s %s\n", "mic", "-", "-", "-", "-"; next} {print}' "$PHONES_TXT" > "$PHONES_TXT.new" && mv "$PHONES_TXT.new" "$PHONES_TXT"
[ "$(field mic 3)" = "-" ] && echo "  (이 폰은 마이크로 쓰던 폰이라 목록에서 마이크를 비웠어요. 새 마이크 폰은 이 파일로 m을 골라 넣으세요)"
echo
if [ $OK = 1 ]; then
  echo "완료: $NAME = ${WHERE[$IDX]} ($WIFI). 이 폰은 USB를 빼고 충전기에 꽂아 자리에 두세요."
  LEFT=$(for n in 1 2 3 4 5 6 7; do [ "$(field node-0$n 3)" = "-" ] && printf "%s번 " $n; done)
  [ -n "$LEFT" ] && echo "남은 폰: $LEFT → 다음 폰을 꽂고 이 파일을 다시 더블클릭" \
                 || echo "1~7번 모두 설치돼 있어요. 끝."
else
  echo "문제가 있어요. 이 창 내용을 확인하세요."
fi
done_wait 0
