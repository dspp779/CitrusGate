# Standard Mode Launch UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In standard mode, give 新楓之谷 separate Cyder (`open`) and MapleStory Launcher (`wine` + env) launch buttons, and keep launch buttons visible but disabled with「啟動中…／已啟動」for ~10s after success.

**Architecture:** Pure `MapleStoryWineLauncher` builds wine executable path, environment, and argv (no Process). `AppModel` exposes `launchViaCyder` and `launchViaMapleStoryLauncherWine` as separate entry points sharing only launch-phase / cooldown UI state. `ContentView` standard account UI shows dual buttons for MapleStory and applies the shared disabled + status pattern.

**Tech Stack:** Swift 5, SwiftUI/AppKit, Foundation `Process`, existing `LaunchCommandBuilder` constants for CX_ROOT / bottle, `./test.sh`.

## Global Constraints

- Modern only; do not change Legacy.
- Dual launch buttons only for 新楓之谷 (`GameDefinition.mapleStory`).
- Classic and other games: Cyder/`open` only; still get disable + status UX.
- Cyder launcher uses `/usr/bin/open`; Wine launcher sets env and runs `wine` binary (not `open`).
- Wine defaults match player guide: `CX_ROOT` = `/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna`, bottle `maplestory`, locale `zh_TW.UTF-8`, `--workdir` = parent of exe.
- Success = Process started (`open` exit 0, or `wine` Process `run()` succeeded without waiting for wine exit); then ~10s cooldown.
- Failure: re-enable immediately + existing error alert.
- User-facing copy in Traditional Chinese.
- Spec: `docs/superpowers/specs/2026-07-24-standard-mode-launch-ux-design.md`.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/MapleStoryWineLauncher.swift` | Pure wine path / env / argv builder |
| `Sources/AppModel.swift` | Launch phase, Cyder vs Wine entry points, cooldown timer |
| `Sources/ContentView.swift` | Standard-mode dual buttons + status beside disabled buttons |
| `Tests/CoreTests.swift` | Wine launcher unit tests |
| `README.md` | One-line note on dual launch in standard mode |

---

### Task 1: `MapleStoryWineLauncher` + tests

**Files:**
- Create: `Sources/MapleStoryWineLauncher.swift`
- Modify: `Tests/CoreTests.swift`
- Modify: `test.sh` only if needed to compile new source (already globs `Sources/*.swift` via build; CoreTests links Sources — check `test.sh`)

**Interfaces:**
- Consumes: `LaunchCommandBuilder.mapleStoryWineCXRoot`, `mapleStoryWineBottle` (or duplicate constants once in Wine launcher and have LaunchCommandBuilder reference them — prefer **Wine launcher owns constants**, update `LaunchCommandBuilder` to call into Wine launcher for CX_ROOT/bottle to avoid drift)
- Produces:
  - `enum MapleStoryWineLauncher`
  - `static let cxRoot: String`
  - `static let bottle: String` (`"maplestory"`)
  - `static func wineExecutableURL(cxRoot: String = cxRoot) -> URL`
  - `static func processEnvironment(cxRoot: String = cxRoot) -> [String: String]`
  - `static func arguments(executablePath: String, accountID: String, otp: String) -> [String]`
    → `["--bottle", bottle, "--workdir", workdir, executablePath] + gameArgs`

- [ ] **Step 1: Add failing tests**

In `Tests/CoreTests.swift` `main()`, add and bump count:

```swift
try testMapleStoryWineLauncher()
print("CoreTests: 12 tests passed")
```

```swift
private static func testMapleStoryWineLauncher() throws {
    let exe = "/Users/jjc/Documents/ogs/gamania Games/MapleStory/MapleStory.exe"
    let args = MapleStoryWineLauncher.arguments(
        executablePath: exe,
        accountID: "T9ACCOUNT",
        otp: "12345678"
    )
    try expect(args == [
        "--bottle", "maplestory",
        "--workdir", "/Users/jjc/Documents/ogs/gamania Games/MapleStory",
        exe,
        "tw.login.maplestory.beanfun.com",
        "8484",
        "BeanFun",
        "T9ACCOUNT",
        "12345678",
    ], "wine argv mismatch")

    let wineURL = MapleStoryWineLauncher.wineExecutableURL()
    try expect(
        wineURL.path.hasSuffix("/MapleStory Launcher/wine"),
        "wine path suffix"
    )
    try expect(
        wineURL.path.contains("SharedSupport/maplestoryna"),
        "wine under CX_ROOT"
    )

    let env = MapleStoryWineLauncher.processEnvironment()
    try expect(env["CX_ROOT"] == MapleStoryWineLauncher.cxRoot, "CX_ROOT")
    try expect(env["LANG"] == "zh_TW.UTF-8", "LANG")
    try expect(env["LC_ALL"] == "zh_TW.UTF-8", "LC_ALL")
    try expect(env["LC_CTYPE"] == "zh_TW.UTF-8", "LC_CTYPE")
    let path = try require(env["PATH"], "PATH")
    try expect(path.hasPrefix(MapleStoryWineLauncher.cxRoot + "/MapleStory Launcher:"), "PATH prefix")
}
```

- [ ] **Step 2: Run `./test.sh` — expect FAIL** (missing type)

- [ ] **Step 3: Implement `Sources/MapleStoryWineLauncher.swift`**

```swift
import Foundation

enum MapleStoryWineLauncher {
    static let cxRoot =
        "/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
    static let bottle = "maplestory"

    static func wineExecutableURL(cxRoot: String = cxRoot) -> URL {
        URL(fileURLWithPath: cxRoot)
            .appendingPathComponent("MapleStory Launcher", isDirectory: true)
            .appendingPathComponent("wine", isDirectory: false)
    }

    static func processEnvironment(cxRoot: String = cxRoot) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let wineDir = URL(fileURLWithPath: cxRoot)
            .appendingPathComponent("MapleStory Launcher", isDirectory: true)
            .path
        env["CX_ROOT"] = cxRoot
        env["PATH"] = wineDir + ":" + (env["PATH"] ?? "")
        env["LANG"] = "zh_TW.UTF-8"
        env["LC_ALL"] = "zh_TW.UTF-8"
        env["LC_CTYPE"] = "zh_TW.UTF-8"
        return env
    }

    static func arguments(
        executablePath: String,
        accountID: String,
        otp: String
    ) -> [String] {
        let workdir = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .path
        let gameArgs = GameDefinition.mapleStory.gameArguments(
            accountID: accountID,
            otp: otp
        )
        return ["--bottle", bottle, "--workdir", workdir, executablePath] + gameArgs
    }
}
```

Update `LaunchCommandBuilder` to use `MapleStoryWineLauncher.cxRoot` / `.bottle` instead of its own static lets (keep `nexonWineCommand` string builder for advanced copy).

- [ ] **Step 4: Run `./test.sh` — expect PASS** (`CoreTests: 12 tests passed`)

- [ ] **Step 5: Commit**

```bash
git add Sources/MapleStoryWineLauncher.swift Sources/Models.swift Tests/CoreTests.swift test.sh
git commit -m "$(cat <<'EOF'
feat: add MapleStory Wine launcher argv and environment helper

EOF
)"
```

---

### Task 2: AppModel launch phase + separate Cyder / Wine launchers

**Files:**
- Modify: `Sources/AppModel.swift`

**Interfaces:**
- Consumes: `MapleStoryWineLauncher`, existing open argv helpers
- Produces:
  - `enum LaunchUIPhase { case idle, launching, launched }`
  - `@Published private(set) var launchUIPhase: LaunchUIPhase = .idle`
  - `@Published private(set) var launchStatusText: String = ""`  // 「啟動中…」「已啟動」or empty
  - `var areLaunchButtonsDisabled: Bool { launchUIPhase != .idle || isBusy }`
  - `func launchViaCyder()` — current open path for selected game + account + OTP
  - `func launchViaMapleStoryLauncherWine()` — MapleStory only; env + wine Process
  - `func launchSelectedAccountViaCyder()` / `launchSelectedAccountViaWine()` — OTP fetch then corresponding launcher (or gate if OTP already present)
  - Cooldown: 10 seconds after success → `idle`
  - Do **not** hide buttons via `launchedAccountID` in a way that removes controls (standard UI change in Task 3); `launchedAccountID` may remain for advanced/logging

- [ ] **Step 1: Add launch phase state and cooldown helper**

```swift
enum LaunchUIPhase: Equatable {
    case idle
    case launching
    case launched
}

@Published private(set) var launchUIPhase: LaunchUIPhase = .idle
@Published private(set) var launchStatusText = ""

private var launchCooldownTask: Task<Void, Never>?
private static let launchCooldownNanoseconds: UInt64 = 10_000_000_000

var areLaunchButtonsDisabled: Bool {
    launchUIPhase != .idle || isBusy
}

private func beginLaunchUI() {
    launchCooldownTask?.cancel()
    launchUIPhase = .launching
    launchStatusText = "啟動中…"
}

private func markLaunchSucceeded() {
    launchUIPhase = .launched
    launchStatusText = "已啟動"
    launchCooldownTask?.cancel()
    launchCooldownTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: Self.launchCooldownNanoseconds)
        guard let self, !Task.isCancelled else { return }
        await MainActor.run {
            self.launchUIPhase = .idle
            self.launchStatusText = ""
        }
    }
}

private func markLaunchFailed() {
    launchCooldownTask?.cancel()
    launchUIPhase = .idle
    launchStatusText = ""
}
```

Reset phase in `showGamePicker` / `selectGame` / `resetGameSession` as appropriate (idle + clear status).

- [ ] **Step 2: Split Cyder launcher from Wine launcher**

Refactor existing `launchGame()` body into `launchViaCyder()`:

- Call `beginLaunchUI()` before `Process.run`
- On `open` termination status 0: `markLaunchSucceeded()`, keep statusMessage for logs
- On failure: `markLaunchFailed()` + present error
- On `run()` throw: `markLaunchFailed()`

Add `launchViaMapleStoryLauncherWine()`:

```swift
func launchViaMapleStoryLauncherWine() {
    guard let game = selectedGame, game.id == GameDefinition.mapleStory.id else {
        errorMessage = "MapleStory Launcher 啟動僅支援新楓之谷"
        return
    }
    let path = normalizedExecutablePath
    // validate exe like launchViaCyder
    guard let account = selectedAccount, let otp else {
        errorMessage = "請先選擇帳號並取得 OTP"
        return
    }
    let wineURL = MapleStoryWineLauncher.wineExecutableURL()
    guard FileManager.default.isExecutableFile(atPath: wineURL.path) else {
        errorMessage = "找不到 MapleStory Launcher 的 Wine。請先安裝並開啟過 MapleStory Launcher。"
        return
    }

    beginLaunchUI()
    launchedAccountID = nil
    isBusy = true
    statusMessage = "正在以 MapleStory Launcher Wine 啟動\(game.name)…"

    let process = Process()
    process.executableURL = wineURL
    process.arguments = MapleStoryWineLauncher.arguments(
        executablePath: path,
        accountID: account.id,
        otp: otp.value
    )
    process.environment = MapleStoryWineLauncher.processEnvironment()
    // Optional: process.currentDirectoryURL = workdir URL

    do {
        try process.run()
        // Do not wait for wine exit
        isBusy = false
        launchedAccountID = account.id
        statusMessage = "已透過 MapleStory Launcher 啟動\(game.name)"
        appendLog("執行 wine：executable=\(path) account=\(account.id)")
        markLaunchSucceeded()
    } catch {
        isBusy = false
        markLaunchFailed()
        present(error)
    }
}
```

Wire OTP auto-launch paths:

- `launchSelectedAccount()` currently ends in `launchGame()` → change default to `launchViaCyder()` for single-account auto flow (preserve behavior).
- Add `launchSelectedAccountViaWine()` that mirrors OTP fetch then `launchViaMapleStoryLauncherWine()`, **or** if OTP already present on standard dual-button screen, buttons call launch methods directly after ensuring OTP (same as today: `launchSelectedAccount` fetches OTP then launches).

Preferred standard-mode wiring for Task 3:

- If OTP already available: Cyder button → `launchViaCyder()`; Wine button → `launchViaMapleStoryLauncherWine()`.
- If OTP not yet fetched: buttons call helpers that fetch OTP once then launch with the chosen launcher (store `pendingLaunchKind`).

Simplest approach matching current code: `launchSelectedAccount()` always used Cyder after OTP. Change to:

```swift
private var pendingLaunchKind: PendingLaunchKind = .cyder
enum PendingLaunchKind { case cyder, mapleStoryWine }

func launchSelectedAccountViaCyder() {
    pendingLaunchKind = .cyder
    launchSelectedAccount()
}
func launchSelectedAccountViaWine() {
    pendingLaunchKind = .mapleStoryWine
    launchSelectedAccount()
}
```

At the end of OTP success path where `launchGame()` is called, switch:

```swift
switch pendingLaunchKind {
case .cyder: launchViaCyder()
case .mapleStoryWine: launchViaMapleStoryLauncherWine()
}
```

Keep `launchGame()` as a deprecated alias calling `launchViaCyder()` for advanced mode button if still named `launchGame`.

- [ ] **Step 3: Build**

Run: `./test.sh && ./build.sh`  
Expected: tests pass; app builds.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppModel.swift
git commit -m "$(cat <<'EOF'
feat: split Cyder and MapleStory Launcher Wine launchers with cooldown

EOF
)"
```

---

### Task 3: Standard-mode dual buttons + status UI

**Files:**
- Modify: `Sources/ContentView.swift` (`standardAccountView`)
- Modify: `README.md` (short note)

**Interfaces:**
- Consumes: `model.areLaunchButtonsDisabled`, `launchStatusText`, `launchSelectedAccountViaCyder`, `launchSelectedAccountViaWine`, `selectedGame?.id == mapleStory`

- [ ] **Step 1: Replace standard launch control block**

In `standardAccountView`, remove the branch that **hides** the button when `launchedAccountID == account.id` and only shows a green label.

Replace with (conceptual):

```swift
} else if let account = model.selectedAccount {
    VStack(spacing: 10) {
        if model.selectedGame?.id == GameDefinition.mapleStory.id {
            HStack(spacing: 10) {
                Button {
                    model.launchSelectedAccountViaCyder()
                } label: {
                    Label("以 Cyder 開啟", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.areLaunchButtonsDisabled)

                Button {
                    model.launchSelectedAccountViaWine()
                } label: {
                    Label("以 MapleStory Launcher 開啟", systemImage: "wineglass")
                }
                .buttonStyle(.bordered)
                .disabled(model.areLaunchButtonsDisabled)
            }
        } else {
            Button {
                model.launchSelectedAccountViaCyder()
            } label: {
                Label("以 \(account.displayName) 開啟遊戲", systemImage: "play.fill")
                    .frame(minWidth: 190)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.areLaunchButtonsDisabled)
        }

        if !model.launchStatusText.isEmpty {
            HStack(spacing: 8) {
                if model.launchUIPhase == .launching {
                    ProgressView().controlSize(.small)
                }
                Text(model.launchStatusText)
                    .foregroundStyle(model.launchUIPhase == .launched ? .green : .secondary)
            }
            .font(.headline)
        } else if model.selectedGame?.supportsAutomaticLogin == false,
                  model.launchedAccountID == account.id {
            HStack {
                Button("複製帳號") { model.copyAccountID() }
                Button("複製 OTP") { model.copyOTP() }
            }
        }
    }
}
```

Ensure `isBusy` OTP-fetch ProgressView still works above/alongside without removing buttons incorrectly. While fetching OTP, `areLaunchButtonsDisabled` is true via `isBusy`.

Do **not** add Wine button on Classic screen.

SF Symbol `wineglass` may be unavailable on older OS — if build warns, use `play.circle` or `shippingbox` instead.

- [ ] **Step 2: README**

Add under 一般模式:

```markdown
新楓之谷在一般模式提供「以 Cyder 開啟」與「以 MapleStory Launcher 開啟」；後者使用 Launcher 內建 Wine（`maplestory` bottle）。啟動後按鈕會暫時停用約 10 秒並顯示狀態。
```

- [ ] **Step 3: Verify**

```bash
./test.sh
./build.sh
```

Manual: standard mode → 新楓之谷 → dual buttons; Classic → single Cyder-style control; cooldown text.

- [ ] **Step 4: Commit**

```bash
git add Sources/ContentView.swift README.md
git commit -m "$(cat <<'EOF'
feat: add standard-mode dual MapleStory launch buttons and cooldown UI

EOF
)"
```

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| Separate Cyder vs Wine launchers | 1, 2 |
| Wine env + wine binary (not open) | 1, 2 |
| Dual buttons 新楓之谷 only | 3 |
| Classic no Wine button | 3 |
| Buttons stay + disabled + status | 2, 3 |
| ~10 s re-enable on success | 2 |
| Fail → immediate re-enable | 2 |
| Unit tests for wine argv/env | 1 |
| Legacy untouched | Global Constraints |
