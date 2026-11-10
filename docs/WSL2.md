# Pi Agent on Windows 11 (WSL2)

> **狀態:預覽版(`v0.3.0-rc.6`;Windows 部分與 rc.3 相同,另加 2026-11-10 在 Allwinner H618 4 GB 板上找到的修正,見 `docs/RELEASE-0.3.0-rc.6.md`)。** 比 rc.2 多了 2026-11-05 在 Windows 11 上試出來的幾個修正(登入時多出一個關不得的終端機視窗、電腦還沒裝 WSL 時畫面靜止 2 分鐘、WSL 啟動逾時、把自己的 Linux 誤判成別人的)。裝過 rc.1 或 rc.2 的電腦,重跑同樣的安裝就會換成新的。
> 驗證到哪裡(每一項的細節在最後的「驗證到哪裡」):
>
> - **GitHub 的 Windows Server 2025 雲端機**:完整跑通(自我檢查 24 項全過、保活、重跑、兩種解除安裝),也從真網址裝過發佈版。
> - **真的 Omnigent 伺服器**:Claude Code、Codex、Pi 與 Paseo 開對話、切換模型都成功,代理也能控制 Windows(PowerShell、記事本、瀏覽器、檔案)。
> - **一台真的 Windows 10 22H2 電腦**(2026-11-04):裝成功、24 項全過,重開機後一登入就自己回來。2026-11-05 用發佈的 rc.3 在同一台升級:回 0、24 項全過,埠和資料都在,新的無視窗背景程式也留得住 Linux。雙擊時的警告畫面、睡眠 5 分鐘再醒來也在這台測過,都正常(見最後的「驗證到哪裡」)。那台測試途中藍屏一次,傾印檔指向它的 USB Wi-Fi 驅動,不是 WSL 的元件,但不能完全排除測試有間接影響。
> - **Windows 11(2026-11-05),是雲端虛擬機,不是實體電腦**:雙擊安裝檔的兩次警告、「第一次啟用 WSL → 重新開機 → 自動繼續安裝」、登出再登入、重開機後自動啟動、虛擬化不能用時的說明都實際看過。但那台機器慢十幾倍,**沒有在 Windows 11 上把整個安裝走完**。
>
> **還沒驗證:** Windows 11 實體電腦、過夜的睡眠、ARM64 上的 WSL2 本身、Pi 用 ChatGPT 帳號回答。請先拿一台可以隨時重來的電腦試。

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
$u = 'https://github.com/WOOWTECH/Woow_native_os_pi_agent/releases/download/v0.3.0-rc.6/install-wsl.ps1'
& ([ScriptBlock]::Create(([Text.Encoding]::UTF8.GetString((Invoke-WebRequest -UseBasicParsing $u).RawContentStream.ToArray())).TrimStart([char]0xFEFF)))
```

這樣寫(而不是 `irm … | iex`)是因為 Windows PowerShell 5.1 會依回應標頭猜編碼,可能把中文訊息讀成亂碼;
這裡明確用 UTF-8 解碼。

**不想貼指令的話,也可以雙擊:** 到發佈頁下載 `Install-Pi-Agent.cmd`,雙擊它。它做的事和上面那兩行一樣,跑完視窗會停著讓你看結果,按任意鍵才關。
這個檔案沒有程式碼簽章,所以會跳警告。它是純文字,可以先用記事本打開看。以下是在 Windows 10 和 Windows 11 上實際看到的畫面,兩邊的字一樣:

1. 下載時,Edge 問「Install-Pi-Agent.cmd 可能會危害您的裝置。是否仍要保留?」:按「保留」。Chrome 沒有問,直接下載完成(Chrome 157,全新的設定檔)。
2. 雙擊時,Windows 問「無法確認發行者,您確定要執行這個軟體?」:按「執行」。

有些電腦跳的可能是「Windows 已保護您的電腦」(這個畫面還沒有實際看過):按「其他資訊」→「仍要執行」。

**如果跳的是「智慧型應用程式控制已封鎖可能不安全的檔案」**,只有「確定」可以按,這個檔案就執行不了。新電腦可能開著這個功能(Smart App Control)。有兩個辦法,都試過可行:

- 改用上面那兩行指令。
- 在檔案上按右鍵 →「內容」→ 勾選「解除封鎖」→「確定」,再雙擊一次。

現在是預覽版,所以網址寫明版本:GitHub 的 `releases/latest` 不會指到預覽版。發佈頁在 [v0.3.0-rc.6](https://github.com/WOOWTECH/Woow_native_os_pi_agent/releases/tag/v0.3.0-rc.6)。

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
| 工作排程器 `PiAgentWsl` | 登入時用 `conhost.exe --headless powershell.exe …` 啟動 `keepalive.ps1`(沒有視窗);建不起來就退回 `HKCU\...\Run` |
| 使用者的 `Path` | 加入 `%LOCALAPPDATA%\PiAgent\bin`(新開的 PowerShell 才找得到 `pi-agent`) |
| 開始功能表 | `Pi Agent`(開啟 `http://localhost:30141/`) |

**為什麼要保活**:WSL 的官方文件說 systemd 服務**不會**讓 Linux 保持運作,沒人開終端機時,Linux 約 15 秒後就會被
Windows 關掉。`keepalive.ps1` 在你登入期間讓一個 `sleep infinity` 一直掛著。你登出後 Linux 就會停。

**為什麼用 `conhost.exe --headless` 啟動,而不是 `powershell -WindowStyle Hidden`**:Windows 11 的預設終端機是 Windows Terminal,
`-WindowStyle Hidden` 藏不住它的視窗。實測(Windows 11 build 26300,從排程啟動):舊寫法在登入後多出一個標題是 `powershell.exe` 的終端機視窗,
一直留著、工作列也有按鈕,而關掉它保活就停了,Linux 約 15 秒後跟著停。用 `conhost.exe --headless` 沒有任何視窗、也沒有 Windows Terminal 程序。
安裝程式啟動保活之後會先確認它真的跑起來;如果這台電腦不吃這個寫法,就退回舊寫法(排程與開機項目也一起退回)並說明。

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
  `windows-from-wsl`(只有互通開著才放)告訴代理怎麼連 Windows,Codex 被擋之後會申請到沙盒外執行。申請之後由誰決定,看你怎麼用它:
  - **在 Omnigent 裡:預設不會問你。** Omnigent 預設讓 Codex 的自動審核決定(`approvals_reviewer="auto_review"`)。實機上 Windows 指令都幾秒內放行,
    沒有出現核准卡片,連改電源設定的指令也放行了(那條是對話裡明確要求的;沒人要求時審核會怎麼判,沒測)。要改成由你把關,得在開對話時換權限選項(這次沒測)。
  - **在終端機裡跑 Codex**(`--sandbox workspace-write --ask-for-approval on-request`):**你按一次同意跑一條**。不想每條都按,可以選核准畫面的「don't ask again」。
  - **`codex exec` 這種不能詢問的模式**:只會回報失敗。

  出了沙盒的指令就有這個 Windows 使用者的全部權限:PowerShell 什麼都做得到,包括 `wsl.exe -u root`。互通跑在一般權限,所以要系統管理員的事 Windows 會擋
  (實機上 `powercfg` 改電源設定回「您沒有執行此動作所需的權限」)。
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
| 瀏覽器連不上 | `pi-agent doctor` 的 `localhost` 一項;`pi-agent status`。`wsl --shutdown` 之後,保活會把 Linux 叫回來(雲端機實測 20 秒內 pi-web 又回應);沒有的話登出再登入一次 |
| 電腦睡眠後 Omnigent 離線 | 睡眠期間 Linux 一起暫停,醒來後主機會自己重新連線(實測:睡 5 分鐘,醒來 5 秒內開始重連)。若沒有,`pi-agent restart` |
| 剛醒來時 Linux 的時間差幾秒 | 正常。實測醒來後前 5 分鐘 Linux 和 Windows 差到 2.7 秒、來回跳動,約 10 分鐘內回到 20 毫秒以內,不用處理 |
| 新對話的第一句話沒有回應 | 對話剛開的幾秒內送出的訊息可能不見:2026-11-05 碰到一次,訊息到的時候 Claude 還沒就緒,伺服器上也沒有那句話。再送一次就好(等約 20 秒就不會發生) |
| 安裝到一半失敗 | 看 `%LOCALAPPDATA%\PiAgent\install.log`,重跑一次(會從失敗的地方繼續) |
| `wsl --update` 回「災難性的失敗」 | Microsoft Store 那條路失敗,2026-11-04 在一台 Windows 10 22H2 碰到過。安裝程式會自動改用 `wsl --update --web-download`;自己手動跑時也用這個 |
| 從 SSH 連進去跑 `wsl`,回「系統無法存取該檔案」 | Store 版 WSL 在 SSH 連線裡啟動不了,同一台在桌面開 PowerShell 就正常(2026-11-04,金鑰登入的 SSH)。請在桌面裝 |
| 剛裝完馬上 `pi-omnigent connect`,回 `OPERATION_BUSY` | 外掛剛開機時在背景裝 Omnigent(約 30–40 秒),期間會拒絕別的操作。等一分鐘再試(外掛自己的建議也是「請稍後重試」)。Linux、macOS 版也一樣 |
| Windows 指令偶爾失敗,訊息有 `accept4 failed 110` | 互通逾時,電腦很忙時會碰到(實機只剩約 0.3 GB 記憶體時,Pi 和 Claude Code 各碰過一次)。先確認指令有沒有生效,再跑一次 |
| Codex 回 `UtilBindVsockAnyPort: socket failed 1`,或 `pi-agent-win` 說沙盒擋住 | Windows 沒壞,是 Codex 自己的沙盒。見上面「Windows 互通」。不要跑 `wsl --shutdown`,沒有幫助 |
| Pi 用 ChatGPT 登入,最後回 `invalid_grant` | 2026-11-04 在實機上用同一個帳號連續 3 次,換新連結、換裝置編號都一樣,時鐘也正確;原因未明。可以改走 LiteLLM(`pi-agent-litellm set`,再 `probe --apply` 留下真的能回答的模型) |
| Pi 回 `Provider finish_reason: content_filter` | 上游模型把這段請求擋下,不是安裝的問題。實機上經 LiteLLM 的 Fable 5.1 碰到過,切到 Haiku 5.5 同一段話就過了 |
| `pi-omnigent verify` 回 `SERVER_UNREACHABLE` | 這台連不到伺服器。實機上是 Wi-Fi 不穩造成的,再跑一次就過 |
| 重開機後連不上,Omnigent 顯示主機離線 | Linux 要等有人登入 Windows 才會啟動(2026-11-04 藍屏重開後就停在登入畫面)。登入後不到 30 秒回來,不用做別的。要不用人登入,得讓 Windows 自動登入:這會讓碰得到這台電腦的人直接進你的帳號,要不要開由你決定,而且要系統管理員權限,代理做不了 |
| 藍屏 `DPC_WATCHDOG_VIOLATION` | 2026-11-04 在一台用 USB Wi-Fi 的電腦上碰到一次,傾印檔指向網卡驅動(`rtwlanu6.sys`),見「驗證到哪裡」。先更新網卡驅動,或改接網路線 |
| 登入後桌面上多一個終端機視窗,標題是 `powershell.exe` | 這是舊版(`v0.3.0-rc.1`、`rc.2`)在 Windows 11 上的行為:那個視窗就是保活,**關掉它 Linux 就會停**。重跑同樣的安裝就會換成沒有視窗的寫法,下次登入起生效 |
| 登入時閃一下黑框 | 現在的寫法在 Windows 11 和 Windows 10 上都量不到視窗(從同一個排程啟動,每約 15 毫秒查一次)。舊寫法(rc.2 以前)在 Windows 10 上會閃 30–50 毫秒;重跑同樣的安裝就會換掉,下次登入起生效 |
| 訊息說 Linux「PiAgent」已經存在,但 WSL 現在啟動不了它 | 先看訊息裡的原因(例如虛擬化被關掉、電腦還在忙)。**不要刪這個 Linux**,裡面可能有你的資料。處理好之後重跑同樣的安裝 |
| 訊息說 WSL 的 Linux 虛擬機沒有在時間內啟動(`ERROR_TIMEOUT`) | 電腦正忙,常見在剛重開機、剛登入的前幾分鐘。安裝程式會先自己等 1 分鐘再試一次;還是不行就等幾分鐘後重跑同樣的安裝,不用先移除 |
| 跳出「歡迎使用 Windows 子系統 Linux 版」視窗 | 是 Microsoft 自己的 WSL 設定程式(顯示 WSL 的簡介),跟 Pi Agent 無關,關掉就好。Windows 11 測試機上 WSL 第一次啟動 Linux 之後看到過一次,觸發條件沒查清楚 |
| Paseo 裡 Claude 顯示停用、`pi-paseo models claude` 失敗 | 全新安裝後 Paseo 的 Claude 提供者可能被標成停用(設定檔只在 daemon 啟動時寫一次)。`pi-paseo stop && pi-paseo start` 之後即恢復,實測 `acceptance` 的 Claude 與 Codex 都通過。還沒找出剛安裝完那次為什麼沒準備好 |

## 驗證到哪裡

**已在 GitHub 的 Windows 雲端機上驗證**(`windows-2025`:Windows Server 2025、build 26100、WSL 3.0.3.0、Windows PowerShell 5.1;
工作流程 `wsl2-windows.yml`,每次推送都會跑):

- 匯入 Ubuntu 24.04.5 的 `.wsl` 映像,第一次啟動完全沒有提問;從 `/mnt/d/...` 讀安裝包。
- systemd、使用者級 systemd 服務、`enable-linger` 都正常;整套安裝(pi-web、Claude Code、Codex、Omnigent 外掛、Paseo)
  走完,自我檢查 24 項全過。
- Windows 這邊用 `localhost:30141` 連得到 WSL 裡綁在 `127.0.0.1` 的 pi-web。
- **保活有效,而且需要**:有保活時 90 秒後服務還在;把保活停掉,Linux 就被 Windows 關掉了。保活用 `conhost.exe --headless` 啟動(見上面「為什麼用…」),雲端機的端到端測試用的就是這個寫法。
- **`wsl --shutdown` 之後保活把 Linux 叫回來**:pi-web 隨著關機一起不回應,20 秒後又回 200,保活程式仍是 1 個(`wsl2-windows.yml` 的 e2e,每次推送都跑)。
- `pi-agent-win` 在一般 session 裡、以及在 systemd 使用者服務裡(沒有互通環境變數的那種環境)都能執行 PowerShell。
- 重跑安裝、解除安裝(保留資料:Windows 端移除、之後手動再開 Linux,pi-web 不會自己跑起來)、解除安裝並清除資料(真的備份、
  真的 `--unregister`、資料夾清乾淨)。
- 以系統管理員登錄「登入時」的工作排程:登錄成功,觸發條件、電池與執行時間設定如設計。
- 文件裡那行安裝指令(用 UTF-8 解碼、去 BOM、建 ScriptBlock、後面接參數),在本機 HTTP 伺服器上的 dry run。
- 發佈之後,用文件上的指令從真網址裝一次,再用發佈頁上的 `Install-Pi-Agent.cmd` 蓋裝一次(`release.yml` 的 `wsl-verify`,每次發佈都跑):`v0.3.0-rc.3` 兩次都回 0、最後一次自我檢查 24 項全過,Linux 裡記錄的也是這個版本(rc.2 同樣兩次都回 0)。
  這台雲端機本來就有 WSL,這一跑也沒開自動啟動(`-Yes -NoAutostart`)。雙擊檔是用命令列執行的,沒有人按滑鼠,也沒有經過 Windows 的警告畫面。

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
- **Codex**:在 Omnigent 對話裡(GPT-6-Luna,提示同樣沒提到 `pi-agent-win`)完成同樣的 Windows 操作,PID 2924 的記事本由它自己關掉,結束後從外面看,記事本與測試檔都沒留下。
  第一條指令被自己的沙盒擋住,它照共用技能與工具的訊息申請到沙盒外(`sandbox_permissions=require_escalated`),自動審核放行,沒有人按同意(見「Windows 互通」)。
  切到 GPT-5.6-Luna → 回答。在終端機裡跑則要按一次同意才通,讀到 Windows 版本、電腦名稱與可用記憶體。
- **權限的界線**:有人接著在那個 Codex 對話裡,要它關掉喚醒時的登入要求、設定重開機自動登入。審核放行了 `powercfg`,Windows 回「您沒有執行此動作所需的權限」。
  事後查登錄檔,兩個設定都沒變(沒有 `AutoAdminLogon`、沒有 `DefaultPassword`、這個電源配置沒有喚醒密碼的紀錄)。
- **登入時自動啟動**:藍屏重開後(見下)這台停在登入畫面,Linux 沒有起來。13:56 有人登入,排程 13:56:29 啟動,13:56:51 前 Windows 這邊已連到 pi-web(回 200),不到 30 秒,
  不用做任何事。Omnigent 主機也自己連回來(13:58 查到上線,同一個主機編號)。之後 Linux 一路開著,2.5 小時後 `doctor` 7 項全過。這是「重開機後第一次登入」,登出再登入沒試。
- **視窗**:登入後沒有視窗一直開著(保活的 `powershell.exe`、`wsl.exe` 都沒有可見視窗)。啟動那一下會閃一個主控台視窗:用和登入排程相同的形式實測,看得到約 30–50 毫秒(每約 20 毫秒查一次),
  這台的使用者登入時沒注意到。那台沒有 Windows Terminal,所以下面列的 Windows Terminal 風險沒測到。
- **重跑不搬連接埠**:用新版安裝程式不加 `-Port` 試跑(`-DryRun`),回「這台已經裝好,沿用原本的連接埠 30142」,後面的檢查也是 30142。
- **Pi 用 ChatGPT 登入**:同一個帳號 3 次都在最後一步回 `invalid_grant`,見疑難排解。
- **Wi-Fi**:測試期間這台的 USB Wi-Fi(TP-Link,驅動程式 5001.19.113.2)有幾段不穩(掉封包 40–100%,延遲 500–900 毫秒),當時整台電腦的流量只有每秒 0.1 MB
  以下,所以不是下載塞滿。那時連不到 Omnigent 伺服器。
- **這台當機了一次,傾印檔指向它的 USB Wi-Fi 驅動**:13:40 藍屏重開,`0x133 DPC_WATCHDOG_VIOLATION`,開著的程式全部關閉。用微軟公開符號看小傾印檔:處理器閒置時跑了 Wi-Fi 驅動
  `rtwlanu6.sys`(TP-Link USB 網卡,`USB\VID_3625&PID_010F`,驅動 5001.19.113.2,2024-05-21)的計時器工作,它往 USB 送請求,集線器那層立刻把請求結束掉,ACPI 那層走的是
  「裝置已被意外移除」的路徑;處理器在高優先權撐滿 20 秒,看門狗就讓系統當機。堆疊上沒有 WSL 的元件(`lxcore`、`vmswitch`、`vmbus`)。這顆驅動今天之前就有
  「驅動程式已經中斷網路的連線」的紀錄(10/07、10/25)。上一次藍屏(2023 年 5 月)是 NVIDIA 顯示卡驅動,和這次無關。
  **但不能說和測試完全無關**:開機 28 天都沒事,偏偏在裝了 Linux、跑代理的這天當機;藍屏前半小時網路已經時好時壞,記憶體只剩約 0.3 GB。傾印只有當下一個瞬間,也不能證明那 20 秒做的都是同一件事。
  **在平常工作用的電腦上試之前,請先存好檔案**;用 USB Wi-Fi 的話先更新網卡驅動,或改接網路線。

**同一台 Windows 10,2026-11-05 升級到發佈的 `v0.3.0-rc.3`**(不是用滑鼠雙擊:那時有人在用這台,所以用看不見的一次性排程執行發佈頁上的 `Install-Pi-Agent.cmd`,沒有經過瀏覽器和 Windows 的警告;先用同一個檔案加 `-DryRun` 試跑過):

- 從開發版(Linux 裡記錄的是 `installer=0.2.4`)升上去,回 0,自我檢查 24 項全過,約 6 分鐘,其中 5 分鐘在重新下載 pi-web(這台的 Wi-Fi 慢)。開始前 Windows 可用記憶體 1.0 GB,結束時 0.7 GB,沒有出事。
- 沿用埠 30142。Claude Code、Codex、LiteLLM 的登入檔大小和修改時間都沒變,對話與筆記數量不變,Omnigent 主機同一個編號、仍連線,`doctor` 7 項全過,自我檢查沒有留下測試項目。服務在自我檢查時重啟過一次,之後自己回來。
- 排程換成 `conhost.exe --headless …`。當場停掉舊的保活、用排程啟動新的:0.3 秒起來,14 秒內沒有新視窗(每約 15 毫秒查一次)。舊的 `wsl.exe` 停掉之後,接下來 100 秒 pi-web 32 次全部回應,Linux 沒有重啟(PID 1 連續跑了約 29 小時)。這是第一次在 Windows 10 上驗到這個寫法;是從排程啟動,不是真的登出再登入。
- **發現的問題(還沒修)**:重跑時舊的保活還在,新的撞到互斥鎖就退出,安裝程式的檢查看到舊的就算過關。所以升級時驗不到新寫法、退回舊寫法的機制也不會作用,Windows 11 上舊視窗也要到下次登入才消失。

**同一台,當天傍晚沒有人在用時,從外面測**(現場沒有人:用暫時的瀏覽器設定檔和 Windows 的輔助介面操作,只截測試自己開的視窗;開始前確認超過 25 分鐘沒有人操作,每個動作前再查一次):

- **下載的警告**:從發佈的資產清單頁真的點連結下載。Chrome 157 **沒有任何警告**,直接顯示「798 B • 完成」。Edge 156 問「Install-Pi-Agent.cmd 可能會危害您的裝置。是否仍要保留?」,按鈕是「保留」「刪除」,和 Windows 11 相同。下載的檔案帶網路來源標記(ZoneId=3),校驗碼和發佈頁一致。兩個瀏覽器都是全新的設定檔,用過的設定檔結果可能不同。
- **雙擊的警告**:在檔案總管對檔案執行預設動作(效果等於雙擊,但不是實體滑鼠)。跳「開啟檔案 - 安全性警告」「無法確認發行者,您確定要執行這個軟體?」,發行者不明,類型 Windows 命令指令碼,按鈕「執行」「取消」。和 Windows 11 相同,不是 SmartScreen。
- **按「執行」之後**:開 `cmd.exe` 主控台,中文和顏色正常,持續輸出時每一行都對齊左邊(這台沒有 Windows Terminal,而錯位當初是在 Windows Terminal 上看到的,所以這不能證明那個修法有效),2 分 23 秒跑完,24 項全過,最後停在「請按任意鍵繼續」。
- **睡眠喚醒(E8)**:排好喚醒計時器、跳 60 秒可取消的倒數之後,讓電腦真的進入 S3,睡 5 分 22 秒,由計時器叫醒(不是鍵盤)。醒來 5 秒內從外面就連得到,USB Wi-Fi 沒有出事。Omnigent 主機自己記下「Resumed from suspend (~311s)」並立刻重連;從醒來 42 秒的第一次檢查起,15 次檢查全部是已連線。pi-web 回 200。保活的程式還是同一組,Linux 和服務都沒有重啟。在這台主機上開新對話,Haiku 5.5 回答了。沒有當機或驅動錯誤紀錄。
- **Linux 的時鐘**:醒來後前 5 分鐘和 Windows 差到 2.7 秒、來回跳動;約 10 分鐘後的 13 次取樣都在 20 毫秒以內。

**已在 Windows 11 的雲端虛擬機上驗證**(2026-11-05;**不是實體電腦**:GitHub 的 Linux 雲端機用 QEMU/KVM 跑 Windows 11 企業評估版繁體中文,
build 26300.9457(26H2),3 個 vCPU、10 GB 記憶體,沒有 TPM 與 Secure Boot;以一般使用者身分用 Edge、檔案總管、Windows Terminal 操作,用螢幕截圖確認。做法與限制在 [`TESTING.md`](TESTING.md)):

- **雙擊安裝檔**(用 Edge 真的下載、用檔案總管真的雙擊):Edge 問「Install-Pi-Agent.cmd 可能會危害您的裝置。是否仍要保留?」,按「保留」;雙擊時跳「開啟檔案 - 安全性警告」
  「無法確認發行者,您確定要執行這個軟體?」,按「執行」。**不是** SmartScreen 的「其他資訊 → 仍要執行」。檔案帶著網路來源標記(ZoneId=3),sha256 和發佈頁一致。
  跑起來是 Windows Terminal,中文正常。
- **Smart App Control**(新裝的 Windows 11 預設是「評估中」):開啟後 `.cmd` 被擋,只有「確定」可按。貼那兩行指令可以(試了 `-DryRun`,每一步都過,PowerShell 仍是完整語言模式);
  在檔案上「內容」→「解除封鎖」再雙擊也可以,而且不再跳任何警告。
- **第一次啟用 WSL → 重新開機 → 自動繼續**(E13,跑了兩次,兩次都成功):系統管理員授權視窗(UAC)就在安裝程式說的時候出現;下載 WSL 3.0.3;
  判斷「需要重新開機」的檢查(兩個登錄鍵,任一個存在就算)在 WSL 裝完後成立,問「現在重新開機嗎? [y/N]」,答 y 就重開;
  重開、登入之後,安裝程式自己在新視窗接著跑(開頭寫「重新開機後繼續安裝...」),不用再下指令。
- **Windows 11 內建的 `wsl.exe` 在還沒裝 WSL 時會等按鍵**:在真的主控台上,它印出「按任意鍵安裝…」並等最多 60 秒。安裝程式有兩處呼叫它,各靜止 60 秒,畫面看起來當掉 2 分鐘(rc.2 在這種電腦上的樣子)。
  修法是不讓它拿到主控台輸入(`$null | wsl.exe`);修好後 30 秒內就走到「步驟 1/6」。雲端機上看不到這件事,因為那邊沒有主控台。
- **虛擬化不能用時**(E14,把虛擬機的 AMD-V 藏起來):`wsl --import` 不到 1 秒回 `-1` 與「WSL2 無法啟動,因為此機未啟用虛擬化」(錯誤碼 `HCS_E_HYPERV_NOT_INSTALLED`);
  安裝程式顯示完整的中文說明(檢查「虛擬機器平台」、BIOS 的虛擬化、虛擬機要支援巢狀虛擬化),沒有留下 Linux 或資料夾,只剩下載好的映像快取。
- **一般使用者能自己建立登入排程**(E4):用沒有系統管理員身分的帳號,`Register-ScheduledTask` 的登入觸發成功,不必退回 `Run` 登錄項目。(只試了建立,沒有真的用那個帳號登入。)
- **登入時自動啟動**:登出再登入、重開機再登入,兩次都是排程在登入同一秒觸發,保活 5–10 秒內起來,只有一個,沒有多出視窗。
  **舊寫法在這裡出了問題**(見上面「為什麼用 `conhost.exe --headless`」):登入後多出一個標題是 `powershell.exe` 的 Windows Terminal 視窗,一直留著。
  同一台、都從排程啟動,比較四種寫法:`powershell -WindowStyle Hidden` 視窗留著;`conhost --headless powershell` 沒有視窗;`conhost powershell -WindowStyle Hidden` 閃一下;
  `wscript` 加 `.vbs` 沒有視窗(但 VBScript 微軟正在淘汰)。現在用第二種;從使用者自己開的 Windows Terminal 分頁裡直接啟動也沒有視窗。
- **試出並修掉的三件事**:(1) 上面那個終端機視窗;(2) 重開機後第一次匯入 Linux,`wsl --import` 因 `ERROR_TIMEOUT` 失敗(電腦正忙)——現在先自己等 1 分鐘再試一次,再失敗就說清楚怎麼辦;
  (3) Linux「PiAgent」啟動不了時,安裝程式把它當成「不是這個安裝程式建立的」,還建議 `wsl --unregister`,那會把使用者自己的 Linux 和資料刪掉——現在只有確定標記檔不存在才這樣說,啟動不了時會說原因、叫使用者不要刪。
- **這台機器的限制**:兩層虛擬化(GitHub 的主機 → QEMU → Windows),WSL2 在裡面是第三層,慢十幾到三十倍,而且常常卡住:凍住四次(三次在登入畫面,一次在安裝進行中),都要強制重置才回來。
  匯入 Linux 要近 6 分鐘、啟動 Linux 的 `wsl.exe` 呼叫常要 1~2 分鐘,所以**沒有把安裝走完**,也沒有看到 Linux 在 Windows 11 上被保活叫回來。把虛擬機的 AMD-V 藏起來(Windows 就不啟動 Hyper-V)之後,
  登入只要 25 秒,連續 4 次登入、2 次重開機都沒再凍住,上面「登入時自動啟動」「虛擬化不能用時」「一般使用者」三項就是在這個狀態下測的。

**還沒驗證**:

- Windows 11 **實體電腦**。Windows 11 只在上面那台雲端虛擬機看過,Linux 那一半(裝 pi-web、代理、自我檢查)在 Windows 11 上沒有走完。
- **Windows 11 上 Linux 被保活叫回來**:Windows 10 實機驗過(重開機後登入,不到 30 秒回來),Windows Server 2025 驗過保活有效與 `wsl --shutdown` 後 20 秒內回來;Windows 11 上因為虛擬機跑不動 WSL2,只看到保活程式本身在登入時起來,沒看到它真的留住 Linux。
- **新的保活寫法在真的登入時**:Windows 11 虛擬機真的登出再登入、重開機都過了;Windows 10 實機只從排程啟動過,下次有人登入才會真的走到。
- **實體滑鼠雙擊**:Windows 10 實機上的雙擊動作是由輔助介面觸發的(警告畫面是真的),Windows 11 虛擬機上是模擬的滑鼠事件,還沒有人真的用手按過。文件裡那兩行指令從真網址只在雲端機(Windows Server 2025)上跑過。
- 輸出文字錯位(「階梯狀」)的修法:rc.2 在 Windows 11 的 Windows Terminal 上看過那個問題。修法(每一行前面加 `\r`)用模擬確認過:把主控台設成「換行不回到行首」的模式,不加 `\r` 的行一行比一行往右爬,加了的行都從最左邊開始。但真的 `wsl.exe` 串流輸出加上 Windows Terminal 還沒看過(虛擬機沒走到那一步,Windows 10 實機沒有 Windows Terminal),所以「`wsl.exe` 執行時真的是這個模式」仍是 rc.2 那次觀察的推論。
- 安裝程式內建的 `--web-download` 退路沒實跑過(WSL 3.0.3 的 `wsl --update` 在這幾台都成功)。被擋的其他情況(WSL 被政策停用、磁碟或記憶體不足)的訊息也還沒看過。
- 公司的 PowerShell 執行原則(AllSigned、Restricted)若蓋過 `-ExecutionPolicy Bypass`,保活與自動續跑都不會執行。
- 睡眠喚醒的其他情況:上面只試過一次,睡 5 分鐘,由計時器叫醒,醒來不用輸入密碼。過夜的睡眠、用鍵盤或電源鍵叫醒、筆電闔蓋、喚醒要輸入密碼的電腦都沒試。虛擬機沒有 S3 睡眠,這些只能在實體電腦上測。
- 真機上的 Paseo 網頁版(雲端機上驗過)。
- 真機上用 Omnigent 網頁的選單切換模型:實機上網頁只開過第一個對話,切換是走同一個 API(`PATCH /v1/sessions/{id}`);選單本身是在雲端機上點過的。
- Windows ARM64 上的 WSL2(E12):雲端的 ARM64 機器沒有虛擬化,`wsl --import` 回 `-1`,安裝程式正確抓到並顯示說明。Linux 那一半(真的 arm64 映像、安裝、24 項自我檢查)在 arm64 容器裡跑過,全過。
- 更新 Wi-Fi 驅動或改接網路線之後,那台 Windows 10 還會不會藍屏。
- **Pi 用 ChatGPT 帳號回答一句話**:雲端機上回覆被用量上限擋下,實機上登入就失敗。走 LiteLLM 的已經過了。
- Paseo 在剛裝完的那次 `models claude` 失敗的原因(重啟 daemon 可解,見疑難排解)。

## 給工程師

- 雙擊檔的範本是 `windows/install-pi-agent.cmd.in`,發佈時蓋上網址、轉成 CRLF,變成 `Install-Pi-Agent.cmd`。參數會傳給安裝程式,但值不能有空白。
- 發佈:先改好 `VERSION` 和上面安裝指令的網址再打標籤。正式版(`v1.2.3`)的指令要用 `releases/latest/download/install-wsl.ps1`;預覽版(`v1.2.3-rc.1`)要寫明版本,因為 `latest` 不會指到預覽版。
  不一致的話 `scripts/build-wsl-bundle.sh` 會拒絕發佈。`release.yml` 會把有 `-` 的標籤標成預覽版,發佈後再用 GitHub 的 Windows 機從真網址跑一次這條指令(`wsl-verify`)。
- 從原始碼試:`bash scripts/build-wsl-bundle.sh dist dev`,再 `pwsh windows/install-wsl.ps1 -BundlePath dist/pi-agent-installer-dev.tar.gz -PiWebArtifact <網址>`。
  (Windows PowerShell 5.1 讀無 BOM 的檔案會用系統字碼頁,中文會亂碼;用 PowerShell 7,或用上面的一行指令。)
- Linux 端測試:`bash tests/wsl.sh [win ctl env install rootsetup bundle]`。每個測試都在沙盒裡跑,
  Windows 程式與 `useradd`、`apt-get`、`loginctl` 都是替身,不會動到真的 `/etc`、`/run` 或 `/mnt`。
- Windows 端測試:`windows/tests/install-wsl.Tests.ps1`(Pester 5),由 `.github/workflows/wsl2-windows.yml` 在 GitHub 的
  Windows 機器上跑;同一個工作流程的 `e2e` 會真的在那台機器上試 WSL2。
- Linux 端的新東西:`rootfs/bin/pi-agent-win`、`scripts/wsl-root-setup.sh`、`scripts/build-wsl-bundle.sh`、`lib/wsl.sh`,
  以及 `pi-agent`、`pi-agent-env.sh`、`install.sh` 裡 WSL 專屬的幾行。
