#!/bin/bash
# Scan the repo (tracked + untracked, not ignored) for things that should not be published:
# real LAN IPs, MAC addresses, iPhone UDIDs, SSH keys, home paths, e-mail addresses, tokens, recordings/logs.
# Example values used in docs (192.168.1.x, 127.0.0.1, 10.255.255.255, all-zero UDID) are allowed.
# Usage: scripts/scan_personal.sh        exit 0 = clean, 1 = something to look at
cd "$(dirname "$0")/.." || exit 1
FILES=$( { git -c core.quotepath=off ls-files; git -c core.quotepath=off ls-files --others --exclude-standard; } 2>/dev/null | sort -u | grep -v '^LICENSE$' | grep -v '^scripts/scan_personal.sh$')
[ -n "$FILES" ] || FILES=$(find . -type f -not -path './.git/*' | sed 's#^\./##')
hits=0
check() {  # check <label> <extended regex> [allow regex]
  local out
  out=$(printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 grep -nIE "$2" 2>/dev/null | { [ -n "${3:-}" ] && grep -vE "$3" || cat; })
  if [ -n "$out" ]; then echo "== $1"; echo "$out" | cut -c1-200; hits=1; fi
}
check "LAN IP addresses" '\b(192\.168|10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+\b' \
      '192\.168\.1\.(x|[0-9]+)|10\.255\.255\.255|192\.168\.\)|\^\(192|192\\\.168|172\\\.|10\\\.'
check "MAC addresses" '\b([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b' 'aa-bb-cc-dd-ee-ff|aa:bb:cc'
check "iPhone UDIDs" '\b0000[0-9]{4}-[0-9A-Fa-f]{16}\b' '0000[0-9]{4}-0{16}'
check "SSH private/public keys" 'BEGIN [A-Z ]*PRIVATE KEY|ssh-(ed25519|rsa) AAAA'
check "Home directory paths" '/Users/[A-Za-z0-9._-]+|C:\\\\Users\\\\[A-Za-z0-9._-]+|C:\\Users\\[A-Za-z0-9._-]+' '/Users/\.\.\.|%USERPROFILE%'
check "E-mail addresses" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' 'noreply@|@example\.|git@github\.com'
check "Tokens / passwords" '(gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|password *= *["'"'"'][^"'"'"']+)'
bad=$(printf '%s\n' "$FILES" | grep -E '\.(wav|caf|mov|mp4|m4a|log|deb|pcap)$|(^|/)(logs|recordings)/|known_hosts|id_ed25519|id_rsa' || true)
[ -n "$bad" ] && { echo "== Files that look like logs/recordings/keys/binaries"; echo "$bad"; hits=1; }
[ $hits = 0 ] && echo "scan_personal: clean" || echo "scan_personal: review the lines above"
exit $hits
