# Beanfun OTP for macOS

原生 SwiftUI 小工具，用 Gama Play 掃描 QR code 登入 Beanfun，列出楓之谷帳號並取得 OTP。成品不依賴 Python、Homebrew、Node.js 或第三方套件。

## 使用方式

1. 雙擊 `dist/Beanfun OTP.app`。
2. 按「產生登入 QR Code」，用 Gama Play 掃描並確認。
3. 選擇楓之谷帳號；帳號 ID、SN 與顯示名稱由 Beanfun 自動取得。
4. 按「取得 OTP」。可複製 OTP 或完整的楓之谷命令列參數。
5. 先將 `.exe` 的預設開啟程式設為 `Cyder.app`，選擇一次 `MapleStory.exe` 後即可直接按「啟動 MapleStory」；路徑會在下次開啟時自動帶入。
6. 視需要開啟每 30、60 或 90 秒自動更新。

直接啟動會呼叫 macOS 的 `open -n`，依 `MapleStory.exe` 的預設開啟 App 建立新的 Cyder instance。`--args` 後的內容會由 Cyder 向下傳給遊戲（路徑即使包含空白也不需自行處理引號）：

```sh
open -n /path/to/MapleStory.exe --args tw.login.maplestory.beanfun.com 8484 BeanFun <ServiceAccountID> <OTP>
```

Debug Log 會印出呼叫網址、表單參數、HTTP 狀態、Cookie、Token、SecretCode、LongPolling key、帳號資料及 OTP。依目前的 debug 設定，敏感內容預設不遮蔽；這些資料等同登入憑證，請勿公開分享。

## 建置與測試

建置機需要 Apple Command Line Tools；使用者執行已建好的 `.app` 不需要安裝其他東西。

```sh
cd apps/BeanfunOTP
./test.sh
./build.sh
```

輸出位於 `apps/BeanfunOTP/dist/Beanfun OTP.app`，支援 Apple Silicon、Intel Mac 與 macOS 13 以上。

這是非官方工具。Beanfun 若修改登入頁面、欄位或 OTP 協定，解析流程可能需要同步調整。
