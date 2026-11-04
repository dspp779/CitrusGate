# cmsdl 與 TMS 安裝／更新

最後更新：2026-10-30

| 項目 | 值 |
| --- | --- |
| 上游版本 | `v0.2.9` |
| 二進位 | `cmsdl_darwin`，arm64 + x86_64 |
| SHA-256 | `9e39d11a4158e322762fef2e32740a064420eeb8c583edf4a1183fbde3c197ff` |
| 別名／主程式 | `tms`／`MapleStory.exe` |
| 工具最低系統 | macOS 11.0 |

來源：[release](https://github.com/HikariCalyx/cmsdl/releases/tag/v0.2.9)。下載與重用快取時驗證 SHA-256。

## 更新路線

```sh
cmsdl_darwin tms --check --json
cmsdl_darwin tms --upgrade-path-check latest /path/to/client -v
cmsdl_darwin tms --patch latest /path/to/client --no-gui
cmsdl_darwin tms --download /path/to/client --no-gui
```

App 將大小預估與更新判斷分開。已安裝的客戶端先做 `--upgrade-path-check`；不能只從檔案存在或總大小判定完成。確認 Base.wz 與官方目前清單一致時，改走主程式篩選下載，保留遊戲自行更新的有效 PE 主程式。

| 路線查詢結束代碼 | App 行為 |
| --- | --- |
| 0 | 解析 current／target、補丁數量與小更新；可走差分路線 |
| 1 | 無適用路線，改用完整檔案下載方式 |
| 2 | 補丁比完整客戶端大，改用完整檔案下載方式 |
| 3 | 本機版本無法辨識，改用完整檔案下載方式 |
| 4 | 目標比本機舊，停止以避免降版 |
| 100 | 伺服器無法連線，停止並提供重試 |
| 其他／未知輸出 | 停止，不猜測版本或繼續修改檔案 |

上游 0.2.9 的非 Windows 路線也會取得 `ExePatch.dat` 並安裝為 `MapleStory.exe`；不需要執行 Windows 安裝器。補丁器是 best-effort，故 App 另追蹤小更新警告，不能僅因 exit 0 宣告所有更新已確認。

## 空間與資料保留

不再傳入 `--purge-wz-files`。此旗標會移除 Data 中 manifest 未列出的檔案，不是「下載永遠只佔 5 GiB」的保證。

既有目錄的完整修復／差分更新保守預留兩份完整客戶端大小，以涵蓋私人副本及展開暫存；差分路線再加補丁下載量，未知時採另一份完整大小。全新目錄以完整大小預留。空間判斷仍保留至少 1 GiB 安全空間，預留不是實際網路下載量。

既有安裝在私人副本更新，取消或失敗保留原安裝；重試從乾淨來源開始，可能重新下載。提交前驗證清單資料檔 SHA-256。同大版本且主程式為有效 PE、與原始清單不同、沒有未完成下載標記時，更新與完整修復均保留 EXE；缺失／原始／無效／舊大版本主程式重新取得。每次清除可能只完成預配置的 `ExePatch.dat`。小更新主程式與 pristine manifest 雜湊不同，App 不將任意本機 exe 當作已通過官方雜湊驗證。

## 同版本小更新與實測證據

cmsdl 0.2.9 的查詢不修改 EXE，`--download` 保留已改變的 EXE，但 `--patch latest` 會安裝發布中的 ExePatch.dat，即使大版本相同。App 已避開同版本無條件覆寫路線；連續更新兩次及完整修復一次均驗證既有變更 EXE 雜湊保留。測試在隔離副本修改一個位元組重現保留條件，不將其宣稱為另一個官方發行版本，也未執行。

已完成 V282→V283 真實官方補丁、下載及套用中斷後恢復、全資料校驗，以及 V283 真實小更新中斷／恢復。V282 官方舊檔唯一不可用的是 ResMan.dll，明確排除後由升級修復；其餘 1,262 檔逐檔驗證歷史清單。

本次最終官方小更新參考為 6.283.5.0、185,430,496 bytes、SHA-256 `12df3d747df74c6c2a006d4bc8e25a9f5d247cdfd5d016190b3d5ec1851ca919`。同一 V283 網址期間曾提供 6.283.3.0／4.0，故不使用固定雜湊作為未來最新版判斷。

有效 PE 結構不是簽章認證；保留策略不會證明未知 EXE 的來源或最新狀態。完整來源、原始日誌與限制見 [D 驗證紀錄](differential-update-validation.md)。
