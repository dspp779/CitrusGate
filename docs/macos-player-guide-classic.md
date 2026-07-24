# 在 macOS 玩新楓之谷：經典版（玩家教學）

最後更新：2026-07-24

本教學說明如何在 Apple Silicon／Intel Mac 上遊玩**新楓之谷：經典版**。這不是官方支援路徑，遊戲與登入服務隨時可能變更。

App 內顯示名稱為「楓之谷：經典版」。新楓之谷（非經典）請見 [`docs/macos-player-guide.md`](macos-player-guide.md)。

## 你會用到什麼

| 項目 | 用途 |
| --- | --- |
| Beanfun OTP（本專案 Modern 版，macOS 13+） | 選擇經典版主程式、開啟網頁登入、接收 `NexonPlug://` 並啟動 |
| Cyder（或系統預設可開 `.exe` 的相容層） | 以 `open -n … --args …` 開啟 `Maplestory_Classic.exe` |
| 經典版主程式 `Maplestory_Classic.exe` | 遊戲客戶端 |
| Beanfun 帳號 | 在官方網頁登入 |

## 為什麼不用北美官方 MapleStory Launcher？

北美官方 **MapleStory Launcher** 內建的是 **CrossOver 25（Wine 10）** OEM 環境，**缺少部分功能**（例如 `EventWriteEx`），經典版（Unity IL2CPP）會載入失敗。

請使用 **Cyder**（或同等已補齊相關功能的 Wine）搭配 `open -n`。

反過來說：新楓之谷（非經典）目前請用 Launcher Wine；**Cyder 還不能跑新楓之谷**（官方修補移植仍在進行中）。見 [`docs/macos-player-guide.md`](macos-player-guide.md)。

---

## 注意事項

1. **經典版請用 Cyder／`open`**，不要用北美 MapleStory Launcher（CrossOver 25／Wine 10）。
2. **Beanfun OTP 僅單一實例**：網頁再次呼叫 `NexonPlug://` 時交給現有視窗，不會再開第二個。
3. **冷啟動會自動結束**：若 App 本來沒開、被網頁喚起並成功啟動遊戲，啟動完成後會自動關閉；失敗或取消選檔則保持開啟以便重試。

---

## 步驟 1：準備環境

1. 安裝並設定好 **Cyder**（或可正確開啟 Windows `.exe` 的相容層）。
2. 取得 `Maplestory_Classic.exe`，放到好找的路徑（例如文件下自訂資料夾）。
3. 建議在 Finder 對該 `.exe` 按「取得資訊」→「打開方式」選 **Cyder**。
4. 準備 **Beanfun OTP**（Modern，macOS 13+；見專案 `README.md`／Release）。

---

## 步驟 2：在 Beanfun OTP 設定

1. 開啟 Beanfun OTP，選擇 **楓之谷：經典版**。
2. 指定 `Maplestory_Classic.exe` 路徑（每款遊戲路徑分開記住）。
3. 在經典版畫面按 **「將 NexonPlug 設為由 Beanfun OTP 處理」**，讓 macOS 把 `NexonPlug://` 交給本 App。
   - 其他 gameCode 的連結仍會轉發到官方  
     `/Library/Application Support/Nexon/Plug/NexonPlug.app`（若已安裝）。
   - 測完若要恢復官方 Plug，可將 handler 改回 `com.nexon.plug`。
4. 按開啟官方登入網頁（約為 <https://maplestoryclassic.beanfun.com/Main>），在瀏覽器完成登入。

---

## 步驟 3：從網頁啟動

1. 網頁登入成功後會開啟類似：

   ```text
   nexonplug://?game=2982@…&passarg=…
   ```

   （`2982` 為經典版；`passarg` 經解碼後即為傳給 `.exe` 的參數。）

2. Beanfun OTP 收到後會以大致如下形式啟動：

   ```sh
   open -n '/path/to/Maplestory_Classic.exe' --args <passarg 各參數…>
   ```

3. 行為說明：
   - **App 本來沒開**（被網頁冷啟動）：啟動成功後 Beanfun OTP 會自動結束。
   - **App 本來就開著**：不會再開第二個 Beanfun OTP；啟動後**不會**自動結束。
   - 若尚未選好 `.exe` 或路徑無效：會跳出選檔／錯誤，App 保持開啟，修好後可再從網頁登入重試。

---

## 常見問題

| 現象 | 可能原因 | 怎麼辦 |
| --- | --- | --- |
| 點登入沒反應／開了第二個 App | 未設為 NexonPlug handler，或舊版行為 | 在經典版畫面重新「設為由 Beanfun OTP 處理」；更新至支援單實例的版本 |
| 出現 il2cpp／EventWrite 相關錯誤 | 誤用北美 MapleStory Launcher（CrossOver 25／Wine 10） | 改用 Cyder + `open -n`；確認 `.exe` 打開方式不是 Launcher OEM Wine |
| 找不到 NexonPlug.app（轉發失敗） | 未裝官方 Plug，且連結不是經典版 | 僅經典版需 Beanfun OTP；其他 Plug 遊戲請安裝官方 NexonPlug |
| 選檔後仍無法啟動 | 路徑不是有效的 `.exe` | 重新選擇真正的 `Maplestory_Classic.exe` |

---

## 路徑速查

```text
建議：新楓之谷：經典版
  （自訂）…/Maplestory_Classic.exe

官方 NexonPlug（轉發非經典版用）
  /Library/Application Support/Nexon/Plug/NexonPlug.app

官方登入網頁
  https://maplestoryclassic.beanfun.com/Main
```

新楓之谷（非經典）的安裝與 Wine／Cyder 手動啟動見 [`docs/macos-player-guide.md`](macos-player-guide.md)。

---

## 免責

- 本流程使用第三方相容層（如 Cyder）執行 Windows 版客戶端，可能違反遊戲服務條款，也有帳號風險。
- 北美官方 MapleStory Launcher（CrossOver 25／Wine 10）**不能**用來開經典版（缺 `EventWriteEx` 等）。
- Nexon、遊戲橘子、Beanfun 皆未為此 macOS 玩法提供官方支援。
- `NexonPlug` 參數與登入相關資料屬敏感資訊，請勿貼到公開頻道或提交到任何版本庫。
