# Beanfun OTP for macOS

專為 macOS 設計的非官方 Beanfun 遊戲免網頁自動帶參登入工具。透過 Gama Play 掃描 QR Code，即可安全取得 OTP 並自動啟動遊戲。零外部套件依賴（無需 Python、Node.js 或 Homebrew）。

## 核心特色

- **零依賴與獨立運作**：純原生成品，解壓即用，不需安裝任何執行環境。
- **支援多款經典遊戲**：新楓之谷、楓之谷：經典版、新瑪奇、艾爾之光。
- **自動帶參登入與啟動**：掃碼後自動獲取 OTP 並帶參啟動遊戲，單一帳號自動一鍵登入。
- **自動 Quarantine 防護**：啟動前自動清除 macOS 隔離標記 (`com.apple.quarantine`)，避免 Wine / Cyder 權限阻擋。
- **經典版 NexonPlug 協定整合**：支援網頁 `NexonPlug://` 協定接收與轉發，具備單一實例與冷啟動自動結束機制。
- **客戶端一鍵下載**：整合釘選版客戶端下載器 ([cmsdl](docs/cmsdl-maplestory-download.md) / [nxdl](docs/nxdl-classic-download.md))，自動完成解壓與路徑還原。

## 版本對比

| 功能特性 | Beanfun OTP (Modern) | Beanfun OTP Legacy |
| --- | --- | --- |
| **系統需求** | macOS 13.0+ (Ventura 以上) | macOS 10.12+ (Sierra 以上) |
| **硬體架構** | Apple Silicon (M系列) + Intel | 僅 Intel (x86_64) |
| **UI 框架** | SwiftUI 原生極簡介面 | AppKit 經典介面 + 動態高度貼合 |
| **特色功能** | 一般/進階模式切換、Wine / Cyder 雙引擎啟動 | 輕量相容舊系統、單一實例自動搶占 |
| **建置腳本** | `./build.sh` | `./build-legacy.sh` |
| **輸出 App** | `dist/Beanfun OTP.app` | `dist/Beanfun OTP Legacy.app` |

## 主要功能亮點

- **一般模式**：以精簡介面選擇遊戲與帳號，支援一鍵掃碼、自動取得 OTP 及遊戲啟動。
- **進階模式 (Modern 版)**：查看完整 Shell 啟動指令、即時 Debug Log 與敏感參數維護。
- **楓之谷：經典版支援**：配合 [Cyder 正式版](https://github.com/dspp779/CyderBits/releases/latest) 使用，支援 `NexonPlug://` 帶參自動關閉。
- **新楓之谷雙引擎**：可自由選擇北美官方 **MapleStory Launcher** (CrossOver 25) 或 [Cyder 新楓之谷分支](https://github.com/dspp779/CyderBits/releases/tag/v0.7.0-maplestory)。

## 玩家指南與專題文件

- 📖 [新楓之谷安裝與遊玩教學](docs/macos-player-guide.md)
- 📖 [新楓之谷：經典版安裝與遊玩教學](docs/macos-player-guide-classic.md)
- ⚙️ [cmsdl 新楓之谷下載整合說明](docs/cmsdl-maplestory-download.md)
- ⚙️ [nxdl 經典版下載整合說明](docs/nxdl-classic-download.md)

## 快速建置與測試

```sh
cd BeanfunOTP

./test.sh          # 執行單元測試
./build.sh         # 建置 Modern 版 (dist/Beanfun OTP.app)
./build-legacy.sh  # 建置 Legacy 版 (dist/Beanfun OTP Legacy.app)
```

> **免責聲明**：本專案為非官方社群工具。遊戲服務與登入協定隨時可能變更。敏感登入憑證請勿公開分享。
