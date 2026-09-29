# 沙箱環境規則

> **這份檔案描述的是 devcontainer 容器內的執行環境**，不是專案規則。
> 專案自己的規則在專案根目錄的 `AGENTS.md`，那份的優先權比這份高。

兩個 agent 各自從不同管道拿到這份規則，**都不會碰到專案根目錄的 `AGENTS.md`**：

- **Claude**：`cc` 以 `--append-system-prompt` 注入（來源 `$AGENT_RULES`）
- **Codex**：`post-create.sh` 複製到 `$CODEX_HOME/AGENTS.md`，也就是 Codex 的全域層。
  Codex 會再從 git root 往下讀專案的 `AGENTS.md` 並蓋在這份上面

這個檔案放在 `.devcontainer/` 底下，而那個目錄在容器內是**唯讀掛載**的，agent 改不掉。
（刻意用目錄 mount 而不是根目錄的單檔——單檔 mount 會因為 lock+rename 靜默脫鉤。）

## 執行環境

- 你在隔離的容器/沙箱內執行，權限已全開。可以自由安裝套件、執行測試、重構、在當前分支 commit。
- **一律不要切換分支、不要 merge、不要 push、不要改寫歷史，也不要自己建 worktree。**
  你可能在兩種位置之一，而兩種都禁止切分支：
  - `.worktrees/<name>/`（由 `agent-wt new` 啟動）——你有專屬的分支 `agent/<name>`。
  - 主工作目錄（直接用 `cc` / `cx` 啟動）——**你和使用者共用同一個 checkout**，
    切分支會當場改變他編輯器裡的檔案。
  用 `git rev-parse --show-toplevel` 可以確認自己在哪。
- 容器內沒有可以推送的憑證，`git push` 會失敗。這是刻意的，不要嘗試繞過。
- 若 `.agent.env` 存在，啟動任何 server 前先載入它，一律使用其中的 `$PORT` 與
  `$COMPOSE_PROJECT_NAME`，避免和其他平行 agent 衝突。server 綁定 `0.0.0.0`。
- 以下路徑唯讀，不要嘗試修改，也不要為了繞過它而改用別的路徑：
  `.devcontainer/`、`.git/hooks/`。專案若另外掛了 `AGENTS.md`、`.mcp.json`、`.claude/`
  也一樣不要碰。
  `.git/config` 雖然可寫，**不要動它**——尤其不要設 `core.hooksPath`。
- 出站網路走白名單。連不到某個網域時，回報給我，不要自己改防火牆或找替代通道。

## 自主權：什麼時候可以問我

- **技術決策自己決定，不要問**：套件選擇、命名、檔案結構、錯誤處理方式、測試寫法、
  重構範圍、要不要跑測試。做了非顯而易見的決定，寫在 commit message 裡。
- **只有商業邏輯不明確時才問**（需求規則、金額或計算方式、權限規則、使用者看得到的行為、
  資料保留政策等）。
  - 會擋住主要進度的 → 停下來問，問題附上「你建議的預設答案」與理由。
  - 不會擋住的 → 採用你的預設假設繼續做，並記錄到 `.agent/QUESTIONS.md`
    （格式：問題 / 採用的假設 / 影響範圍）。
- 不要問「要不要繼續？」「要我做 X 嗎？」這類流程問題，直接做完再回報。

## 與 superpowers skills 的搭配

- 照常使用 superpowers 的流程（TDD、systematic debugging、verification-before-completion、
  code review 等）。
- brainstorming / 需求釐清階段：只針對**商業邏輯**提問，技術設計自行決定並寫進計畫文件。
- `using-git-worktrees`：**跳過**。worktree 由使用者用 `agent-wt` 決定，不是你的事。
- `finishing-a-development-branch`：做到「測試全綠 + 已 commit」就停，不要 merge、不要開 PR。
  最後輸出變更摘要與 `.agent/QUESTIONS.md` 內容。

## 完成定義

1. 所有相關測試通過（新增的功能要有測試）。
2. 變更已 commit 到目前分支，commit message 說明做了什麼與為什麼。
3. 最後回報：變更摘要、做過的技術決策、待我確認的商業問題。
