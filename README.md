# Beanfun OTP for macOS

原生 SwiftUI 小工具，用 Gama Play 掃描 QR code 登入 Beanfun，列出楓之谷帳號並取得 OTP。成品不依賴 Python、Homebrew、Node.js 或第三方套件。

## 一般模式

App 每次啟動預設使用一般模式。第一次開啟會要求選擇 `MapleStory.exe`，路徑會自動記住；按「取得 QR Code」後才會向 Beanfun 產生 QR Code，避免開啟 App 時過度頻繁請求。用 Gama Play 掃描並確認後：

- 只有一個楓之谷帳號時，會自動取得 OTP 並啟動遊戲。
- 有多個帳號時，選擇帳號後按「以〈帳號〉開啟遊戲」。

可從 macOS 上方的「遊戲」選單重新選擇 MapleStory 主程式。

一般模式使用精簡的固定大小視窗，QR 畫面只保留 QR Code、掃描說明、剩餘時間與重新產生按鈕。QR 區域以一致的 `12pt` 四邊白色留白延伸至視窗上、左、右邊緣。視窗不可縮放或進入全螢幕；系統選單不顯示「編輯」、「顯示方式」與「視窗」。

## 進階模式

從 macOS 上方的「模式」選單切換至進階模式，可查看及操作 OTP、立即／自動更新、目前狀態、Debug Log、完整遊戲啟動參數與手動啟動功能。

直接啟動會呼叫 macOS 的 `open -n`，依 `MapleStory.exe` 的預設開啟 App 建立新的 Cyder instance。`--args` 後的內容會由 Cyder 向下傳給遊戲（路徑即使包含空白也不需自行處理引號）：

```sh
open -n /path/to/MapleStory.exe --args tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

Debug Log 會印出呼叫網址、表單參數、HTTP 狀態、Cookie、Token、SecretCode、LongPolling key、帳號資料及 OTP。依目前的 debug 設定，敏感內容預設不遮蔽；這些資料等同登入憑證，請勿公開分享。

關閉最後一個視窗會直接結束 App。

## 建置與測試

建置機需要 Apple Command Line Tools；使用者執行已建好的 `.app` 不需要安裝其他東西。

```sh
cd apps/BeanfunOTP
./test.sh
./build.sh
```

輸出位於 `apps/BeanfunOTP/dist/Beanfun OTP.app`，支援 Apple Silicon、Intel Mac 與 macOS 13 以上。

這是非官方工具。Beanfun 若修改登入頁面、欄位或 OTP 協定，解析流程可能需要同步調整。
