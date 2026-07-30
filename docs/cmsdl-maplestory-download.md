# cmsdl 與新楓之谷：客戶端下載

最後更新：2026-07-30

本文說明 Beanfun OTP 如何用 [cmsdl](https://github.com/HikariCalyx/cmsdl) 下載**新楓之谷**（非經典版）客戶端，以及整合時要注意的磁碟空間檢查、路徑問題與進度取得方式。

## 這是什麼

[cmsdl](https://github.com/HikariCalyx/cmsdl) 是獨立的命令列工具，可依 Gamania TMS manifest 下載新楓之谷客戶端。別名為 `tms`。

Beanfun OTP **不**內嵌 cmsdl 原始碼；執行時會下載並快取固定版本的 `cmsdl_darwin`，再以子行程呼叫。

| 項目 | 值 |
| --- | --- |
| 目前釘選版本 | `v0.2.5` |
| 二進位 | `cmsdl_darwin`（universal x86_64 + arm64） |
| SHA-256 | `706efcf17608a807c884e1eb8e0c8b97084f67dfbec29f7664e9aba77d0a0b78` |
| 遊戲別名 | `tms` |
| 主程式檔名 | `MapleStory.exe` |
| App 快取路徑 | `~/Library/Application Support/local.ogom.beanfunotp/cmsdl/cmsdl_darwin` |

版本常數見 `Sources/NxdlDownloader.swift` 的 `GameClientToolConfig.cmsdlMapleStory`。升級 cmsdl 前請先重測路徑還原與進度解析，並更新 SHA-256。

下載或重用快取時都會驗證 SHA-256；校驗失敗會刪除快取並重新下載（仍失敗則回報錯誤）。

---

## 手動使用方式

```bash
# 查詢 manifest 總大小（JSON）
./cmsdl_darwin tms --check --json

# 下載（將客戶端寫入 ./maplestory）
./cmsdl_darwin tms --download ./maplestory
```

`--check --json` 範例輸出：

```json
{"region":"tms","build":0,"version":"V280","files":1234,"total_size":13245678901}
```

App 只解析 `total_size`（位元組）；解析失敗則不開始下載。

成功後目錄內應有 `MapleStory.exe` 與資料檔。Beanfun OTP 的「下載新楓之谷客戶端」等同於 `--download` 指令，並會自動選資料夾、清 quarantine、還原路徑、設定主程式。

其他注意：

1. **檔案很大**（約十數 GiB），請預留磁碟空間（見下方磁碟空間檢查）。
2. 從網路下載的 `cmsdl_darwin` 可能帶 `com.apple.quarantine`；App 每次執行前會解除。手動測試可：
   ```bash
   xattr -d com.apple.quarantine ./cmsdl_darwin
   chmod +x ./cmsdl_darwin
   ```
3. 進度條（TUI／OSC）只有在 **stdout 是 TTY** 時才會出現；把輸出導向 pipe／檔案時通常只剩狀態文字、沒有即時進度。

---

## 磁碟空間檢查（下載前）

新楓之谷與經典版下載**共用**同一套三級規則。下載前先執行 `--check --json` 取得 `total_size`，再與目的地磁碟的可用空間比較：

判定順序（`DiskSpaceGate.evaluate`；硬下限 `minimum = total_size + 1 GiB` 優先）：

1. **硬下限**：可用空間 < `total_size + 1 GiB` → **阻擋**下載；僅顯示錯誤，無法繼續
2. **否則**，若可用空間 < `total_size × 1.05` → 警告對話框，可選 **「仍要下載」** 或取消
3. **否則** → 直接下載；**不**顯示警告

其中 `1 GiB = 1024³` 位元組。實作見 `Sources/GameClientDiskGate.swift` 的 `DiskSpaceGate.evaluate`。

當 `total_size < 20 GiB` 時，`total_size × 1.05` < `total_size + 1 GiB`，警告帶不存在；僅在可用空間 ≥ `total_size + 1 GiB` 時才能下載（直接下載，無警告）。

經典版 nxdl 的 `--check --json` 與相同規則見 [`nxdl-classic-download.md`](nxdl-classic-download.md#磁碟空間檢查下載前)。

---

## 下載後路徑 workaround（防禦性）

### 現象

cmsdl 的 `tms.rs` 多半以 `/` 組合路徑並常正規化 `\`，但**不保證**每次寫入前都已正規化。少數情況仍可能出現 basename 含反斜線 `\` 的項目，例如：

```text
MapleStory_Data\Plugins\x86_64\...\locales\af.pak
```

正確結構應為：

```text
MapleStory_Data/Plugins/x86_64/.../locales/af.pak
```

若不還原，遊戲檔案樹可能不完整，啟動會失敗。

### App 作法

下載結束後，`NxdlDownloader.normalizeWindowsPathFilenames(in:)` 會（與經典版相同）：

1. 掃目的地目錄
2. 找出 basename 含 `\` 的項目
3. 依 `\` 拆成目錄層級並 `move` 到真實路徑

cmsdl 多數情況下此步驟為 no-op；保留是為防禦性。

### 為什麼要 pin version

路徑行為屬於 cmsdl 實作細節，之後 release 可能改變。App **釘選** `v0.2.5`（正式 release 標籤；TMS 下載核心與較新的 prerelease 相同）。換版本時請：

1. 手動下載到空目錄一次
2. 確認是否仍有 `\` 檔名
3. 跑 `./test.sh` 與實機下載／啟動
4. 再改 `GameClientToolConfig.cmsdlMapleStory` 的 `releaseTag`、下載 URL 與 SHA-256

---

## 進度取得

cmsdl TMS 的 indicatif 進度格式與 nxdl 非常接近，App **重用**同一套 TUI 解析器與進度 UI（總量、速度、預估剩餘時間、目前檔名文字）。

詳細 TUI／OSC 9;4 說明見 [`nxdl-classic-download.md`](nxdl-classic-download.md#進度取得tui-與-osc-94)。`NxdlDownloader` 同樣以 `openpty` 建立虛擬終端讀取進度。

---

## 在 Beanfun OTP 中的流程

```text
使用者選下載資料夾
        │
        ▼
確保 cmsdl_darwin（釘選版＋SHA-256）就緒並清 quarantine
        │
        ▼
執行：cmsdl_darwin tms --check --json → total_size
        │
        ▼
讀取目的地磁碟可用空間 → 磁碟空間檢查（ok / warn / blocked）
        │
        ├─ blocked → 錯誤提示；停止
        ├─ warn → 確認「仍要下載」；取消則停止
        └─ ok → 繼續
        │
        ▼
PTY 執行：cmsdl_darwin tms --download <dir>
        │
        ├─ 解析 TUI → 進度對話框（總量／速度／預估剩餘時間）
        │
        ▼
normalizeWindowsPathFilenames（\ → 真實目錄；保留整體進度）
        │
        ▼
尋找 MapleStory.exe → 寫入主程式路徑
```

Modern 與 Legacy 皆支援；同一時間僅允許一個客戶端下載（新楓之谷或經典版）。

相關檔案：

| 檔案 | 角色 |
| --- | --- |
| `Sources/NxdlDownloader.swift` | 共用下載管線、PTY、TUI 解析、路徑還原、`GameClientToolConfig` |
| `Sources/GameClientDiskGate.swift` | `--check --json` 解析、磁碟空間三級判定、可用空間讀取 |
| `Sources/ClassicDownloadProgressView.swift` | Modern 進度 sheet |
| `Legacy/Sources/ClassicDownloadProgressWindow.swift` | Legacy 進度視窗 |
| `Sources/AppModel.swift` / `Legacy/Sources/AppController.swift` | 觸發下載、磁碟 gate 對話框與取消 |

玩家操作步驟見 [`macos-player-guide.md`](macos-player-guide.md)。
