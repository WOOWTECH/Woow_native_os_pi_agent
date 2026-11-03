# Pi Agent 原生版 — Windows(WSL2)規劃

> 狀態:**規劃稿,尚未實作** · 2026-11-03 · 分支 `windows-wsl2`(基於 v0.2.4,`3427c25`)· 未推送

這份文件回答一件事:怎麼讓 Windows 電腦也能裝 Pi Agent,並且在 Omnigent 上連得到、
Pi Agent / Claude Code / Codex 三個代理都能開對話和切換模型。

原生 Windows(非 WSL)已在 2026-11-03 暫緩,理由和證據在 `windows-native` 分支的
`docs/WINDOWS-NATIVE-RESEARCH.md`(上游目前只支援「降級模式」)。本文是 `DESIGN.md`
Q3「v1 走 WSL2」的落實。

## 0. 摘要

- **做法**:一支 PowerShell 安裝程式,替使用者建一個專用的 WSL2 Linux(名叫 `PiAgent`,
  Ubuntu 24.04),把現有的 Linux 版裝進去,登入 Windows 時自動啟動並防止被 Windows
  閒置關掉。使用者用 Windows 的瀏覽器開 `http://localhost:30141`。
- **為什麼可行**:WSL2 跑的是真的 Linux 核心,對 Omnigent 來說就是一台 Linux 主機,所以**預期**
  原生對話、終端機(tmux)、三個代理都跟 Linux 版一樣(要靠 E10 實測確認)。原生 Windows 的限制
  (原生 harness 與 tmux 被擋)在這條路上不存在。
- **多出來的功能**:Windows 互通(預設開、可關)。代理可以在 WSL 裡執行 `powershell.exe`、
  `cmd.exe`,用使用者的 Windows 權限操作 Windows 本機。
- **可重用的**:install.sh 已把 `wsl` 當 Linux 處理;預建 pi-web、smoke 測試、host 名稱規則
  都能直接用。要新增的是 Windows 端安裝器、保活與自動啟動、互通小工具、WSL 專屬測試。
- **最大的障礙是測試機**:這台 Mac 即使買了 Parallels 也不能測 WSL2(第 2 節第 11 列)。
  最便宜的候選是 GitHub 免費的 Windows 雲端機,但**還沒實測過能不能開 WSL2**(第 6 節)。
- **工作量(估計)**:7–11 個工作天;其中必須用真 Windows 的約 1–3 天。

## 1. 成功標準

和當初要求的三件事一一對應,另加維運需要的幾項:

1. 乾淨的 Windows 11 → 一行指令 → 完成後 Windows 瀏覽器開得起 `http://localhost:30141`。
2. Omnigent 上看得到這台電腦的 host(名稱 `<電腦名> (pi-agent)`),狀態 online。
3. 在 Omnigent 網頁新開對話:**Pi Agent、Claude Code、Codex 各一個**都能收發訊息,
   且每個都能在對話中**切換模型**(3 個代理 × 2 項 = 6 項全過)。
4. 關掉所有終端機、登出再登入、重新開機後,**不用手動做任何事**就恢復(host 回到 online)。
5. 代理能從對話裡執行 `powershell.exe` 並拿到結果,**互動 shell 與背景服務啟動的代理兩種情境都要過**。
6. 重跑安裝程式不會壞;解除安裝乾淨(預設不刪資料)。
7. `tests/smoke.sh` 24 項全過,加上 WSL 專屬項目。

## 2. 已查證的事實

2026-11-03 查的官方文件與實際檔案;來源編號見第 10 節。

| # | 項目 | 查到的 | 對設計的影響 | 來源 |
|---|---|---|---|---|
| 1 | 最低系統 | WSL2 需 Windows 10 2004(build 19041)以上或 Windows 11;但 `wsl.conf` 的 `[boot]`(含 systemd)文件寫「只在 Windows 11 與 Server 2022」 | 門檻訂 **Windows 11**(建議 22H2、build 22621 以上);Windows 10 不在範圍 | S1 S2 |
| 2 | 第一次啟用 | `wsl --install` 要用系統管理員執行,然後重開機 | 安裝器要能自動提權、重開機後續跑;已經裝好 WSL 的電腦完全不需要系統管理員 | S1 |
| 3 | systemd | 需 WSL 0.67.6 以上;`[boot] systemd=true` 預設 false,改了要 `wsl --shutdown` 才生效 | 我們自己寫 wsl.conf,不依賴映像預設值,重啟後驗證 | S2 S4 |
| 4 | 會被閒置關掉 | 官方:「systemd 服務**不會**讓 WSL 實例保持運作」。`[general] instanceIdleTimeout` 預設 15000 ms,`-1` 為不自動關(WSL 2.5.4 起);`[wsl2] vmIdleTimeout` 預設 60000 ms(僅 Windows 11) | **一定要保活**,否則沒人開終端機時整套服務會被關掉 | S4 S2 S5 |
| 5 | 瀏覽器連線 | NAT(預設)下 Windows 瀏覽器可用 `localhost` 連 WSL 內服務;`localhostForwarding` 預設 true,涵蓋綁在 localhost 的 port | pi-web 維持只綁 127.0.0.1,和其他平台一致 | S6 S2 |
| 6 | 區網存取 | NAT 下區網連不到 WSL;要 portproxy,或 mirrored 模式(Windows 11 22H2 以上)加 Hyper-V 防火牆規則 | v1 不做區網/手機直連 | S6 |
| 7 | 互通 | `[interop] enabled` 與 `appendWindowsPath` 預設都是 true;設 false 會擋掉 Windows 程式。WSL 內存取 Windows 檔案與程式時,用的是**啟動 wsl.exe 的那位 Windows 使用者**的權限 | 預設開;代理的權限 = 使用者的權限;要提供關閉開關 | S2 S7 |
| 8 | 公司管控 | IT 可用 Intune / 群組原則管 WSL;「控制使用者能用哪些發行版」「控制 root 權限」官方列為尚不支援 | 預檢要認得 WSL 被禁用的情況並給明確訊息 | S7 |
| 9 | 發行版格式 | `.wsl` 是 tar.gz(內含 `/etc/wsl-distribution.conf`、`/etc/wsl.conf`),WSL 2.4.4 以上。`wsl --import <名稱> <位置> <檔案>` 與 `wsl --install <發行版> --name <自訂名>` 都有文件。首次啟動的提問(OOBE)只在「第一次開互動 shell」時跑 | 用 `--import` 搭配自己釘的映像;`--install --name` 當備案 | S3 S8 S9 |
| 10 | 釘住的映像 | Ubuntu 24.04.5:amd64 371 MiB、sha256 `bb415d82…6039e`;arm64 370 MiB、sha256 `74478b50…a806b`。Microsoft 的 `DistributionInfo.json` 與 Canonical 的 `SHA256SUMS` 兩邊**一致**(實查) | 直接釘進 `windows/lib/pins.ps1`,和 Linux 實測用的是同一個大版本 | S10 S11 |
| 11 | 這台 Mac | Parallels 知識庫(最後審閱 2026-08-25):Apple 晶片上的 Windows 11「不支援巢狀虛擬化……WSL2 也不能用,改用 WSL1」 | 這台 M2 Mac **不能**當 WSL2 測試機,買授權也一樣 | S12 |
| 12 | GitHub 的 Windows 雲端機 | Windows Server 2025 映像(20261021)內建 WSL2 套件;第三方 `Particular/setup-wsl-action` 聲明可在託管 Windows 機上跑 WSL2(「需要巢狀虛擬化」);GitHub 沒有官方明說 | 可能是免費的自動化測試場;**必須先實測**(P3 spike) | S13 S14 |
| 13 | ARM64 | Ubuntu 24.04 有 arm64 的 WSL 映像;本 repo 的 `release.yml` 只建 `linux-x64` 與 `macos-arm64` 的預建 pi-web | Windows ARM64 要補 `linux-arm64` 預建包;CI 沒有可測的 ARM Windows | S10、`release.yml` |
| 14 | 現有程式 | `pa_os` 用 `/proc/version` 判斷 wsl;install.sh 的 preflight、uv、預建包、service 都把 wsl 當 linux;`build-piweb-artifact.sh` 把 wsl 標成 linux。但 `pi-agent open` 只試 `xdg-open`/`open`;`stage_service` 用 `systemctl --user show-environment` 判斷有沒有使用者級 systemd | 重用率高;缺口:`open` 在 WSL 多半沒有 `xdg-open`,`stage_service` 在沒有登入工作階段時可能誤判(待 E2) | 本 repo |

## 3. 設計

### 3.1 整體

```
Windows 11 使用者帳號
 ├─ install-wsl.ps1(一行安裝)──► 啟用 WSL ──► 匯入專用 Linux「PiAgent」
 ├─ 登入時自動啟動 ──► wsl.exe -d PiAgent --exec sleep infinity     (保活,防閒置關閉)
 ├─ pi-agent.cmd / 開始功能表「Pi Agent」 ──► 轉呼叫 VM 內的 pi-agent、開瀏覽器
 └─ Windows 瀏覽器 ──► localhost:30141 ──(WSL localhost 轉發)──┐
                                                               ▼
                         PiAgent(Ubuntu 24.04,systemd,一般使用者 piagent)
                          └─ pi-web.service(使用者級 systemd)
                              ├─ pi-web + Omnigent 外掛 → Omnigent host ──對外連線──► Omnigent 伺服器
                              ├─ Pi / Claude Code / Codex(Linux 版:原生 harness、tmux 都可用)
                              └─ pi-agent-win ──互通──► powershell.exe / cmd.exe / explorer.exe(Windows)
```

### 3.2 決定(推薦預設)

| # | 決定 | 預設 | 理由 | 備選 |
|---|---|---|---|---|
| 1 | 隔離 | **專用發行版 `PiAgent`** | 可重現、不碰使用者既有的 Ubuntu、解除安裝乾淨 | `-Distro <名稱>` 裝進既有的(第二階段) |
| 2 | 基底映像 | Ubuntu 24.04.5,**自己釘 URL + sha256**,用 `wsl --import` | 任何 WSL 版本都能用;不受 Microsoft 清單改版影響;符合本 repo「全部釘死」的做法 | `wsl --install Ubuntu-24.04 --name PiAgent`(E1 失敗時用) |
| 3 | Linux 使用者 | 一般使用者 `piagent`(UID 1000),`[user] default=piagent`,**不給 sudo** | 官方建議 UID 1000;系統套件由安裝器以 root 先裝好 | — |
| 4 | systemd | `[boot] systemd=true`,寫入後 `wsl --terminate` 並驗證 | 沿用現有 Linux 的 `systemd --user` 單元 | — |
| 5 | 保活與自動啟動 | 登入時啟動隱藏的 `wsl.exe -d PiAgent --exec sleep infinity`;首選工作排程器,建不起來退回 `HKCU\...\Run` | systemd 不會讓實例保持運作;排程同時負責「開機後把 Linux 叫起來」 | 另加 `.wslconfig` 的 `instanceIdleTimeout=-1`(WSL ≥ 2.5.4,全域設定,會影響使用者其他發行版,預設不寫) |
| 6 | 連線 | NAT + localhost 轉發,pi-web 只綁 127.0.0.1 | 與其他平台一致;不開區網 | 區網/手機:mirrored + 防火牆規則(後續) |
| 7 | Windows 互通 | **開**,但 `appendWindowsPath=false`,只把 `System32` 與 `WindowsPowerShell\v1.0` 補進代理的 PATH;提供 `-NoWindowsInterop` 一鍵關閉 | 使用者想要這個能力;不把整個 Windows PATH 灌進 Linux,避免誤用 Windows 的 node/npm/git | 全開 `appendWindowsPath=true` |
| 8 | 檔案位置 | 全部在 Linux 檔案系統;**拒絕** `PI_AGENT_HOME` 在 `/mnt/*` | `/mnt/c` 慢,且外掛要求 0600 權限在那裡不可靠 | — |
| 9 | 啟用 WSL 本身 | 需要時自動提權,重開機後用 `HKCU\...\RunOnce` 自動續跑 | 只有「WSL 還沒裝好」的電腦才會碰到 | — |
| 10 | 解除安裝 | 預設只移除 Windows 端整合並停止服務;`-PurgeData` 才會先 `wsl --export` 備份再 `wsl --unregister` | 官方警告 unregister 會永久刪除資料 | — |
| 11 | 發佈形式 v1 | release 附 `install-wsl.ps1`,一行 `irm <網址> \| iex` | 不經瀏覽器下載、不落地成檔案;程式碼簽章留到客戶版 `.exe`/`.msi` | 客戶版安裝檔(後續) |
| 12 | 版本綁定 | 腳本內嵌「對應的安裝包版本 + sha256」(release 時蓋章);install.sh 內部沿用 `lib/pins.sh` | 同一個 release 的腳本只裝同一個 release 的內容 | — |

### 3.3 安裝流程(每一步都能重跑、已完成就跳過)

| 步驟 | 做什麼 | 需系統管理員? |
|---|---|---|
| S0 預檢 | Windows build ≥ 22621、CPU(x64 / ARM64)、虛擬化是否可用、記憶體(< 4 GB 擋、< 8 GB 警告)、磁碟(≥ 10 GB)、30141 與 6769 是否被 Windows 占用、是否已有 `PiAgent`、WSL 是否被政策禁用 | 否 |
| S1 WSL 本體 | `wsl --version` 可用且 ≥ 2.4.4(暫定,備案 C 需要)就跳過;否則 `wsl --install --no-distribution`(必要時 `wsl --update`,受限網路用 `--web-download`);需要重開機就寫 RunOnce 並請使用者重開機。只有這一步放進提權的子行程,其餘都以原本的使用者身分跑 | **只有這步,且只在 WSL 沒裝好時** |
| S2 專用 Linux | 下載映像並驗 sha256 → `wsl --import PiAgent %LOCALAPPDATA%\PiAgent\ <映像>` → 以 root 寫 `/etc/wsl.conf`、建立使用者、停用首次啟動提問 → `wsl --terminate PiAgent` → 重啟並確認 systemd 在跑 | 否 |
| S3 系統前置 | 以 root 裝 apt 套件(與 install.sh preflight 同一份清單,抽成共用避免兩邊漂移)、`loginctl enable-linger piagent` | 否 |
| S4 Pi Agent 本體 | 以 `piagent` 把安裝包解開到 VM 內,`PI_AGENT_PIWEB_ARTIFACT=<linux 預建包網址> ./install.sh`,並設好 `XDG_RUNTIME_DIR` | 否 |
| S5 Windows 端整合 | 登入自動啟動 + 保活;`pi-agent.cmd`(放進使用者 PATH 內的資料夾);開始功能表「Pi Agent」捷徑;寫入互通設定檔 | 否(盡量不要) |
| S6 驗證 | WSL 版 smoke + 印出下一步(在瀏覽器的 Omnigent 分頁連線;Claude / Codex 登入方式) | 否 |

### 3.4 Linux 端要改的(以新增檔案為主,install.sh 只動 10–20 行,降低和其他 lane 的衝突)

| 檔案 | 動作 |
|---|---|
| `lib/wsl.sh`(新) | `pa_wsl_*` 小函式:systemd 是否在跑、WSL 版本、互通是否可用、Windows 系統目錄的 Linux 路徑、拒絕 `/mnt/*` |
| `rootfs/bin/pi-agent-win`(新) | `run <exe> …` 執行 Windows 程式;`ps '<指令>'` 跑 PowerShell;`path to-win\|to-linux`;`open <網址或路徑>`;`doctor`。核心:背景服務拿不到 `WSL_INTEROP` 時,自己從 `/run/WSL/*_interop` 找一條活著的通道(待 E7) |
| `rootfs/bin/pi-agent` | `open` 在 WSL 走 `pi-agent-win open`;`sd()` 補 `XDG_RUNTIME_DIR`;新增 `doctor`(先做 WSL 區塊) |
| `rootfs/bin/pi-agent-env.sh` | 比照現有「macOS only」區塊,加一個 WSL 區塊:讀 `$PI_AGENT_HOME/windows-interop.env`(沒有檔案就完全不動),把 System32 與 PowerShell 目錄**附加**在 PATH 最後面,設定 `BROWSER` |
| `install.sh` | preflight 的 WSL 檢查;`stage_service` 在 WSL 補 `XDG_RUNTIME_DIR` 並在沒有 systemd 時給出明確指示 |
| `.github/workflows/release.yml` | 加 `linux-arm64` 預建包(`ubuntu-24.04-arm`,實作時確認標籤);加安裝包 `tar.gz` + `.sha256`(`git archive`) |
| `tests/wsl-premises.sh`(新) | 封閉式測試:假的 `/proc/version`、假的 `/run/WSL/*_interop`、假的 `powershell.exe` |
| `tests/smoke.sh` | 加 WSL 區塊(互通探測、port 轉發、`doctor`) |

### 3.5 Windows 端新檔

```
windows/install-wsl.ps1       入口:-Resume -Uninstall -PurgeData -NoWindowsInterop -DryRun -RootfsPath -Distro -Yes
windows/lib/pins.ps1          映像 URL 與 sha256、最低 WSL 版本、安裝包版本與 sha256(release 蓋章)
windows/lib/wsl.ps1           wsl.exe 包裝:UTF-8 輸出、退出碼、重試;Pester 可模擬
windows/lib/preflight.ps1     S0
windows/lib/integration.ps1   S5:保活與自動啟動、shim、捷徑
windows/templates/wsl.conf    寫進 VM 的設定
windows/tests/*.Tests.ps1     Pester
```

### 3.6 和 Omnigent 的關係

- Omnigent 看到的是一台 Linux host:原生 harness 與 tmux 終端都可用。
- host 名稱沿用 v0.2.2 的規則 `<hostname> (pi-agent)`。WSL 的 hostname 預設就是 Windows 電腦名。
- Windows 上沒有舊的 host,所以**不需要** session-home 的切換工具。
- Claude Code 與 Codex 要在 VM 內**重新登入**(Windows 端的登入不會帶過來)。優先用不需要本機回呼的
  登入流程,`BROWSER` 指向 `pi-agent-win open` 當輔助;各自實際可用的流程待 E10 確認。

### 3.7 為什麼不選別條路

| 方案 | 優點 | 缺點 | 結論 |
|---|---|---|---|
| A 專用發行版 + 自釘映像 `--import` | 可重現、不碰使用者環境、解除安裝乾淨、任何 WSL 版本可用 | 多一個 371 MiB 下載;磁碟約 4–5 GB(估計,待 E9 量) | **採用** |
| B 裝進使用者既有的 Ubuntu | 快、省空間 | 基底不明(版本、有沒有 systemd)、動到使用者設定、移除麻煩 | 第二階段給進階使用者(`-Distro`) |
| C `wsl --install Ubuntu-24.04 --name PiAgent` | 指令最短 | 映像版本跟著 Microsoft 清單走;要 WSL ≥ 2.4.4;建使用者要靠放在使用者資料夾的 cloud-init 檔 | 備案 |
| D Docker / Podman | — | 不是原生、更重 | 不做 |

### 3.8 實作注意(PowerShell 的坑,先記下來)

- Windows 11 內建的是 **Windows PowerShell 5.1**:不能用 `&&`、`??`、三元運算子;腳本必須在 5.1 跑得動。
- `wsl.exe -l` 的輸出是 UTF-16。預計設 `$env:WSL_UTF8=1`(**未驗證**目標版本支援,待 E1),否則改用 `[Console]::OutputEncoding`。
  另外,VM 內程式輸出的 UTF-8 中文,在繁中 Windows(預設 code page 950)會變亂碼:執行前要把
  `[Console]::OutputEncoding` 設成 UTF-8。
- 含中文訊息的腳本用 `irm … | iex` 時,Windows PowerShell 5.1 可能依回應標頭誤解碼(release 資產沒有
  charset):一行指令的最終寫法要改成讀位元組再以 UTF-8 解碼,待 E1 驗證。
- 使用者若是用**另一個系統管理員帳號**提權,提權後的行程會變成那個帳號。WSL 發行版是**每個使用者各自一份**,
  所以提權只能用在 S1,其餘步驟一律回到原本的使用者身分。
- 寫進 VM 的檔案必須是 **LF、無 BOM**:先在 Windows 端用 .NET 寫成 UTF-8(無 BOM)+ LF,再讓 VM 內
  `cp "$(wslpath …)"`;不要走 PowerShell 管線(會帶 CRLF 與 BOM)。
- `irm … | iex` 執行時沒有檔案路徑(`$PSScriptRoot` 是空的):需要的檔案一律從安裝包下載到暫存資料夾。
- 工作排程器「使用電池時不啟動 / 改用電池就停止 / 執行超過 3 天就停止」的預設值會讓筆電上的保活被關掉,要明確關閉。
- 映像與 VHDX 放 `%LOCALAPPDATA%`,不要放會被 OneDrive 同步的資料夾。
- 訊息以繁體中文為主,錯誤附英文關鍵字方便搜尋。

## 4. 風險與未知

| ID | 風險 | 對策 | 驗證 |
|---|---|---|---|
| R1 | 沒有能跑 WSL2 的測試機 | 第 6 節 | 決策 1 |
| R2 | 第一次啟用 WSL 要系統管理員 + 重開機,CI 測不到 | RunOnce 續跑;用全新機器或全新雲端 VM 測一次 | E13 |
| R3 | 發行版被閒置關掉(15 秒 / 60 秒) | 保活;`instanceIdleTimeout=-1` 補強 | E3 |
| R4 | systemd 啟動的程序拿不到互通通道(`WSL_INTEROP`);社群回報 [#8056](https://github.com/microsoft/WSL/issues/8056)、[#8846](https://github.com/microsoft/WSL/issues/8846)、[#10812](https://github.com/microsoft/WSL/issues/10812),官方未修 | `pi-agent-win` 自己找通道 | E7 |
| R5 | `stage_service` 在沒有登入工作階段時誤判成「沒有 systemd」(**推測**,由讀程式碼得出) | S3 `enable-linger`、S4 設 `XDG_RUNTIME_DIR`、`pi-agent` 的 `sd()` 同樣處理 | E2 |
| R6 | 首次啟動的提問或 cloud-init 卡住非互動安裝 | root 非互動建立使用者、停用 OOBE 與 cloud-init;不行就改用備案 C | E1 |
| R7 | BIOS 虛擬化關閉、在虛擬機裡沒有巢狀虛擬化、公司政策禁用 WSL | S0 預檢給明確訊息與下一步;這類電腦只能走雲端 host,或日後的原生精簡版 | E14 |
| R8 | 睡眠/休眠後 host 斷線、時間漂移 | 確認會自動重連;文件建議電源設定 | E8 |
| R9 | Windows 已占用 30141 / 6769 | S0 預檢;`PI_WEB_PORT` 既有可改 | E5 |
| R10 | 使用者把專案放 `/mnt/c`(慢、權限不對) | 拒絕 `PI_AGENT_HOME` 在 `/mnt/*`;`doctor` 警告 | E9 |
| R11 | 互通 = 代理拿到使用者的 Windows 權限;**互通開著時代理也能呼叫 `wsl.exe -u root`,所以「VM 內不給 sudo」在互通開啟時擋不住任何事** | PATH 只放 System32 與 PowerShell、安裝時明講、`-NoWindowsInterop`;兩件事要一起看 | 文件 |
| R12 | `wsl --unregister` 永久刪資料 | 解除安裝預設不刪;`-PurgeData` 先 export 備份並二次確認 | E11 |
| R13 | 另一條 lane 同時改 install.sh | 以新增檔案為主;每次動工前先 rebase origin/main | — |
| R14 | Windows ARM64:CI 測不到、`linux-arm64` 預建包還沒有 | 補預建包;標「盡力」,實機測過前不宣稱支援 | E12 |
| R15 | 未簽章的 `.ps1` / `.exe` 被 SmartScreen 或防毒擋 | v1 用 `irm \| iex`;客戶版再處理簽章 | E14 |
| R16 | `wsl.exe` 的輸出編碼、換行,以及繁中 Windows 的 code page 950 造成亂碼 | 見 3.8 | E1 |

## 5. 驗證計畫

### 5.1 四個層級

| 層級 | 在哪裡 | 能證明什麼 | 現在能做? |
|---|---|---|---|
| L0 | 這台 Mac / Ubuntu 主機 | `bash -n`、shellcheck;`tests/wsl-premises.sh`(假 WSL 環境);PowerShell 用 `pwsh` + Pester + PSScriptAnalyzer(模擬 `wsl.exe`);延伸 0.2.4 的 `tests/installer-rerun.sh` | **可以** |
| L1 | GitHub 免費 Windows 雲端機 | 真的匯入映像、systemd、保活、完整安裝、smoke、重跑與解除安裝;每次推送自動跑 | 要先過 spike |
| L2 | 真的 Windows 11(實體機或全新雲端 VM) | 第一次啟用 + 重開機、登入自動啟動、睡眠喚醒、被擋的情境、**Omnigent 三代理端對端** | 需要機器 |
| L3 | Windows ARM64 | 同上,盡力 | 需要機器 |

### 5.2 實驗清單

| 編號 | 要確認什麼 | 通過條件 | 層級 |
|---|---|---|---|
| E1 | `wsl --import` 釘住的 `.wsl`:全程有無提問;root 非互動建立 UID 1000 使用者;`[user] default` 是否生效;`WSL_UTF8` 是否可用 | 3 分鐘內完成,沒有任何提問 | L1 L2 |
| E2 | systemd:寫入 wsl.conf → terminate → 重啟;`systemctl --user` 在 `wsl.exe -u piagent --exec` 下能不能用;`enable-linger` | `systemctl is-system-running` 為 running 或 degraded;服務可 `enable --now` | L1 L2 |
| E3 | 保活:保活開 / 關各量一次,關掉所有終端機後 90 秒 pi-web 還答不答 | 保活開:仍回 200;關:當對照組 | L1 L2 |
| E4 | 自動啟動:排程與 Run 鍵比較 | 登入後 30 秒內可連;不閃視窗;電池供電也成立;登出再登入、重開機皆成立 | L2 |
| E5 | Windows 端 `curl.exe` 與瀏覽器連 `localhost:30141`;port 被占用時預檢擋得住 | 兩者皆通 | L1 L2 |
| E6 | 互通(互動 shell):`powershell.exe -NoProfile -Command Get-Date`;PATH 只有 System32 與 PowerShell 時 `cmd.exe`、`explorer.exe`、`tasklist.exe` 可呼叫 | 全部成功 | L1 L2 |
| E7 | 互通(背景服務):由 pi-web 服務啟動的代理行程呼叫 `powershell.exe`,不處理時是否失敗;用 `pi-agent-win` 後是否成功;發行版重啟後是否仍成功 | 用 `pi-agent-win` 全成功 | L1 L2 |
| E8 | 睡眠 5 分鐘後喚醒 | host 60 秒內回到 online;VM 與 Windows 時間差 < 2 秒 | L2 |
| E9 | 完整安裝:耗時、記憶體高峰(8 GB 機)、磁碟占用、smoke | 24/24 + WSL 項目 | L1 L2 |
| E10 | **Omnigent 端對端**:連線 → 三代理各開對話 → 各自切換模型 | 6 項全過;需要 owner 的帳號與登入 | L2 |
| E11 | 連續跑兩次、升級到下一版、`-Uninstall`、`-PurgeData` | 無殘留、資料不誤刪 | L1 L2 |
| E12 | 以上在 Windows ARM64 | 盡力 | L3 |
| E13 | 全新 Windows 11:自動提權 → 安裝 WSL → 重開機 → 自動續跑到完成 | 不需人工再下任何指令 | L2 |
| E14 | 被擋的情境:虛擬化關閉、WSL 被禁用、磁碟或記憶體不足、port 被占 | 每一種都有明確的繁中訊息與下一步 | L2 |

## 6. 測試機的選項

| 路線 | 能測 | 不能測 | 成本與前置 | 建議 |
|---|---|---|---|---|
| a. GitHub 免費 Windows 雲端機(Windows Server 2025,x64) | E1–E3、E5–E7、E9、E11;每次推送自動跑 | 第一次啟用 + 重開機、登入自動啟動、睡眠、真實 Omnigent 對話、ARM64 | 免費(公開 repo);要**推一條測試分支**觸發;**未證實**能開 WSL2,先做約半天的 spike | **先做** |
| b. 臨時雲端 Windows 11 虛擬機(要選支援巢狀虛擬化的機型,用完即刪) | 全新機器、E13、遠端桌面可互動、E10 | 睡眠喚醒、真實筆電行為、ARM64 | 需要雲端帳號;費用小但不是零 | 備案 |
| c. 一台實體 Windows 11 x64(借,或買小主機;記憶體 ≥ 8 GB、BIOS 開虛擬化) | 全部(含睡眠、電池、公司防毒);同時解鎖暫緩中的原生 Windows 路線 | — | 要有一台機器;遠端操作方式再議 | 最完整 |
| d. 這台 Mac 上的 Parallels | — | WSL2 完全不能 | — | **不可行** |

## 7. 工作拆分

P1 與 P2 互不依賴,可以並行。

| 階段 | 內容 | 要真 Windows? | 估計 |
|---|---|---|---|
| P0 | 定案本規劃;決定測試機路線;取得推測試分支的許可 | 否 | 0.5 天 |
| P1 | Linux 端(3.4 節)+ L0 測試 | 否 | 1–1.5 天 |
| P2 | Windows 端安裝器(3.5 節)+ Pester;release 加安裝包與 arm64 預建包 | 否 | 2.5–3.5 天 |
| P3 | CI spike → CI 整合測試(L1) | 否 | 1–1.5 天 |
| P4 | 真機驗證 E1–E14 與修正 | **是** | 1–3 天 |
| P5 | `docs/WSL2.md`、README 狀態表、版本號、release;(選)客戶版 `.exe` | 否 | 1 天 |

合計估計 7–11 個工作天。**第一個有價值的里程碑**:S2 + S4 + 保活,在 L1 或 L2 上讓
`localhost:30141` 通——先證明這條路走得通,再補其餘。

## 8. 需要 owner 決定

| # | 決定 | 我的建議 |
|---|---|---|
| 1 | **測試機路線**,以及是否同意我推一條測試分支到 GitHub(`windows-wsl2`,不碰 main)做 spike | 先做 a;同時評估 c |
| 2 | 專用 Linux `PiAgent` 還是用使用者現有的 Ubuntu | 專用 |
| 3 | Windows 互通預設開(PATH 只放 System32 與 PowerShell) | 開,附明確提示與關閉開關 |
| 4 | 支援門檻:Windows 11 22H2 以上;x64 必達、ARM64 盡力 | 同意 |
| 5 | 版本號與發佈時機(可延後) | 標「預覽」,不動 Linux / macOS 的版本線 |

## 9. 不做的事

- 原生 Windows(非 WSL):暫緩,見 `windows-native` 分支的研究報告。
- Windows 10、WSL1(沒有 systemd)。
- 區網/手機直連 WSL 內的服務。
- 代理操作 Windows **圖形介面**(點按鈕):v1 只提供命令列互通;之後另案(UI Automation、AutoHotkey)。
- Docker / Podman。

## 10. 來源

- S1 [Install WSL](https://learn.microsoft.com/en-us/windows/wsl/install)
- S2 [Advanced settings configuration in WSL](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
- S3 [Basic commands for WSL](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
- S4 [Use systemd to manage Linux services with WSL](https://learn.microsoft.com/en-us/windows/wsl/systemd)
- S5 [WSL release 2.5.4](https://github.com/microsoft/WSL/releases/tag/2.5.4)(`general.instanceIdleTimeout` 在此版加入)
- S6 [Accessing network applications with WSL](https://learn.microsoft.com/en-us/windows/wsl/networking)
- S7 [Set up WSL for your company](https://learn.microsoft.com/en-us/windows/wsl/enterprise)
- S8 [Build a custom Linux distro for WSL](https://learn.microsoft.com/en-us/windows/wsl/build-custom-distro)
- S9 [Using WSL with cloud-init](https://docs.cloud-init.io/tutorial/wsl.html)、[Manage and configure instances of Ubuntu on WSL](https://documentation.ubuntu.com/wsl/latest/howto/manage-and-configure/)
- S10 [DistributionInfo.json](https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json)
- S11 Canonical 的校驗檔:[amd64 `SHA256SUMS`](https://releases.ubuntu.com/24.04.5/SHA256SUMS)、[arm64 `SHA256SUMS`](https://cdimages.ubuntu.com/releases/24.04.5/release/SHA256SUMS)
- S12 [Parallels KB 129497:Limitations of running Windows 11 on Apple silicon](https://kb.parallels.com/en/129497)
- S13 [Particular/setup-wsl-action](https://github.com/Particular/setup-wsl-action)
- S14 [GitHub runner-images:Windows 2025 清單](https://raw.githubusercontent.com/actions/runner-images/main/images/windows/Windows2025-Readme.md)

## 附錄 A. 草案(**未實測**,僅供審查)

`/etc/wsl.conf`(寫進 `PiAgent`):

```ini
[boot]
systemd=true

[user]
default=piagent

[interop]
enabled=true
appendWindowsPath=false
```

保活與登入啟動執行的動作(視窗隱藏的做法待 E4):

```powershell
wsl.exe -d PiAgent --exec /usr/bin/sleep infinity
```

選用的全域設定(`%UserProfile%\.wslconfig`;WSL ≥ 2.5.4;預設**不寫**,因為會影響使用者的其他發行版):

```ini
[general]
instanceIdleTimeout=-1
```

`$PI_AGENT_HOME/windows-interop.env`(由 Windows 端安裝器寫入;不存在就代表互通關閉):

```
PA_WIN_SYSTEM32=/mnt/c/Windows/System32
```
