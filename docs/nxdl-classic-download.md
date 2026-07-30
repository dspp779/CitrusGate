# nxdl 與新楓之谷：經典版下載

最後更新：2026-07-30

本文說明 Beanfun OTP 如何用 [nxdl](https://github.com/HikariCalyx/nxdl) 下載經典版客戶端，以及整合時要注意的路徑問題與進度取得方式。

## 這是什麼

[nxdl](https://github.com/HikariCalyx/nxdl) 是獨立的命令列工具，可依 Nexon／Gamania 的 NGM manifest 下載遊戲檔。經典版別名為 `tms_cw`。

Beanfun OTP **不**內嵌 nxdl 原始碼；執行時會下載並快取固定版本的 `nxdl_darwin`，再以子行程呼叫。

| 項目 | 值 |
| --- | --- |
| 目前釘選版本 | `v0.1.2-prerelease2` |
| 二進位 | `nxdl_darwin` |
| SHA-256 | `a0cf22ae06f94268a33d3bed847619f70842fbd3b0ee758cd0c607782d31a1f7` |
| 遊戲別名 | `tms_cw` |
| 主程式檔名 | `Maplestory_Classic.exe` |
| App 快取路徑 | `~/Library/Application Support/local.ogom.beanfunotp/nxdl/nxdl_darwin` |

版本常數見 `Sources/NxdlDownloader.swift` 的 `NxdlDownloader.releaseTag`／`NxdlBinaryIntegrity.expectedSHA256Hex`。升級 nxdl 前請先重測路徑還原與進度解析，並更新 SHA-256。

下載或重用快取時都會驗證 SHA-256；校驗失敗會刪除快取並重新下載（仍失敗則回報錯誤）。

---

## 手動使用方式

```bash
# 下載（將客戶端寫入 ./classic）
./nxdl_darwin tms_cw --download ./classic
```

成功後目錄內應有 `Maplestory_Classic.exe` 與資料檔。Beanfun OTP 的「下載經典版客戶端」等同於此指令，並會自動選資料夾、清 quarantine、還原路徑、設定主程式。

其他注意：

1. **檔案很大**（約數 GiB），請預留磁碟空間。
2. 從網路下載的 `nxdl_darwin` 可能帶 `com.apple.quarantine`；App 每次執行前會解除。手動測試可：
   ```bash
   xattr -d com.apple.quarantine ./nxdl_darwin
   chmod +x ./nxdl_darwin
   ```
3. 進度條（TUI／OSC）只有在 **stdout 是 TTY** 時才會出現；把輸出導向 pipe／檔案時通常只剩狀態文字、沒有即時進度。

---

## 磁碟空間檢查（下載前）

經典版與新楓之谷下載**共用**同一套三級規則。下載前先執行 `--check --json` 取得 `total_size`，再與目的地磁碟的可用空間比較：

```bash
./nxdl_darwin tms_cw --check --json
```

`--check --json` 範例輸出：

```json
{"appid":"2982@2141","game_name":"新楓之谷：經典版",...,"total_size":2962637533}
```

App 只解析 `total_size`（位元組）；解析失敗則不開始下載。

判定順序（`DiskSpaceGate.evaluate`；硬下限 `minimum = total_size + 1 GiB` 優先）：

1. **硬下限**：可用空間 < `total_size + 1 GiB` → **阻擋**下載；僅顯示錯誤，無法繼續
2. **否則**，若可用空間 < `total_size × 1.05` → 警告對話框，可選 **「仍要下載」** 或取消
3. **否則** → 直接下載；**不**顯示警告

其中 `1 GiB = 1024³` 位元組。實作見 `Sources/GameClientDiskGate.swift` 的 `DiskSpaceGate.evaluate`。

當 `total_size < 20 GiB` 時，`total_size × 1.05` < `total_size + 1 GiB`，警告帶不存在；僅在可用空間 ≥ `total_size + 1 GiB` 時才能下載（直接下載，無警告）。

新楓之谷 cmsdl 的 `--check --json` 與相同規則見 [`cmsdl-maplestory-download.md`](cmsdl-maplestory-download.md#磁碟空間檢查下載前)。

---

## 下載後路徑 workaround（必須釘版本）

### 現象

此版本 nxdl 在 macOS 上，可能把 Windows 風格路徑當成**單一檔名**寫入，basename 內含反斜線 `\`，例如：

```text
Maplestory_Classic_Data\Plugins\x86_64\VuplexWebViewChromium\locales\af.pak
```

正確結構應為：

```text
Maplestory_Classic_Data/Plugins/x86_64/VuplexWebViewChromium/locales/af.pak
```

若不還原，遊戲檔案樹不完整，啟動會失敗。

### App 作法

下載結束後，`NxdlDownloader.normalizeWindowsPathFilenames(in:)` 會：

1. 掃目的地目錄
2. 找出 basename 含 `\` 的項目
3. 依 `\` 拆成目錄層級並 `move` 到真實路徑

單元測試覆蓋 `WindowsPathFilenameNormalizer` 與實際落盤案例。

### 為什麼要 pin version

路徑行為屬於 nxdl 實作細節，之後 release 可能：

- 修好（不再產生 `\` 檔名）→ 還原邏輯仍應無害（找不到就不做事）
- 改用其他錯誤編碼 → 現有還原可能不夠

因此 App **釘選** `v0.1.2-prerelease2`，不要自動追 `latest`。換版本時請：

1. 手動下載到空目錄一次
2. 確認是否仍有 `\` 檔名
3. 跑 `./test.sh` 與實機下載／啟動
4. 再改 `releaseTag` 與下載 URL

---

## 進度取得：TUI 與 OSC 9;4

nxdl 透過 [indicatif](https://crates.io/crates/indicatif) 輸出進度。在支援的終端機（例如 Ghostty）會同時看到：

1. **TUI 文字進度**：終端機內容區的進度列（含總量、速度、ETA、各檔）
2. **OSC 9;4**：終端機**原生**頂部進度條（ConEmu／Ghostty／Windows Terminal）

### TUI 文字進度（App 採用）

整體進度列範例：

```text
⠙ [00:00:14] [=============>--------------------------] 950.77 MiB/2.76 GiB (65.06 MiB/s, ETA 29s)
```

可解析出：

| 欄位 | 範例 |
| --- | --- |
| 已用時間 | `00:00:14` |
| 已下載／總量 | `950.77 MiB` / `2.76 GiB` |
| 速度 | `65.06 MiB/s` |
| 預估剩餘時間 | `ETA 29s`（UI 顯示為「預估剩餘時間 29 秒」） |
| 進度比例 | 由 `950.77 MiB / 2.76 GiB` 換算為位元組後相除（ASCII bar 僅作 fallback） |

平行下載的各檔列（行首空白）範例：

```text
  [===>---------------------]  84.00 MiB/586.71 MiB ( 6.88 MiB/s) Maplestory_Classic_Data\...\spritesheet.bundle
```

**優點**：資訊完整，適合做成下載對話框。  
**缺點**：需處理 ANSI、`\r` 原地更新；格式隨 indicatif／nxdl 可能變動。

Beanfun OTP **只依 TUI 解析**，在進度視窗顯示總量、速度、預估剩餘時間，以及「正在下載 〈檔名〉」文字（多執行緒同時下載時，同一畫格的檔名以 `, ` 併列；不顯示各檔進度條）。整體總量（例：`2.76 GiB`）一律由這行文字解析而來，程式內沒有任何固定值。

### OSC 9;4（僅文件說明；App 不採用）

格式：

```text
ESC ] 9 ; 4 ; <state> ; <progress> BEL
# 或 ST 結尾：ESC ]
```

| state | 含義 |
| --- | --- |
| 0 | 清除 |
| 1 | 正常進度（0–100） |
| 2 | 錯誤 |
| 3 | 不確定 |
| 4 | 暫停／警告（indicatif 下載中常用此 state） |

實測片段：`\x1b]9;4;4;42\x1b\\` → 約 42%。

**優點**：協定簡單、只要百分比。  
**缺點**：沒有 MiB／速度／ETA，不足以取代對話框所需資訊。

App **不**用 OSC 驅動 UI；`stripANSI` 會去掉 OSC，避免干擾 TUI 解析。若將來要做 Dock／精簡百分比指示，可再接 OSC。

### 必須用 PTY

| 輸出方式 | 狀態文字 | TUI 進度 | OSC 9;4 |
| --- | --- | --- | --- |
| 真實終端機／PTY | 有 | 有 | 有 |
| `Pipe`（非 TTY） | 多半只有摘要 | **無** | **無** |

indicatif 在非 TTY 會關閉即時進度。因此 `NxdlDownloader` 以 `openpty` 建立虛擬終端，把 nxdl 的 stdout／stderr 接到 PTY slave，再從 master 讀取並解析 TUI。

---

## 在 Beanfun OTP 中的流程

```text
使用者選下載資料夾
        │
        ▼
確保 nxdl_darwin（釘選版＋SHA-256）就緒並清 quarantine
        │
        ▼
執行：nxdl_darwin tms_cw --check --json → total_size
        │
        ▼
讀取目的地磁碟可用空間 → 磁碟空間檢查（ok / warn / blocked）
        │
        ├─ blocked → 錯誤提示；停止
        ├─ warn → 確認「仍要下載」；取消則停止
        └─ ok → 繼續
        │
        ▼
PTY 執行：nxdl_darwin tms_cw --download <dir>
        │
        ├─ 解析 TUI → 進度對話框（總量／速度／預估剩餘時間）
        │
        ▼
normalizeWindowsPathFilenames（\ → 真實目錄；保留整體進度）
        │
        ▼
尋找 Maplestory_Classic.exe → 寫入主程式路徑
```

相關檔案：

| 檔案 | 角色 |
| --- | --- |
| `Sources/NxdlDownloader.swift` | 下載、PTY、TUI 解析、路徑還原 |
| `Sources/GameClientDiskGate.swift` | `--check --json` 解析、磁碟空間三級判定、可用空間讀取 |
| `Sources/ClassicDownloadProgressView.swift` | Modern 進度 sheet |
| `Legacy/Sources/ClassicDownloadProgressWindow.swift` | Legacy 進度視窗 |
| `Sources/AppModel.swift` / `Legacy/Sources/AppController.swift` | 觸發下載、磁碟 gate 對話框與取消 |

玩家操作步驟見 [`macos-player-guide-classic.md`](macos-player-guide-classic.md)。
