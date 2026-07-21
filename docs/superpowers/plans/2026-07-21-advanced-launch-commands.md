# Advanced Launch Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In advanced mode, show and copy a complete pasteable Terminal launch command (`open` for all games; Nexon MapleStory Launcher Wine form for 新楓之谷), without changing the in-app Cyder launch button.

**Architecture:** Add a pure `LaunchCommandBuilder` in `Models.swift` that shell-quotes paths and builds full commands. Advanced UI selects `open` vs Wine for MapleStory only; `AppModel` computes the display string live from executable path + account + OTP. Actual `launchGame()` stays on `/usr/bin/open`.

**Tech Stack:** Swift 5, SwiftUI, AppKit, existing `./test.sh` CoreTests (compiles `Models.swift` + `DESCipher.swift` + `CoreTests.swift`).

## Global Constraints

- Display/copy only — do not change `launchGame()` / standard mode.
- Wine command form is MapleStory-only.
- Wine defaults must match `docs/macos-player-guide.md` step 5: `CX_ROOT` → SharedSupport `maplestoryna`, `PATH` includes `$CX_ROOT/MapleStory Launcher`, bottle `maplestory`, locale `zh_TW.UTF-8` ×3. Do **not** use bottle `default` or `…/bin/wine --wait-children --enable-alt-loader macdrv`.
- Wine path / bottle / workdir are not user-editable in this iteration.
- Keep `OTPResult.commandLine` as the argument-only fragment.
- Conventional Commits; Traditional Chinese UI copy where applicable.
- Run verification with `./test.sh` after each task that touches Models/tests.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/Models.swift` | `AdvancedLaunchCommandStyle`, `LaunchCommandBuilder` (shell quote + open/Wine full commands) |
| `Sources/AppModel.swift` | Persist command style preference; expose computed full command + copy helper |
| `Sources/ContentView.swift` | Advanced 「遊戲啟動指令」 UI: segmented control, full command text, copy button |
| `Tests/CoreTests.swift` | Unit tests for quoting and both command forms |
| `README.md` | Document full commands + Wine option; link player guide |
| `docs/macos-player-guide.md` | Source of truth for Wine form (already written; ensure tracked / referenced) |
| `docs/superpowers/specs/2026-07-21-advanced-launch-commands-design.md` | Spec (already amended for player-guide Wine form) |

---

### Task 1: `LaunchCommandBuilder` — shell quote + `open` full command

**Files:**
- Modify: `Sources/Models.swift`
- Modify: `Tests/CoreTests.swift`
- Test: `./test.sh`

**Interfaces:**
- Consumes: `GameDefinition.gameArguments(accountID:otp:)`, `GameDefinition.supportsAutomaticLogin`
- Produces:
  - `enum AdvancedLaunchCommandStyle: String, CaseIterable, Identifiable { case open, nexonWine }` with `title`
  - `enum LaunchCommandBuilder` with:
    - `static func shellQuote(_ value: String) -> String`
    - `static func openCommand(executablePath: String, game: GameDefinition, accountID: String, otp: String) -> String`
    - `static let mapleStoryWineCXRoot: String`
    - `static let mapleStoryWineBottle: String` (`"maplestory"`)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CoreTests.swift` (and call from `main`):

```swift
private static func testShellQuote() throws {
    try expect(LaunchCommandBuilder.shellQuote("/Games/MapleStory.exe") == "'/Games/MapleStory.exe'", "plain path quote mismatch")
    try expect(
        LaunchCommandBuilder.shellQuote("/Games/Maple Story/MapleStory.exe") == "'/Games/Maple Story/MapleStory.exe'",
        "spaced path quote mismatch"
    )
    try expect(
        LaunchCommandBuilder.shellQuote("/Games/O'Brien/MapleStory.exe") == "'/Games/O'\\''Brien/MapleStory.exe'",
        "single-quote path escaping mismatch"
    )
}

private static func testOpenFullLaunchCommand() throws {
    let command = LaunchCommandBuilder.openCommand(
        executablePath: "/Games/Maple Story/MapleStory.exe",
        game: .mapleStory,
        accountID: "T9ACCOUNT",
        otp: "12345678"
    )
    try expect(
        command == "open -n '/Games/Maple Story/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun T9ACCOUNT 12345678",
        "MapleStory open full command mismatch"
    )

    let lineage = try require(GameDefinition.all.first { $0.id == "lineage" }, "Lineage missing")
    let manual = LaunchCommandBuilder.openCommand(
        executablePath: "/Games/Lineage.exe",
        game: lineage,
        accountID: "id",
        otp: "otp"
    )
    try expect(manual == "open -n '/Games/Lineage.exe'", "manual open full command must omit --args")
}
```

Update `main` to run the new tests and bump the printed pass count.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test.sh`

Expected: compile error `cannot find 'LaunchCommandBuilder' in scope` (or similar).

- [ ] **Step 3: Implement minimal builder APIs**

Add to `Sources/Models.swift` (after `AppMode` / near `MapleStoryLaunch`):

```swift
enum AdvancedLaunchCommandStyle: String, CaseIterable, Identifiable {
    case open
    case nexonWine

    var id: Self { self }

    var title: String {
        switch self {
        case .open: return "open"
        case .nexonWine: return "Nexon Launcher Wine"
        }
    }
}

enum LaunchCommandBuilder {
    static let mapleStoryWineCXRoot =
        "/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
    static let mapleStoryWineBottle = "maplestory"

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func openCommand(
        executablePath: String,
        game: GameDefinition,
        accountID: String,
        otp: String
    ) -> String {
        let quotedPath = shellQuote(executablePath)
        let args = game.gameArguments(accountID: accountID, otp: otp)
        if args.isEmpty {
            return "open -n \(quotedPath)"
        }
        return "open -n \(quotedPath) --args \(args.joined(separator: " "))"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`

Expected: `CoreTests: N tests passed` (updated count).

- [ ] **Step 5: Commit**

```bash
git add Sources/Models.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add shell-quoted open launch command builder

EOF
)"
```

---

### Task 2: Wine full command (player-guide form)

**Files:**
- Modify: `Sources/Models.swift`
- Modify: `Tests/CoreTests.swift`
- Test: `./test.sh`

**Interfaces:**
- Consumes: `LaunchCommandBuilder.shellQuote`, `mapleStoryWineCXRoot`, `mapleStoryWineBottle`, `GameDefinition.mapleStory.gameArguments`
- Produces:
  - `static func nexonWineCommand(executablePath: String, accountID: String, otp: String) -> String`
  - `static func fullCommand(style:game:executablePath:accountID:otp:) -> String`  
    (if `style == .nexonWine` and `game.id == GameDefinition.mapleStory.id` → Wine; else → open)

- [ ] **Step 1: Write the failing test**

```swift
private static func testNexonWineFullLaunchCommand() throws {
    let command = LaunchCommandBuilder.nexonWineCommand(
        executablePath: "/Users/jjc/Documents/ogs/gamania Games/MapleStory/MapleStory.exe",
        accountID: "T9ACCOUNT",
        otp: "12345678"
    )
    let expected = """
    export CX_ROOT='/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna'
    export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
    export LANG=zh_TW.UTF-8
    export LC_ALL=zh_TW.UTF-8
    export LC_CTYPE=zh_TW.UTF-8

    wine --bottle maplestory --workdir '/Users/jjc/Documents/ogs/gamania Games/MapleStory' '/Users/jjc/Documents/ogs/gamania Games/MapleStory/MapleStory.exe' tw.login.maplestory.beanfun.com 8484 BeanFun T9ACCOUNT 12345678
    """
    try expect(command == expected, "Nexon Wine full command mismatch")

    let openFallback = LaunchCommandBuilder.fullCommand(
        style: .nexonWine,
        game: try require(GameDefinition.all.first { $0.id == "mabinogi" }, "Mabinogi missing"),
        executablePath: "/Games/mabinogi.exe",
        accountID: "A2ACCOUNT",
        otp: "OTP123"
    )
    try expect(
        openFallback.hasPrefix("open -n "),
        "non-MapleStory must not emit Wine command even if style is nexonWine"
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test.sh`

Expected: compile error for missing `nexonWineCommand` / `fullCommand`.

- [ ] **Step 3: Implement Wine + dispatcher**

```swift
static func nexonWineCommand(
    executablePath: String,
    accountID: String,
    otp: String
) -> String {
    let workdir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
    let args = GameDefinition.mapleStory
        .gameArguments(accountID: accountID, otp: otp)
        .joined(separator: " ")
    return """
    export CX_ROOT=\(shellQuote(mapleStoryWineCXRoot))
    export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
    export LANG=zh_TW.UTF-8
    export LC_ALL=zh_TW.UTF-8
    export LC_CTYPE=zh_TW.UTF-8

    wine --bottle \(mapleStoryWineBottle) --workdir \(shellQuote(workdir)) \(shellQuote(executablePath)) \(args)
    """
}

static func fullCommand(
    style: AdvancedLaunchCommandStyle,
    game: GameDefinition,
    executablePath: String,
    accountID: String,
    otp: String
) -> String {
    if style == .nexonWine, game.id == GameDefinition.mapleStory.id {
        return nexonWineCommand(
            executablePath: executablePath,
            accountID: accountID,
            otp: otp
        )
    }
    return openCommand(
        executablePath: executablePath,
        game: game,
        accountID: accountID,
        otp: otp
    )
}
```

Note: trailing newline from Swift multiline string literals — keep the test `expected` string consistent with whatever the implementation produces (prefer a single trailing newline after the wine line, matching the triple-quoted block above).

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Models.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add MapleStory Nexon Launcher Wine command builder

EOF
)"
```

---

### Task 3: Wire `AppModel` preference + computed command + copy

**Files:**
- Modify: `Sources/AppModel.swift`
- Test: manual compile via `./test.sh` still green; UI wiring verified in Task 4

**Interfaces:**
- Consumes: `LaunchCommandBuilder.fullCommand`, `AdvancedLaunchCommandStyle`
- Produces on `AppModel`:
  - `@Published var advancedLaunchCommandStyle: AdvancedLaunchCommandStyle` (UserDefaults key e.g. `AdvancedLaunchCommandStyle`, default `.open`)
  - `var canCopyLaunchCommand: Bool`
  - `var fullLaunchCommand: String?` — `nil` when missing game / exe / account / otp
  - `func copyLaunchCommand()` — copies `fullLaunchCommand`, status 「啟動指令已複製」
  - Keep `copyCommandLine()` either redirected to `copyLaunchCommand()` or remove call sites in Task 4

- [ ] **Step 1: Add preference + computed helpers to `AppModel`**

```swift
private static let advancedLaunchCommandStyleKey = "AdvancedLaunchCommandStyle"

@Published var advancedLaunchCommandStyle: AdvancedLaunchCommandStyle {
    didSet {
        defaults.set(advancedLaunchCommandStyle.rawValue, forKey: Self.advancedLaunchCommandStyleKey)
    }
}

// in init, after other setup:
if let raw = defaults.string(forKey: Self.advancedLaunchCommandStyleKey),
   let style = AdvancedLaunchCommandStyle(rawValue: raw) {
    advancedLaunchCommandStyle = style
} else {
    advancedLaunchCommandStyle = .open
}

var canCopyLaunchCommand: Bool { fullLaunchCommand != nil }

var fullLaunchCommand: String? {
    guard let game = selectedGame else { return nil }
    let path = normalizedExecutablePath
    guard !path.isEmpty,
          let account = selectedAccount,
          let otp else { return nil }
    return LaunchCommandBuilder.fullCommand(
        style: advancedLaunchCommandStyle,
        game: game,
        executablePath: path,
        accountID: account.id,
        otp: otp.value
    )
}

func copyLaunchCommand() {
    guard let value = fullLaunchCommand else { return }
    copy(value)
    statusMessage = "啟動指令已複製"
}
```

Ensure `advancedLaunchCommandStyle` is initialized before `didSet` fires during `init` (use a stored default of `.open`, then assign from defaults carefully — same pattern as other published prefs, or set via a private backing approach if `didSet` would write during init undesirably).

- [ ] **Step 2: Leave `launchGame()` untouched**

Do not edit the `Process` / `/usr/bin/open` path in this task.

- [ ] **Step 3: Run unit tests**

Run: `./test.sh`

Expected: pass (Models unchanged behavior for existing tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/AppModel.swift
git commit -m "$(cat <<'EOF'
feat: compute and copy full advanced launch commands

EOF
)"
```

---

### Task 4: Advanced mode UI

**Files:**
- Modify: `Sources/ContentView.swift` (OTP / 「遊戲啟動參數」 group ≈ lines 481–503)

**Interfaces:**
- Consumes: `model.advancedLaunchCommandStyle`, `model.fullLaunchCommand`, `model.canCopyLaunchCommand`, `model.copyLaunchCommand()`, `model.selectedGame`
- Produces: updated advanced-mode group titled 「遊戲啟動指令」

- [ ] **Step 1: Replace the 「遊戲啟動參數」 GroupBox body**

Target structure:

```swift
GroupBox("遊戲啟動指令") {
    VStack(alignment: .leading, spacing: 10) {
        if model.selectedGame?.id == GameDefinition.mapleStory.id {
            Picker("指令形式", selection: $model.advancedLaunchCommandStyle) {
                ForEach(AdvancedLaunchCommandStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        if let command = model.fullLaunchCommand {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.selectedGame?.supportsAutomaticLogin == false {
            Text("此遊戲尚無可核對的命令列登入格式；仍可複製不含登入參數的 open 指令（需已選主程式與 OTP）。")
                .foregroundStyle(.secondary)
            // Still show fullLaunchCommand when exe+otp exist — for manual games
            // fullLaunchCommand is non-nil once path+account+otp are set.
            // If nil, show:
            // Text("請先選擇主程式並取得 OTP，以產生完整啟動指令。")
        } else {
            Text("請先選擇主程式並取得 OTP，以產生完整啟動指令。")
                .foregroundStyle(.secondary)
        }

        HStack {
            Button { model.copyLaunchCommand() } label: {
                Label("複製啟動指令", systemImage: "terminal")
            }
            .disabled(!model.canCopyLaunchCommand)
            Spacer()
            Button("選擇其他遊戲") { model.showGamePicker() }
            Button("選擇其他帳號") { model.chooseAnotherAccount() }
        }
    }
    .padding(10)
}
```

Simplify the empty/manual messaging in implementation to:

1. If `fullLaunchCommand != nil` → show it (works for automatic and manual once path+account+otp exist).
2. Else → 「請先選擇主程式並取得 OTP，以產生完整啟動指令。」

Remove dependence on `model.otp?.commandLine` for this panel. Do not change the 「透過 Cyder 啟動遊戲」 GroupBox.

- [ ] **Step 2: Build the app (optional smoke)**

Run: `./test.sh` then `./build.sh` if practical.

Expected: tests pass; app builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "$(cat <<'EOF'
feat: show selectable full launch commands in advanced mode

EOF
)"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md` (進階模式 section)
- Ensure tracked: `docs/macos-player-guide.md`
- Amend already done: `docs/superpowers/specs/2026-07-21-advanced-launch-commands-design.md` (commit if dirty)

- [ ] **Step 1: Update README advanced-mode section**

Document that:

- Advanced mode shows a **full Terminal command** (not only args).
- 新楓之谷 can switch between `open` and Nexon MapleStory Launcher Wine (bottle `maplestory`, locale exports per player guide).
- In-app launch button still uses Cyder via `open -n`.
- Link to `docs/macos-player-guide.md` for the full macOS play setup.

Example snippet to include:

```markdown
## 進階模式

…可查看完整可貼上終端機的啟動指令（`open`；新楓之谷另可選 Nexon MapleStory Launcher Wine）、OTP、Debug Log 與手動啟動。

複製用的 Wine 指令對齊 `docs/macos-player-guide.md`（`maplestory` bottle + `zh_TW.UTF-8`）。實際按下「啟動」仍走 Cyder 的 `open -n`。
```

- [ ] **Step 2: Stage player guide + README + any design amendment**

```bash
git add README.md docs/macos-player-guide.md docs/superpowers/specs/2026-07-21-advanced-launch-commands-design.md
git commit -m "$(cat <<'EOF'
docs: document full launch commands and macOS player guide

EOF
)"
```

- [ ] **Step 3: Final verification**

Run: `./test.sh`

Expected: all tests pass.

---

## Spec Coverage Checklist

| Spec requirement | Task |
| --- | --- |
| Full `open` terminal command | Task 1 |
| MapleStory Wine form (player guide) | Task 2 |
| Live computation from path/account/OTP | Task 3 |
| Segmented control MapleStory-only | Task 4 |
| Copy full command; rename button | Task 3–4 |
| Launch button unchanged | Task 3 (explicit non-edit) |
| Missing exe/OTP → prompt, copy disabled | Task 3–4 |
| README + player guide | Task 5 |
| Unit tests for open/Wine/manual/quoting | Tasks 1–2 |

## Out of Scope (do not implement)

- Editable Wine path / bottle / workdir
- Using Wine from the launch button
- Wine commands for non-MapleStory games
