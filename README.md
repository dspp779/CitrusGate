# Beanfun OTP for macOS

本 repo 提供兩個 macOS 用戶端：**Beanfun OTP**（Modern，SwiftUI，macOS 13 以上，完整功能）與 **Beanfun OTP Legacy**（AppKit，macOS 10.12 以上，經典 AppKit 介面，支援自動帶參啟動）。Modern 版用 Gama Play 掃描 QR code 登入 Beanfun，選擇遊戲與帳號後取得 OTP。成品不依賴 Python、Homebrew、Node.js 或第三方套件。

目前支援 4 款可自動帶參/協定登入之服務：新楓之谷、楓之谷：經典版、新瑪奇與艾爾之光。爆爆王未納入，無命令列自動帶參功能之舊款遊戲已移除。

## 兩個版本

| | Beanfun OTP | Beanfun OTP Legacy |
| --- | --- | --- |
| 系統需求 | macOS 13 以上 | macOS 10.12 以上（Intel） |
| 架構 | Apple Silicon + Intel | 僅 Intel (x86_64) |
| 功能 | 完整（含 Wine 啟動、FPS 顯示、進階模式） | 經典 AppKit 介面（含主程式選擇、Cyder 啟動與經典版支援） |
| 建置 | `./build.sh` | `./build-legacy.sh` |
| 輸出 | `dist/Beanfun OTP.app` | `dist/Beanfun OTP Legacy.app` |

10.12–12 請用 Legacy。13 以上請用一般版（最新版本皆為 `v0.4.1`）。Beanfun 登入協定若變更，兩個版本的 client 都需要同步更新。

以下「一般模式」與「進階模式」說明僅適用於 **Beanfun OTP**（Modern 版）。

## 一般模式

App 每次啟動預設使用一般模式。先從附有官方縮圖的精簡清單選擇遊戲；第一次選擇該遊戲時會要求指定 `.exe`，每款遊戲的路徑會分別記住。畫面提供「選擇〈遊戲〉主程式…」與「選擇其他遊戲」按鈕（採垂直排版並以 `·` 點狀符號分隔）。按「取得 QR Code」後才會向 Beanfun 產生 QR Code，避免開啟 App 時過度頻繁請求。用 Gama Play 掃描並確認後：

- 只有一個遊戲帳號時，會自動取得 OTP 並啟動遊戲。
- 有多個帳號時，選擇帳號後按「以〈帳號〉開啟遊戲」。

提供可選的「顯示遊戲流暢度 (FPS)」勾選項（預設關閉且不記憶），開啟時會透過 macOS 官方 `open --env MTL_HUD_ENABLED=1` 參數將 Metal Performance HUD 注入目標進程。

新楓之谷在一般模式提供「以 Cyder 開啟」與「以 MapleStory Launcher 開啟」。新楓之谷可選：

- **MapleStory Launcher**（內建 CrossOver 25／Wine 10，`maplestory` bottle，帶入 `--wait-children` 與 `--enable-alt-loader macdrv`）
- 或不想裝 GMS Launcher 時，改用 [Cyder 新楓之谷分支](https://github.com/dspp779/CyderBits/releases/tag/v0.7.0-maplestory)（`v0.7.0-maplestory`）+「以 Cyder 開啟」

[Cyder 正式版](https://github.com/dspp779/CyderBits/releases/latest) **不能**跑新楓之谷。啟動後按鈕會暫時停用約 10 秒並顯示狀態。

一般模式使用精簡的固定大小視窗，QR 畫面只保留 QR Code、掃描說明、剩餘時間與重新產生按鈕。QR 區域以一致的 `12pt` 四邊白色留白延伸至視窗上、左、右邊緣。視窗不可縮放或進入全螢幕；系統選單不顯示「編輯」、「顯示方式」、「遊戲」與「視窗」，保持最純粹乾淨的介面。

另支援**楓之谷：經典版**（教學稱新楓之谷：經典版）：無 QR。選擇 `Maplestory_Classic.exe` 後開啟官方登入網頁；網頁透過 `NexonPlug://` 回傳參數，App 以 `open -n … --args` 啟動（預設走 [Cyder 正式版](https://github.com/dspp779/CyderBits/releases/latest)）。可在頁面直接將 `NexonPlug` 設為由 Beanfun OTP 處理（位在說明文案正下方）；其他非經典版 gameCode 會自動轉發官方 NexonPlug.app。測完可改回 `com.nexon.plug`。Beanfun OTP 僅允許單一實例；若由網頁 `NexonPlug://` 冷啟動並成功開啟經典版，啟動完成後會自動結束。完整步驟見 [`docs/macos-player-guide-classic.md`](docs/macos-player-guide-classic.md)。

## 進階模式

從 macOS 上方的「模式」選單切換至進階模式，可查看及操作 OTP、立即／自動更新、目前狀態、Debug Log、完整可貼上終端機的啟動指令與手動啟動功能。

「遊戲啟動指令」區塊會顯示**完整** shell 指令（不是只有 `--args` 後的遊戲參數），可直接複製到「終端機」執行。新楓之谷可在 `open` 與 **Nexon MapleStory Launcher Wine** 兩種形式間切換；其他遊戲僅顯示 `open` 形式。

`open` 形式會呼叫 macOS 的 `open -n`（或帶入 `--env MTL_HUD_ENABLED=1`），依 `.exe` 的預設開啟 App 建立新的 Cyder instance（路徑即使包含空白也會正確引號）。支援帶入登入參數的遊戲如下：

```sh
open -n '/path/to/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
open -n '/path/to/mabinogi.exe' --args /N:<ServiceAccountID> /V:<OTP> /T:gamania
open -n '/path/to/elsword.exe' --args <ServiceAccountID> <OTP> TW
```

Wine 形式（僅新楓之谷）對齊 [`docs/macos-player-guide.md`](docs/macos-player-guide.md)：`maplestory` bottle、`--wait-children`、`--enable-alt-loader macdrv`、`zh_TW.UTF-8` locale，以及 MapleStory Launcher SharedSupport 的 Wine 路徑。macOS 完整安裝與手動啟動流程亦見該文件；經典版見 [`docs/macos-player-guide-classic.md`](docs/macos-player-guide-classic.md)。

**實際按下「透過 Cyder 啟動遊戲」仍走 Cyder 的 `open -n`**，不會從 App 內直接呼叫 Wine。

Debug Log 會印出呼叫網址、表單參數、HTTP 狀態、Cookie、Token、SecretCode、LongPolling key、帳號資料及 OTP。依目前的 debug 設定，敏感內容預設不遮蔽；這些資料等同登入憑證，請勿公開分享。

關閉最後一個視窗會直接結束 App。

## 建置與測試

建置機需要 Apple Command Line Tools；使用者執行已建好的 `.app` 不需要安裝其他東西。

```sh
cd BeanfunOTP
./test.sh
./build.sh          # Modern (--release 可執行 Developer ID 簽署與 Apple Notarization 公證)
./build-legacy.sh   # Legacy
```

Modern 版輸出位於 `dist/Beanfun OTP.app`，支援 Apple Silicon、Intel Mac 與 macOS 13 以上。Legacy 版輸出位於 `dist/Beanfun OTP Legacy.app`，僅支援 Intel Mac 與 macOS 10.12 以上。

這是非官方工具。Beanfun 若修改登入頁面、欄位或 OTP 協定，解析流程可能需要同步調整。
