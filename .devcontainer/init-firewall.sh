#!/usr/bin/env bash
# 出站白名單防火牆（改寫自 Anthropic / OpenAI 官方 devcontainer 範例的做法）
#
# 重要：不接受參數。白名單路徑釘死在 image 內的 /usr/local/share/allowed-domains.txt，
# sudoers 也限定不帶參數執行，避免 agent 指向自己寫的「全部放行」清單。
#
# 重要：fail-closed。任何一步失敗（DNS 不通、GitHub 連不上、公司 proxy 擋掉）
# 都會把預設政策設成 DROP 再退出，而不是留下一個沒有防火牆的容器。
set -euo pipefail

ALLOW_FILE=/usr/local/share/allowed-domains.txt
OK_FLAG=/run/firewall-ok

rm -f "$OK_FLAG"

lockdown() {
  echo "[firewall] FAILED — 進入全封鎖狀態" >&2
  iptables -P INPUT   DROP 2>/dev/null || true
  iptables -P FORWARD DROP 2>/dev/null || true
  iptables -P OUTPUT  DROP 2>/dev/null || true
  rm -f "$OK_FLAG"
  exit 1
}
trap lockdown ERR

# 只清 filter table；nat table 保留（Docker 內建 DNS 127.0.0.11 靠它）
iptables -F
iptables -X
ipset destroy allowed-domains 2>/dev/null || true

# DNS 與 loopback
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT  -p tcp --sport 53 -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

# GitHub 官方 IP 段
echo "[firewall] fetching GitHub meta"
gh_cidrs=$(curl -fsS --connect-timeout 10 https://api.github.com/meta \
  | jq -r '(.web + .api + .git)[]' | grep -v ':' | aggregate -q)
[ -n "$gh_cidrs" ] || { echo "[firewall] GitHub meta 取得失敗" >&2; false; }
while read -r cidr; do
  [ -n "$cidr" ] && ipset add allowed-domains "$cidr" -exist
done <<< "$gh_cidrs"

# 白名單網域（啟動當下解析；CDN 換 IP 時重啟容器即可）
resolved=0
while read -r domain; do
  ips=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [ -z "$ips" ]; then echo "[firewall] WARN 無法解析 $domain"; continue; fi
  for ip in $ips; do ipset add allowed-domains "$ip" -exist; done
  resolved=$((resolved + 1))
done < <(grep -vE '^\s*(#|$)' "$ALLOW_FILE")
[ "$resolved" -gt 0 ] || { echo "[firewall] 沒有任何網域解析成功" >&2; false; }

# 允許主機所在網段（port forwarding / 編輯器連線需要）
HOST_IP=$(ip route | awk '/default/ {print $3; exit}')
[ -n "$HOST_IP" ] || { echo "[firewall] 找不到 default gateway" >&2; false; }
HOST_NET="${HOST_IP%.*}.0/24"
iptables -A INPUT  -s "$HOST_NET" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NET" -j ACCEPT

iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# 自我驗證：白名單外的站台必須連不到
if curl -s --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  echo "[firewall] FAIL: example.com 仍可連線" >&2
  false
fi

trap - ERR
touch "$OK_FLAG"
chmod 644 "$OK_FLAG"
echo "[firewall] OK：出站已限制在白名單內（$resolved 個網域 + GitHub IP 段）"
