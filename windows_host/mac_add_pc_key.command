#!/bin/bash
# Run once on the Mac (copy this file into the repo's run/ folder, then double-click):
# lets the Windows PC reach the phones over SSH. Adds the PC's public key to each phone in run/phones.txt.
# The PC key is %USERPROFILE%\.ssh\id_ed25519_phones.pub — copy that file next to this script as pc_key.pub,
# or pass its path:  run/mac_add_pc_key.command /path/to/id_ed25519_phones.pub
cd "$(dirname "$0")/.." || exit 1
. run/phones.sh
PUBF=${1:-run/pc_key.pub}
[ -f "$PUBF" ] || { echo "PC 공개키 파일이 없습니다: $PUBF"; read -r -t 30 _; exit 1; }
PUB=$(head -1 "$PUBF")
case "$PUB" in ssh-ed25519\ *|ssh-rsa\ *) ;; *) echo "공개키 형식이 아닙니다: $PUBF"; exit 1;; esac
grep -v '^\s*#' run/phones.txt | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | while read -r ip; do
  printf '%-15s ' "$ip"
  ssh -n -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "mobile@$ip" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && (grep -qF '$PUB' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUB' >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys && echo OK" \
    || echo "실패"
done
read -r -p "끝났습니다. Enter를 누르면 창이 닫힙니다."
