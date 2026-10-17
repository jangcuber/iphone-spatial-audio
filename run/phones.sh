# 다른 run 스크립트가 읽어 쓰는 폰 목록 (run/phones.txt, run/14_add_phone.command가 고침)
#  PH_PHONES = "node-01=IP node-02=IP ...", PH_ACTIVE = "FL,FR,C,...", PH_N = 대수, PH_MIC = 마이크 폰 IP
_rd="$(dirname "${BASH_SOURCE[0]}")"
# 개인 설정(SSH 키 경로 등): run/config.sh (git에 안 올라감, config.example.sh를 복사해서 만듦)
[ -f "$_rd/config.sh" ] && . "$_rd/config.sh"
SSH_KEY=${SSH_KEY:-$HOME/.ssh/spatial_phones_ed25519}
_pt="$_rd/phones.txt"
# 처음이면 예시에서 복사 (run/14_add_phone.command가 폰을 넣을 때 채움)
[ -f "$_pt" ] || cp "$_rd/phones.example.txt" "$_pt"
PH_PHONES=$(awk '$1~/^node-/ && $3!="-" {printf "%s%s=%s", (n++?" ":""), $1, $3}' "$_pt")
PH_ACTIVE=$(awk '$1~/^node-/ && $3!="-" {printf "%s%s", (n++?",":""), $2}' "$_pt")
PH_N=$(awk '$1~/^node-/ && $3!="-"' "$_pt" | wc -l | tr -d ' ')
PH_MIC=$(awk '$1=="mic" && $3!="-" {print $3}' "$_pt")
