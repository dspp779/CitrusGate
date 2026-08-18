# GGM Manifest Remote Update Design

## Goal

讓 Beanfun OTP 不必因為 `GGMWebStart.dll` hash 或 `CV` 更新而重新發版，同時保留離線可用能力，避免 GitHub 短暫故障影響新楓之谷原生 OTP 流程。

## Non-goals

- 本設計不改動 `gamaniagames://` / GGM 啟動流程本身。
- 本設計不在第一版加入簽章驗證。
- 本設計不支援多個遠端來源或多 repo 同步。

## Requirements

- App 啟動時檢查遠端 manifest 是否更新。
- 若遠端 manifest 較新，下載並寫入本機快取。
- 若 GitHub 無法連線，繼續使用本機快取；若本機也沒有，使用 app 內建 fallback。
- 取 OTP 當下不得依賴 GitHub。
- 第一版只需要覆蓋新楓之谷原生 otp_v2 所需的 `CV` 與 `Hash`。

## Remote Location

Manifest 放在同一個 repo 的固定路徑，不使用另一個 repo，也不使用 `latest` release API。

建議路徑：

`metadata/ggm-manifest.json`

App 使用固定 raw URL：

`https://raw.githubusercontent.com/<owner>/<repo>/main/metadata/ggm-manifest.json`

選擇固定 raw URL 的原因：

- 比解析 GitHub Releases 更穩定
- 可直接使用 `ETag` / `Last-Modified`
- 維護成本低
- 與程式碼同 repo，歷史容易追蹤

## Manifest Format

第一版 manifest 只包含目前必需欄位：

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-08-18T17:20:00Z",
  "maplestory": {
    "ggmClientVersion": "1.5.0.2",
    "ggmWebStartDllSha256": "dfd568a69d87abcd8f4a93d1a4481ebb57712d1d28ab0b6fc018fcf140101e06"
  }
}
```

### Field meanings

- `schemaVersion`: manifest 格式版本。第一版固定為 `1`。
- `updatedAt`: manifest 發布時間，使用 UTC ISO-8601。
- `maplestory.ggmClientVersion`: otp_v2 POST 用到的 `CV`。
- `maplestory.ggmWebStartDllSha256`: otp_v2 POST 用到的 `Hash`。

## Source Priority

執行期採用以下優先順序：

1. 啟動後成功更新的本機快取
2. 啟動前已存在的本機快取
3. App bundle 內建 fallback manifest

App bundle 內建 manifest 永遠不覆蓋、不改名、不寫回。

## Local Storage

### Bundle fallback

放在 app bundle 中，例如：

`Resources/ggm-manifest.json`

### Local cache

放在 Application Support，例如：

`~/Library/Application Support/Beanfun OTP/ggm-manifest.json`

快取 metadata 另存一份，例如：

`~/Library/Application Support/Beanfun OTP/ggm-manifest.metadata.json`

建議內容：

```json
{
  "etag": "\"abc123\"",
  "lastModified": "Tue, 18 Aug 2026 09:20:00 GMT",
  "fetchedAt": "2026-08-18T17:30:00Z"
}
```

## Startup Update Flow

啟動流程：

1. 載入 bundle 內建 fallback manifest
2. 嘗試讀取本機快取 manifest
3. 若本機快取合法且較新，將 active manifest 設為本機快取
4. 發送 conditional GET 到 GitHub raw URL
5. 若回 `304 Not Modified`，保留本機快取
6. 若回 `200 OK`，解析遠端 manifest
7. 遠端 manifest 合法且較新時，覆蓋本機快取與 active manifest
8. 任一步驟失敗都不得中斷 App 啟動或 OTP 功能

## HTTP Caching Strategy

遠端 manifest 更新檢查優先使用 HTTP cache validators：

- `ETag`
- `Last-Modified`

App 行為：

- 若已有快取 metadata，送出 `If-None-Match`
- 若有 `Last-Modified`，可同時送出 `If-Modified-Since`
- `304` 代表遠端未變，不重新下載 body
- `200` 才下載新的 manifest body

判斷邏輯：

- HTTP cache headers 決定「要不要下載」
- manifest 內欄位決定「下載後要不要採用」

## Validation Rules

遠端或本機 manifest 只有在以下條件成立時才可採用：

- JSON 可解析
- `schemaVersion == 1`
- `updatedAt` 可解析
- `maplestory.ggmClientVersion` 非空
- `maplestory.ggmWebStartDllSha256` 為 64 字元 hex

較新判斷使用 `updatedAt`。

若 `updatedAt` 相同，保留現有 active manifest，不做覆蓋。

## Runtime Usage

OTP 流程不直接讀 GitHub，也不在取 OTP 時碰快取檔。

啟動後由一個 active manifest 常駐記憶體，原生 otp_v2 只讀：

- `CV` <- active manifest
- `Hash` <- active manifest

這樣可保證：

- OTP 路徑穩定
- GitHub 慢或掛掉不影響取 OTP
- 更新邏輯與 OTP 邏輯分離

## Components

### `GGMManifest`

責任：

- 定義 manifest JSON model
- 驗證欄位
- 暴露 `ggmClientVersion` 與 `ggmWebStartDllSha256`

### `GGMManifestStore`

責任：

- 讀取 bundle fallback manifest
- 讀取與寫入本機快取
- 讀取與寫入 metadata
- 比較本機 / 遠端 / fallback 新舊

### `GGMManifestUpdater`

責任：

- 啟動時執行 conditional GET
- 處理 `ETag` / `Last-Modified`
- 收到新 manifest 時驗證並更新快取
- 回報 log，但不阻斷主流程

### `BeanfunClient`

責任：

- 僅讀取 active manifest
- 不處理下載、快取與更新策略

## Error Handling

### Remote fetch failure

- 記 log
- 保留當前 active manifest
- 不顯示阻斷式錯誤給使用者

### Invalid remote JSON

- 忽略遠端資料
- 保留當前 active manifest

### Corrupted local cache

- 忽略本機快取
- 回退到 bundle fallback

### Missing bundle fallback

- 視為程式包裝錯誤
- 啟動仍可繼續，但 MapleStory 原生 OTP 應顯示明確錯誤

## Security Notes

第一版不做 manifest 簽章驗證，但保留未來擴充空間。

風險接受範圍：

- 信任同 repo 固定 raw 路徑
- 依賴 repo 權限控管避免錯誤或惡意修改

未來若要補強，可加入：

- manifest 簽章檔
- App 內建公開金鑰
- 驗簽成功才採用遠端 manifest

## Testing

需要覆蓋：

1. fallback manifest 解析成功
2. 本機快取比 fallback 新時會被採用
3. 遠端 `304` 不改變 active manifest
4. 遠端 `200` 且 `updatedAt` 較新時會更新快取
5. 遠端 `200` 但 JSON 無效時會忽略
6. 遠端不可連線時仍可使用本機快取
7. 取 OTP 時使用 active manifest 的 `CV` / `Hash`

## Rollout

第一步：

- 保留目前內建寫死 hash 作為 fallback manifest 初值

第二步：

- 加入 manifest model / store / updater

第三步：

- 將 MapleStory otp_v2 流程改讀 active manifest

第四步：

- 在 repo 加入 `metadata/ggm-manifest.json`

## Recommendation

採用：

- 同 repo 固定 raw URL
- bundle fallback + local cache + active manifest
- 啟動時 conditional GET
- OTP 流程只讀 active manifest

這個方案能同時滿足：

- 不用因 hash 更新而重發版
- GitHub 暫時不可用時仍可正常使用
- 第一版維護成本低
