# GGMWebStart LaunchTicket 與 OTP 協議分析報告

本文件詳細記錄 Gamania Games Manager（GGM）之 WebStart 客戶端（`GGMWebStart.dll`、`GGM.Shared.dll`）如何解析啟動參數、計算／解密 `LaunchTicket`、進行客戶端完整性校驗，並最終透過 OTP v2 介面取得與解密遊戲一次性密碼（OTP）的完整技術規範。

---

## 1. 核心結論（Key Findings）

1. **`LaunchTicket` 的本機計算與解密**：
   - 透過 Beanfun 網頁（`game_start_step2.aspx`）喚起 `gamaniagames://`（指令碼 `Cmd=06006` 或 `06004`）時，**`LaunchTicket` 已經被伺服器加密打包在 URL Scheme 的 `Data` 參數中**。
   - `GGMWebStart.exe` 透過內建的 **`Command.DecryptParam`（字元代換表 + DES-ECB）直接於本機解密**，完全不需要發送任何網路請求給 `gamesync.beanfun.com`（06006 路徑為本機離線解密）。
2. **`06009` vs `06006` / `06004` 雙軌機制**：
   - **`Cmd=06004` / `06006`（目前官方網頁標準啟動流程）**：`Data` 內含加密的 `LaunchTicket`（或舊版 `WebToken`/`SecretCode`/`ppppp`），GGMWebStart 於本機離線解密後直接發送 `POST get_webstart_otp_v2.ashx`。
   - **`Cmd=06009`（GameSync API 遠端認證流程）**：若採用 `06009` 指令，GGMWebStart 才會向 `https://gamesync.beanfun.com/api/GGM/Authentication` 發送 HTTP POST 換取 `LaunchTicket`。**實測 06006 路徑對 GameSync 回 404，不可依賴。**
3. **SN 來源**：
   - **`otp_v2` POST 的 `SN` 取自 URL Scheme 的 `SN=` 參數**（`m_objData.sn`），**不在** `Data` 解密後的明文裡。
4. **客戶端完整性校驗**：
   - 向 `get_webstart_otp_v2.ashx` 請求時，必須附帶 `CV`（版本號，目前 GGM 1.5.0.2 為 `1.5.0.2`）、`arch`（`x64`/`x86`）以及 `GGMWebStart.dll` 的 SHA-256 二進位檔案雜湊 `Hash`。
   - Beanfun OTP 內建 fallback manifest，並在啟動時從同 repo 的 `metadata/ggm-manifest.json` 檢查更新；若 GitHub 無法連線，則回退到本機快取或內建值。runtime 不讀本機 dll，因此原生 OTP 不需安裝 Games Manager。
   - **請求不帶 Cookie**（與舊版 GET `get_webstart_otp.ashx` 不同）。
5. **OTP 密文解密**：
   - `get_webstart_otp_v2.ashx` 回傳 40 字元 `data` 欄位，以前 8 字元為 Key、後 32 字元 Hex 為密文，進行 DES-ECB 解密取得明文 OTP。

---

## 2. 協議整體架構與流程圖

```mermaid
sequenceDiagram
    autonumber
    participant Web as Beanfun 網頁 (game_start_step2.aspx)
    participant GGM as GGMWebStart.exe (Cyder / Wine)
    participant BF as Beanfun Block (get_webstart_otp_v2.ashx)
    participant Game as MapleStory.exe (遊戲行程)

    Web->>GGM: 喚起 URL Scheme (gamaniagames://Region=TW;Production&&&&SN=<scheme UUID>&&&&Cmd=06006&&&&Data=...)
    Note over GGM: 【本機離線解密階段】<br/>1. 讀取 Data[0] 取得 Hex 偏移量 (offset)<br/>2. 選用 TABLES[1 + offset % 4] 還原 Hex 字串<br/>3. 從 offset+1 提取 8 字元 DES Key<br/>4. 執行 DES-ECB 解密還原 LaunchTicket=...;ServiceCode=...
    GGM->>GGM: 計算完整性校驗 (CV, arch, GGMWebStart.dll SHA-256 Hash)
    GGM->>BF: POST https://tw.beanfun.com/beanfun_block/generic_handlers/get_webstart_otp_v2.ashx
    Note over GGM,BF: Body: { "SN": "<scheme SN>", "LaunchTicket": "<解密>", "CV": "1.5.0.2", "Hash": "...", "arch": "x64" }（無 Cookie）
    BF-->>GGM: 回傳 JSON: { "result": 1, "data": "<40字元密文>", "message": "OK" }
    Note over GGM: 【OTP 解密階段】<br/>Key: data[0..8] (8 Bytes UTF-8)<br/>Ciphertext: data[8..40] (16 Bytes from Hex)<br/>演算法: DES-ECB (NoPadding) -> TrimEnd('\0')
    GGM->>Game: 帶入明文 OTP 與伺服器參數啟動遊戲
```

---

## 3. `Data` 參數本機解密演算法（`Command.DecryptParam`）

實作於 `GGMWebStart.Command::DecryptParam`（RVA: `0x2170`）與代換方法（RVA: `0x3608`）：

### 3.1 八組字元代換表（Substitution Tables）

代換表存放於內部類別 `b`（RVA: `0x3744`），每張表長度均為 16 字元：

```
Table 0: "18EA0FD239BBD938"   ← 非有效 hex 排列，實際解密不使用
Table 1: "bac987d65e432f10"
Table 2: "3bc4d5e6f2a79108"
Table 3: "cdbeaf9012456378"
Table 4: "4e6fb81a3c5d7092"
Table 5: "bdef1246789ac530"
Table 6: "5f82cb4093e71d6a"
Table 7: "df1468ace0357b92"
```

### 3.2 解密四步驟

1. **提取 Hex 偏移量與代換表**：
   - 設 `data_str` 為 URL Scheme 中的 `Data` 參數值。
   - `offset = Convert.ToInt32(data_str[0..1], 16)`（首字元轉 0~15 之整數）。
   - **`table_index = 1 + (offset % 4)`**（只用 Table 1–4；Table 0 不是合法 hex 字元排列）。
   - 選用 `table = TABLES[table_index]`。
2. **字元代換還原 Hex 字串**：
   - 對 `data_str[1..]` 中的每個字元 `c`，尋找其在 `table` 中的索引位置 `pos = table.IndexOf(c)`。
   - 將 `pos` 轉為 16 進位字元（`0`~`f`），拼接成 `hex_payload`。
3. **提取 8 字元 DES Key**：
   - `key_start = offset + 1`
   - `des_key = hex_payload.Substring(key_start, 8)`
   - `ciphertext_hex = hex_payload[0..key_start] + hex_payload[(key_start+8)..]`
4. **DES-ECB 解密還原啟動參數**：
   - 密文：將 `ciphertext_hex` 轉為 Byte Array。
   - 金鑰：`Encoding.UTF8.GetBytes(des_key)`（8 Bytes）。
   - 模式：`CipherMode.ECB`、`PaddingMode.None`。
   - 解密後轉為 UTF-8 字串，即得到以 **`;` 與 `&`** 分隔的鍵值對，例如：
     ```
     LaunchTicket=e3b0c442...;ServiceCode=611046;ServiceRegion=TW;ServiceAccount=...;BeanfunUrl=...;WebStartPatch=...
     ```
     （舊版格式可能包含 `WebToken=...;SecretCode=...;ppppp=...`）

**注意**：明文裡**沒有** `SN=`；`SN` 只在 scheme URI 的 `SN=` 參數。

---

## 4. 客戶端校驗計算與 OTP v2 請求

### 4.1 校驗參數計算（`A.E::b`，RVA: `0x3f50`）

- **`arch`**：`Environment.Is64BitProcess ? "x64" : "x86"`
- **`CV`**：組件版本號（目前 Cyder 內建 GGM 1.5.0.2 為 **`1.5.0.2`**）
- **`Hash`**：讀取 `GGMWebStart.dll` 二進位資料計算 SHA-256 雜湊值（64 字元 Hex）：
  $$\text{Hash} = \text{SHA256}(\text{ReadAllBytes}(\text{"GGMWebStart.dll"}))$$
  Beanfun OTP 不在 runtime 讀檔；實作上改讀啟動時載入的 active manifest。預設 fallback 值目前為  
  `dfd568a69d87abcd8f4a93d1a4481ebb57712d1d28ab0b6fc018fcf140101e06`。

### 4.2 發送 OTP 請求（`StartGameCommand::a`，RVA: `0x2958`）

- **URL**：`https://tw.beanfun.com/beanfun_block/generic_handlers/get_webstart_otp_v2.ashx`
- **Method**：`POST`（`Content-Type: application/json; charset=utf-8`）
- **Cookie**：**不帶**（與舊 GET 流程不同）
- **Request Body**：
  ```json
  {
    "SN": "<scheme URI 的 SN，非解密明文>",
    "LaunchTicket": "<Data 解密取得的 64 hex LaunchTicket>",
    "CV": "1.5.0.2",
    "Hash": "dfd568a69d87abcd8f4a93d1a4481ebb57712d1d28ab0b6fc018fcf140101e06",
    "arch": "x64"
  }
  ```
- **Response Body**：
  ```json
  {
    "result": 1,
    "data": "K1E2Y3T4A9B8C7D6E5F4A3B2C1D0E9F8A7B6C5D4",
    "message": "OK"
  }
  ```

---

## 5. OTP 密文解密演算法

實作於內部方法 `RVA: 0x3664`：

1. **拆分回傳之 40 字元 `data` 欄位**：
   - **Key**：前 8 字元 `data[0..8]`（8 Bytes UTF-8）。
   - **密文**：後 32 字元 `data[8..40]`（16 Bytes from Hex）。
2. **DES-ECB 解密**：
   - 演算法：DES (`DESCryptoServiceProvider`)
   - 模式：`CipherMode.ECB`
   - 填充：`PaddingMode.None`
   - 解密後轉 UTF-8 並執行 `.TrimEnd('\0')` 剔除尾端補位，即得明文 **OTP**（通常 10 字元）。

---

## 6. 兩種 macOS 啟動路徑（Beanfun OTP 測試版）

| 路徑 | 說明 | 指令範例 |
|------|------|----------|
| **A. 原生 OTP** | 本 App 離線解密 `Data` → POST v2 → DES 解 OTP → Cyder 正式版開 `MapleStory.exe` | `open -n -b local.cyder.app /path/MapleStory.exe --args ...` |
| **B. Scheme 啟動** | 本 App 組 `gamaniagames://` → `open` 交給已註冊 handler（Cyder） | `open -n 'gamaniagames://Region=...&&&&SN=...&&&&Cmd=06006&&&&Data=...'` |

路徑 B 不需要指定 `GGMWebStart.exe`；Cyder 收到 scheme 後自行處理 OTP 與啟動。

---

## 7. Python 完整離線解密實作參考

以下 Python 程式碼可直接完整解密 `gamaniagames://` 中的 `Data` 參數，無需連網至 GameSync：

```python
import subprocess

TABLES = [
    "18EA0FD239BBD938",  # Table 0 — 非有效 hex 排列，解密不使用
    "bac987d65e432f10",
    "3bc4d5e6f2a79108",
    "cdbeaf9012456378",
    "4e6fb81a3c5d7092",
    "bdef1246789ac530",
    "5f82cb4093e71d6a",
    "df1468ace0357b92",
]

def des_ecb_decrypt(cipher_bytes: bytes, key_str: str) -> bytes:
    key_hex = key_str.encode("utf-8").hex()
    proc = subprocess.run(
        ["openssl", "enc", "-d", "-des-ecb", "-K", key_hex, "-nopad"],
        input=cipher_bytes,
        capture_output=True,
        check=True,
    )
    return proc.stdout

def decrypt_data_param(data_str: str) -> dict[str, str]:
    """解密 gamaniagames:// 中的 Data 參數，取得 LaunchTicket 等欄位（不含 SN）"""
    offset = int(data_str[0], 16)
    table = TABLES[1 + (offset % 4)]  # 只用 Table 1–4

    hex_chars = []
    for ch in data_str[1:]:
        idx = table.find(ch)
        if idx < 0:
            raise ValueError(f"字元 {ch} 不在代換表 {table} 中")
        hex_chars.append(f"{idx:x}")
    hex_payload = "".join(hex_chars)

    key_start = offset + 1
    des_key = hex_payload[key_start : key_start + 8]
    cipher_hex = hex_payload[:key_start] + hex_payload[key_start + 8 :]

    cipher_bytes = bytes.fromhex(cipher_hex)
    decrypted_bytes = des_ecb_decrypt(cipher_bytes, des_key)
    plaintext = decrypted_bytes.decode("utf-8", errors="replace").rstrip("\x00")

    params = {}
    for pair in plaintext.replace("&", ";").split(";"):
        if "=" in pair:
            k, v = pair.split("=", 1)
            params[k] = v
    return params

def decrypt_otp_data(otp_data_field: str) -> str:
    """解密 get_webstart_otp_v2.ashx 回傳之 40 字元 data 欄位取得明文 OTP"""
    key = otp_data_field[:8]
    cipher_hex = otp_data_field[8:]
    cipher_bytes = bytes.fromhex(cipher_hex)
    decrypted = des_ecb_decrypt(cipher_bytes, key)
    return decrypted.decode("utf-8", errors="replace").rstrip("\x00")
```

---

## 8. 驗證紀錄

2026-08-17 實測（06006 / 新楓之谷）：

- `DecryptParam` 使用 `TABLES[1 + offset % 4]` → `LaunchTicket` 64 hex
- `SN` 取自 scheme URI（非解密明文）
- POST v2（`CV=1.5.0.2`，無 Cookie）→ `result=1`
- DES 解 40 字元 envelope → OTP 10 字
