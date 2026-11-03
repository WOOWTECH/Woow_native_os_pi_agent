# WSL2 真實測試:對你的 Omnigent 開對話、切換模型

目的:證明 WSL2 裡的 Pi Agent 能登記成你 Omnigent 裡的一台主機,Pi、Claude Code、Codex 三個代理都能在 Omnigent
開對話、切換模型,Paseo 也能配對。對應 [`WSL2-PLAN.md`](WSL2-PLAN.md) 的實驗 E10。

工作流程是 [`.github/workflows/wsl2-live.yml`](../.github/workflows/wsl2-live.yml)。它**不是 CI**:只有推送到名叫
`wsl2-live/…` 的分支才會跑,需要下面三個必填的 Secrets,跑起來後會把測試機**保持開著**讓人操作。

## 為什麼需要你的帳號

- Omnigent 插件規定密碼**只能由人從標準輸入給**,不接受由我(或任何代理)代為輸入。工作流程把密碼從 GitHub
  Secret 交給插件的標準輸入,完全不經過命令列、不印出來。
- 登記的主機必須屬於你**瀏覽器裡已經登入的那個 Omnigent 帳號**,我才看得到它。我不會在瀏覽器的登入表單輸入密碼,
  所以不能用另一個專用帳號。
- 你的 Omnigent 伺服器把 Claude Code、Codex、Pi 都設成「訂閱登入」:每個引擎要在那台主機上用自己的訂閱登入才有模型。
  授權由你本人按(插件文件寫明不代按)。LiteLLM 閘道是**選用**:你有現成的網址和金鑰才填,沒有就讓 Pi 也用訂閱登入。

## 風險,先說清楚

- 這幾個值會以**加密 Secret** 存在 GitHub,只在這個工作流程的少數步驟當環境變數用,GitHub 會在日誌裡遮蔽它們。
- 工作流程只會被「有寫入權限的人推送到 `wsl2-live/…` 分支」觸發;有寫入權限的人本來就能改工作流程去讀 Secrets,
  所以只在你信任這個 repo 的協作者時才做。
- 測試機是一次性的虛擬機,工作結束就整台銷毀,裡面登入的 Claude/Codex 一併消失。
- Omnigent 目前的公開 API 不能刪除主機登記:測完你的主機清單裡會留一台**離線**的 `WSL2 CI <編號> (pi-agent)`,
  可以自己在 Omnigent 裡忽略或移除。
- **測完請刪掉這幾個 Secrets**,並視情況改 Omnigent 密碼。

## 步驟

1. 到 <https://github.com/WOOWTECH/Woow_native_os_pi_agent/settings/secrets/actions>,按 **New repository secret**,
   建立這三個(名稱要一字不差):

   | 名稱 | 內容 |
   |---|---|
   | `OMNIGENT_SERVER` | 你的 Omnigent 網址,例如 `https://omnigent.woowtech.io` |
   | `OMNIGENT_USERNAME` | 你登入 Omnigent 的使用者名稱 |
   | `OMNIGENT_PASSWORD` | 那個帳號的密碼 |

   選用(有現成的才填,沒有就不要建):`LITELLM_BASE_URL`(閘道網址,結尾是 `/v1`)和 `LITELLM_API_KEY`(閘道金鑰)。
   兩個都有,Pi 就走 LiteLLM,不用登入;缺任何一個,Pi 改用訂閱登入。
   閘道不接受這兩個值(第二次試跑回了 HTTP 401)時,測試**不會中斷**:警告註解只寫狀態碼、網址的形狀(是否 `/v1`
   結尾)、金鑰的長度和是否 `sk-` 開頭,不寫值本身;Pi 改用自己的登入。
   **要在我推分支之前加好**:GitHub 在工作開始的那一刻就把 Secrets 交出去,之後才加的,進行中的那一輪看不到
   (第一次試跑就踩到:LiteLLM 金鑰晚了約 1 分半)。補加之後要重跑一輪,新的一輪會取代舊的,舊的收尾步驟照跑。

2. 回來告訴我「加好了」。我會推 `wsl2-live/run-1` 分支,GitHub 開一台 Windows,約 20 分鐘後它會註冊成你 Omnigent 裡的
   主機,名稱 `WSL2 CI <編號> (pi-agent)`(工作流程的 **HOST READY** 註解也會寫)。
3. 我用你的 Chrome 打開 Omnigent,找到那台主機,依序:
   - **Pi**:在那台主機的終端機跑 `pi`,輸入 `/login`,選一個你有訂閱的供應商,把授權網址給你,**你按授權**(有填 LiteLLM 就免登入);
     然後開對話、送一句話、切換到另一個模型再送一句,看回覆。
   - **Codex**:我在那台主機的終端機跑 `codex login --device-auth`,把網址和一次性代碼給你,**你在瀏覽器按授權**;然後開對話、切換模型。
   - **Claude Code**:我跑 `claude auth login --claudeai`,把授權網址給你,你按授權後把頁面上的代碼給我貼回去;然後開對話、切換模型。
   - **Paseo**:在那台主機上產生配對連結(只在私人終端機,不進日誌),用官方加密 relay 在你的瀏覽器配對,開一個代理對話、換模型。
4. 結束時我在主機上執行 `touch /tmp/pa-live-done`,工作流程收尾、斷線、銷毀虛擬機。
5. **你刪掉那幾個 Secrets。**
