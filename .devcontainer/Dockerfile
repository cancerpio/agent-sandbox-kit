FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG NODE_MAJOR=22
# 版本釘死。Anthropic 官方建議用 npm i -g ...@X.Y.Z 而非 devcontainer feature，
# 因為 feature 永遠裝 latest。搭配 DISABLE_AUTOUPDATER=1（見 devcontainer.json）。
# 升版就改這兩行再 rebuild。
ARG CLAUDE_VERSION=2.1.283
ARG CODEX_VERSION=0.158.0

USER root

# git-core PPA：worktree 的相對路徑需要 git >= 2.48
RUN apt-get update \
 && apt-get install -y --no-install-recommends software-properties-common \
 && add-apt-repository -y ppa:git-core/ppa \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      git tmux jq ripgrep curl ca-certificates \
      iptables ipset iproute2 dnsutils aggregate \
 && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm i -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" "@openai/codex@${CODEX_VERSION}"

# 防火牆腳本與白名單放在 image 內，agent 改不到（workspace 是可寫的）
COPY init-firewall.sh /usr/local/share/init-firewall.sh
COPY allowed-domains.txt /usr/local/share/allowed-domains.txt

# cc / cx：啟動 agent 的入口。做成 image 內的執行檔而不是 shell 函式，理由有兩個：
#   1. 烤進 image，agent 改不到
#   2. 非互動 shell 也能用——agent-wt 產生的 runner 會呼叫它們，
#      而非互動 bash 不會 source /etc/bash.bashrc，函式放那裡就用不到
COPY <<'EOF' /usr/local/bin/cc
#!/usr/bin/env bash
[ -f /run/firewall-ok ] || { echo "防火牆未就緒，拒絕啟動 agent。" >&2; exit 1; }
args=(--dangerously-skip-permissions)
[ -d /opt/agent-skills/.claude-plugin ] && args+=(--plugin-dir /opt/agent-skills)
# 規則來源固定是唯讀掛載的根目錄副本，不是 worktree 裡那份可寫的 checkout
[ -r "${AGENT_RULES:-}" ] && args+=(--append-system-prompt "$(cat "$AGENT_RULES")")
exec claude "${args[@]}" "$@"
EOF

COPY <<'EOF' /usr/local/bin/cx
#!/usr/bin/env bash
[ -f /run/firewall-ok ] || { echo "防火牆未就緒，拒絕啟動 agent。" >&2; exit 1; }
exec codex --dangerously-bypass-approvals-and-sandbox "$@"
EOF

# volume 掛載點先建好並設好擁有者，否則 named volume 會是 root 擁有。
# skills 的接線在 post-create.sh——要先看掛進來的是 plugin 還是純 skills 目錄。
RUN chmod 755 /usr/local/share/init-firewall.sh /usr/local/bin/cc /usr/local/bin/cx \
 && chmod 644 /usr/local/share/allowed-domains.txt \
 && mkdir -p /home/vscode/.claude /home/vscode/.codex /home/vscode/.agents/skills \
 && chown -R vscode:vscode /home/vscode/.claude /home/vscode/.codex /home/vscode/.agents

# sudo 收斂刻意不在這裡做：devcontainer features 疊在這個 image 之上、以 root 執行，
# common-utils 之類的會把 NOPASSWD:ALL 寫回來，抵銷這裡做的任何收斂。
# 所以那一步在 post-create.sh 的最後（features 跑完之後）。

USER vscode
