# 在 macOS 玩新楓之谷（玩家教學）

最後更新：2026-07-24

本教學依實際可玩流程整理，目標是讓一般玩家能在 Apple Silicon／Intel Mac 上安裝並啟動**新楓之谷**（台灣 Beanfun 版）。這不是官方支援路徑，遊戲與登入服務隨時可能變更。

新楓之谷：經典版請見 [`docs/macos-player-guide-classic.md`](macos-player-guide-classic.md)。

## 你會用到什麼

| 項目 | 用途 |
| --- | --- |
| Beanfun OTP（本專案 Modern 版，macOS 13+） | QR 登入取得 OTP，並啟動遊戲 |
| 美版 [MapleStory Launcher](https://www.nexon.com/maplestory/) | **目前跑新楓之谷的主要方式**：內建 CrossOver 25（Wine 10）OEM Wine 與 bottle |
| [台灣官方新楓之谷主程式](https://maplestory.beanfun.com/download) | 下載 `MapleStory.exe`（手動下載可略過橘子遊戲管理器） |
| Beanfun 帳號 | 登入憑證來源 |

## 哪個環境開哪款（請先看）

| 環境 | 新楓之谷 | 新楓之谷：經典版 |
| --- | --- | --- |
| **北美官方 MapleStory Launcher**（CrossOver 25／Wine 10） | 可用 | **不可用**（缺功能，例：`EventWriteEx`） |
| **Cyder** | **目前還不行**（官方修補移植仍在進行中） | 可用（經典版請走此路徑） |

經典版完整步驟見 [`docs/macos-player-guide-classic.md`](macos-player-guide-classic.md)。

研究細節（OEM engine、Cyder、防作弊 lifecycle）見同目錄其他文件；一般遊玩不必閱讀。

## 注意事項（請先看）

1. **安裝路徑請選好找的地方**  
   遊戲若裝進 bottle 的 `Program Files`，之後很難在 Finder 找到。建議裝到 macOS「文件」底下，例如：  
   `~/Documents/gamania Games/MapleStory`  
   Wine 的「我的文件」通常對應你的 macOS `Documents`，選 Documents／文件即可。

2. **啟動參數必須是帳號 ID + OTP**  
   遊戲命令列需要 `ServiceAccountID`（形如 `T9...`）與短期 OTP。  
   **不要**把 Beanfun 顯示名稱或純數字 SN 當成帳號 ID，否則可能畫面正常卻顯示「未登錄的帳號」。

3. **OTP 很快過期**  
   請在取得後立刻啟動；不要把 OTP 寫進長期筆記或分享出去。

4. **Apple Silicon 需要 Rosetta**  
   美版 Launcher 內的 Wine 是 x86_64。若系統尚未安裝 Rosetta，首次開啟相關程式時依提示安裝即可。

5. **繁體中文環境（Wine 路徑）**  
   新楓之谷會檢查繁中 code page。下方 Wine 指令會設定 `zh_TW.UTF-8`；若出現 Traditional Chinese／code-page 相關錯誤，請確認這三個變數都有設上。

---

## 步驟 0：準備目錄（建議）

安裝遊戲時，請指向 macOS「文件」目錄 `$HOME/Documents`（Wine 內通常對應 `C:\users\crossover\Documents`）。此目錄預設已存在，無須額外建立子資料夾。

---

## 步驟 1：安裝美版 MapleStory Launcher

新楓之谷目前請用 Launcher 內建 Wine；**請勿依賴 Cyder**（移植官方修補仍在進行中）。經典版也不要用這個 Launcher（見下方注意與經典版教學）。

1. 到北美楓之谷官方網站下載並安裝 macOS 版 **MapleStory Launcher**：  
   <https://www.nexon.com/maplestory/>  
   安裝說明也可參考 Nexon 支援文件（含 macOS）：  
   <https://support-maplestory.nexon.com/hc/en-us/articles/43855651499284-How-to-install-MapleStory>
2. 開啟 `/Applications/MapleStory Launcher.app`，完成首次啟動。  
   系統會建立 Wine bottle（約在 `~/Library/Application Support/MapleStoryNA/Bottles/maplestory`）。
3. **不必**下載或遊玩美版楓之谷本體；我們只要它的 Wine 環境（CrossOver 25／Wine 10 OEM）。

確認 Wine 工具存在：

```sh
ls "/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna/MapleStory Launcher/wine"
```

若找不到上述路徑，代表 Launcher 尚未正確安裝。

---

<details>
  <summary>

  ## 步驟 2：用 Wine 安裝橘子遊戲管理器（手動下載可略過）

  </summary>

若你已從[官方下載頁](https://maplestory.beanfun.com/download)取得主程式，可略過本步驟。

### 2.1 下載安裝檔

1. 開啟：<https://tw.beanfun.com/ggm/index.html>
2. 下載 **gamania Games Manager**（約十數 MB 的 Windows 安裝程式）。
3. 把下載到的 `.exe` 放到好找的位置，例如 `~/Downloads/`。

下列指令假設安裝檔名為 `~/Downloads/GamesManagerSetup.exe`；請依實際檔名修改。

### 2.2 設定環境並執行安裝

在終端機執行：

```sh
export CX_ROOT="/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

wine --bottle maplestory \
  --workdir "$HOME/Downloads" \
  "$HOME/Downloads/GamesManagerSetup.exe"
```

安裝精靈注意：

- 安裝路徑請改成例如：`C:\users\crossover\Documents\ggm`  
  （對應 macOS：`~/Documents/ggm`）
- 過程中若提示安裝 **.NET Desktop Runtime / .NET Framework 6**，請接受並完成安裝。
- 安裝完成後，管理器主程式通常是 `GGMWebStart.exe`。

之後若要再開管理器：

```sh
export CX_ROOT="/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

wine --bottle maplestory \
  --workdir "$HOME/Documents/ggm" \
  "$HOME/Documents/ggm/GGMWebStart.exe"
```

若你的實際路徑不同，把上面的 `ggm` 路徑改成你安裝時選的位置。

</details>

---

## 步驟 3：取得並確認新楓之谷主程式

1. 建議直接使用[官方主程式下載](https://maplestory.beanfun.com/download)，解壓／安裝到好找的資料夾（例如 `~/Documents/gamania Games/MapleStory`）。
2. 若改用橘子遊戲管理器安裝：登入 Beanfun／選擇**新楓之谷**，把遊戲目錄設到文件底下（詳見上方可收合的步驟 2）。
3. 確認存在：

```sh
ls "$HOME/Documents/gamania Games/MapleStory/MapleStory.exe"
```

路徑可依你實際安裝位置調整。重點是你要能在 Finder 或終端機輕易找到 `MapleStory.exe`。

（之後若 Cyder 已可跑新楓之谷，再考慮把「打開方式」設成 Cyder；**目前請用 Launcher Wine**。）

---

## 步驟 4：用 Beanfun OTP 啟動新楓之谷（建議）

新楓之谷不能只雙擊 `MapleStory.exe`；必須附上 Beanfun 的帳號 ID 與 OTP。

1. 建置或取得 **Beanfun OTP.app**（Modern，macOS 13+；見專案 `README.md`／Release）。
2. 若系統提示「無法驗證開發者」，到「系統設定 → 隱私權與安全性」允許開啟，或對 App 按右鍵 → 打開。（公證過的 Developer ID 建置通常可直接開。）
3. 開啟 App（預設為**一般模式**）：

   **選擇遊戲** — 點「新楓之谷」，第一次會要求指定 `MapleStory.exe`：

   <img src="screenshots/citrusgate-1-home.png" alt="選擇遊戲" width="480">

   **登入 Beanfun** — 用 Gama Play App 掃描 QR Code：

   <img src="screenshots/citrusgate-2-qrcode.png" alt="QR Code 登入" width="480">

   **選擇帳號並啟動** — 選要進入的遊戲帳號後，新楓之谷會出現兩個按鈕：

   - **以 MapleStory Launcher 開啟**（建議）：設定 Wine 環境後，直接執行 Launcher 內建 `wine`（`maplestory` bottle），**不會**走 `open`。
   - **以 Cyder 開啟**：透過 macOS `open -n`，依 `.exe` 的「打開方式」啟動。  
     **目前 Cyder 還不能跑新楓之谷**（官方修補移植仍在進行中）；按鈕保留供日後使用，現階段請選 Launcher。

   <img src="screenshots/citrusgate-3-service-account.png" alt="選擇帳號" width="480">

   啟動後按鈕會暫時停用約 10 秒，並顯示「啟動中…／已啟動」。

4. **進階模式**（可選）— 從選單「模式」切換後可複製完整終端機指令，並在 `open` 與 **Nexon MapleStory Launcher Wine** 兩種形式間切換。  
   現階段請用 Wine 形式；`open`／Cyder 路徑對新楓之谷尚不可靠。

若工具介面有變，請改用下方手動指令。

---

## 步驟 5：手動啟動新楓之谷（備援）

遊戲命令列格式固定為：

```text
MapleStory.exe tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

### 5.1 MapleStory Launcher Wine

在終端機（請替換帳號 ID、OTP，以及遊戲路徑）：

```sh
export CX_ROOT="/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

GAME_DIR="$HOME/Documents/gamania Games/MapleStory"
ACCOUNT_ID='T9你的帳號ID'
OTP='一次性OTP'

wine --bottle maplestory \
  --workdir "$GAME_DIR" \
  "$GAME_DIR/MapleStory.exe" \
  tw.login.maplestory.beanfun.com 8484 BeanFun "$ACCOUNT_ID" "$OTP"
```

重點：

- `--workdir` 必須是 `MapleStory.exe` 所在目錄。
- `ACCOUNT_ID` 必須與該次 OTP 綁定的帳號一致。
- OTP 用過即失效；失敗時重新向 Beanfun／Beanfun OTP 取得一組再試。

### 5.2 Cyder／`open`（目前不建議用於新楓之谷）

**目前 Cyder 還不能跑新楓之谷**（移植官方修補仍在進行中）。下列指令僅供日後參考或進階除錯：

```sh
open -n '/path/to/MapleStory.exe' --args \
  tw.login.maplestory.beanfun.com 8484 BeanFun 'T9你的帳號ID' '一次性OTP'
```

經典版請改用 Cyder；見 [`docs/macos-player-guide-classic.md`](macos-player-guide-classic.md)。

---

## 常見問題

| 現象 | 可能原因 | 怎麼辦 |
| --- | --- | --- |
| 找不到遊戲或管理器 | 裝進 bottle 的 Program Files | 重裝並改裝到 `Documents`；或用 Finder 搜尋 `MapleStory.exe`／`GGMWebStart.exe` |
| 錯誤 5 | 沒帶有效 OTP | 用 Beanfun OTP 或手動指令帶上新 OTP |
| 「未登錄的帳號」 | 傳了顯示名稱／錯的 ID，或 ID 與 OTP 不符 | 改用該帳號的 `T9...` ServiceAccountID |
| Traditional Chinese／code-page 錯誤 | locale 不是繁中 | 確認 `LANG`／`LC_ALL`／`LC_CTYPE` 皆為 `zh_TW.UTF-8` 後再啟動 |
| `wine: command not found` | 未設定 `PATH`／未裝 Launcher | 重新執行步驟 2 的 `export`，或確認 Launcher 已安裝 |
| Apple Silicon 打不開 x86 程式 | 未裝 Rosetta | 依系統提示安裝 Rosetta 2 |
| 管理器裝完無法執行 | 缺少 .NET 6 | 回到安裝流程接受 .NET 元件，或再執行一次安裝程式補裝 |
| 「以 MapleStory Launcher 開啟」失敗 | 未裝／未開過 Launcher | 完成「步驟 1」，確認 `wine` 路徑存在 |
| 「以 Cyder 開啟」失敗／進不了遊戲 | Cyder 尚未完成官方修補移植 | 改用「以 MapleStory Launcher 開啟」或步驟 5.1 |
| 想用 Launcher 開經典版 | Launcher 為 CrossOver 25（Wine 10），缺 `EventWriteEx` 等 | 經典版請改用 Cyder；見[經典版教學](macos-player-guide-classic.md) |

---

## 路徑速查

以下為本教學建議／已驗證的常見位置（使用者名稱請自行對應）：

```text
MapleStory Launcher.app
  /Applications/MapleStory Launcher.app

OEM Wine（cxstart / wine）— 新楓之谷目前請用此路徑（CrossOver 25／Wine 10）
  .../Contents/SharedSupport/maplestoryna/MapleStory Launcher/

Bottle
  ~/Library/Application Support/MapleStoryNA/Bottles/maplestory

建議：遊戲管理器
  ~/Documents/ggm/GGMWebStart.exe

建議：新楓之谷
  ~/Documents/gamania Games/MapleStory/MapleStory.exe
```

---

## 免責

- 本流程使用 Nexon 官方 MapleStory Launcher 內建 Wine（CrossOver 25／Wine 10）執行 Windows 版新楓之谷客戶端，可能違反遊戲服務條款，也有帳號風險。
- 目前 **Cyder 尚不能跑新楓之谷**；經典版則相反（需 Cyder、不能用該 Launcher），見[經典版教學](macos-player-guide-classic.md)。
- Nexon、遊戲橘子、Beanfun 皆未為此 macOS 玩法提供官方支援。
- OTP、Cookie、帳號 ID 屬敏感資料，請勿貼到公開頻道或提交到任何版本庫。

經典版請見 [`docs/macos-player-guide-classic.md`](macos-player-guide-classic.md)。
