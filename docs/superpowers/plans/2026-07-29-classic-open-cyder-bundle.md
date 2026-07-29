# Classic Prefer Cyder (`-b`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classic `NexonPlug` launches prefer `open -n -b local.cyder.app … --args …`; if Cyder is missing, confirm then optionally fall back to the default `.exe` handler.

**Architecture:** Add a small `CyderInstallation` helper (bundle-id lookup, injectable for tests) on Modern and Legacy `Models.swift`. Refactor `launchClassic` to choose `OpenLauncher` before quarantine/`open`, using `NSAlert` for the missing-Cyder confirmation in both tracks. Reuse existing `classicOpenArguments(..., launcher:)`.

**Tech Stack:** Swift 5, AppKit (`NSWorkspace` / `NSAlert`), existing `OpenLauncher` / `OpenLaunchArguments`, `./test.sh`, `./build-legacy.sh` (compile check).

## Global Constraints

- Modern **and** Legacy.
- Prefer `OpenLauncher.cyder` → `-b local.cyder.app` only (never OEM `local.cyder.maplestory-oem25` for Classic).
- Missing Cyder: modal confirm; **do not** call `open` until the user chooses; cancel → status 「已取消」, no cold-start quit.
- Continue without Cyder → `OpenLauncher.defaultApplication`.
- Choose launcher **before** Modern quarantine clear (cancel must not clear quarantine).
- Prefer small focused changes; no new dependencies.
- Commit messages: Conventional Commits, concise subject.
- Verification: `./test.sh`; Legacy at least `./build-legacy.sh` when Legacy files change.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/Models.swift` | `CyderInstallation.isOfficialCyderInstalled` (Modern) |
| `Legacy/Sources/Models.swift` | Same helper (Legacy duplicate, 10.12-safe lookup) |
| `Sources/AppModel.swift` | Classic launch: detect → confirm → quarantine → `open` with launcher |
| `Legacy/Sources/AppController.swift` | Same Classic launch flow with `NSAlert` |
| `Tests/CoreTests.swift` | Cyder argv + installation helper unit tests |
| `docs/macos-player-guide-classic.md` | Soften Finder Open-with; document `-b` preference |
| `README.md` | Classic blurb: App prefers Cyder via `-b` |

**Spec:** `docs/superpowers/specs/2026-07-29-classic-open-cyder-bundle-design.md`

---

### Task 1: Failing tests for Classic Cyder argv + installation helper

**Files:**
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes: `NexonPlugURLParser.classicOpenArguments`, `OpenLauncher.cyderBundleIdentifier`
- Produces (to implement in Task 2):
  - `CyderInstallation.isOfficialCyderInstalled(resolvePath: (String) -> String?) -> Bool`

- [ ] **Step 1: Write the failing tests**

In `main()`, after `try testClassicOpenArguments()`, add:

```swift
try testClassicOpenArgumentsPreferCyder()
try testCyderInstallationDetectsPath()
try testCyderInstallationMissingPath()
```

Bump the final print count from 17 to 20:

```swift
print("CoreTests: 20 tests passed")
```

Extend / add near `testClassicOpenArguments`:

```swift
private static func testClassicOpenArgumentsPreferCyder() throws {
    let args = NexonPlugURLParser.classicOpenArguments(
        executablePath: "/Games/Classic/Maplestory_Classic.exe",
        passargTokens: ["4554314", "sessabc", "2373", "944"],
        launcher: .cyder
    )
    try expect(args == [
        "-n",
        "-b",
        "local.cyder.app",
        "/Games/Classic/Maplestory_Classic.exe",
        "--args",
        "4554314",
        "sessabc",
        "2373",
        "944",
    ], "classic open argv with Cyder -b")
}

private static func testCyderInstallationDetectsPath() throws {
    let installed = CyderInstallation.isOfficialCyderInstalled { id in
        try! expect(id == OpenLauncher.cyderBundleIdentifier, "lookup must use official Cyder id")
        return "/Applications/Cyder.app"
    }
    try expect(installed == true, "non-empty resolve path should count as installed")
}

private static func testCyderInstallationMissingPath() throws {
    try expect(
        CyderInstallation.isOfficialCyderInstalled { _ in nil } == false,
        "nil resolve should be not installed"
    )
    try expect(
        CyderInstallation.isOfficialCyderInstalled { _ in "" } == false,
        "empty resolve should be not installed"
    )
}
```

Note: `testCyderInstallationDetectsPath` should not use `try! expect` inside the closure if that is awkward; instead assert `id` after the call by capturing:

```swift
private static func testCyderInstallationDetectsPath() throws {
    var lookedUp: String?
    let installed = CyderInstallation.isOfficialCyderInstalled { id in
        lookedUp = id
        return "/Applications/Cyder.app"
    }
    try expect(lookedUp == OpenLauncher.cyderBundleIdentifier, "lookup must use official Cyder id")
    try expect(installed == true, "non-empty resolve path should count as installed")
}
```

Use the capture form (not `try! expect` in the closure).

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`

Expected: FAIL — `CyderInstallation` undefined (argv test may already pass because `classicOpenArguments` already accepts `launcher:`; that is fine). At least the installation tests must fail.

- [ ] **Step 3: Commit test-only changes**

```bash
git add Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
test: cover classic Cyder -b argv and installation lookup

EOF
)"
```

---

### Task 2: Implement `CyderInstallation` (Modern)

**Files:**
- Modify: `Sources/Models.swift` (near `OpenLauncher`)
- Modify: `Tests/CoreTests.swift` only if signature tweak needed

**Interfaces:**
- Consumes: `OpenLauncher.cyderBundleIdentifier`, `NSWorkspace`
- Produces:
  ```swift
  enum CyderInstallation {
      static func isOfficialCyderInstalled(
          resolvePath: (String) -> String? = { bundleID in
              NSWorkspace.shared.absolutePathForApplication(withBundleIdentifier: bundleID)
          }
      ) -> Bool
  }
  ```

- [ ] **Step 1: Add helper to `Sources/Models.swift`**

Place immediately after `OpenLauncher`:

```swift
enum CyderInstallation {
    /// True when Launch Services can resolve Cyder 正式版 (`local.cyder.app`).
    static func isOfficialCyderInstalled(
        resolvePath: (String) -> String? = { bundleID in
            NSWorkspace.shared.absolutePathForApplication(withBundleIdentifier: bundleID)
        }
    ) -> Bool {
        guard let path = resolvePath(OpenLauncher.cyderBundleIdentifier), !path.isEmpty else {
            return false
        }
        return true
    }
}
```

Do **not** resolve OEM id. Prefer `absolutePathForApplication(withBundleIdentifier:)` so the same call shape works when duplicated on Legacy 10.12 (deprecated but available). On Modern this is acceptable.

- [ ] **Step 2: Run tests**

Run: `./test.sh`

Expected: `CoreTests: 20 tests passed`

- [ ] **Step 3: Commit**

```bash
git add Sources/Models.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: detect official Cyder via bundle id

EOF
)"
```

---

### Task 3: Modern `launchClassic` prefers Cyder + confirm fallback

**Files:**
- Modify: `Sources/AppModel.swift` (`launchClassic(passargTokens:)`)

**Interfaces:**
- Consumes: `CyderInstallation.isOfficialCyderInstalled()`, `NexonPlugURLParser.classicOpenArguments`, `OpenLauncher`
- Produces: Classic launch with launcher chosen before quarantine/`open`

- [ ] **Step 1: Refactor `launchClassic`**

Replace the body of `private func launchClassic(passargTokens: [String])` so order matches the spec:

1. Validate path (existing).
2. Choose launcher:
   - If `CyderInstallation.isOfficialCyderInstalled()` → `.cyder`
   - Else show `NSAlert`:
     - `messageText` = `未偵測到 Cyder`
     - `informativeText` = `經典版需透過 Cyder 才能可靠傳遞執行參數。請安裝 Cyder 正式版後再試。若仍要以系統預設的「打開方式」開啟，參數可能無法正確傳遞，遊戲可能無法登入。`
     - First button: `仍要開啟` → `.defaultApplication`
     - Second button: `取消` → set `statusMessage = "已取消"`; `return` (no quarantine, no `open`, no quit)
3. `clearQuarantineIfNeeded(at: path)` (existing).
4. `Process` `/usr/bin/open` with:
   ```swift
   process.arguments = NexonPlugURLParser.classicOpenArguments(
       executablePath: path,
       passargTokens: passargTokens,
       launcher: launcher
   )
   ```
5. On success log, include whether Cyder `-b` or default was used, e.g.  
   `classic executable=… launcher=cyder|default args=…`  
   Keep success status `已開啟新楓之谷：經典版`. Keep existing `quitAfterSuccessfulClassicLaunch` only on successful `open`.

`NSAlert` sketch:

```swift
let alert = NSAlert()
alert.messageText = "未偵測到 Cyder"
alert.informativeText = "經典版需透過 Cyder 才能可靠傳遞執行參數。請安裝 Cyder 正式版後再試。若仍要以系統預設的「打開方式」開啟，參數可能無法正確傳遞，遊戲可能無法登入。"
alert.alertStyle = .warning
alert.addButton(withTitle: "仍要開啟")
alert.addButton(withTitle: "取消")
let response = alert.runModal()
if response != .alertFirstButtonReturn {
    statusMessage = "已取消"
    return
}
let launcher = OpenLauncher.defaultApplication
```

When Cyder **is** installed, skip the alert and use `let launcher = OpenLauncher.cyder`.

- [ ] **Step 2: Verify Modern still builds / unit tests still pass**

Run: `./test.sh`

Expected: `CoreTests: 20 tests passed`

Optional: `./build.sh` if normally used for Modern packaging; not required if `./test.sh` already compiles `AppModel.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppModel.swift
git commit -m "$(cat <<'EOF'
feat: classic launch prefers Cyder -b with confirm fallback

EOF
)"
```

---

### Task 4: Legacy `CyderInstallation` + `launchClassic` parity

**Files:**
- Modify: `Legacy/Sources/Models.swift`
- Modify: `Legacy/Sources/AppController.swift` (`launchClassic(passargTokens:)`)

**Interfaces:**
- Same `CyderInstallation` API as Task 2 (duplicate in Legacy tree; Legacy does not share Modern sources).
- Same alert copy and launcher branching as Task 3.

- [ ] **Step 1: Add `CyderInstallation` to `Legacy/Sources/Models.swift`**

Identical enum to Modern Task 2, placed after Legacy `OpenLauncher`.

- [ ] **Step 2: Refactor Legacy `launchClassic`**

In `Legacy/Sources/AppController.swift`, mirror Task 3:

1. Validate path.
2. Detect Cyder → `.cyder`, or `NSAlert` → cancel (`statusLabel.stringValue = "已取消"`; return) / continue (`.defaultApplication`).
3. Build args with `launcher:` (Legacy has no quarantine helper — skip that step).
4. `runProcess` `/usr/bin/open` as today.
5. Success status stays `已開啟新楓之谷：經典版`; cancel must not trigger `quitAfterSuccessfulClassicLaunch`.

- [ ] **Step 3: Compile Legacy**

Run: `./build-legacy.sh`

Expected: exits 0; app binary produced under `dist/Beanfun OTP Legacy.app`.

- [ ] **Step 4: Commit**

```bash
git add Legacy/Sources/Models.swift Legacy/Sources/AppController.swift
git commit -m "$(cat <<'EOF'
feat(legacy): classic launch prefers Cyder -b with confirm fallback

EOF
)"
```

---

### Task 5: Player docs + README

**Files:**
- Modify: `docs/macos-player-guide-classic.md`
- Modify: `README.md` (Classic paragraph only)

- [ ] **Step 1: Update classic player guide**

In `docs/macos-player-guide-classic.md`:

1. Step 1 item 3: change from required-sounding Finder Open-with to optional, e.g.  
   `Beanfun OTP 會優先以 open -b local.cyder.app 指定 Cyder；通常不必再改 Finder「打開方式」。若未安裝 Cyder，App 會提示後才可用系統預設 App 開啟。`
2. Step 3 command example: show the preferred form:
   ```sh
   open -n -b local.cyder.app '/path/to/Maplestory_Classic.exe' --args <passarg 各參數…>
   ```
3. FAQ row that says confirm `.exe` 打開方式正確: soften to check Cyder 正式版已安裝 / App 是否以 `-b` 啟動，打開方式僅在手動 `open` 或略過提示時相關。

- [ ] **Step 2: Update README Classic blurb**

In `README.md` Classic sentence (~line 37), clarify that launch prefers Cyder via `-b local.cyder.app`, not merely “預設走 Cyder” via Finder association. Keep NexonPlug / single-instance wording.

- [ ] **Step 3: Commit**

```bash
git add docs/macos-player-guide-classic.md README.md
git commit -m "$(cat <<'EOF'
docs: classic launch prefers Cyder -b without Finder Open with

EOF
)"
```

---

## Manual verification (after all tasks)

| Case | Expected |
| --- | --- |
| Cyder installed; `.exe` Open-with ≠ Cyder | Classic URL still launches via Cyder; args work |
| Cyder uninstalled / renamed; Cancel | No `open`; status 已取消; no auto-quit |
| Cyder missing; 仍要開啟 | `open` without `-b`; may fail login if default handler ignores args |
| Non-2982 NexonPlug | Still forwards to official NexonPlug.app |

---

## Spec coverage (self-review)

| Spec item | Task |
| --- | --- |
| Prefer `-b local.cyder.app` | 3, 4 |
| Detect `local.cyder.app` | 2, 4 |
| Confirm cancel / continue | 3, 4 |
| Cancel before quarantine | 3 |
| Never OEM for Classic | 2–4 (hard-coded official id) |
| Modern + Legacy | 3, 4 |
| Docs soften Open with | 5 |
| Unit tests for Cyder argv | 1 |
| Cold-start quit only on success | 3, 4 (unchanged success path) |
