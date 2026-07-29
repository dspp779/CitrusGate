# 在 macOS 玩新楓之谷：經典版（玩家教學）

最後更新：2026-07-24

本教學說明如何在 Apple Silicon／Intel Mac 上遊玩**新楓之谷：經典版**。這不是官方支援路徑，遊戲與登入服務隨時可能變更。

App 內顯示名稱為「楓之谷：經典版」。新楓之谷（非經典）請見 [`docs/macos-player-guide.md`](macos-player-guide.md)。

## 你會用到什麼

| 項目 | 用途 |
| --- | --- |
| Beanfun OTP（本專案 Modern 版，macOS 13+） | 選擇經典版主程式、開啟網頁登入、接收 `NexonPlug://` 並啟動 |
| [Cyder](https://github.com/dspp779/CyderBits/releases/latest) | 以 `open -n … --args …` 開啟 `Maplestory_Classic.exe` |
| 經典版主程式 `Maplestory_Classic.exe` | 遊戲客戶端（可手動準備，或用 App 內「下載經典版客戶端」） |
| Beanfun 帳號 | 在官方網頁登入 |

Cyder 下載：<https://github.com/dspp779/CyderBits/releases/latest>

開發／維護用的 nxdl 整合說明（釘選版本、路徑還原、進度解析）見 [`nxdl-classic-download.md`](nxdl-classic-download.md)。

## 為什麼不用北美官方 MapleStory Launcher？

北美官方 **MapleStory Launcher** 內建的是 **CrossOver 25（Wine 10）** OEM 環境，**缺少部分功能**（例如 `EventWriteEx`），經典版（Unity IL2CPP）會載入失敗。

請使用 **[Cyder 正式版](https://github.com/dspp779/CyderBits/releases/latest)** 搭配 `open -n`。

**不要**用北美 MapleStory Launcher，也**不要**用 [Cyder 新楓之谷分支](https://github.com/dspp779/CyderBits/releases/tag/v0.7.0-maplestory)（`v0.7.0-maplestory` 為 oem25，同樣缺 `EventWriteEx`）。

新楓之谷（非經典）則可選北美 Launcher，或可選該 Cyder 新楓之谷分支（不想裝 GMS Launcher 時）。**Cyder 正式版不能跑新楓之谷。** 見 [`docs/macos-player-guide.md`](macos-player-guide.md)。

---

## 注意事項

1. **經典版請用 Cyder 正式版／`open`**，不要用北美 MapleStory Launcher，也不要用 Cyder 新楓之谷分支（皆為 oem25／CrossOver 25，缺 `EventWriteEx`）。
2. **Beanfun OTP 僅單一實例**：網頁再次呼叫 `NexonPlug://` 時交給現有視窗，不會再開第二個。
3. **冷啟動會自動結束**：若 App 本來沒開、被網頁喚起並成功啟動遊戲，啟動完成後會自動關閉；失敗或取消選檔則保持開啟以便重試。

---

## 步驟 1：準備環境

1. 下載並安裝 **Cyder 正式版**：<https://github.com/dspp779/CyderBits/releases/latest>  
   （不要用 `v0.7.0-maplestory` 開經典版。）
2. 取得 `Maplestory_Classic.exe`，放到好找的路徑（例如文件下自訂資料夾）。
3. Beanfun OTP 會優先以 `open -b local.cyder.app` 指定 Cyder；通常不必再改 Finder「打開方式」。若未安裝 Cyder，App 會提示後才可用系統預設 App 開啟。
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
   open -n -b local.cyder.app '/path/to/Maplestory_Classic.exe' --args <passarg 各參數…>
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
| 出現 il2cpp／EventWrite 相關錯誤 | 誤用北美 Launcher 或 Cyder 新楓之谷分支（oem25） | 改用 [Cyder 正式版](https://github.com/dspp779/CyderBits/releases/latest) + `open -n -b local.cyder.app`；確認 Cyder 正式版已安裝，且 App 以 `-b` 指定 Cyder 啟動（Finder「打開方式」僅在手動 `open` 或略過未安裝提示時相關） |
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

- 本流程使用 [Cyder 正式版](https://github.com/dspp779/CyderBits/releases/latest) 等相容層執行 Windows 版客戶端，可能違反遊戲服務條款，也有帳號風險。
- 北美官方 MapleStory Launcher 與 Cyder 新楓之谷分支（oem25／CrossOver 25）**不能**用來開經典版（缺 `EventWriteEx` 等）。
- Nexon、遊戲橘子、Beanfun 皆未為此 macOS 玩法提供官方支援。
- `NexonPlug` 參數與登入相關資料屬敏感資訊，請勿貼到公開頻道或提交到任何版本庫。
