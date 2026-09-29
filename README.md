# agent-sandbox-kit

讓 **Claude Code 和 Codex 在隔離容器裡全權限執行、不問授權**，並可用 git worktree
平行開多個 agent。容器就是邊界，所以兩個 agent 都以 bypass 模式跑。

走 `@devcontainers/cli`，不需要 VS Code 的 Dev Containers 擴充——所以在
Antigravity、Cursor 等拿不到微軟 Marketplace 的編輯器上也能用。

> **只用於你自己信任的 repo。** bypass 模式下，惡意專案可以讀走容器內
> `~/.claude`、`~/.codex` 的登入憑證。這是 Anthropic 官方明列的限制。
> 不可信的第三方程式碼請用 VM 或 cloud session。

## 它擋得住什麼

| 威脅 | 狀態 | 靠什麼 |
|---|---|---|
| 誤碰專案外的檔案（`~/.ssh`、其他 repo） | 擋住 | 容器邊界 |
| 弄壞開發環境（nvm、全域 CLI） | 擋住 | 容器邊界 |
| 一直要按授權 | 解決 | 兩個 agent 都 bypass |
| 改到會在主機執行的檔案 | 擋住 | `.devcontainer/`（含沙箱規則）、`.git/hooks/` 唯讀 |
| `git push` | 擋住 | 容器內沒有憑證 |
| agent 自己關掉防火牆 | 擋住 | sudo 收斂成只能跑防火牆腳本且不能帶參數 |
| VS Code IPC 逃逸（容器內在主機執行指令） | 不存在 | 走 CLI，容器內沒有編輯器 process |
| 把東西往外送 | **部分** | 出站白名單，但 IP 粒度且無紀錄 |
| 砍掉 `.git` 歷史 | **擋不住** | 設計如此，靠「放 agent 進去前先 push」 |

---

## 安裝到一個專案

### 一、每台機器一次

```bash
brew install git        # 需要 >= 2.48（worktree 相對路徑）
```

### 二、複製到目標專案

```bash
cd /path/to/your-project
KIT=/path/to/agent-sandbox-kit
cp -r $KIT/.devcontainer $KIT/scripts $KIT/prompts .
chmod +x scripts/* .devcontainer/*.sh
```

**kit 不會碰你專案根目錄的 `AGENTS.md`。** 沙箱規則放在
`.devcontainer/sandbox-rules.md`，兩個 agent 各自從不同管道拿到它：

| agent | 怎麼拿到沙箱規則 | 你自己的 `AGENTS.md` |
|---|---|---|
| Claude | `cc` 以 `--append-system-prompt` 注入 | 照 Claude Code 原本的規則載入 |
| Codex | `post-create.sh` 複製到 `$CODEX_HOME/AGENTS.md`（全域層） | 照常讀，而且**優先權更高** |

Codex 的載入順序是官方定義的：先讀 `$CODEX_HOME/AGENTS.md`，再從 git root 往下
逐層讀，後面的覆蓋前面的。所以沙箱規則當底，你的專案規則蓋在上面。

### 三、決定 skills 從哪裡來

`devcontainer.json` 裡有兩條註解掉的 mount，**二選一打開**（來源不存在會讓容器啟動失敗，
所以預設都註解）。

**(a) 專案自己的一份（推薦）** — 每個專案可以有不同的 skills，例如魔改過的 superpowers
放在 `.agent/skills/`：

```jsonc
"source=${localWorkspaceFolder}/.agent/skills,target=/opt/agent-skills,type=bind,readonly",

// 再把來源路徑本身蓋成唯讀，否則 agent 可以從 workspace 改掉自己的 skills。
// 刻意只蓋 skills 這一層——.agent/ 其餘部分必須可寫（QUESTIONS.md、agent-wt 的暫存）。
"source=${localWorkspaceFolder}/.agent/skills,target=${containerWorkspaceFolder}/.agent/skills,type=bind,readonly",
```

**(b) 機器共用的一份**：

```bash
mkdir -p ~/.agent-skills
ln -sfn ~/.claude/plugins/cache/claude-plugins-official/superpowers/<版本> \
        ~/.agent-skills/superpowers
```

```jsonc
"source=${localEnv:HOME}/.agent-skills/superpowers,target=/opt/agent-skills,type=bind,readonly",
```

兩種**目錄結構**都支援，`post-create.sh` 自動判斷：

| 結構 | 判斷依據 | 怎麼接 |
|---|---|---|
| plugin 形式 | 底下有 `.claude-plugin/` | Claude 由 `cc` 的 `--plugin-dir` 載入；Codex 讀 `<dir>/skills` |
| 純 skills 目錄 | 底下直接是 `<skill-name>/SKILL.md` | 逐個 symlink 到 `~/.agents/skills/`（Codex）與 `$CLAUDE_CONFIG_DIR/skills/`（Claude） |

### 四、依專案調整四個地方

`devcontainer.json` 裡標了 `專案自訂` 的註解就是這些：

| 要改的 | 怎麼改 |
|---|---|
| `name` | 改成你的專案名稱 |
| 依賴目錄的 volume | Node 專案打開 `node-modules-*` 那行；Python 改成 `.venv`；沒有原生相依可以整段不要 |
| `forwardPorts` | 要從主機看畫面才需要 |
| `.mcp.json` / `.claude` 的 mount | **確認檔案真的存在再打開**，來源不存在會讓容器啟動失敗 |

再加上兩處：

- **`.devcontainer/allowed-domains.txt`** — 刪掉專案用不到的套件來源，加上公司內部 registry
- **`.devcontainer/sandbox-rules.md`** — 通常不用改。裡面只有沙箱環境的規則，
  你的專案規則寫在自己的 `AGENTS.md` 就好

### 五、依賴安裝的 hook

兩支，都是「存在就執行」，不存在就跳過：

```bash
cp .devcontainer/project-setup.sh.example .devcontainer/project-setup.sh
cp .worktree-setup.sh.example .worktree-setup.sh
chmod +x .devcontainer/project-setup.sh .worktree-setup.sh
# 編輯內容，填入你的 npm ci / uv sync / gradlew
```

| Hook | 何時跑 | 用途 |
|---|---|---|
| `.devcontainer/project-setup.sh` | 容器建立時，**收斂 sudo 之前** | 裝依賴、`chown` 掛在 workspace 底下的 volume。這是唯一還能用 sudo 的時機 |
| `.worktree-setup.sh` | `agent-wt new` 建好 worktree 後 | 在那個 worktree 裡裝一份依賴 |

**為什麼依賴目錄要用 named volume**：主機若是 macOS，`npm install` 裝出來的原生
binary 是 darwin-arm64，bind mount 進 Linux 容器會找不到 binding
（`Cannot find module '@rolldown/binding-linux-arm64-gnu'` 這類）。用 volume 讓容器
有自己的一份，主機那份不受影響，兩邊可同時跑。

---

## 每次使用

```bash
# 起容器（第一次會 build，之後幾秒）
npx @devcontainers/cli up   --workspace-folder .

# 進去
npx @devcontainers/cli exec --workspace-folder . bash
```

容器內：

```bash
claude            # 第一次要登入（瀏覽器回調失敗時，把畫面上的代碼貼回終端機）
codex login       # 第一次要登入

verify-sandbox    # 每次都跑，全 PASS 才往下做

cc                # 啟動 Claude（bypass + superpowers + 沙箱規則注入系統提示）
cx                # 啟動 Codex（danger-full-access）
```

`cc` / `cx` 會在防火牆未就緒時拒絕啟動。

### 平行開多個 agent

```bash
agent-wt new feat-a claude "把 X 重構成 Y"
agent-wt new feat-b codex  @prompts/some-task.md
tmux attach -t agents        # 切視窗：Ctrl-b n / Ctrl-b w
```

每個 worktree 有自己的分支 `agent/<name>`、自己的依賴、以及 `.agent.env` 裡一個
依名稱算出的不重複 `PORT`。

**為什麼要 worktree**：沒有的話 agent 和你共用同一個 checkout，它一切分支，
你編輯器裡的檔案就整批被換掉。

### 收成（主機或容器都可以）

`agent-wt` 只有 `new`。其餘用原生 git，本來就各是一行：

```bash
git worktree list
git diff main...agent/feat-a
git merge agent/feat-a
git worktree remove .worktrees/feat-a && git branch -d agent/feat-a
git push
```

### 放 agent 進去之前先 push

專案目錄在容器內可寫（agent 要能改程式碼），`.git` 也在裡面。沙箱規則禁止它
砍歷史，但那是文字約束不是機制。**沒 push 的 commit 被砍掉就是沒了。**

---

## 已知的洞

**單檔唯讀 mount 會靜默脫鉤。** 工具改檔案常用「寫 `.lock` 再 rename」，換的是 inode；
主機那側一旦換掉檔案，容器裡的 mount 就脫鉤、檔案變回可寫，**沒有任何錯誤訊息**。

**目錄的 mount 沒這問題**——這也是沙箱規則放在 `.devcontainer/` 而不是根目錄單檔的
原因之一。會受影響的是你自己打開的那幾條單檔 mount（`AGENTS.md`、`.mcp.json`）：
在主機上編輯過就會脫鉤。

所以 `verify-sandbox` 要每次進容器都跑。FAIL 的修法是重建容器：

```bash
docker rm -f $(docker ps -aq --filter label=devcontainer.local_folder=$PWD)
npx @devcontainers/cli up --workspace-folder .
```

**其他**

- 白名單是 IP 粒度：同一個 IP 上的其他網域（SNI 共用）擋不住。
- 沒有出站紀錄。要補就在 `init-firewall.sh` 最後那條 REJECT 之前加 `-j LOG`。
- **緊急關閉防火牆**：sudo 已收斂，容器內辦不到。從主機下
  `docker exec -it -u root <容器> bash`。

---

## 檔案

| 路徑 | 行數 | 作用 |
|---|---|---|
| `.devcontainer/devcontainer.json` | 93 | mount、能力、環境變數、生命週期 |
| `.devcontainer/Dockerfile` | 61 | base image、工具、兩個 agent（版本釘死）、`cc`／`cx` |
| `.devcontainer/init-firewall.sh` | 84 | 出站白名單，**fail-closed**：任何一步失敗就全封鎖 |
| `.devcontainer/allowed-domains.txt` | 32 | 白名單網域（放在 image 內，agent 改不到） |
| `.devcontainer/post-create.sh` | 48 | git identity、Codex 設定、專案 hook、**最後收斂 sudo** |
| `scripts/agent-wt` | 89 | `agent-wt new`：worktree ＋ 依賴 ＋ PORT ＋ tmux |
| `scripts/verify-sandbox` | 64 | 邊界檢查，21 項 |
| `.devcontainer/sandbox-rules.md` | 80 | 沙箱環境的規則。Claude 由 `cc` 注入，Codex 由 post-create 放進全域層 |

### 三個容易誤解的設計

**規則不放在專案根目錄。** 放 `AGENTS.md` 到根目錄有兩個問題：會蓋掉專案自己的那份，
而且主機上的 session 也會讀到「你在容器內、權限全開」——在主機上是錯的。
所以規則放 `.devcontainer/sandbox-rules.md`（已被目錄 mount 保護），
Claude 由 `cc` 以 `--append-system-prompt` 注入，Codex 由 post-create 放進
`$CODEX_HOME/AGENTS.md`。兩邊都不碰你的檔案。

**`cc` / `cx` 是 image 內的執行檔，不是 shell alias。** `agent-wt` 產生的 runner 是
非互動 bash，不會 source `/etc/bash.bashrc`，函式放那裡用不到；而且烤進 image 後
agent 改不掉。

**sudo 收斂在 `post-create.sh` 而不是 `Dockerfile`。** devcontainer features 疊在
image 之上、以 root 執行，會把 `NOPASSWD:ALL` 寫回來。所以收斂必須是最後一步。

---

## 與 Claude Code 官方範例的差異

對照對象是 [`anthropics/claude-code`](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
的 `.devcontainer/`，官方自己的定位是「a working example rather than a maintained base image」。

**沿用官方的**：`runArgs`（`NET_ADMIN` / `NET_RAW`）、`postStartCommand` 的單行
`sudo …/init-firewall.sh`、`waitFor: postStartCommand`、`~/.claude` 用 named volume
＋ `CLAUDE_CONFIG_DIR`、非 root 使用者、`init-firewall.sh` 的做法。

**本 kit 多出來的**：

| 功能 | 為什麼 |
|---|---|
| Codex 支援 | Codex CLI 的網路只有開關、沒有網域白名單，所以容器是唯一 vendor-neutral 的邊界 |
| 防火牆 fail-closed ＋ `/run/firewall-ok` | 任一步失敗就進全封鎖，而不是留下沒防火牆的容器；`cc`／`cx` 靠旗標判斷 |
| 白名單獨立成檔 | 放在 image 內，加網域不必動腳本 |
| sudo 收斂 | 否則 agent 可以 `iptables -F`，或指向自己寫的全放行清單重建防火牆 |
| 控制面唯讀 | `.git/hooks`、`.mcp.json` 這類檔案是**由主機端工具執行**的，寫進去等於在等你觸發 |
| IPC 環境變數清空 | 走 CLI 本來就沒這條路，這是「萬一改用擴充套件開」的保險 |
| `verify-sandbox` | 單檔 mount 脫鉤是無聲的，沒有它會以為防護還在 |
| `agent-wt` | worktree ＋ 依賴 ＋ 不重複的 PORT ＋ tmux 視窗 |
| 沙箱規則 | 不碰專案的 `AGENTS.md`：Claude 由 `cc` 注入，Codex 走 `$CODEX_HOME` 全域層 |
| 版本釘死 | 官方是 `latest` ＋ 容器內自動更新；要可重現的 build 就得釘死 |

**官方有而本 kit 刻意不要的**：Reopen in Container 當主要用法（擴充套件會注入 IPC
socket 並轉發憑證，容器內可反向在主機執行指令）、zsh ＋ powerlevel10k ＋ git-delta
（agent 不需要好看的 shell）、eslint／prettier／gitlens 擴充（編輯器在主機）。

---

## 踩過的坑

建這套東西時撞到的問題、根因與解法，以及被否決過的方向，記在
[`docs/agent-sandbox-kit-review.md`](docs/agent-sandbox-kit-review.md)。
排版過、含真實指令輸出的版本在 [`docs/manual.html`](docs/manual.html)。

幾個最值得先知道的：

- **worktree 的連結必須是相對路徑**，否則只有建立它的那一邊能用。偵測
  `--relative-paths` 支援度時有兩個陷阱（help 印的是 `--[no-]relative-paths`，
  而且 `git worktree add -h` 離開碼是 129 會撞上 `pipefail`）。
- **只掛 worktree 不可行**，必須掛整個 repo：worktree 沒有自己的 object database。
- **`.git/config` 不要掛唯讀**：`worktree add` 首次要寫它，掛了會 EBUSY 失敗。
  它的威脅（`core.hooksPath`）改由 `verify-sandbox` 直接檢查。
- **mount 的語意只能在真容器裡驗**：用 `chmod` 模擬唯讀會得到錯誤結論，
  因為 git 走 lock+rename，而 `rename()` 只檢查目錄權限。
