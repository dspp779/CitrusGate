# Open Launch Quarantine Clear Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically clear macOS `com.apple.quarantine` from the selected `.exe` immediately before `open`-based launches so Gatekeeper does not block Cyder and Classic startup.

**Architecture:** Keep `chooseExecutable()` side-effect free and add a small quarantine helper inside `AppModel` because the behavior only applies to modern `open` launch paths. Reuse that helper from `launchViaCyder()` and `launchClassic()` after path validation but before `Process.run()`, while leaving MapleStory Launcher Wine untouched.

**Tech Stack:** Swift 5, SwiftUI/AppKit, Foundation, CoreServices/URL resource APIs, existing `./test.sh` core test runner.

## Global Constraints

- Modern only; do not change Legacy.
- Do not clear quarantine when the user merely selects a file.
- Only `open`-based launch paths participate: `launchViaCyder()` and `launchClassic()`.
- `launchViaMapleStoryLauncherWine()` must remain unchanged.
- On clear failure, abort launch and show a Traditional Chinese error.
- Prefer small, focused changes in existing files; do not add dependencies.
- Verification must use the narrowest relevant check available.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/AppModel.swift` | Quarantine helper, pre-launch hook for `open`-based launches, user-facing error copy |
| `Tests/CoreTests.swift` | Pure helper tests for quarantine attribute detection and error shaping |

---

### Task 1: Add failing tests for quarantine helper behavior

**Files:**
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes: none
- Produces:
  - `AppModel.QuarantineStatus`
  - `AppModel.quarantineStatus(forExtendedAttributes:)`
  - `AppModel.quarantineRemovalErrorDescription(path:underlying:)`

- [ ] **Step 1: Write the failing test**

Add these calls in `main()` before the final print and bump the count to 15:

```swift
try testQuarantineStatusWithoutAttribute()
try testQuarantineStatusWithAttribute()
try testQuarantineRemovalErrorDescription()
print("CoreTests: 15 tests passed")
```

Add the tests near the bottom of `Tests/CoreTests.swift`:

```swift
private static func testQuarantineStatusWithoutAttribute() throws {
    let status = AppModel.quarantineStatus(forExtendedAttributes: [
        "com.apple.metadata:kMDItemWhereFroms",
        "com.apple.lastuseddate#PS",
    ])
    try expect(status == .notQuarantined, "missing quarantine attribute should be not quarantined")
}

private static func testQuarantineStatusWithAttribute() throws {
    let status = AppModel.quarantineStatus(forExtendedAttributes: [
        "com.apple.quarantine",
        "com.apple.metadata:kMDItemWhereFroms",
    ])
    try expect(status == .quarantined, "quarantine attribute should be detected")
}

private static func testQuarantineRemovalErrorDescription() throws {
    let message = AppModel.quarantineRemovalErrorDescription(
        path: "/Games/Maple Story/MapleStory.exe",
        underlying: "Operation not permitted"
    )
    try expect(
        message == "無法解除檔案的 macOS quarantine，請檢查檔案權限後再試一次：/Games/Maple Story/MapleStory.exe\nOperation not permitted",
        "quarantine removal error copy mismatch"
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`
Expected: FAIL because `AppModel` does not yet expose `QuarantineStatus`, `quarantineStatus(forExtendedAttributes:)`, or `quarantineRemovalErrorDescription(path:underlying:)`.

- [ ] **Step 3: Write minimal implementation**

Add these pure helpers to `AppModel`:

```swift
enum QuarantineStatus: Equatable {
    case notQuarantined
    case quarantined
}

static func quarantineStatus(
    forExtendedAttributes names: [String]
) -> QuarantineStatus {
    names.contains("com.apple.quarantine") ? .quarantined : .notQuarantined
}

static func quarantineRemovalErrorDescription(
    path: String,
    underlying: String
) -> String {
    "無法解除檔案的 macOS quarantine，請檢查檔案權限後再試一次：\(path)\n\(underlying)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test.sh`
Expected: PASS with `CoreTests: 15 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppModel.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
test: cover quarantine helper decisions

EOF
)"
```

---

### Task 2: Wire quarantine clearing into `open` launch paths

**Files:**
- Modify: `Sources/AppModel.swift`
- Test: `Tests/CoreTests.swift` (already updated in Task 1)

**Interfaces:**
- Consumes:
  - `AppModel.QuarantineStatus`
  - `AppModel.quarantineStatus(forExtendedAttributes:)`
  - `AppModel.quarantineRemovalErrorDescription(path:underlying:)`
- Produces:
  - `private func clearQuarantineIfNeeded(at path: String) throws`
  - `private func extendedAttributeNames(at path: String) throws -> [String]`
  - `launchViaCyder()` and `launchClassic()` call `clearQuarantineIfNeeded(at:)` before creating/running `Process`

- [ ] **Step 1: Add the runtime helper**

In `Sources/AppModel.swift`, add a focused helper that reads URL resource values and removes the quarantine attribute only when present:

```swift
private func clearQuarantineIfNeeded(at path: String) throws {
    let names = try extendedAttributeNames(at: path)
    guard Self.quarantineStatus(forExtendedAttributes: names) == .quarantined else {
        return
    }

    let url = URL(fileURLWithPath: path)
    do {
        try url.removeExtendedAttribute(forName: "com.apple.quarantine")
        appendLog("已解除 quarantine：\(path)")
    } catch {
        let detail = (error as NSError).localizedDescription
        throw BeanfunError.rejected(
            Self.quarantineRemovalErrorDescription(path: path, underlying: detail)
        )
    }
}
```

Add the attribute reader beside it:

```swift
private func extendedAttributeNames(at path: String) throws -> [String] {
    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileExtendedAttributesKey])
    return Array(values.fileExtendedAttributes?.keys ?? [])
}
```

- [ ] **Step 2: Hook Cyder launch before `Process.run()`**

Inside `launchViaCyder()`, after `validatedLaunchTarget(for:)` succeeds and before `beginLaunchUI()` / `Process()` setup, insert:

```swift
do {
    try clearQuarantineIfNeeded(at: path)
} catch {
    present(error)
    return
}
```

- [ ] **Step 3: Hook Classic launch before `Process.run()`**

Inside `launchClassic(passargTokens:)`, after `isValidExecutablePath(path)` passes and before `Process()` setup, insert the same pattern:

```swift
do {
    try clearQuarantineIfNeeded(at: path)
} catch {
    present(error)
    return
}
```

- [ ] **Step 4: Run tests and a focused smoke check**

Run: `./test.sh`
Expected: PASS with `CoreTests: 15 tests passed`

Then review the changed behavior in code:

Run: `git diff -- Sources/AppModel.swift Tests/CoreTests.swift`
Expected: only the helper, hook points, and tests changed.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppModel.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
fix: clear quarantine before open-based game launch

EOF
)"
```
