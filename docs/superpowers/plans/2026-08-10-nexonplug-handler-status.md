# NexonPlug Handler Status UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Classic screens (Modern + Legacy), show the NexonPlug claim button only when this app is not the default handler; otherwise show static 「NexonPlug 已由 Beanfun OTP 處理」.

**Architecture:** Pure Bundle-ID comparison helper; Launch Services read via `LSCopyDefaultHandlerForURLScheme("NexonPlug")`; refresh on entering Classic and after successful claim. Modern uses `@Published isNexonPlugHandler`; Legacy toggles button vs static label visibility.

**Tech Stack:** Swift 5, SwiftUI (Modern), AppKit (Legacy), CoreServices Launch Services, `./test.sh`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-10-nexonplug-handler-status-design.md`
- Bound = current default handler Bundle ID **equals this app’s** Bundle ID only (Modern `local.ogom.beanfunotp`, Legacy `local.ogom.beanfunotp.legacy`).
- Scheme string for read/write: `NexonPlug` (same as existing claim).
- Unbound copy: 「將 NexonPlug 設為由 Beanfun OTP 處理」 (existing button).
- Bound copy: 「NexonPlug 已由 Beanfun OTP 處理」 (static text, not a disabled button).
- Refresh: enter Classic; after successful claim. No activate/foreground refresh.
- Prefer small focused changes; Conventional Commits when committing.
- Verification: `./test.sh` after tasks that touch Modern sources compiled by it. Legacy is not compiled by `./test.sh` — build/run Legacy app manually if available.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/Models.swift` | Pure `NexonPlugHandlerStatus.isBound(currentHandlerBundleID:selfBundleID:)` |
| `Legacy/Sources/Models.swift` | Same pure helper (Legacy tree mirror) |
| `Sources/AppModel.swift` | `@Published isNexonPlugHandler`; `refreshNexonPlugHandlerStatus()`; claim success refresh; refresh when entering Classic |
| `Sources/ContentView.swift` | Classic: Button vs Text from `model.isNexonPlugHandler` |
| `Legacy/Sources/AppController.swift` | Static bound label; refresh on Classic enter / claim success; toggle visibility |
| `Tests/CoreTests.swift` | Unit tests for pure helper |
| Spec (already written) | UX source of truth |

---

### Task 1: Pure helper + unit tests (TDD)

**Files:**
- Modify: `Sources/Models.swift`
- Modify: `Legacy/Sources/Models.swift`
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes: none
- Produces:
  - `enum NexonPlugHandlerStatus` with
    - `static func isBound(currentHandlerBundleID: String?, selfBundleID: String) -> Bool`

- [x] **Step 1: Write the failing test**

In `Tests/CoreTests.swift` `main()`, add `try testNexonPlugHandlerStatus()` and bump the pass count string by 1 (currently `35`).

```swift
private static func testNexonPlugHandlerStatus() throws {
    try expect(
        !NexonPlugHandlerStatus.isBound(currentHandlerBundleID: nil, selfBundleID: "local.ogom.beanfunotp"),
        "nil handler → unbound"
    )
    try expect(
        !NexonPlugHandlerStatus.isBound(
            currentHandlerBundleID: "com.nexon.plug",
            selfBundleID: "local.ogom.beanfunotp"
        ),
        "other handler → unbound"
    )
    try expect(
        !NexonPlugHandlerStatus.isBound(
            currentHandlerBundleID: "local.ogom.beanfunotp.legacy",
            selfBundleID: "local.ogom.beanfunotp"
        ),
        "Legacy handler is not Modern bound"
    )
    try expect(
        NexonPlugHandlerStatus.isBound(
            currentHandlerBundleID: "local.ogom.beanfunotp",
            selfBundleID: "local.ogom.beanfunotp"
        ),
        "same Bundle ID → bound"
    )
    try expect(
        NexonPlugHandlerStatus.isBound(
            currentHandlerBundleID: "local.ogom.beanfunotp.legacy",
            selfBundleID: "local.ogom.beanfunotp.legacy"
        ),
        "Legacy same Bundle ID → bound"
    )
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `./test.sh`

Expected: compile failure or FAIL mentioning `NexonPlugHandlerStatus` undefined.

- [x] **Step 3: Minimal implementation in Modern + Legacy Models**

Add to **both** `Sources/Models.swift` and `Legacy/Sources/Models.swift` (near other small enums such as `ClientUpdateUI` / after `ClassicUpdateStatus`):

```swift
enum NexonPlugHandlerStatus {
    static func isBound(currentHandlerBundleID: String?, selfBundleID: String) -> Bool {
        guard let currentHandlerBundleID else { return false }
        return currentHandlerBundleID == selfBundleID
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `./test.sh`

Expected: `CoreTests: 36 tests passed` (or previous count + 1).

- [ ] **Step 5: Commit** (only if the user asked to commit)

```bash
git add Sources/Models.swift Legacy/Sources/Models.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add NexonPlug handler bound helper

EOF
)"
```

---

### Task 2: Modern AppModel + ContentView

**Files:**
- Modify: `Sources/AppModel.swift`
- Modify: `Sources/ContentView.swift`

**Interfaces:**
- Consumes: `NexonPlugHandlerStatus.isBound(currentHandlerBundleID:selfBundleID:)`
- Produces:
  - `@Published private(set) var isNexonPlugHandler = false`
  - `func refreshNexonPlugHandlerStatus()`
  - `claimNexonPlugHandler()` refreshes on success
  - Entering Classic calls refresh (via `selectGame` and any other path that sets `screen = .classic`, plus cold Classic from URL)

- [ ] **Step 1: Add published flag + refresh + claim update in AppModel**

Near other `@Published` properties, add:

```swift
@Published private(set) var isNexonPlugHandler = false
```

Add method (near `claimNexonPlugHandler`):

```swift
func refreshNexonPlugHandlerStatus() {
    let current = LSCopyDefaultHandlerForURLScheme(Self.nexonPlugScheme as CFString)?
        .takeRetainedValue() as String?
    isNexonPlugHandler = NexonPlugHandlerStatus.isBound(
        currentHandlerBundleID: current,
        selfBundleID: Self.beanfunOTPBundleID
    )
}
```

Replace `claimNexonPlugHandler()` body so success refreshes:

```swift
func claimNexonPlugHandler() {
    let status = LSSetDefaultHandlerForURLScheme(
        Self.nexonPlugScheme as NSString,
        Self.beanfunOTPBundleID as NSString
    )
    if status == noErr {
        refreshNexonPlugHandlerStatus()
        statusMessage = "已將 NexonPlug 設為由 Beanfun OTP 處理"
    } else {
        errorMessage = "設定 NexonPlug 處理程式失敗（代碼 \(status)）"
    }
}
```

Call `refreshNexonPlugHandlerStatus()` wherever Classic is entered:

1. In `selectGame`, inside `if game.authFlow == .webNexonPlug` after `screen = .classic`.
2. In `startLogin` when it sets `screen = .classic` (same branch that early-returns for Classic).
3. In `handleClassicNexonPlug` when it sets `screen = .classic` / selects Classic.

Do **not** rely only on SwiftUI `onAppear` if those model paths already set Classic; calling refresh in the model keeps Legacy-parity and avoids missing URL-driven Classic entry.

- [ ] **Step 2: Update ContentView classicView**

Replace the always-on claim `Button` with:

```swift
if model.isNexonPlugHandler {
    Text("NexonPlug 已由 Beanfun OTP 處理")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
} else {
    Button("將 NexonPlug 設為由 Beanfun OTP 處理") {
        model.claimNexonPlugHandler()
    }
    .buttonStyle(.link)
}
```

Keep surrounding Classic copy and 「開啟登入網頁」 unchanged.

- [ ] **Step 3: Verify Modern compile/tests**

Run: `./test.sh`

Expected: pass.

Optional: build Modern app with the project’s usual `./build.sh` (if present) and manually open Classic.

- [ ] **Step 4: Commit** (only if the user asked to commit)

```bash
git add Sources/AppModel.swift Sources/ContentView.swift
git commit -m "$(cat <<'EOF'
feat: show NexonPlug bound status on Classic screen

EOF
)"
```

---

### Task 3: Legacy AppController parity

**Files:**
- Modify: `Legacy/Sources/AppController.swift`

**Interfaces:**
- Consumes: `NexonPlugHandlerStatus.isBound` from `Legacy/Sources/Models.swift`; `Self.nexonPlugScheme`; `Self.beanfunOTPBundleID`
- Produces: Classic UI shows either claim button or static bound label; refresh on Classic enter and successful claim

- [ ] **Step 1: Add static bound label property**

Near `claimNexonPlugButton` / `classicNoticeLabel`:

```swift
private let nexonPlugBoundLabel = NSTextField(
    wrappingLabelWithString: "NexonPlug 已由 Beanfun OTP 處理"
)
```

In Classic section setup (where `claimNexonPlugButton` is configured), style the label like `classicNoticeLabel` (center, secondary, ~11pt), start `nexonPlugBoundLabel.isHidden = true`.

Insert `nexonPlugBoundLabel` into `classicContainer` stack **in the same slot as** `claimNexonPlugButton` (adjacent: both present; visibility toggled so only one shows). Example order:

```swift
classicContainer = NSStackView(views: [
    classicNoticeLabel,
    openClassicWebButton,
    claimNexonPlugButton,
    nexonPlugBoundLabel,
    downloadClassicButton,
])
```

- [ ] **Step 2: Add refresh + apply visibility helpers**

```swift
private func refreshNexonPlugHandlerStatus() {
    let current = LSCopyDefaultHandlerForURLScheme(Self.nexonPlugScheme as CFString)?
        .takeRetainedValue() as String?
    let bound = NexonPlugHandlerStatus.isBound(
        currentHandlerBundleID: current,
        selfBundleID: Self.beanfunOTPBundleID
    )
    claimNexonPlugButton.isHidden = bound
    nexonPlugBoundLabel.isHidden = !bound
}
```

If Legacy needs an explicit import for Launch Services, add `import CoreServices` at the top of `AppController.swift` (Modern already imports it).

Call `refreshNexonPlugHandlerStatus()`:

1. In `selectGame(at:)` when setting `screen = .classic`.
2. Anywhere else that sets `screen = .classic` (including Classic NexonPlug URL handling).
3. Optionally at the start of `updateVisibility()` when `screen == .classic` — **prefer explicit calls on enter** to match spec (enter Classic only), not every visibility pass unless that is the cleanest single hook; if using only `updateVisibility`, document that it runs whenever Classic is shown after `screen` didSet → `updateVisibility`.

Check whether `screen`’s `didSet` already calls `updateVisibility()`. If yes, calling refresh inside `updateVisibility` when `screen == .classic` is acceptable and covers all enter paths; if `screen != .classic`, leave both controls hidden via container hide (bound label may stay whatever — container is hidden).

- [ ] **Step 3: Update claim handler**

```swift
@objc private func handleClaimNexonPlug() {
    let status = LSSetDefaultHandlerForURLScheme(
        Self.nexonPlugScheme as NSString,
        Self.beanfunOTPBundleID as NSString
    )
    if status == noErr {
        refreshNexonPlugHandlerStatus()
        statusLabel.stringValue = "已將 NexonPlug 設為由 Beanfun OTP 處理"
    } else {
        showError(BeanfunError.rejected("設定 NexonPlug 處理程式失敗（代碼 \(status)）"))
    }
}
```

- [ ] **Step 4: Verify Legacy**

`./test.sh` does not compile Legacy. If `./build-legacy.sh` (or the project’s Legacy build script) exists, run it. Otherwise note: Legacy not verified by automated tests in this task.

Manual checklist:

- Unbound → claim button visible, bound label hidden.
- Claim success → button hidden, 「NexonPlug 已由 Beanfun OTP 處理」 visible.
- If Modern is system handler but Legacy is open → Legacy still shows claim button.

- [ ] **Step 5: Commit** (only if the user asked to commit)

```bash
git add Legacy/Sources/AppController.swift Legacy/Sources/Models.swift
git commit -m "$(cat <<'EOF'
feat: show NexonPlug bound status in Legacy Classic UI

EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
| --- | --- |
| `LSCopyDefaultHandlerForURLScheme("NexonPlug")` vs this Bundle ID | 2, 3 |
| Unbound → existing button | 2, 3 |
| Bound → static 「NexonPlug 已由 Beanfun OTP 處理」 | 2, 3 |
| Refresh on Classic enter + successful claim | 2, 3 |
| Modern + Legacy | 2 + 3 |
| Other OTP track ≠ bound | 1 tests + Bundle ID constants |
| No foreground refresh / no restore control | not implemented (intentional) |

**Placeholder scan:** none intentional.  
**Type consistency:** `NexonPlugHandlerStatus.isBound(currentHandlerBundleID:selfBundleID:)` used in Tasks 1–3; `isNexonPlugHandler` / `refreshNexonPlugHandlerStatus()` naming aligned Modern/Legacy.
