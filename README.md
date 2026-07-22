# Beanfun OTP for macOS

原生 SwiftUI 小工具，用 Gama Play 掃描 QR code 登入 Beanfun，選擇遊戲與帳號後取得 OTP。成品不依賴 Python、Homebrew、Node.js 或第三方套件。

目前依 Beanfun 官方遊戲專區支援 9 個服務：新楓之谷、天堂國際伺服器、天堂、天堂健康伺服器、天堂免費伺服器、新瑪奇、艾爾之光、新龍之谷與絕對武力 Online。爆爆王未納入。

## 一般模式

App 每次啟動預設使用一般模式。先從附有官方縮圖的精簡清單選擇遊戲；第一次選擇該遊戲時會要求指定 `.exe`，每款遊戲的路徑會分別記住。按「取得 QR Code」後才會向 Beanfun 產生 QR Code，避免開啟 App 時過度頻繁請求。用 Gama Play 掃描並確認後：

- 只有一個遊戲帳號時，會自動取得 OTP 並啟動遊戲。
- 有多個帳號時，選擇帳號後按「以〈帳號〉開啟遊戲」。

可從 macOS 上方的「遊戲」選單切換遊戲或重新選擇目前遊戲的主程式。

一般模式使用精簡的固定大小視窗，QR 畫面只保留 QR Code、掃描說明、剩餘時間與重新產生按鈕。QR 區域以一致的 `12pt` 四邊白色留白延伸至視窗上、左、右邊緣。視窗不可縮放或進入全螢幕；系統選單不顯示「編輯」、「顯示方式」與「視窗」。

## 進階模式

從 macOS 上方的「模式」選單切換至進階模式，可查看及操作 OTP、立即／自動更新、目前狀態、Debug Log、完整可貼上終端機的啟動指令與手動啟動功能。

「遊戲啟動指令」區塊會顯示**完整** shell 指令（不是只有 `--args` 後的遊戲參數），可直接複製到「終端機」執行。新楓之谷可在 `open` 與 **Nexon MapleStory Launcher Wine** 兩種形式間切換；其他遊戲僅顯示 `open` 形式。

`open` 形式會呼叫 macOS 的 `open -n`，依 `.exe` 的預設開啟 App 建立新的 Cyder instance（路徑即使包含空白也會正確引號）。已核對可直接帶入登入參數的遊戲如下：

```sh
open -n '/path/to/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
open -n '/path/to/mabinogi.exe' --args /N:<ServiceAccountID> /V:<OTP> /T:gamania
open -n '/path/to/elsword.exe' --args <ServiceAccountID> <OTP> TW
```

Wine 形式（僅新楓之谷）對齊 [`docs/macos-player-guide.md`](docs/macos-player-guide.md)：`maplestory` bottle、`zh_TW.UTF-8` locale，以及 MapleStory Launcher SharedSupport 的 Wine 路徑。macOS 完整安裝與手動啟動流程亦見該文件。

天堂系列、新龍之谷與 CSO 尚無可核對的命令列登入格式，因此完整指令不會誤傳楓之谷參數；實際啟動時會先複製 OTP，再以 `open -n` 開啟使用者指定的主程式。

**實際按下「透過 Cyder 啟動遊戲」仍走 Cyder 的 `open -n`**，不會從 App 內直接呼叫 Wine。

Debug Log 會印出呼叫網址、表單參數、HTTP 狀態、Cookie、Token、SecretCode、LongPolling key、帳號資料及 OTP。依目前的 debug 設定，敏感內容預設不遮蔽；這些資料等同登入憑證，請勿公開分享。

關閉最後一個視窗會直接結束 App。

## 兩個版本

| | Beanfun OTP | Beanfun OTP Legacy |
| --- | --- | --- |
| 系統需求 | macOS 13 以上 | macOS 10.12 以上（Intel） |
| 架構 | Apple Silicon + Intel | 僅 Intel (x86_64) |
| 功能 | 完整（含啟動遊戲、進階模式） | 精簡：QR 登入後複製 OTP |
| 建置 | `./build.sh` | `./build-legacy.sh` |
| 輸出 | `dist/Beanfun OTP.app` | `dist/Beanfun OTP Legacy.app` |

10.12–12 請用 Legacy。13 以上請用一般版。Beanfun 登入協定若變更，兩個版本的 client 都需要同步更新。

以下「一般模式」與「進階模式」說明僅適用於 **Beanfun OTP**（Modern 版）。

## 建置與測試

建置機需要 Apple Command Line Tools；使用者執行已建好的 `.app` 不需要安裝其他東西。

```sh
cd BeanfunOTP
./test.sh
./build.sh          # Modern
./build-legacy.sh   # Legacy
```

Modern 版輸出位於 `dist/Beanfun OTP.app`，支援 Apple Silicon、Intel Mac 與 macOS 13 以上。Legacy 版輸出位於 `dist/Beanfun OTP Legacy.app`，僅支援 Intel Mac 與 macOS 10.12 以上。

這是非官方工具。Beanfun 若修改登入頁面、欄位或 OTP 協定，解析流程可能需要同步調整。
