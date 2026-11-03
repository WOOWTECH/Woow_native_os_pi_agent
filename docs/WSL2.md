# Pi Agent on Windows 11 (WSL2)

> **狀態:預覽版。** Linux 那一半在沙盒裡測過(`tests/wsl.sh`,150 項,全過)。
> Windows 這一半(`windows/install-wsl.ps1`)**還沒有在真正的 Windows 上跑過**,也沒有跑過
> Pester 測試。下面「尚未驗證」一節列出了哪些行為還只是推測。請先拿一台可以隨時重來的電腦試。

一行 PowerShell 指令,替你的 Windows 11 建一個**專用的 Linux 小系統**(WSL2 裡的 Ubuntu 24.04,
名叫 `PiAgent`),把 Linux 版的 Pi Agent 裝進去,登入 Windows 時自動啟動。Omnigent 看到的就是一台
Linux 主機,所以 Pi Agent、Claude Code、Codex 三個代理的行為跟 Linux 版一樣。

設計與取捨在 [`WSL2-PLAN.md`](WSL2-PLAN.md)。

## 需求

| 項目 | 需求 |
|---|---|
| Windows | **Windows 11 22H2 以上**(build 22621)。Windows 10 不支援 |
| CPU | x64。ARM64 是盡力支援,**尚未測試** |
| 虛擬化 | BIOS/UEFI 要開啟。在虛擬機器裡要有「巢狀虛擬化」;**Apple 晶片上的 Parallels 不行**(Parallels 官方知識庫寫明 WSL2 不能用) |
| 記憶體 | 建議 8 GB 以上(4 GB 是底線) |
| 磁碟 | 可用空間 10 GB 以上 |
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
| `-Port 30142` | 改用別的連接埠(預設 30141) |
| `-DistroName`、`-LinuxUser`、`-InstallDir` | 改名稱或位置 |
| `-RootfsPath`、`-BundlePath`、`-PiWebArtifact` | 離線或開發用:改用本機檔案(映像的雜湊值照樣會驗) |

如果電腦還沒有 WSL,安裝到一半會要求重新開機。重開機後登入,會**自動接著跑完**;自動接續需要連網。

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
  [#10812](https://github.com/microsoft/WSL/issues/10812));`pi-agent-win` 會自己去 `/run/WSL` 找一條活著的通道。
  找不到時它會明說(結束碼 3),並建議跑 `pi-agent doctor`。
- 想關掉:重新安裝並加上 `-NoWindowsInterop`(`/etc/wsl.conf` 會寫成 `[interop] enabled=false`,
  Windows 程式完全叫不起來)。
- **別以為「VM 裡沒給 sudo」就擋得住代理**:互通開著時,代理也可以呼叫 `wsl.exe -u root`。互通與權限要一起看。

只能用命令列操作。點按 Windows 圖形介面的按鈕(UI Automation、AutoHotkey)不在這個版本裡。

## 升級與重裝

重新執行安裝指令即可:已存在的 `PiAgent` 與裡面的資料會沿用,安裝包與設定會更新。

## 解除安裝

在安裝指令的最後面加上 `-Uninstall`;或用下載下來的 `install-wsl.ps1`:

```powershell
.\install-wsl.ps1 -Uninstall                # 移除 Windows 端的設定,保留 Linux 和裡面的資料
.\install-wsl.ps1 -Uninstall -PurgeData     # 連資料一起刪:先備份,再請你輸入發行版名稱確認
```

`-PurgeData` 會先 `wsl --export` 到 `%USERPROFILE%\PiAgent-backup-<日期>.tar`,**備份失敗就一個檔都不刪**;
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

## 尚未驗證

這些是**推測**,對應 [`WSL2-PLAN.md`](WSL2-PLAN.md) 裡要在真機上做的實驗。在做完之前,不要當成事實:

- `wsl --import` 匯入 Ubuntu 的 `.wsl` 檔、第一次啟動完全沒有提問(E1)
- 非互動的 `wsl.exe -u … --exec` 下 `systemctl --user` 可用(E2)
- 保活真的讓 Linux 不被關掉(E3)
- 一般使用者能登錄「登入時」的工作排程,不閃視窗(E4)
- Windows 瀏覽器經 `localhost` 連得到 WSL 裡綁在 127.0.0.1 的 pi-web(E5)
- 背景服務下 `pi-agent-win` 找得到互通通道(E7)
- 睡眠喚醒後 host 自動重連(E8)
- 乾淨電腦:自動提權 → 裝 WSL → 重開機 → 自動接續(E13)
- 虛擬化關閉、WSL 被政策停用時的錯誤訊息(E14)
- ARM64(E12)
- **Omnigent 端對端**:三個代理各開對話並切換模型(E10)

## 給工程師

- 從原始碼試:`bash scripts/build-wsl-bundle.sh dist dev`,再 `pwsh windows/install-wsl.ps1 -BundlePath dist/pi-agent-installer-dev.tar.gz -PiWebArtifact <網址>`。
  (Windows PowerShell 5.1 讀無 BOM 的檔案會用系統字碼頁,中文會亂碼;用 PowerShell 7,或用上面的一行指令。)
- Linux 端測試:`bash tests/wsl.sh [win ctl env install rootsetup bundle]`。每個測試都在沙盒裡跑,
  Windows 程式與 `useradd`、`apt-get`、`loginctl` 都是替身,不會動到真的 `/etc`、`/run` 或 `/mnt`。
- Windows 端測試:`windows/tests/install-wsl.Tests.ps1`(Pester 5),由 `.github/workflows/wsl2-windows.yml` 在 GitHub 的
  Windows 機器上跑;同一個工作流程的 `e2e` 會真的在那台機器上試 WSL2。
- Linux 端的新東西:`rootfs/bin/pi-agent-win`、`scripts/wsl-root-setup.sh`、`scripts/build-wsl-bundle.sh`、`lib/wsl.sh`,
  以及 `pi-agent`、`pi-agent-env.sh`、`install.sh` 裡 WSL 專屬的幾行。
