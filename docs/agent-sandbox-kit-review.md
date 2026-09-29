# 檢視紀錄與設計決策

> 這份文件是這個 kit 的**開發歷程紀錄**：踩過的坑、根因、被否決過的方向。
> 使用說明在 [README.md](../README.md)，這裡只回答「為什麼是這樣設計的」。
> 部分段落提到 `personalrecord`，那是第一個套用這套設定的專案。

最後更新：2026-09-28（A1/A2 已套用到 v2；已 rollout 到 personalrecord）

## 這份文件是什麼

對 `agent-sandbox-kit`（v1）與 `agent-sandbox-kit-v2` 的逐檔檢視紀錄，含實測證據。
目的是把 v2 修到可用，然後**更新所有 sandbox 相關文件**，並在 README 留下
一份照著打就能跑起來的步驟。

## 需求前提（決定了架構選擇）

要擋的四件事：

1. agent 誤碰專案外的檔案（`~/.ssh`、其他 repo）
2. agent 把東西往外送（原始碼、Firestore 資料、金鑰）
3. 不想一直按授權
4. 怕弄壞開發環境本身（nvm、全域 CLI）

**關鍵約束：Claude 和 Codex 都要能用。** 這條排除了兩個 agent 各自的原生沙箱——
Claude Code 有內建 Bash 沙箱與 sandbox runtime（Seatbelt/bubblewrap，不需 Docker），
但那是 Anthropic 專屬的；Codex CLI 的沙箱只有 `read-only` /
`workspace-write` / `danger-full-access` 三段，**網路只有開關、沒有網域白名單**
（managed allowlist 是 ChatGPT Work 的功能，不是 CLI）。

也就是說第 2 項（網域白名單）Codex 原生做不到，只能靠容器層的 iptables。
**容器是唯一 vendor-neutral 的邊界，這個架構選擇是對的。**

另一個理由：兩套原生沙箱的粒度、詞彙、預設值全不同，維護兩份的代價不是工作量，
而是無法回答「我現在的邊界在哪」。

## 執行環境注意事項

使用者用 **Antigravity**（Google 的 VS Code fork，已實測確認：
`__CFBundleIdentifier=com.google.antigravity-ide`、
`VSCODE_ESM_ENTRYPOINT=vs/workbench/api/node/extensionHostProcess`）。

- **拿不到微軟的 Dev Containers 擴充**（只上架 MS Marketplace，授權限定微軟產品）。
  Google 論壇的 feature request 從 2025-11 拖到 2026-08 仍未出貨。
- 因此只能走 `devcontainer up` / `devcontainer exec` **CLI 路徑**。
- **副作用是好的**：CLI 路徑容器內沒有編輯器 process，所以沒有
  `VSCODE_IPC_HOOK_CLI` 逃逸（Trail of Bits：容器內程式碼可以驅動
  `terminal.newLocal` 在主機執行指令）。
- **副作用是壞的**：CLI 不會像擴充那樣複製主機 `.gitconfig`，所以 git identity
  必須自己設，否則 agent 完全無法 commit。

---

## 已驗證的結論

測試方式：scratchpad 建拋棄式 repo + `docker run` 掛 readonly bind mount
（`alpine/git:latest`，git 2.54.0）。測完已全部還原。

### 1. 相對路徑 worktree 的機制（確認）

`--relative-paths` 讓 worktree 連結的兩個方向都不帶前綴：

```
.worktrees/demo/.git        → gitdir: ../../.git/worktrees/demo
.git/worktrees/demo/gitdir  → ../../../.worktrees/demo/.git
```

並自動設 `extensions.relativeworktrees = true`。

**它不是讓容器能 commit 的原因**——整個 repo（含 `.git`）都在 bind mount 裡，
commit 本來就成立。它救的是**主機端**：讓你能 review、`git diff`、
`worktree remove` 容器建出來的 worktree。`agent-wt` 的 warning 方向寫對了：
「git < 2.48，改用絕對路徑（主機端 git 將無法操作此 worktree）」。

附帶風險：絕對路徑時主機的 `git gc` 會觸發 `worktree prune`，可能把註冊資訊刪掉，
反過來破壞容器那一側。（推論，未實測。）

### 2. v2 出廠狀態下 `agent-wt new` 會失敗（確認，這是 blocker）

v2 把 `.git/config` 掛成唯讀（正確——否則 agent 可用 `core.hooksPath`
把 hooks 指向可寫目錄，繞過 `.git/hooks` 的唯讀保護）。

但 `git worktree add --relative-paths` **第一次**執行時必須寫 config 兩件事：

```ini
[core]
    repositoryformatversion = 1    # git 規定：宣告任何 extensions.* 就必須是 1
[extensions]
    relativeworktrees = true
```

實測（`.git/config` readonly mount）：

```
error: could not write config file .git/config: Resource busy
fatal: could not set 'core.repositoryformatversion' to '1'
worktree add 回傳碼 = 128
worktree 不存在
agent/x 分支存在嗎： yes      ← 失敗不乾淨，留下孤兒分支
```

**v2 的規避方式無效。** 它叫你在主機先跑 `git config worktree.useRelativePaths true`，
但實測確認那只寫 `[worktree]` 區段，**不會**寫入 `extensions.relativeworktrees`
也不會升版本號——那兩個是 `worktree add` 當下才寫的。

錯誤是 `Resource busy`（EBUSY）而非 `EROFS`，因為 git 走
`config.lock` + `rename()`，而 rename 蓋不過一個掛載點。
（這也是為什麼容器外用 `chmod 444` 模擬會測不出來——chmod 檢查檔案權限，
rename 只看目錄權限。此類問題只能在真容器裡驗。）

### 3. bootstrap 修法有效（確認）

主機端先觸發那一次性的寫入，容器內就無事可做：

```
容器內（.git/config readonly mount 確認生效）：
  worktree add --relative-paths   回傳碼 = 0     ← 原本 128
  worktree 連結  gitdir: ../../.git/worktrees/x
  worktree 內 commit              回傳碼 = 0

主機端（路徑前綴與容器完全不同）：
  worktree list          兩筆正常
  git log agent/x        看得到容器建的 commit
  worktree 內 git status ## agent/x
  git diff main..agent/x 1 file changed
  git worktree remove    成功（agent-wt rm 可用）
```

---

## build 實測：v2 另外三個 bug（2026-09-28，已修）

在 personalrecord 上 build 起來跑端到端時才發現的，v1/v2 都有：

### B-1 相對路徑 worktree 從來沒生效過（嚴重）

`agent-wt` 的偵測條件有**兩個獨立的 bug**，任一個都會讓它 fallback 成絕對路徑：

```bash
if ! git worktree add -h 2>&1 | grep -q -- --relative-paths; then rel=""; fi
```

1. **grep 樣式錯**：git 的 help 印的是 `--[no-]relative-paths`，
   字面上的 `--relative-paths` 在任何版本都不存在。
2. **pipefail**：腳本開頭是 `set -euo pipefail`，而 `git worktree add -h`
   的離開碼是 **129**（usage）。pipefail 讓整條 pipeline 回傳 129，
   條件因此永遠成立。

也就是說 kit 的招牌功能（主機／容器雙向可用）一直是壞的，而且只會印一行 WARN。
改成不用 pipeline：

```bash
local rel="--relative-paths" help
help="$(git worktree add -h 2>&1 || true)"
case "$help" in *relative-paths*) ;; *) rel="" ;; esac
```

### B-2 tmux "command too long"

v2 的 `launch()` 把**整份 AGENTS.md** 用 `printf %q` 內嵌進命令列，外層再 `%q` 一次。
中文每個字會展開成多個八進位跳脫，長度爆增後 tmux 直接拒絕，worktree 建好了但
agent 沒啟動。改成產生一支 runner 腳本，內容在腳本裡才展開，tmux 只拿到一個路徑。

### B-3 單檔唯讀 mount 會靜默脫鉤（設計層級的問題）

v2 用單一檔案的 bind mount 保護 `.git/config`、`AGENTS.md`、`.mcp.json`。
**這個保護會自己消失。** git 改檔案是「寫 `.lock` 再 rename 蓋過去」，換的是 inode；
主機那側一旦重寫檔案，容器裡的 mount 就脫鉤，檔案變回可寫，沒有任何錯誤訊息。

實測：一輪操作之後 `.git/config` 就從容器的 `mount` 清單消失，
容器內 append 成功並直接寫進主機的檔案。重建容器可復原。

**目錄的 bind mount 沒有這個問題**（`.git/hooks`、`.claude/`、`.devcontainer/`
在同一輪裡都還在），因為目錄不會被 rename 換掉。

結論：單檔唯讀 mount 只能算「提高門檻」，不是可靠的邊界。
必須靠 `verify-sandbox` **每次進容器都跑**來偵測，它抓得到。
這一點要寫進 kit 的 README 與 AGENTS.md。

### B-4 macOS 的 node_modules 掛進 Linux 容器會炸

不是 kit 的 bug，是所有 macOS + devcontainer 專案都會踩到的：原生 binary 是
darwin-arm64。解法是 `node_modules` 用 named volume，容器自己 `npm ci` 一份。
chown volume 需要 sudo，所以那步必須排在 `post-create.sh` 收斂 sudo **之前**。

---

## 未驗證（需要 build 一次完整 image）

沒測過的部分佔比很高，**不要當它有效**：

- 完整 image build（apt / git-core PPA / node / npm 裝 claude + codex）
- 防火牆：`init-firewall.sh` 的 fail-closed（`trap lockdown ERR`）、
  GitHub meta 抓取、ipset、自我驗證、`/run/firewall-ok` 旗標
- sudo 收斂：`NOPASSWD: /usr/local/share/init-firewall.sh ""` 這個語法
  是否真的擋住帶參數執行；`visudo -c -q`；`rm -f /etc/sudoers.d/*` 的副作用
- `start-firewall.sh` 不帶參數呼叫是否符合收斂後的 sudoers
- `cc` / `cx` 函式與 `_agent_guard`
- Claude / Codex 在容器內登入（含瀏覽器回調失敗時貼碼）
- `scripts/verify-sandbox`
- tmux + `agent-wt` 端到端、多 agent 平行

---

## v3 修改清單

### A. 定點修正（4 項，3 項只是改文字）

**A1. bootstrap 提醒改掉（blocker）**

`post-create.sh` 現在檢查 `worktree.useRelativePaths`，改成檢查真正需要的：

```bash
if [ "$(git config --get core.repositoryformatversion)" != "1" ] \
   || [ "$(git config --get extensions.relativeworktrees)" != "true" ]; then
  cat >&2 <<'MSG'
[post-create] 這個 repo 還沒 bootstrap。.git/config 在容器內唯讀，agent-wt 會失敗。
              請在「主機」上執行一次：
                git worktree add --relative-paths -b _bootstrap .worktrees/_bootstrap
                git worktree remove .worktrees/_bootstrap && git branch -d _bootstrap
MSG
fi
```

**A2. `worktree add` 失敗要收尾**

`scripts/agent-wt` 的 `cmd_new`：

```bash
if ! git -C "$ROOT" worktree add $rel -b "$branch" "$path" "$base"; then
  git -C "$ROOT" branch -D "$branch" 2>/dev/null || true
  die "worktree add 失敗（已清掉分支 $branch）"
fi
```

**A3. 把 `.mcp.json` / `.claude` 的唯讀 mount 打開**

v2 裡是註解掉的（理由合理：來源不存在會讓容器啟動失敗），
結果是這兩個控制面路徑**預設仍可寫**。套用到 `personalrecord` 時兩個都存在
（`.mcp.json` 有 firebase MCP、`.claude/` 有 commands 與 skills），必須打開。

**A4. worktree 裡的 `AGENTS.md` 可寫（設計缺口，尚無定案）**

唯讀 mount 在 workspace 根目錄，但 agent 跑在 `.worktrees/<name>/`，
那裡的 `AGENTS.md` 是 git checkout 出來的副本，**agent 改得動自己的規則檔**。
候選解法見 B2。

### B. 從官方拿的（3 項）

**B1. 在 Dockerfile 釘死 Claude 版本**

Anthropic 官方：「The Dev Container Feature always installs the latest Claude Code
release. To pin a specific Claude Code version for reproducible builds, install it
from your Dockerfile with `npm install -g @anthropic-ai/claude-code@X.Y.Z`
instead of using the feature, and set `DISABLE_AUTOUPDATER` to `1`」

kit 已設 `DISABLE_AUTOUPDATER=1` 但**沒釘版本**——關掉自動更新卻不知道裝到哪一版，
是半套。

**B2. `/etc/claude-code/managed-settings.json`**

官方：「Claude Code reads `/etc/claude-code/managed-settings.json` on Linux and
applies it at the highest precedence in the settings hierarchy, so values there
override anything an engineer sets in `~/.claude` or the project's `.claude/`」

從 Dockerfile `COPY` 進 image，agent 改不到。這正好補上 A4 的缺口。
**限制：Claude 專屬，Codex 沒有對應機制**，所以是「Claude 側多一道保險」
而非統一方案。

**B3. 與上游 `init-firewall.sh` 對一次 diff**

kit 的版本是「改寫自 Anthropic / OpenAI 官方 devcontainer 範例」的某時點快照。
上游在 `anthropics/claude-code/.devcontainer/init-firewall.sh`，值得比對有無修正。

### C. 明確否決的方向

**C1. 不改用 devcontainer features 裝 agent。**
`anthropics/devcontainer-features/claude-code` 與 `dirien/devcontainer-feature-codex`
**都是純安裝器，零沙箱功能**。它們只替代 Dockerfile 那兩行 `npm i -g`，
我找到的四個問題一個都不在那一層。

而且 dirien 那個是社群專案（7 stars / 4 commits / 0 forks），
**feature 在 build 時以 root 執行**（v2 自己的註解和微軟 issue #287765
都指出這點：「Untrusted feature sources can execute arbitrary code during
container setup」），對一個以安全為目的的 image 是往反方向走。

**C2. 不從官方 reference container 重建。**
官方那份是單 agent、無 worktree，且官方自稱
「provided as a working example rather than a maintained base image」。
kit 獨有的價值是 worktree + tmux 平行 agent 與雙 agent 共用規則；
重建等於重寫獨有的、保留通用的。

**C3. 不加寬度斷點式的思維——不用 Reopen in Container。**
Trail of Bits 對該功能的結論是 "Not recommended for untrusted code"。
Antigravity 本來就沒有，但 README 現在把它列在 CLI 之前，要對調。

**C4. 不依賴 Claude 的內建沙箱作為主方案。** 見「需求前提」：Codex 沒有對應物。
（可作為容器內的額外一層，但官方也說不必疊，容器已是邊界。）

---

## 適用範圍限制（必須寫進 README）

Anthropic 官方把這段放在頁面最上方的警告框：

> When executed with `--dangerously-skip-permissions`, dev containers **do not
> prevent a malicious project from exfiltrating anything accessible inside the
> container, including the Claude Code credentials stored in `~/.claude`**.
> Only use dev containers when developing with trusted repositories.

**這套的適用範圍是「你自己信任的 repo」**，不是「可以拿來開來路不明的程式碼」。
不可信的第三方 repo 官方建議用 VM 或 cloud session。

另外兩個 kit 本身的已知取捨：

- **`.git` 歷史可被砍。** 專案目錄可寫是設計如此（官方：「any approach that
  mounts your project directory writable can still modify that code」），
  但沒 push 的 commit 被 `rm -rf .git` 掉就是沒了。
  緩解：**放 agent 進去之前先 push。**
- **防火牆是 IP 粒度**，同 IP 上的其他網域（SNI 共用）擋不住；且**無出站紀錄**，
  事後查不出連過哪裡。要補的話在最後那條 REJECT 之前加 `-j LOG`。

---

## 待辦

已套用到 `agent-sandbox-kit-v2` 本體：

- [x] A1 bootstrap 檢查改掉（`post-create.sh`）
- [x] A2 `worktree add` 失敗收掉孤兒分支（`scripts/agent-wt`）
- [x] 清掉空的 `rules/`

已在 `personalrecord` 的第一版 devcontainer 中處理（kit 本體尚未回填）：

- [x] A3 `.mcp.json` / `.claude` 唯讀 mount 打開
- [x] A4 **Claude 側已解**：`cc()` 改讀 `$AGENT_RULES`（指向唯讀的根目錄副本），
      不再讀 worktree 裡那份可寫的 `./AGENTS.md`。
      **Codex 側未解**——它原生從 cwd 讀 `AGENTS.md`，無法重導。
- [x] B1 版本釘死（`CLAUDE_VERSION` / `CODEX_VERSION` build args）
- [x] 不建立 `CLAUDE.md`（會污染主機 session），改由 `cc()` 以
      `--append-system-prompt` 注入
- [x] 白名單收斂成該專案實際需要的來源

尚未做：

- [ ] B2 `/etc/claude-code/managed-settings.json`（評估後認為 v1 沒有值得放的鍵，
      放一個空殼是 cargo cult。等有具體要強制的政策再加）
- [ ] B3 與上游 `anthropics/claude-code/.devcontainer/init-firewall.sh` 對 diff
- [ ] 把 personalrecord 這邊的修正回填到 kit v2
- [x] build 一次完整 image，把「未驗證」那一節全部測掉 → **verify-sandbox 19 PASS / 0 FAIL**，
      `npm test` 122 passed、`npm run build` 通過、`agent-wt` 端到端可用、
      主機端能操作容器建的 worktree、`git push` 如預期因憑證失敗
- [ ] 把 B-3（node_modules volume / project-setup.sh）的做法回填到 kit
      （B-1、B-2 已回填）

`personalrecord` 專屬三項的決定：

- **firebase MCP**：容器內**不可用**，刻意不給憑證。把正式環境 Firestore 讀取權
  放進全權限 agent 的沙箱，正好是「把東西往外送」那條風險。
  要查資料就讓 agent 寫進 `.agent/QUESTIONS.md`，在主機查。
- **LIFF 實機測試**：留在主機。容器內只做 `npm test` 與 `npm run build`，
  兩者都不需要對外連線，不值得為此拉 HTTPS 通道進容器。
- **dev server**：`npm run dev -- --host 0.0.0.0 --port $PORT`，`$PORT` 來自
  `.agent.env`；`forwardPorts` 開 5173。

## README 步驟（已實作）

`personalrecord/README.md` 有精簡版（複製貼上就能跑），完整說明在
`personalrecord/docs/agent-sandbox.md`。下面是當初設定的目標樣貌，已達成。

## README 步驟的目標樣貌

必須是「複製貼上就能跑」，不是選項說明書。目標結構：

```
## 第一次設定（每台機器一次）
  1. clone superpowers fork 到 ~/.agent-skills/superpowers
  2. brew install git（需 >= 2.48）
  3. npm i -g @devcontainers/cli

## 每個專案一次
  4. 複製 .devcontainer/ scripts/ AGENTS.md CLAUDE.md prompts/ 到專案根目錄
  5. bootstrap（A1 那兩行）
  6. 確認 .mcp.json / .claude 的唯讀 mount 有打開（A3）

## 每次要用
  7. devcontainer up   --workspace-folder . --config .devcontainer/both/devcontainer.json
  8. devcontainer exec --workspace-folder . --config .devcontainer/both/devcontainer.json bash
  9. 容器內第一次：claude 登入、codex login
 10. scripts/verify-sandbox   ← 確認邊界真的關上了
 11. agent-wt new <name> claude @prompts/xxx.md

## 收成
 12. agent-wt diff <name> / git merge agent/<name> / agent-wt rm <name>
```

每一步只有一個動作，不要在步驟裡夾選項討論——取捨寫在下面的章節。

## 參考來源

- https://code.claude.com/docs/en/sandbox-environments（各種隔離方式的比較與選擇表）
- https://code.claude.com/docs/en/devcontainer（官方 reference container、managed-settings、版本釘死）
- https://code.claude.com/docs/en/sandboxing（內建 Bash 沙箱與 sandbox runtime）
- https://learn.chatgpt.com/docs/sandboxing（Codex CLI 的三種模式）
- https://github.com/trailofbits/claude-code-devcontainer（威脅模型、Reopen in Container、`.git` 延遲逃逸）
- https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers（IPC 三層防護）
- https://github.com/microsoft/vscode/issues/287765（`initializeCommand` 在主機執行、feature 供應鏈）
- https://github.com/anthropics/devcontainer-features/tree/main/src/claude-code（純安裝器）
- https://github.com/dirien/devcontainer-feature-codex（純安裝器，社群維護）
