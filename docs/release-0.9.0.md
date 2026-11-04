# 0.9.0 候選版驗證紀錄

日期：2026-10-30（Asia/Taipei）；build 30

本版核定範圍：nxdl／cmsdl 升級、Issue #5、Modern UI／UX、診斷遮蔽與匯出、建置與發布驗證、啟動前檢查，以及有來源版本條件的差分更新。未加入最近使用／常用遊戲。

## 正式版更新說明

### Beanfun OTP 0.9.0

- **更新更安心**：既有安裝在隔離副本更新，檔案驗證完成才切換；取消或失敗時保留原安裝，重試可能重新下載。
- **新楓之谷小更新相容性**：同大版本更新與修復會保留遊戲自行更新的有效主程式，避免反覆回蓋 MapleStory.exe。
- **經典版差分更新**：加入補丁相容處理與必要檔案同步；無可用差分時改走完整檔案修復。
- **下載工具升級**：nxdl 更新至 v0.1.2-prerelease9、cmsdl 更新至 v0.2.9，移除每次下載後不再需要的路徑重排。
- **登入可靠性**：加強 WebToken 解析及 Modern／Legacy 共用回歸測試，涵蓋 Issue #5 的問題情境。
- **Modern 介面改進**：重新整理遊戲選擇、掃碼登入、帳號選擇、更新狀態及錯誤重試；改善深色模式、文字對比與長帳號顯示。
- **Legacy 操作收尾**：更新階段切換時清除過期進度與預估時間，取消後防止重複操作，更新期間鎖定會互相干擾的操作。
- **診斷與啟動檢查**：加入啟動前檢查及遮蔽敏感資料的診斷匯出。

Modern 支援 macOS 13 以上、Apple Silicon／Intel。Legacy App 保留 Intel macOS 10.12 建置目標；內建呼叫的新版下載工具需要 macOS 11 以上。更新遊戲前請先關閉遊戲。

本段為待發布文案；實際正式發布仍須完成下方發布前驗收，不表示已建立 GitHub release。

## Build 30 最後程式碼與介面檢查

- 修正取消後仍承諾接續下載的提示，明確說明可能重新下載。
- 修正 Legacy 在進入套用／校驗／物件同步時留下舊百分比與 ETA；隱藏不適用欄位，避免留白被無效資訊佔用。
- Legacy 預檢及下載量查詢的回呼加入操作識別與取消檢查，避免取消後啟動下一階段；兩版取消按鈕均防止重複操作。Legacy 解除更新鎖後會恢復返回／複製等操作，並加入原生控制項回歸檢查。
- 更新期間鎖定主程式選擇與相關操作；經典版官網登入連結不會在更新途中直接啟動遊戲，完成後需重新登入。
- 原子切換前再檢查取消；Modern 以已提交的成功結果為準，避免最後瞬間取消造成「已成功更新卻顯示取消」。新增邊界回歸案例。
- 移除兩版未使用、且會把快速檢查誤稱完整校驗的舊提示。
- Modern 26 張、Legacy 18 張原生合成畫面，檢查淺／深色、QR 到期、長帳號、校驗、取消及錯誤恢復；另檢查 Modern 進階模式。這是視覺自評，未取得 Awwwards／Webby／FWA 評審認證。
- 預覽工具不登入、不取 OTP、不更新 manifest，也不修改使用者偏好。Legacy 預覽先前的透明背景缺圖已修正，不以該渲染失真畫面作為產品證據。

## 功能與證據

- nxdl／cmsdl 的 macOS release assets 已實際下載，SHA-256 與固定值一致；兩者皆有 arm64／x86_64，最低系統為 macOS 11.0。
- nxdl 已在既有客戶端的 APFS 隔離副本下載 173 檔（3,421,949,015 bytes），零失敗，零反斜線檔名。新版不再執行每次下載後路徑重排。
- `2982.manifest.hash` 正確寫入；同版本差分 no-op 成功。缺少 marker 時，上游拒絕；無效 marker 會走到上游失敗路線，App 則在本機先拒絕該 marker 並選擇完整下載。
- TMS V283 的小更新在隔離副本實際套用，主程式雜湊改變，原遊戲安裝目錄未修改。詳見 [cmsdl 紀錄](cmsdl-maplestory-download.md)。
- 實際 App 下載器封裝已驗證：查詢更新路線、TMS 小更新套用與進度、經典版同版本差分、PTY 取消、取消後下一次查詢恢復。
- Issue #5 沿用 `12e9644` 的保守 selector；Modern 與 Legacy 使用相同離線 fixtures。真人登入證據沿用 Issue 的 2026-10-07 紀錄，本次沒有新登入或 OTP 請求。

## Build 29 更新驗證

- V282→V283 真實補丁下載／WZ 套用中斷後保留來源，乾淨重試、缺檔修復、最新官方小更新與資料校驗後才切換。
- 經典版官方 1.10.0→1.13.1 差分，涵蓋下載、套用、額外物件同步三階段中斷；修正 nxdl 未支援 0x18，以及差分未覆蓋全部異動的問題。
- 同大版本已變更的有效 PE 主程式在連續更新及完整修復時保留，避免遊戲啟動後自行更新又被回蓋；此保留策略不表示任意 EXE 已通過官方簽章驗證。
- 官方 V283 小更新同一路徑持續變動，最終參考為 6.283.5.0；實測採獨立當次下載，沒有把固定雜湊當成永久最新值。

## UI 自我檢查

採用生產用 SwiftUI view 及合成帳號／QR 資料，以原生 NSHostingView 產生淺色與深色畫面。靜態 ImageRenderer 無法繪製原生選單與捲動區，因此不以其佔位畫面作為驗收證據。

1. 第一輪：移除重複標題與多重容器，統一視窗、間距、主次操作；加入逾時與啟動前檢查。
2. 第二輪：修正原有 150×100 圖像放大的模糊，改用有來源紀錄的官方標誌／分享圖，讓經典版與一般版可辨識。
3. 第三輪：提高次要文字對比，檢查長帳號換行、小更新進度重置、深色模式與標題列留白。
4. 第四輪：更新失敗時移除大圖，將錯誤原因與重試操作前移，避免重要恢復操作被擠到捲動區下方。共產生 20 張淺／深色原生畫面。

檢查目標是原生產品的清晰度、一致性、可恢復性及可及性；本文件不把自評當作 Awwwards、Webby 或 FWA 的實際評審認證。鍵盤快捷鍵、可讀標籤與減少動態效果已納入實作；完整 VoiceOver 操作仍需真人驗收。

## 測試命令

```sh
./test.sh
./build.sh
./scripts/preview-ui.sh
./scripts/build-downloader-smoke.sh
# 僅對隔離的遊戲副本及固定版本工具執行：
.build/tests/DownloaderSmoke "$PWD/.build/upstream"
./scripts/verify-release.sh "dist/Beanfun OTP.app" --development
```

`DownloaderSmoke` 會在指定測試目錄下修改 `tms-clone`／`classic-clone`，不可指向日常遊戲安裝目錄。產物與原始測試日誌位於 `.build/`，不提交憑證、帳號、票券或完整遊戲客戶端。

## 尚未由本次實測建立的證據

- 未測所有歷史版本配對。已建立 V282→V283 真實補丁與經典版 1.10.0→1.13.1 官方差分的證據；V282 來源有一個官方已不可用的 ResMan.dll，升級中修復，因此不等於完整 pristine 舊版驗收。來源、必要物件同步及中斷恢復邊界詳見 [D 驗證與修正紀錄](differential-update-validation.md)。
- 實際 Intel 硬體及 macOS 10.12 上的操作；建置目標或離線 fixtures 不等於在該硬體／系統上執行。
- 新的真人登入／遊戲啟動與完整 VoiceOver 使用流程。

正式發布前仍應依發行者的裝置與帳號完成上述適用項目的驗收。

## 建置與發布結果

- `./test.sh`：5 項 Python manifest 測試、48 項核心測試、Modern／Legacy 各 14 個 WebToken 案例與敏感資料檢查，以及更新路線、無效大小／溢位、混合輸出 JSON、路徑衝突／符號連結、診斷遮蔽、啟動前檢查與進度階段的回歸案例均通過。
- Modern universal（二架構、macOS 13.0）與 Legacy Intel（macOS 10.12）均已建置。Legacy 使用官方 Swift 6.1.2 的 Intel 靜態相容庫，動態 back-deployment 庫皆為 macOS 10.9 起可用；沒有替換系統工具或提高 App deployment target。
- 官方 Swift 6.1.2 套件已確認 Apple Developer ID Installer 簽章、可信時間戳與 Apple 公證；固定 SHA-256 為 `46cd71f0ee4d80e389494c1237335a0a4f43a8ada04fcd97b22953d6f2a14d67`。新版開發工具搭配這組靜態相容庫已完成 Legacy 連結。直接以舊編譯器讀新版 SDK 的路線未採用。
- 兩版 build 30 候選建置皆執行 Developer ID 簽章、Apple 公證、票證附加及獨立 Gatekeeper 檢查；ZIP 的 CRC、版本及主程式內容與簽章 App 一致，SHA-256 見 `dist/SHA256SUMS.txt`。未建立 GitHub release、tag 或公開發布。
- 原始公證與驗證日誌：`.build/release-modern.log`、`.build/release-legacy.log`；最終獨立驗證：`.build/verify-modern-final.log`、`.build/verify-legacy-final.log`；下載器本輪實測日誌見 D 驗證紀錄。

## 覆核畫面

- [一般模式淺色首頁](screenshots/0.9.0/home-light.png)
- [一般模式深色首頁](screenshots/0.9.0/home-dark.png)
- [長帳號與深色模式](screenshots/0.9.0/accounts-dark.png)
- [更新失敗與恢復操作](screenshots/0.9.0/update-error-light.png)
- [主程式小更新進度](screenshots/0.9.0/minor-update-dark.png)

- [Modern 校驗階段](screenshots/0.9.0/verifying-light.png)
- [Modern 取消中](screenshots/0.9.0/cancelling-dark.png)
- [Modern 進階模式](screenshots/0.9.0/advanced-dark.png)
- [Legacy 官網登入](screenshots/0.9.0/legacy-classic-light.png)
- [Legacy 帳號選擇](screenshots/0.9.0/legacy-accounts-dark.png)
- [Legacy 校驗階段](screenshots/0.9.0/legacy-verifying-light.png)
- [Legacy 取消中](screenshots/0.9.0/legacy-cancelling-dark.png)

## 正式發布前驗收清單

以下未完成項目不以離線 fixtures、建置成功或自我檢查代替。P0 為正式發布前應完成；P1 為建議補齊的相容性與品質驗收。

| 優先級／狀態 | 項目 | 通過標準與目前缺口 |
| --- | --- | --- |
| P0／待驗收 | Modern、Legacy 真人登入 | 使用正式帳號完成掃碼、帳號選擇、OTP 與實際遊戲啟動；涵蓋 Issue #5 原情境、QR 到期重試及重新登入。本輪只有合成資料與既有歷史真人證據。 |
| P0／待驗收 | 經典版官網啟動 | 兩版驗證冷／暖啟動、重複遞送登入連結；更新途中不啟動，完成後重新登入可啟動。不得在紀錄中保存有效票券。 |
| P0／待驗收 | 遊戲自行小更新後再檢查 | 由真實遊戲更新 EXE，再連續檢查／更新、完整修復，確認沒有回蓋或重複更新循環。本輪已通過修改有效 PE 的保留策略測試，未實際啟動遊戲。 |
| P0／待驗收 | Intel 與最低系統 | 實際 Intel 上操作 Modern；Legacy 在 macOS 10.12 驗證啟動／登入，在 macOS 11 以上驗證新版下載工具。若不驗證 10.12，不應將建置目標宣稱為實機支援證據。 |
| P0／待驗收 | 使用者取得發布包 | 從實際發布位置下載兩個最終 ZIP，在乾淨使用者環境解壓、首次開啟，確認 Gatekeeper、版本與偏好遷移。現有本機簽章、公證、票證及 ZIP 完整性均通過；尚未公開發布。 |
| P1／待驗收 | 可及性 | 以鍵盤完成主要流程，驗證 Tab／Return／Escape、焦點、VoiceOver 朗讀、增加對比與減少動態效果。程式標籤與畫面檢查不等於真人輔助科技驗收。 |
| P1／待驗收 | 非 APFS 與外接磁碟 | 驗證空間預留、取消、暫存清理；不支援原子交換時應明確停止並保留原安裝。當前真實大型更新使用 APFS。 |
| 已驗證、有邊界 | 官方跨版本差分 | V282→V283 與經典版 1.10.0→1.13.1、指定中斷重試均通過。V282 少一個官方不可用 DLL、由升級修復；其他版本配對可用性未普遍驗證。詳見 D 紀錄。 |

### 最終證據與交付

- 程式碼／回歸：`.build/final-review-tests.log`；5 項 Python、48 項核心、兩版各 14 個 WebToken fixtures，以及更新與原子提交邊界案例。
- 介面：`.build/ui-review-final.log`、`.build/ui-review-legacy-final.log`；Legacy 原生控制項另檢查僅有階段訊息時與校驗時無過期資訊、取消鎖定，以及結束後操作恢復。
- 簽章／公證：`.build/release-modern.log`、`.build/release-legacy.log`；獨立檢查：`.build/verify-modern-final.log`、`.build/verify-legacy-final.log`。
- 產物：`dist/Beanfun-OTP-0.9.0-macOS.zip`、`dist/Beanfun-OTP-Legacy-0.9.0-macOS.zip`，版本均為 0.9.0 build 30；SHA-256 見 `dist/SHA256SUMS.txt`。
- 本輪沒有重跑所有大型官方下載；保留 build 29 的真實跨版本證據，build 30 以對應取消邊界回歸、兩版建置及原生介面測試驗證最後修正。
