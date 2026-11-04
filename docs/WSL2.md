# Pi Agent on Windows 11 (WSL2)

> **狀態:預覽版。** Linux 那一半在沙盒裡測過(`tests/wsl.sh`,186 項),也在 GitHub 的 Ubuntu 與 macOS 上跑過。
> Windows 那一半(`windows/install-wsl.ps1`)已經在 **GitHub 的 Windows Server 2025 雲端機**上完整跑通:用
> Windows PowerShell 5.1 裝完、自我檢查 24 項全過、Windows 這邊連得到 `http://localhost:30141`、保活有效、
> 重跑與兩種解除安裝都試過。2026-11-03 還用**真的 Omnigent 伺服器**驗證過:那台雲端機登記成 Omnigent 主機,
> Claude Code 與 Codex 在 Omnigent、Paseo 網頁版開對話並切換模型都成功,代理也能控制 Windows(PowerShell、Notepad、
> 瀏覽器、檔案互通)。2026-11-04 也在**一台真的 Windows 10 22H2 電腦**上裝成功(一般權限的桌面環境,自我檢查 24 項全過),
> 連上 Omnigent 之後,Pi(走 LiteLLM)與 Claude Code 都開對話、切模型、操作了 Windows 的 PowerShell 與記事本;Codex 會被自己的沙盒擋住,要逐條核准。
> **那台實機在測試途中藍屏當機一次,原因未明,不能排除和這次測試有關(見「驗證到哪裡」)。**
> **還沒在 Windows 11 實機上跑過**,也還沒測到「第一次啟用 WSL 並重新開機」、實際的「登入時自動啟動」、睡眠喚醒;Pi 用 ChatGPT 登入在那台實機上失敗(`invalid_grant`,原因未明),要改走 LiteLLM。細節在最後的「驗證到哪裡」。請先拿一台可以隨時重來的電腦試。

一行 PowerShell 指令,替你的 Windows 11 建一個**專用的 Linux 小系統**(WSL2 裡的 Ubuntu 24.04,
名叫 `PiAgent`),把 Linux 版的 Pi Agent 裝進去,登入 Windows 時自動啟動。Omnigent 看到的就是一台
Linux 主機,所以 Pi Agent、Claude Code、Codex 三個代理的行為跟 Linux 版一樣。

設計與取捨在 [`WSL2-PLAN.md`](WSL2-PLAN.md)。

## 需求

| 項目 | 需求 |
|---|---|
| Windows | 建議 **Windows 11 22H2 以上**(build 22621)。Windows 10 2004 以上(build 19041)也能裝,安裝時會先警告 |
| CPU | x64。ARM64 是盡力支援,**尚未測試** |
| 虛擬化 | BIOS/UEFI 要開啟。在虛擬機器裡要有「巢狀虛擬化」;**Apple 晶片上的 Parallels 不行**(Parallels 官方知識庫寫明 WSL2 不能用) |
| 記憶體 | 建議 8 GB 以上(4 GB 是底線)。裝好後約多用 2 GB;已經開很多程式的 8 GB 電腦裝得起來,但沒有餘裕 |
| 磁碟 | 可用空間至少 10 GB,建議 15 GB(裝好後 Linux 約佔 7 GB) |
| 網路 | 安裝時要連網:Ubuntu 映像約 371 MB、pi-web 約 180 MB |
| 權限 | 一般帳號就行。只有「這台電腦還沒有 WSL」時才會跳出系統管理員授權(UAC),而且要重新開機一次 |
| 公司電腦 | IT 可以用 Intune 或群組原則關掉 WSL;被關掉的話這個安裝程式會告訴你原因,但幫不上忙 |

## 安裝

在 PowerShell(不必是系統管理員)貼上:

```powershell
$u = 'https://github.com/WOOWTECH/Woow_native_os_pi_agent/releases/latest/download/install-wsl.ps1'
& ([ScriptBlock]::Create(([Text.Encoding]::UTF8.GetString((Invoke-WebRequest -UseBasicParsing $u).RawContentStream.ToArray())).TrimStart([char]0xFEFF)))
```

這樣寫(而不是 `irm … | iex`)是因為 Windows PowerShell 5.1 會依回應標頭猜編碼,可能把中文訊息讀成亂碼;
這裡明確用 UTF-8 解碼。

可以在最後面加選項:

| 選項 | 意思 |
|---|---|
| `-DryRun` | 只檢查,不改任何東西。**第一次建議先跑這個** |
| `-Yes` | 不問問題(但不會自己重新開機) |
| `-NoWindowsInterop` | 關閉 Windows 互通(見下) |
| `-NoAutostart` | 不登錄「登入時自動啟動」 |
| `-SkipSmoke` | 最後不跑自我檢查 |
| `-Port 30142` | 改用別的連接埠(預設 30141;重跑時不加,就沿用這台原本的連接埠) |
| `-DistroName`、`-LinuxUser` | 改 Linux 的名稱、使用者名稱(使用者不可以是 `root`,要小寫) |
| `-InstallDir D:\Data` | 把 `PiAgent` 資料夾放在這裡(實際用 `D:\Data\PiAgent`;最後一層本來就叫 `PiAgent` 才照原樣用)。這樣解除安裝刪東西時,絕不會碰到你放在 `D:\Data` 的其他資料 |
| `-RootfsPath`、`-BundlePath`、`-PiWebArtifact` | 離線或開發用:改用本機檔案(映像的雜湊值照樣會驗) |

如果電腦還沒有 WSL,安裝到一半會要求重新開機(重開機前請先把其他程式的工作存好,安裝程式不會強制關掉它們)。重開機後登入,會**自動接著跑完**;自動接續需要連網,最多等 2 分鐘,仍連不上會印出要手動輸入的指令。

結束碼(給腳本用):`0` 成功;`1` 未預期的錯誤;`2` 你取消了;`3` 拒絕執行(那個 Linux 不是這個安裝程式建的);`10` 這台電腦不符合條件;`20` 需要重新開機;`30` WSL 本身裝不起來;`40` 準備 Linux 失敗;`50` 安裝 Pi Agent 失敗;`60` Windows 端設定失敗;`70` 裝好了但確認不通過。

## 安裝程式做了什麼

| 步驟 | 內容 |
|---|---|
| 0 檢查這台電腦 | Windows 版本、CPU、記憶體、磁碟、連接埠(30141 與 6769)是否被占用、是否已有同名 Linux |
| 1 WSL | 沒裝或太舊(< 2.4.4)才處理,這是唯一需要系統管理員的地方 |
| 2 專用 Linux | 下載 Ubuntu 24.04.5(固定版本,驗證 sha256)→ 匯入為 `PiAgent` → 建使用者 `piagent`(沒有密碼、沒有 sudo)→ 開 systemd |
| 3 系統套件 | 以 root 在 Linux 裡裝 apt 套件,並讓使用者的 systemd 在沒人登入時也保持運作 |
| 4 Pi Agent | 以 `piagent` 執行 `install.sh`(和 Linux 版是同一份) |
| 5 Windows 端 | 保活與自動啟動、`pi-agent` 指令、開始功能表捷徑 |
| 6 確認可以使用 | 等 `http://localhost:30141/api/home` 回應,再跑 `tests/smoke.sh` |

每一步都能重跑,做過的會跳過。

### 它在 Windows 上放了什麼

| 位置 | 內容 |
|---|---|
| `%LOCALAPPDATA%\PiAgent\` | `distro\`(Linux 的虛擬硬碟)、`cache\`(下載的檔案)、`bin\pi-agent.cmd`、`keepalive.ps1`、`resume.ps1`、`install.log` |
| 工作排程器 `PiAgentWsl` | 登入時啟動 `keepalive.ps1`;建不起來就退回 `HKCU\...\Run` |
| 使用者的 `Path` | 加入 `%LOCALAPPDATA%\PiAgent\bin`(新開的 PowerShell 才找得到 `pi-agent`) |
| 開始功能表 | `Pi Agent`(開啟 `http://localhost:30141/`) |

**為什麼要保活**:WSL 的官方文件說 systemd 服務**不會**讓 Linux 保持運作,沒人開終端機時,Linux 約 15 秒後就會被
Windows 關掉。`keepalive.ps1` 在你登入期間讓一個 `sleep infinity` 一直掛著。你登出後 Linux 就會停。

## 日常使用

```powershell
pi-agent status      # 看服務狀態
pi-agent restart     # 重新啟動
pi-agent logs        # 看紀錄
pi-agent open        # 用 Windows 瀏覽器開 http://localhost:30141
pi-agent doctor      # 診斷:互通、systemd、Windows 連不連得到 pi-web
```

1. 用瀏覽器開 `http://localhost:30141/`。
2. 在頁面的 **Omnigent** 分頁,連線到你的 Omnigent 伺服器。這台電腦會以 `<電腦名稱> (pi-agent)` 註冊。
3. Claude Code 與 Codex 要各登入一次(登入資料放在 Linux 裡,Windows 上已有的登入不會帶過來):

   ```powershell
   wsl -d PiAgent
   ~/.local/share/pi-agent/bin/claude auth login
   ~/.local/share/pi-agent/bin/codex login
   ```

專案檔案請放在 **Linux 這一側**(`\\wsl.localhost\PiAgent\home\piagent\...` 可以從檔案總管開啟)。放在 `C:\` 底下
(`/mnt/c`)會很慢,而且不保留 Linux 的檔案權限。安裝器會拒絕把 Pi Agent 本身裝在 `/mnt` 底下。

## Windows 互通

預設**開啟**。代理可以在 Linux 裡執行 Windows 程式,例如:

```bash
pi-agent-win ps 'Get-Process | Select-Object -First 5'     # 跑 PowerShell,輸出強制 UTF-8
pi-agent-win run notepad.exe
pi-agent-win open https://example.com                       # 用 Windows 預設瀏覽器開
```

- **權限就是你的 Windows 權限。** 微軟的文件寫得很清楚:Linux 裡的程式存取 Windows 時,用的是啟動 `wsl.exe` 的那位
  Windows 使用者的權限,等同你自己開 PowerShell。代理要什麼,你的帳號就給得了什麼。
- 代理的 PATH 只多了 `System32` 與 PowerShell 兩個目錄,而且放在**最後**,不會讓 Windows 的 node、npm、git 蓋過
  Linux 這邊的。整個 Windows PATH 並沒有灌進來(`appendWindowsPath=false`)。
- 背景服務(systemd)啟動的程式,在 WSL 裡拿不到互通所需的環境變數(microsoft/WSL
  [#8056](https://github.com/microsoft/WSL/issues/8056)、[#8846](https://github.com/microsoft/WSL/issues/8846)、
  [#10812](https://github.com/microsoft/WSL/issues/10812));`pi-agent-win` 會自己去 `/run/WSL` 找一條活著的通道,找不到時
  會多試兩次(很忙的電腦偶爾會漏接一次),再明說(結束碼 3)。實機上的 WSL 3.0.3,在 systemd 服務裡直接呼叫 `powershell.exe` 也通。
- **Codex 的沙盒會擋住 Windows。** Codex 把每個指令放進自己的沙盒,沙盒不讓程式開互通要用的連線
  (`UtilBindVsockAnyPort: socket failed 1`)。Claude Code 沒有這層,直接就能用。安裝時會放一份共用技能
  `windows-from-wsl`(只有互通開著才放)告訴代理怎麼連 Windows。實機上在終端機跑 Codex
  (`--sandbox workspace-write --ask-for-approval on-request`)時,它被擋之後會自己申請到沙盒外執行,**你按一次同意跑一條**。
  在 `codex exec` 這種不能詢問的模式裡,它只會回報失敗。不想每條都按的話,核准畫面的「don't ask again」或 Omnigent 開對話時選
  「Full access」都是 Codex/Omnigent 自己的選項,要不要開由你決定:PowerShell 什麼都做得到,包括 `wsl.exe -u root`,所以
  放行之後,沙盒對 Windows 這邊等於沒有保護。
- 想關掉:重新安裝並加上 `-NoWindowsInterop`(`/etc/wsl.conf` 會寫成 `[interop] enabled=false`,
  Windows 程式完全叫不起來)。
- **別以為「VM 裡沒給 sudo」就擋得住代理**:互通開著時,代理也可以呼叫 `wsl.exe -u root`。互通與權限要一起看。

只能用命令列操作。點按 Windows 圖形介面的按鈕(UI Automation、AutoHotkey)不在這個版本裡。

**實測過的控制能力**(2026-11-03,GitHub 的 Windows Server 2025 雲端機,從 Omnigent 開的 Claude Code 與 Codex 對話、以及
終端機直接下指令):

- `pi-agent doctor` 的 `interop`、`powershell`、`localhost` 三項都是 `[PASS]`。
- 用 `pi-agent-win ps` 讀 Windows 版本、PowerShell 版本、使用者、服務清單、處理程序;讀登錄檔列出已安裝的軟體;查 `git`、
  `node`、`python` 的版本。
- 啟動 Notepad,`Get-Process` 看得到,再 `Stop-Process` 關掉;`pi-agent-win open https://…` 用 Windows 的 Edge 開網頁
  (多個程序),再關掉。雲端機有桌面工作階段(`dwm.exe` 在跑),所以圖形程式啟得起來;沒有桌面的環境不保證。
- 檔案互通:Windows 的 `C:` 在 Linux 是 `/mnt/c`,兩邊寫的檔對方都讀得到。
- **權限**:在這台雲端機上,從 Linux 啟動的 Windows 程式是**系統管理員**(`IsInRole(Administrator)` 為 True)。這取決於
  啟動 WSL 的那個 Windows 帳號與工作階段;一般使用者的 Windows 11 不一定是,但別假設不是。
- 小坑:Windows PowerShell 5.1 的 `Set-Content -Encoding UTF8` 會在檔案前加 BOM,Linux 讀回來會多三個位元組(Codex 自己
  發現並改用無 BOM 的寫法);`cmd.exe` 從 Linux 家目錄啟動時會抱怨「UNC 路徑不支援,改用 Windows 目錄」,不影響結果;
  `wsl.exe -l -v` 在 Linux 裡的輸出編碼要自己處理。

## 升級與重裝

重新執行安裝指令即可:已存在的 `PiAgent` 與裡面的資料會沿用,安裝包與設定會更新。

## 解除安裝

在安裝指令的最後面加上 `-Uninstall`;或用下載下來的 `install-wsl.ps1`:

```powershell
.\install-wsl.ps1 -Uninstall                # 移除 Windows 端的設定,保留 Linux 和裡面的資料
.\install-wsl.ps1 -Uninstall -PurgeData     # 連資料一起刪:先備份,再請你輸入發行版名稱確認
```

不加 `-PurgeData` 的解除安裝,除了移除 Windows 端的設定,也會**停止並關掉 Linux 裡的 pi-web 服務**(`systemctl --user disable`),所以之後即使你自己開了 `wsl -d PiAgent`,它和 Omnigent host 也不會自己跑起來;重新安裝會再開啟。

`-PurgeData` 會先 `wsl --export` 到 `%USERPROFILE%\PiAgent-backup-<日期>.tar`(大小和 Linux 現在差不多;雲端機上測到約 7 GB,要有這麼多空間,也要幾分鐘),**備份失敗就一個檔都不刪**;
而且只會刪「這個安裝程式建立的」Linux(看 `/etc/pi-agent-distro`),不會刪同名的別人的 Linux。`wsl --unregister`
會永久刪除資料,這是微軟文件的警告。

## 疑難排解

先跑 `pi-agent doctor`,它每一項都印 `[PASS]`、`[FAIL]` 或 `[SKIP]`,不會遇到第一個錯誤就停。

| 症狀 | 可能原因與做法 |
|---|---|
| 預檢說不能執行 WSL2 / 虛擬化 | BIOS/UEFI 沒開虛擬化(Intel VT-x、AMD-V);或在虛擬機器裡沒有巢狀虛擬化。Apple 晶片上的 Parallels 做不到 |
| 連接埠被占用 | 加 `-Port 30142`。6769 是 Paseo 用的 |
| 說有同名的 Linux | 你已經有一個叫 `PiAgent` 的 Linux 不是這個安裝程式建的。用 `-DistroName` 換個名字 |
| 瀏覽器連不上 | `pi-agent doctor` 的 `localhost` 一項;`pi-agent status`。`wsl --shutdown` 之後,保活應該會把 Linux 叫回來(尚未驗證);沒有的話登出再登入一次 |
| 電腦睡眠後 Omnigent 離線 | 睡眠期間 Linux 一起暫停;醒來後應該自動重新連線。若沒有,`pi-agent restart` |
| 安裝到一半失敗 | 看 `%LOCALAPPDATA%\PiAgent\install.log`,重跑一次(會從失敗的地方繼續) |
| `wsl --update` 回「災難性的失敗」 | Microsoft Store 那條路失敗,2026-11-04 在一台 Windows 10 22H2 碰到過。安裝程式會自動改用 `wsl --update --web-download`;自己手動跑時也用這個 |
| 從 SSH 連進去跑 `wsl`,回「系統無法存取該檔案」 | Store 版 WSL 在 SSH 連線裡啟動不了,同一台在桌面開 PowerShell 就正常(2026-11-04,金鑰登入的 SSH)。請在桌面裝 |
| 剛裝完馬上 `pi-omnigent connect`,回 `OPERATION_BUSY` | 外掛剛開機時在背景裝 Omnigent(約 30–40 秒),期間會拒絕別的操作。等一分鐘再試(外掛自己的建議也是「請稍後重試」)。Linux、macOS 版也一樣 |
| Windows 指令偶爾失敗,訊息有 `accept4 failed 110` | 互通逾時,電腦很忙時會碰到(實機只剩約 0.3 GB 記憶體時,Pi 和 Claude Code 各碰過一次)。先確認指令有沒有生效,再跑一次 |
| Codex 回 `UtilBindVsockAnyPort: socket failed 1`,或 `pi-agent-win` 說沙盒擋住 | Windows 沒壞,是 Codex 自己的沙盒。見上面「Windows 互通」。不要跑 `wsl --shutdown`,沒有幫助 |
| Pi 用 ChatGPT 登入,最後回 `invalid_grant` | 2026-11-04 在實機上用同一個帳號連續 3 次,換新連結、換裝置編號都一樣,時鐘也正確;原因未明。可以改走 LiteLLM(`pi-agent-litellm set`,再 `probe --apply` 留下真的能回答的模型) |
| Pi 回 `Provider finish_reason: content_filter` | 上游模型把這段請求擋下,不是安裝的問題。實機上經 LiteLLM 的 Fable 5.1 碰到過,切到 Haiku 5.5 同一段話就過了 |
| `pi-omnigent verify` 回 `SERVER_UNREACHABLE` | 這台連不到伺服器。實機上是 Wi-Fi 不穩造成的,再跑一次就過 |
| Paseo 裡 Claude 顯示停用、`pi-paseo models claude` 失敗 | 全新安裝後 Paseo 的 Claude 提供者可能被標成停用(設定檔只在 daemon 啟動時寫一次)。`pi-paseo stop && pi-paseo start` 之後即恢復,實測 `acceptance` 的 Claude 與 Codex 都通過。還沒找出剛安裝完那次為什麼沒準備好 |

## 驗證到哪裡

**已在 GitHub 的 Windows 雲端機上驗證**(`windows-2025`:Windows Server 2025、build 26100、WSL 3.0.3.0、Windows PowerShell 5.1;
工作流程 `wsl2-windows.yml`,每次推送都會跑):

- 匯入 Ubuntu 24.04.5 的 `.wsl` 映像,第一次啟動完全沒有提問;從 `/mnt/d/...` 讀安裝包。
- systemd、使用者級 systemd 服務、`enable-linger` 都正常;整套安裝(pi-web、Claude Code、Codex、Omnigent 外掛、Paseo)
  走完,自我檢查 24 項全過。
- Windows 這邊用 `localhost:30141` 連得到 WSL 裡綁在 `127.0.0.1` 的 pi-web。
- **保活有效,而且需要**:有保活時 90 秒後服務還在;把保活停掉,Linux 就被 Windows 關掉了。
- `pi-agent-win` 在一般 session 裡、以及在 systemd 使用者服務裡(沒有互通環境變數的那種環境)都能執行 PowerShell。
- 重跑安裝、解除安裝(保留資料:Windows 端移除、之後手動再開 Linux,pi-web 不會自己跑起來)、解除安裝並清除資料(真的備份、
  真的 `--unregister`、資料夾清乾淨)。
- 以系統管理員登錄「登入時」的工作排程:登錄成功,觸發條件、電池與執行時間設定如設計。
- 文件裡那行安裝指令(用 UTF-8 解碼、去 BOM、建 ScriptBlock、後面接參數),在本機 HTTP 伺服器上的 dry run。

**已用真的 Omnigent 伺服器驗證**(2026-11-03,同一種雲端機,工作流程 `wsl2-live.yml`,見 [`WSL2-LIVE-TEST.md`](WSL2-LIVE-TEST.md)):

- 外掛用帳號密碼(從標準輸入)連上伺服器,這台機器登記成 Omnigent 主機並上線。Omnigent 網頁能對它開對話、開 bash 終端機、
  瀏覽檔案。
- **Claude Code**:Haiku 5.5 回答 → 對同一個對話切到 Sonnet → 第二句自報 Sonnet 5.5。**Codex**:GPT-6-Luna 回答 →
  切到 GPT-5.6-Terra → 第二句自報 GPT-5。兩個都要先在那台機器上各登入一次(`claude auth login --claudeai`、
  `codex login --device-auth`),授權由人按。
- **Paseo**:daemon 在 WSL2 裡跑;`pi-paseo acceptance`(真的對話加追問)Claude 與 Codex 通過。用官方加密 relay
  (`relay.paseo.sh`)在瀏覽器配對 Paseo 網頁版後,開對話、Sonnet 5.5 → Opus 5.5 切換都成功。
- 代理自己控制 Windows:見上面「實測過的控制能力」。
- **Pi**(第 5 輪):在 Pi 裡 `/login` → OpenAI,用 ChatGPT 帳號登入成功(Pi 給授權網址;授權後瀏覽器轉到打不開的
  `http://127.0.0.1:1455/…`,把那整串網址貼回 Pi)。Omnigent 列出 Pi 的 38 個 OpenAI 模型、可以切換;GPT-6-Luna 與
  GPT-5.6-Terra 被 OpenAI 接受,但**回覆被這個 ChatGPT 帳號的「訂閱分享用量上限」擋下**,所以沒看到 Pi 的回答。
  兩個要注意:這個帳號的後端只收 GPT-6 / GPT-5.6 系列(Pi 登入時自選的 `gpt-5.5` 回 `model_not_found`);登入之後要開
  **新的** Omnigent 對話才看得到模型(舊對話仍顯示「沒有可用模型」)。

**已在一台真的 Windows 電腦上驗證**(2026-11-04,Windows 10 家用版 22H2 build 19045、Ryzen 5 4500、7.9 GB 記憶體、USB Wi-Fi;
是一台平常在用的電腦,開工前只剩 0.4 GB 記憶體;從桌面環境以一般權限執行):

- 完整安裝回 0,自我檢查 24 項全過。第一次約 7 分鐘(下載映像、匯入、裝套件、裝 Pi Agent),重跑約 2 分鐘。
- 用 `-Port 30142` 避開這台原本占 30141 的 pi-web,兩個互不影響。Windows 連 `localhost:30142` 回 200。
- 開新的 PowerShell 直接打 `pi-agent url`、`doctor`、`status` 都正確,`doctor` 7 項全過。
- `pi-agent-win` 在一般 session 和 systemd 服務裡都能執行 PowerShell。權限是一般使用者,不是系統管理員(雲端機才是)。
- 登入時的工作排程從非提權的桌面環境登錄成功(這個帳號屬於系統管理員群組;純標準使用者沒試過)。
- 保活:Linux 從裝好起一路開著,途中 Wi-Fi 斷了 25 分鐘也沒停;Wi-Fi 回來後 Linux 的 DNS 和 HTTPS 都通。
- 記憶體:Linux 這台虛擬機在 Windows 上約用 1.3–2.5 GB,裡面的 pi-web 服務約 660 MB。安裝時全系統承諾記憶體最高到 29.3 / 31.9 GB,
  安裝當下沒有出事,但沒有餘裕(後來當機一次,見下)。
- **Omnigent**:外掛從標準輸入拿密碼連上伺服器,這台以 `DESKTOP-5RSIP1C (pi-agent)` 上線。`pi-omnigent verify` 三個代理都在真的對話裡回答正確
  (Codex 第一次回 `SERVER_UNREACHABLE`,重跑就過,但測試對話沒能自動停掉)。
- **Pi 走 LiteLLM**:`pi-agent-litellm set` 接上閘道,`probe --apply` 從 85 個模型留下 40 個真的能回答的。Omnigent 對話裡 Fable 5.1 回
  `content_filter`,切到 Haiku 5.5 → 完成下面的 Windows 操作,再切到 DeepSeek → 回答。這是第一次看到 Pi 回答。
- **Claude Code**:Haiku 5.5 完成下面的 Windows 操作 → 切到 Sonnet 5.5 → 回答。
- **代理操作 Windows**(Pi 與 Claude Code,都在 Omnigent 對話裡,提示沒有提到 `pi-agent-win`):用 PowerShell 查版本與電腦名稱;建測試檔;用記事本打開,
  讀到視窗標題(`note-pi - 記事本`);**用自己拿到的 PID 只關那一個**;刪掉測試檔。Pi 那次另外從外面觀察:記事本 PID 29688 出現又消失,
  測試檔出現又消失,其他有視窗的程式沒變動。兩次各碰到一次互通逾時,代理都自己查過再重試成功。
- **Codex**:預設沙盒擋住 Windows(見上面「Windows 互通」),在終端機按一次同意就通,讀到 Windows 版本、電腦名稱與可用記憶體。
- **Pi 用 ChatGPT 登入**:同一個帳號 3 次都在最後一步回 `invalid_grant`,見疑難排解。
- **Wi-Fi**:測試期間這台的 USB Wi-Fi(TP-Link,驅動程式 5001.19.113.2)有幾段不穩(掉封包 40–100%,延遲 500–900 毫秒),當時整台電腦的流量只有每秒 0.1 MB
  以下,所以不是下載塞滿。那時連不到 Omnigent 伺服器。
- **這台當機了一次**:13:42 藍屏重開,`0x133 DPC_WATCHDOG_VIOLATION`(某個驅動程式佔住處理器太久),開著的程式全部關閉。之前約半小時已經時好時壞,
  可用記憶體約 0.3 GB。這台上一次藍屏是 2023 年 5 月;當天裝了這個 Linux、把 WSL 升到 3.0.3、跑了好幾個代理,所以**不能排除有關**。傾印檔還沒分析,
  是哪個驅動程式、跟 WSL2 有沒有關都還不知道。**在平常工作用的電腦上試之前,請先存好檔案**,記憶體只有 8 GB 的尤其要小心。

**還沒驗證**:

- Windows 11 實機。上面那台是 Windows 10。
- 乾淨機器的「自動提權 → 裝 WSL → 重開機 → 自動續跑」(E13):那台的 WSL 功能本來就開著,不用重開機,也沒跳過 UAC。安裝程式內建的
  `--web-download` 退路也沒實跑,因為 WSL 已先手動升好。被擋的情況(虛擬化關閉、WSL 被政策停用、磁碟或記憶體不足)的訊息(E14)也還沒看過。
- 實際的「登入時」自動啟動:排程登錄好了,但還沒登出再登入過;有沒有閃視窗也還沒看(E4)。**已知風險**:如果預設終端機是
  Windows Terminal,`-WindowStyle Hidden` 可能不生效,登入後會多一個視窗在跑保活;關掉那個視窗,Linux 就會停。另外,
  公司的 PowerShell 執行原則(AllSigned、Restricted)若蓋過 `-ExecutionPolicy Bypass`,保活與自動續跑都不會執行。
- 睡眠喚醒後 host 自動重連(E8)。
- 真機上 Codex 在 Omnigent 對話裡切換模型與操作 Windows(雲端機上驗過切換模型;Windows 操作在實機終端機裡驗過)。換上新的錯誤訊息後,它知道要申請到沙盒外執行,
  但結果還沒看到,那台就當機了。
- 那次藍屏的原因(傾印檔還沒分析)。
- 真機上用 Omnigent 網頁的選單切換模型:實機上網頁只開過第一個對話,切換是走同一個 API(`PATCH /v1/sessions/{id}`);選單本身是在雲端機上點過的。
- Windows ARM64(E12)。
- **Pi 用 ChatGPT 帳號回答一句話**:雲端機上回覆被用量上限擋下,實機上登入就失敗。走 LiteLLM 的已經過了。
- Paseo 在剛裝完的那次 `models claude` 失敗的原因(重啟 daemon 可解,見疑難排解)。

## 給工程師

- 從原始碼試:`bash scripts/build-wsl-bundle.sh dist dev`,再 `pwsh windows/install-wsl.ps1 -BundlePath dist/pi-agent-installer-dev.tar.gz -PiWebArtifact <網址>`。
  (Windows PowerShell 5.1 讀無 BOM 的檔案會用系統字碼頁,中文會亂碼;用 PowerShell 7,或用上面的一行指令。)
- Linux 端測試:`bash tests/wsl.sh [win ctl env install rootsetup bundle]`。每個測試都在沙盒裡跑,
  Windows 程式與 `useradd`、`apt-get`、`loginctl` 都是替身,不會動到真的 `/etc`、`/run` 或 `/mnt`。
- Windows 端測試:`windows/tests/install-wsl.Tests.ps1`(Pester 5),由 `.github/workflows/wsl2-windows.yml` 在 GitHub 的
  Windows 機器上跑;同一個工作流程的 `e2e` 會真的在那台機器上試 WSL2。
- Linux 端的新東西:`rootfs/bin/pi-agent-win`、`scripts/wsl-root-setup.sh`、`scripts/build-wsl-bundle.sh`、`lib/wsl.sh`,
  以及 `pi-agent`、`pi-agent-env.sh`、`install.sh` 裡 WSL 專屬的幾行。
