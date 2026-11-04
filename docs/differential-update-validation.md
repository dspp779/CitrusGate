# D：跨版本與中斷恢復驗證

日期：2026-10-30（Asia/Taipei）；候選版 0.9.0（build 29）。所有寫入均在 `.build/` 下的隔離副本進行，日常遊戲安裝未套用更新。

## 真實官方路線與來源

### TMS V282 → V283

透過 Internet Archive 保存的 [2026-09-09 官方 productInfo.json](https://web.archive.org/web/20260909125920id_/https://maplestory-download.beanfun.com/maplestory/productInfo.json)，找到仍可下載的官方 V282 `P2PdPoyK5obH` 目錄。依歷史清單取得並驗證 1,262 個檔案；這不是人工修改版本標記建立的舊版。

**來源限制：** 清單共有 1,263 項。唯一無法取得的是 `ResMan.dll`：官方舊網址回傳 804,832 bytes 全零內容，與歷史 SHA-256 不符。測試來源明確排除此檔，沒有將全零內容當作有效來源；升級時由 cmsdl 從目前官方完整檔案修復。故本次涵蓋「真實 V282、已知缺少一個 DLL」的升級與修復，並非全套 pristine V282 驗收。

- V282 `Data/Base/Base.wz` SHA-256：`d669c238a8434155cd3c9f33ee80925ce119bdd361a7ace841f4ba18c8c56b21`。
- V283 Base SHA-256：`bb976af4052e0e8d1211600e89923402d6dd977baf8755e9fa3ea0144c2c0a66`。
- [官方 00282to00283.patch](http://tw.cdnpatch.maplestory.beanfun.com/maplestory/patch/patchdir/00283/00282to00283.patch)：921,074,235 bytes。
- 套用後以目前官方完整清單逐檔驗證必要資料。`MapleStory.exe` 另對照獨立下載的小更新；官方補丁移除的 `shortcuts.ini` 視為非必要安裝捷徑設定，不阻擋提交，其他資料缺檔或雜湊不符仍失敗。

### 經典版 1.10.0 → 1.13.1

已找到實際 HTTP 200 的 [官方差分清單](https://tw-ngm.maplestoryclassic.games.gamania.com/457e2f2938a243aba86bb472828d6fb8-9ae5648c8ec84da1ac5d6d94c8993b68)：

- [來源 1.10.0 清單](https://tw-ngm.maplestoryclassic.games.gamania.com/9ae5648c8ec84da1ac5d6d94c8993b68)：177 項、2,961,858,818 bytes；全部物件 SHA-1 驗證後建立測試來源。
- [目標 1.13.1 清單](https://tw-ngm.maplestoryclassic.games.gamania.com/457e2f2938a243aba86bb472828d6fb8)：168 項。
- 差分清單 25 項，壓縮物件共 40,409,036 bytes，展開 56,493,932 bytes。
- 差分不涵蓋全部目標異動。套用後依完整目標清單補齊／修復 33 個檔案、下載 373 個物件；這是「官方差分加必要完整物件同步」，不宣稱只靠 25 個補丁就完成升級。

這條歷史路線可重現；App 一般操作仍以官方目前版本為目標。其他歷史版本配對可能 HTTP 403，不能據此承諾任意舊版都有直接差分。先前 `955e… → af9e…` 的差分不可用、改走完整下載路線也已通過。

## 中斷恢復與主程式保留

| 情境 | 驗證方式與結果 |
| --- | --- |
| V282→V283 補丁下載中斷 | 等待真實補丁寫入非零內容後取消；原 V282 每個檔案 SHA-256 不變。 |
| V282→V283 補丁套用中斷 | 偵測私人副本內 WZ 檔實際替換後取消；原 V282 每個檔案 SHA-256 不變。重新從乾淨來源更新，完整資料校驗後才切換。 |
| V283 小更新下載中斷 | 以官方小更新同長度的全零暫存重現未完成下載；App 丟棄暫存，取消時原 EXE／Base 保持不變，重試比對獨立官方小更新及全部資料雜湊。 |
| 同大版本主程式保留 | 在隔離的有效 PE 主程式末端改一個位元組，分別查詢、連續更新兩次、完整修復一次；各次 EXE 雜湊不變，必要資料仍完整校驗。這是保留策略測試，該變更檔不是另一個經官方認證的版本，也未執行。 |
| 經典版補丁下載中斷 | 等待實際官方補丁寫入後取消；來源逐檔 SHA-256 不變。 |
| 經典版補丁套用中斷 | 在私人副本 EXE 被替換、版本 marker 提交前取消；來源逐檔 SHA-256 不變。 |
| 經典版完整物件同步中斷 | 在相容解碼後的物件同步途中取消；來源逐檔 SHA-256 不變。重試完成所有目標物件驗證及原子切換。 |

另保留固定版 nxdl／cmsdl 的合成補丁強制終止測試：nxdl 對套用一半的來源直接重套可能誤報成功；從乾淨來源重跑後全部目標雜湊正確。此合成故障證據與上述真實官方測試分開記錄。

## MapleStory.exe 為何會重複更新

已檢查 [cmsdl 0.2.9 下載原始碼](https://github.com/HikariCalyx/cmsdl/blob/v0.2.9/src/tms.rs) 與 [補丁原始碼](https://github.com/HikariCalyx/cmsdl/blob/v0.2.9/src/tms_patch.rs)，並實際執行固定 binary：

- `--check`／`--upgrade-path-check` 只查詢，不寫主程式。
- `--download` 保留與完整清單原始主程式不同的既有 EXE；缺檔／原始 EXE 優先使用官方小更新。
- `--patch latest` 即使大版本相同，也會安裝目前發布的 `ExePatch.dat`。若遊戲自行更新較快，這條路線仍可能把主程式蓋回較早的內容。

App 已修正：確認 Base.wz 與目前官方清單一致時，同版本更新採主程式篩選下載；有效 PE、內容不同於完整清單原始 EXE、且沒有未完成下載標記時，更新及完整修復都保留該 EXE。原始／缺失／明顯無效的 EXE 重新取得小更新；跨大版本仍使用實際補丁與新的主程式。每次清除可能僅預配置的 `ExePatch.dat`，不再只因長度相同就重用。

**保留不等於官方驗證：** PE 結構檢查不是簽章驗證，App 不會把任意修改 EXE 宣稱為官方最新版。這項策略以避免回蓋為優先；若需要替換自行更新或損壞但結構仍有效的 EXE，須另行還原／移除該檔再修復。

實測期間官方同一 V283 路徑多次改檔，測試已改為獨立取得當次參考，不硬編碼「永久最新」雜湊：

| PE 版本 | bytes | SHA-256 |
| --- | --- | --- |
| 6.283.1.3（完整清單原始 EXE） | 185,932,768 | `6ad43945f184d6ba061f6eef536a78793071c8b62a3bfa5533cb900e247f3a6c` |
| 6.283.3.0（較早小更新） | 185,472,992 | `2b8d9a57007ed8dc787b5ed82edeec0350e1364549bcdf927e2c2ce0e855a2fc` |
| 6.283.4.0 | 186,222,560 | `963f6bb175d7d3663adf2cb4c0f4e8e6ba1f5f969a842c1aa17c4a7ab39fe511` |
| 6.283.5.0（本次最終參考） | 185,430,496 | `12df3d747df74c6c2a006d4bc8e25a9f5d247cdfd5d016190b3d5ec1851ca919` |

6.283.5.0 官方 Last-Modified：2026-10-29 22:36:03（Asia/Taipei）。上述雜湊只對應該次下載內容，不表示未來官方路徑不再更新。

## 本輪修正

1. 既有安裝在同磁碟私人副本更新；完成完整資料驗證後原子交換目錄。取消／失敗不提交，重試不沿用套用一半的來源。
2. nxdl prerelease9 在真實 `resources.assets` 補丁遇到未支援 `0x18`。新增有長度、位移及輸出大小界限的相容解碼，讀取未修改的原始來源；下載流先驗證官方 SHA-1，再以完整目標物件驗證結果。未知指令仍失敗。
3. 官方差分沒有涵蓋所有異動，新增依完整目標清單逐物件同步。下載的 zlib 物件限制解壓大小、驗證 SHA-1，檔案完整才替換私人副本；完成後才更新 marker。
4. 同大版本保留遊戲自行更新 EXE；清除未完成小更新暫存；官方清單要求重新取得網路內容，避免沿用本機舊快取。
5. 修正進度切換時沿用 100% 的顯示；驗證與額外物件下載重新呈現對應階段。
6. 排他鎖、切換前來源修改檢查、程序意外終止暫存回收、路徑／符號連結防護與保守磁碟預留均保留。Legacy 補上正確的 macOS API 可用版本判斷；下載工具本身仍要求 macOS 11。

## 重現方式與證據

固定 binary SHA-256：nxdl prerelease9 `e200004877ce629a1f3103da2bbb1c3235c15dafcfe7996ac0907e09f481e34e`；cmsdl 0.2.9 `9e39d11a4158e322762fef2e32740a064420eeb8c583edf4a1183fbde3c197ff`。

```sh
./test.sh
./scripts/build-downloader-smoke.sh
# 測試根目錄須含兩個固定 binary 及對應隔離來源；切勿指向日常安裝。
# V282 來源放 tms-major：
.build/tests/DownloaderSmoke "$PWD/.build/delta-followup/major-final" cms-major
# 官方 1.10.0 來源放 classic-major；僅此測試模式固定歷史目標：
.build/tests/DownloaderSmoke "$PWD/.build/delta-followup/classic-app" nx-official
# V283 原始 EXE／同版本變更 EXE 分別放在各自的 tms-clone：
.build/tests/DownloaderSmoke "$PWD/.build/delta-followup/minor-app" cms-interrupt
.build/tests/DownloaderSmoke "$PWD/.build/delta-followup/post-major-preserve" cms-preserve
```

歷史來源準備程式：`scripts/prepare-tms-history.py`、`scripts/prepare-classic-history.py`。前者預設所有檔案都必須通過；本次明確指定 `--allow-missing ResMan.dll`，將不可用檔案與原因記錄在來源之外。

本機原始日誌位於 `.build/delta-followup/`：`prepare-tms-v282-final.log`、`prepare-classic-v110.log`、`cms-major-complete.log`、`minor-app-final.log`、`post-major-preserve.log`、`classic-official-complete.log`、`exe-policy-final.log`、`unit-final.log`。較早 `cms-major-final.log` 在更新成功後因參考仍寫死為較早小更新而判定失敗；保留此紀錄，最終結果以重新取得官方參考的完整重跑為準。完整客戶端不納入版本控制。

安全切換需要實際獨立遊戲資料夾及支援原子目錄交換的檔案系統。取消後安全重試可能重新下載，不承諾沿用下載位元組。尚未實測 Intel 硬體、macOS 10.12、真人遊戲啟動及所有歷史版本配對。

Modern universal（macOS 13）／Legacy Intel（App macOS 10.12，下載工具 macOS 11）均已重新建置為 0.9.0 build 29，通過 Developer ID 簽章、Apple 公證、票證附加與獨立 Gatekeeper 檢查。當時 ZIP 已重新建立並驗證 CRC、版本及主程式內容。後續最後程式碼／UI 檢查產生 build 30，最終交付與發布前驗收詳見 [0.9.0 發布紀錄](release-0.9.0.md)；`dist/SHA256SUMS.txt` 對應目前最終交付包。

## 本次驗收結論

指定的 V282→V283、經典版官方 1.10.0→1.13.1 路線，以及上述下載／套用／物件同步中斷重試均通過。最終 V283 EXE 與獨立官方 6.283.5.0 參考一致；同大版本變更 EXE 的兩次更新與一次完整修復保留測試通過。此結論保留前述 V282 缺一個 DLL、歷史路線可用性與未進行真人遊戲啟動的限制，不推論任意版本均可差分。
