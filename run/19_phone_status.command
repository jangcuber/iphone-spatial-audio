#!/bin/bash
# 폰 상태 보기 — 7대 + 마이크 폰의 Wi-Fi 응답, 서버 연결, 배터리 (조회만, 소리 없음, 약 5~15초)
#  - snapserver·폰 설정·phones.txt는 읽기만. 폰에 바꾸는 것은 배터리 읽는 작은 프로그램(/var/mobile/battinfo) 복사뿐
#    (iOS 17 이상은 mobile 권한 ioreg가 비어 있어 IOPowerSources로 읽음, iOS 16은 ioreg)
#  - IP가 바뀌었을 수 있어 phones.txt의 IP로 먼저 보고, 없는 폰은 같은 Wi-Fi 대역에서 SSH 열린 기기를 찾아 이름으로 구분
#  - 응답 없는 폰: 꺼짐/잠듦이거나 재부팅으로 탈옥이 풀렸을 수 있음 → 그 폰에서 Dopamine 앱 > Jailbreak
#  - STATUS_TSV=1 이면 표 대신 탭 구분 줄만 출력 (폰 상태 앱이 씀)
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
. run/phones.sh
KEY="$SSH_KEY"
# 키가 없으면 새로 만든다 (비밀번호 없는 ed25519, 이 Mac에서만 씀)
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C spatial-phones -f "$KEY"
PT=run/phones.txt
BI="$ROOT/ios_client/battinfo/battinfo"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SSHO=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

if [ ! -x "$BI" ] || [ "$BI.c" -nt "$BI" ]; then
  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -O2 -o "$BI" "$BI.c" \
    -framework CoreFoundation -framework IOKit 2>/dev/null && ldid -S "$BI" 2>/dev/null || rm -f "$BI"
fi

# 폰 하나 조회 → $TMP/ip_<IP>: 이름|배터리%|충전기|충전 중|완충|snapclient 실행 수|iOS|battinfo 있음
probe() {   # probe <IP>
  ssh "${SSHO[@]}" "mobile@$1" '
    NAME=; [ -f /var/jb/etc/snapclient.conf ] && . /var/jb/etc/snapclient.conf
    [ -z "$NAME" ] && [ -x /var/mobile/iosrec ] && NAME=mic
    if [ -x /var/mobile/battinfo ] && B=$(/var/mobile/battinfo 2>/dev/null); then :
    else
      I=$(ioreg -rn AppleSmartBattery -w0 2>/dev/null)
      v() { echo "$I" | sed -n "s/.*\"$1\" = \([A-Za-z0-9]*\).*/\1/p" | head -1; }
      B="$(v CurrentCapacity)|$(v ExternalConnected)|$(v IsCharging)|$(v FullyCharged)"
    fi
    R=$(ps -ax -o comm= | grep -c "[s]napclient$")
    echo "$NAME|$B|$R|$(sw_vers -productVersion 2>/dev/null)|$([ -x /var/mobile/battinfo ] && echo 1)"
  ' </dev/null > "$TMP/ip_$1" 2>/dev/null || rm -f "$TMP/ip_$1"
}
# iOS 16 ioreg로 못 읽었고 battinfo가 없으면 복사 후 다시 조회
fill_battery() {   # fill_battery <IP>
  local f="$TMP/ip_$1"
  [ -f "$f" ] && [ -x "$BI" ] || return
  IFS='|' read -r _ bat _ _ _ _ _ has < "$f"
  [ -z "$bat" ] && [ -z "$has" ] || return
  scp -q "${SSHO[@]}" "$BI" "mobile@$1:/var/mobile/battinfo" </dev/null 2>/dev/null && probe "$1"
}

# 1) phones.txt의 IP부터
WANT=$(awk '($1~/^node-/ || $1=="mic") {print $1}' "$PT")
for ip in $(awk '($1~/^node-/ || $1=="mic") && $3!="-" {print $3}' "$PT"); do probe "$ip" & done
wait
found() { cat "$TMP"/ip_* 2>/dev/null | cut -d'|' -f1; }
MISSING=$(for n in $WANT; do found | grep -qx "$n" || echo "$n"; done)

# 2) 못 찾은 폰이 있으면 같은 Wi-Fi 대역에서 SSH(22) 열린 기기 찾기
MYIP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
if [ -n "$MISSING" ] && [ -n "$MYIP" ]; then
  NET=${MYIP%.*}
  [ -z "$STATUS_TSV" ] && echo "찾는 중: $(echo $MISSING) — $NET.1~254 훑는 중..."
  for i in $(seq 1 254); do
    ip="$NET.$i"; { [ "$ip" = "$MYIP" ] || [ -f "$TMP/ip_$ip" ]; } && continue
    ( nc -z -G 2 "$ip" 22 2>/dev/null && probe "$ip" ) &
  done
  wait
fi
for f in "$TMP"/ip_*; do [ -f "$f" ] && fill_battery "${f##*/ip_}" & done
wait

# 3) 서버 쪽 연결 상태 (snapserver JSON-RPC 조회만)
"$ROOT/tools/.venv/bin/python" - > "$TMP/server" 2>/dev/null <<'EOF'
import json, socket
s = socket.create_connection(("127.0.0.1", 1705), timeout=3); f = s.makefile("rwb")
f.write(b'{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}\r\n'); f.flush()
while True:
    m = json.loads(f.readline())
    if m.get("id") == 1: break
for g in m["result"]["server"]["groups"]:
    for c in g["clients"]:
        print(c["id"], "O" if c.get("connected") else "X")
EOF
SRV=$([ -s "$TMP/server" ] && echo 켜짐 || echo 꺼짐)
ON=$(pgrep -x sysbridge >/dev/null && echo 켜짐 || echo 꺼짐)

# 4) 출력: 이름 채널 IP Wi-Fi 서버연결 배터리 충전 iOS
ROWS=()
while read -r n ch ip _; do
  case "$n" in node-*|mic) ;; *) continue;; esac
  f=$(grep -l "^$n|" "$TMP"/ip_* 2>/dev/null | head -1)
  sv=-; [ "$n" != mic ] && { sv=$(awk -v n=$n '$1==n{print $2}' "$TMP/server"); [ -z "$sv" ] && sv="?"; }
  if [ -z "$f" ]; then
    ROWS+=("$n	$ch	$ip?	X	$sv	-	-	-")
    continue
  fi
  nip=${f##*/ip_}
  IFS='|' read -r _ bat ext chg full run ver _ < "$f"
  if [ "$ext" = Yes ]; then
    if [ "$chg" = Yes ]; then c="충전 중"; elif [ "$full" = Yes ]; then c="완충"; else c="연결(대기)"; fi
  elif [ -n "$ext" ]; then c="배터리"; else c="?"; fi
  [ "$n" != mic ] && [ "$run" = 0 ] && sv="$sv(꺼짐)"
  ROWS+=("$n	$ch	$nip	O	$sv	${bat:-?}%	$c	$ver")
done < "$PT"

if [ -n "$STATUS_TSV" ]; then
  echo "#	$(date '+%H:%M:%S')	$MYIP	$SRV	$ON"
  printf '%s\n' "${ROWS[@]}"
  exit 0
fi
echo
echo "폰 상태 $(date '+%Y-%m-%d %H:%M')   (Mac $MYIP, 폰 스피커 $ON, 서버 $SRV)"
{ printf '이름\t채널\tIP\tWi-Fi\t서버\t배터리\t충전\tiOS\n'; printf '%s\n' "${ROWS[@]}"; } | column -t -s $'\t'
echo
echo "서버: O = snapserver에 붙어 있음, X = 끊김, (꺼짐) = 폰에서 snapclient가 안 돎"
echo "충전 '연결(대기)' = 충전기는 꽂혀 있지만 iOS가 80% 근처에서 충전을 쉬는 상태(정상)"
echo "Wi-Fi X = 꺼짐/잠듦이거나 탈옥이 풀림 → 폰 화면을 눌러 깨우고, 안 되면 Dopamine 앱 > Jailbreak"
NEW=$(printf '%s\n' "${ROWS[@]}" | awk -F'\t' '$4=="O"' | while IFS=$'\t' read -r n _ nip _; do
  old=$(awk -v n=$n '$1==n{print $3}' "$PT"); [ "$old" != "$nip" ] && printf ' %s=%s' "$n" "$nip"; done)
[ -n "$NEW" ] && echo "IP가 phones.txt와 다른 폰:$NEW  (phones.txt는 고치지 않음)"
[ -t 0 ] && { read -r -p "엔터를 누르면 닫습니다" _ || true; }
exit 0
