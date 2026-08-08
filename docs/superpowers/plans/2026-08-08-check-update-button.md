# Check Update Button + Integrity File Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a valid main-program path exists, show a manual 「檢查更新」 flow (quick check + result actions), and show current file names while cmsdl verifies integrity.

**Architecture:** Reuse `probeManifestInfo` + `IncrementalSizeCalculator` for a shared quick check that drives a generalized update-status enum; place a small SwiftUI state-machine view where download buttons currently live; improve progress parsing/tracker so integrity phase publishes file names; rename deep-update copy to 「嘗試更新」(MapleStory) / 「完整下載」(Classic).

**Tech Stack:** Swift 5, SwiftUI/AppKit, existing `NxdlDownloader` / `GameClientDiskGate`, `./test.sh`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-08-check-update-button-design.md`
- Modern UI only (Legacy out of scope).
- No auto-check on enter.
- `.updateAvailable` → 「更新」 only (no force button).
- `.upToDate` / error → MapleStory 「嘗試更新」, Classic 「完整下載」.
- Quick check must not open the download progress sheet.
- Prefer small focused changes; Conventional Commits.
- Verification: `./test.sh` after each task that touches tests/sources compiled by it.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/Models.swift` | Keep `ClassicUpdateStatus` (shared semantics); add pure `ClientUpdateUI` helpers for labels/captions |
| `Sources/NxdlDownloader.swift` | Parse verified status lines; tracker `destinationURL`; publish file names during integrity |
| `Sources/ClassicDownloadProgressView.swift` | Prefer 「正在檢查 {names} 檔案完整性…」 |
| `Sources/AppModel.swift` | `checkClientUpdate()`, force deep-update APIs, alert button titles, reset status, init progress with destination |
| `Sources/ContentView.swift` | Shared check/update button slot for welcome + classic surfaces |
| `Tests/CoreTests.swift` | Label helpers, verified-line parsing, integrity file-name tracker behavior |
| Spec (already committed) | Source of truth for UX |

---

### Task 1: Pure UI label helpers (TDD)

**Files:**
- Modify: `Sources/Models.swift`
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes: `ClassicUpdateStatus`, `GameDefinition.mapleStory.id`, `GameDefinition.mapleStoryClassic.id`
- Produces:
  - `enum ClientUpdateUI` (or `struct`) with:
    - `static func forceUpdateButtonTitle(gameID: String) -> String`
    - `static func statusCaption(_ status: ClassicUpdateStatus) -> String?`
    - `static func showsForceUpdateButton(_ status: ClassicUpdateStatus) -> Bool`
    - `static func showsPrimaryUpdateButton(_ status: ClassicUpdateStatus) -> Bool`
    - `static func showsCheckButton(_ status: ClassicUpdateStatus) -> Bool`

- [ ] **Step 1: Write the failing test**

In `Tests/CoreTests.swift` `main()`, add `try testClientUpdateUIHelpers()` and bump the pass count string.

```swift
private static func testClientUpdateUIHelpers() throws {
    try expect(
        ClientUpdateUI.forceUpdateButtonTitle(gameID: GameDefinition.mapleStory.id) == "嘗試更新",
        "maple force title"
    )
    try expect(
        ClientUpdateUI.forceUpdateButtonTitle(gameID: GameDefinition.mapleStoryClassic.id) == "完整下載",
        "classic force title"
    )
    try expect(ClientUpdateUI.showsCheckButton(.none), "none → check")
    try expect(!ClientUpdateUI.showsCheckButton(.upToDate), "upToDate → no check")
    try expect(ClientUpdateUI.showsForceUpdateButton(.upToDate), "upToDate → force")
    try expect(ClientUpdateUI.showsForceUpdateButton(.maintenanceOrError("x")), "error → force")
    try expect(!ClientUpdateUI.showsForceUpdateButton(.updateAvailable), "available → no force")
    try expect(ClientUpdateUI.showsPrimaryUpdateButton(.updateAvailable), "available → update")
    try expect(!ClientUpdateUI.showsPrimaryUpdateButton(.upToDate), "upToDate → no primary update")
    try expect(ClientUpdateUI.statusCaption(.upToDate) == "已是最新版本", "upToDate caption")
    try expect(ClientUpdateUI.statusCaption(.updateAvailable) == "發現可用更新", "available caption")
    try expect(ClientUpdateUI.statusCaption(.checking) == nil, "checking has no caption")
    try expect(ClientUpdateUI.statusCaption(.none) == nil, "none has no caption")
    if let msg = ClientUpdateUI.statusCaption(.maintenanceOrError("無法檢查更新")) {
        try expect(msg == "無法檢查更新", "error caption passthrough")
    } else {
        throw TestFailure(message: "expected error caption")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`  
Expected: compile error `cannot find 'ClientUpdateUI' in scope` (or similar).

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/Models.swift` (near `ClassicUpdateStatus`):

```swift
enum ClientUpdateUI {
    static func forceUpdateButtonTitle(gameID: String) -> String {
        gameID == GameDefinition.mapleStoryClassic.id ? "完整下載" : "嘗試更新"
    }

    static func showsCheckButton(_ status: ClassicUpdateStatus) -> Bool {
        status == .none
    }

    static func showsPrimaryUpdateButton(_ status: ClassicUpdateStatus) -> Bool {
        status == .updateAvailable
    }

    static func showsForceUpdateButton(_ status: ClassicUpdateStatus) -> Bool {
        switch status {
        case .upToDate, .maintenanceOrError: return true
        default: return false
        }
    }

    static func statusCaption(_ status: ClassicUpdateStatus) -> String? {
        switch status {
        case .upToDate: return "已是最新版本"
        case .updateAvailable: return "發現可用更新"
        case let .maintenanceOrError(message): return message
        case .none, .checking: return nil
        }
    }
}
```

Keep enum name `ClassicUpdateStatus` (shared use); do not rename unless a later task needs it.

- [ ] **Step 4: Run test to verify it passes**

Run: `./test.sh`  
Expected: `CoreTests: N tests passed` (count = previous + 1).

- [ ] **Step 5: Commit**

```bash
git add Sources/Models.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add ClientUpdateUI helpers for check-update labels

EOF
)"
```

---

### Task 2: Parse verified lines + publish integrity file names (TDD)

**Files:**
- Modify: `Sources/NxdlDownloader.swift`
- Modify: `Tests/CoreTests.swift`
- Modify: `Sources/ClassicDownloadProgressView.swift`

**Interfaces:**
- Consumes: existing `NxdlProgressParser`, `NxdlProgressTracker`, `NxdlDownloadProgressState`
- Produces:
  - `NxdlProgressParser.parseVerifiedFileName(_ cleaned: String) -> String?`
  - `NxdlProgressTracker.setDestinationURL(_ url: URL?)`
  - Tracker updates `currentFileNames` from verified lines
  - `downloadClient` stamps `destinationURL` onto progress states before `onUpdate`
  - Progress view prefers file-name integrity copy

- [ ] **Step 1: Write the failing tests**

Extend `testNxdlProgressParser` (or add `testNxdlVerifiedFileNameParser` + call from `main`):

```swift
private static func testNxdlVerifiedFileNameParser() throws {
    let name = try require(
        NxdlProgressParser.parseVerifiedFileName(
            "Data/Base/Base.wz already present and verified (skipping download)."
        ),
        "verified path"
    )
    try expect(name == "Data/Base/Base.wz", "verified basename path")

    try expect(
        NxdlProgressParser.parseVerifiedFileName("下載中：1 / 2") == nil,
        "non-verified line"
    )

    let tracker = NxdlProgressTracker()
    tracker.setDestinationURL(URL(fileURLWithPath: "/Games/MapleStory"))
    _ = NxdlProgressParser.ingestLine(
        "⠙ [00:00:01] [===>----] 1.0 GiB/10.0 GiB (2.5 GiB/s, ETA 4s)",
        into: tracker
    )
    _ = NxdlProgressParser.ingestLine(
        "Data/Base/Base.wz already present and verified (skipping download).",
        into: tracker
    )
    try expect(tracker.state.isCheckingIntegrity, "GiB/s → checking")
    try expect(
        tracker.state.currentFileNamesText == "Base.wz"
            || tracker.state.currentFileNamesText?.contains("Base.wz") == true,
        "verified line publishes file name"
    )
}
```

Also add a UI-facing helper test if you extract copy building; otherwise cover in Step 3 via view change only (parser/tracker is the regression lock).

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`  
Expected: fail — `parseVerifiedFileName` / `setDestinationURL` missing.

- [ ] **Step 3: Implement parser + tracker + stamp destination**

In `NxdlProgressParser`:

```swift
static func parseVerifiedFileName(_ cleaned: String) -> String? {
    let marker = " already present and verified"
    guard let range = cleaned.range(of: marker) else { return nil }
    let path = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    return path.isEmpty ? nil : path
}
```

In `ingestLine`, after status-line handling (or before returning nil), if `parseVerifiedFileName(cleaned)` succeeds, call `tracker.noteVerifiedFile(displayName(for: path))` and return `.progress(tracker.state)`.

In `NxdlProgressTracker`:

```swift
func setDestinationURL(_ url: URL?) {
    state.destinationURL = url
}

func noteVerifiedFile(_ displayName: String) {
    if state.currentFileNames == [displayName] { return }
    state.currentFileNames = [displayName]
}
```

Also: when `upsert` runs, keep existing behavior. When `setOverall` runs with empty `frameFileNames`, **do not clear** existing `currentFileNames`.

In `downloadClient`’s `track` closure, whenever emitting `.progress`, ensure `destinationURL` is set:

```swift
let track: (NxdlDownloadUpdate) -> Void = { update in
    switch update {
    case var .progress(state):
        state.destinationURL = destination
        progressLock.lock()
        lastProgress = state
        progressLock.unlock()
        onUpdate(.progress(state))
    default:
        onUpdate(update)
    }
}
```

And when creating `NxdlOutputStreamParser` inside `runDownload` / PTY path, after creation call `streamParser`’s tracker destination if exposed — if parser hides tracker, the stamp in `track` above is sufficient.

Update `ClassicDownloadProgressView`:

- Keep speed-area 「檢查完整性中」 as fallback.
- For the lower caption, when `isCheckingIntegrity`:
  - if `currentFileNamesText` present → `正在檢查 \(fileNames) 檔案完整性…`
  - else → `檢查完整性中` (or status message)

Ensure the integrity caption is visible even when `overall == nil` is false but names empty (already partially true via speed label).

- [ ] **Step 4: Run tests**

Run: `./test.sh`  
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/NxdlDownloader.swift Sources/ClassicDownloadProgressView.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: show verified file names during client integrity check

EOF
)"
```

---

### Task 3: Shared `checkClientUpdate()` + force deep-update wiring

**Files:**
- Modify: `Sources/AppModel.swift`

**Interfaces:**
- Consumes: `ClientUpdateUI`, `probeManifestInfo`, `IncrementalSizeCalculator`, existing update/download entry points
- Produces:
  - `func checkClientUpdate()`
  - `func forceUpdateClient()` (deep update for current MapleStory/Classic selection)
  - `presentUpToDateAlert(forceButtonTitle:)` using `ClientUpdateUI.forceUpdateButtonTitle`
  - Status resets on `selectGame` / successful `chooseExecutable` path change

- [ ] **Step 1: Replace classic-only check with shared quick check**

Replace `checkClassicClientUpdate()` body (or add `checkClientUpdate()` and make the old method call it) with:

```swift
func checkClientUpdate() {
    guard let game = selectedGame else {
        classicUpdateStatus = .none
        return
    }
    let isClassic = game.id == GameDefinition.mapleStoryClassic.id
    let isMaple = game.id == GameDefinition.mapleStory.id
    guard isClassic || isMaple else {
        classicUpdateStatus = .none
        return
    }
    let path = normalizedExecutablePath
    guard !path.isEmpty, isValidExecutablePath(path) else {
        classicUpdateStatus = .none
        return
    }
    guard !isDownloadingGameClient else { return }

    classicUpdateCheckTask?.cancel()
    classicUpdateStatus = .checking

    let config: GameClientToolConfig = isClassic ? .nxdlClassic : .cmsdlMapleStory
    let destination = URL(fileURLWithPath: path).deletingLastPathComponent()

    classicUpdateCheckTask = Task { [weak self] in
        guard let self else { return }
        do {
            let manifestInfo = try await self.nxdlDownloader.probeManifestInfo(config: config) { _ in }
            guard !Task.isCancelled else {
                await MainActor.run { self.classicUpdateStatus = .none }
                return
            }
            let bytesNeeded = IncrementalSizeCalculator.calculateRequiredDownloadBytes(
                manifestFiles: manifestInfo.filePaths,
                totalManifestBytes: manifestInfo.totalBytes > 0
                    ? manifestInfo.totalBytes
                    : (try await self.nxdlDownloader.probeTotalSize(config: config) { _ in }),
                destination: destination
            )
            guard !Task.isCancelled else {
                await MainActor.run { self.classicUpdateStatus = .none }
                return
            }
            await MainActor.run {
                self.classicUpdateStatus = bytesNeeded == 0 ? .upToDate : .updateAvailable
            }
        } catch {
            guard !Task.isCancelled else {
                await MainActor.run { self.classicUpdateStatus = .none }
                return
            }
            let errorMsg = error.localizedDescription
            let message: String
            if errorMsg.contains("failed to parse game-info response")
                || errorMsg.contains("failed to lookup address information")
                || errorMsg.contains("Dns Failed")
                || errorMsg.contains("HTTP request failed")
                || errorMsg.contains("ConnectFailed")
                || errorMsg.contains("timed out") {
                message = "無法檢查更新（可能是伺服器維修中）"
            } else {
                message = "無法檢查更新：\(errorMsg)"
            }
            await MainActor.run {
                self.classicUpdateStatus = .maintenanceOrError(message)
            }
        }
    }
}
```

Adjust `MainActor` usage to match file conventions (`@MainActor` class may already hop automatically — follow existing `checkClassicClientUpdate` style: assign on main without extra hops if already `@MainActor`).

If `AppModel` is `@MainActor`, keep assignments as in the existing check method (direct property sets inside `Task`).

- [ ] **Step 2: Add force update + rename alert button**

```swift
func forceUpdateClient() {
    guard let game = selectedGame else { return }
    if game.id == GameDefinition.mapleStoryClassic.id {
        // deep path: mirror updateClassicClient but always isDeepUpdate
        guard !isDownloadingGameClient else { return }
        let path = normalizedExecutablePath
        guard !path.isEmpty, isValidExecutablePath(path) else {
            downloadClassicClient()
            return
        }
        let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
        startGameClientDownload(
            targetGame: GameDefinition.mapleStoryClassic,
            config: .nxdlClassic,
            destination: destination,
            progressTitle: "完整下載新楓之谷：經典版",
            statusWhileDownloading: "正在完整下載新楓之谷：經典版…",
            missingExecutableHint: "下載完成，請手動選擇 Maplestory_Classic.exe",
            logLabel: "經典版",
            isDeepUpdate: true
        )
    } else if game.id == GameDefinition.mapleStory.id {
        guard !isDownloadingGameClient else { return }
        let path = normalizedExecutablePath
        guard !path.isEmpty, isValidExecutablePath(path) else {
            downloadMapleStoryClient()
            return
        }
        let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
        startGameClientDownload(
            targetGame: GameDefinition.mapleStory,
            config: .cmsdlMapleStory,
            destination: destination,
            progressTitle: "更新新楓之谷",
            statusWhileDownloading: "正在更新新楓之谷…",
            missingExecutableHint: "更新完成，請手動選擇 MapleStory.exe",
            logLabel: "新楓之谷",
            isDeepUpdate: true
        )
    }
}
```

Change `presentUpToDateAlert` to take the force title:

```swift
private func presentUpToDateAlert(forceButtonTitle: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "已是最新版本"
    alert.informativeText = "經快速檢查，本機檔案完整且檔案大小一致。\n目前不需要下載額外檔案。"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "確定")
    alert.addButton(withTitle: forceButtonTitle)
    return alert.runModal() == .alertSecondButtonReturn
}
```

At call site inside `startGameClientDownload`, pass:

```swift
let forceTitle = ClientUpdateUI.forceUpdateButtonTitle(gameID: targetGame.id)
if self.presentUpToDateAlert(forceButtonTitle: forceTitle) { ... isDeepUpdate: true }
```

Also update deep-prep status strings: prefer 「正在準備更新…」 / for classic deep 「正在準備完整下載…」 instead of 「正在準備深度更新…」.

- [ ] **Step 3: Reset status on game / path change**

In `selectGame`, set `classicUpdateStatus = .none` and cancel `classicUpdateCheckTask`.  
After `chooseExecutable` saves a new path, set `classicUpdateStatus = .none`.  
At start of `startGameClientDownload`, set `classicUpdateStatus = .none` (pipeline may set `.upToDate` later).

- [ ] **Step 4: Compile via tests**

Run: `./test.sh`  
Expected: pass (AppModel is compiled by `test.sh`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AppModel.swift
git commit -m "$(cat <<'EOF'
feat: add shared client update check and force-update actions

EOF
)"
```

---

### Task 4: ContentView check/update button slot

**Files:**
- Modify: `Sources/ContentView.swift`

**Interfaces:**
- Consumes: `model.classicUpdateStatus`, `ClientUpdateUI`, `model.checkClientUpdate()`, `model.updateMapleStoryClient()`, `model.updateClassicClient()`, `model.forceUpdateClient()`, `model.hasValidExecutable`
- Produces: reusable private view used by standard welcome, advanced welcome, classic view

- [ ] **Step 1: Add `ClientUpdateActionsSection`**

```swift
private struct ClientUpdateActionsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        guard let game = model.selectedGame else { return AnyView(EmptyView()) }
        let isMaple = game.id == GameDefinition.mapleStory.id
        let isClassic = game.id == GameDefinition.mapleStoryClassic.id
        guard isMaple || isClassic else { return AnyView(EmptyView()) }

        return AnyView(
            Group {
                if !model.hasValidExecutable {
                    downloadButton(for: game)
                } else {
                    updateStatusControls(for: game)
                }
            }
        )
    }

    @ViewBuilder
    private func downloadButton(for game: GameDefinition) -> some View {
        if game.id == GameDefinition.mapleStoryClassic.id {
            Button {
                model.downloadClassicClient()
            } label: {
                Label("下載經典版", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.isDownloadingGameClient || model.isBusy)
        } else if game.id == GameDefinition.mapleStory.id {
            Button {
                model.downloadMapleStoryClient()
            } label: {
                Label("下載新楓之谷", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.isDownloadingGameClient || model.isBusy)
        }
    }

    @ViewBuilder
    private func updateStatusControls(for game: GameDefinition) -> some View {
        let status = model.classicUpdateStatus
        VStack(spacing: 8) {
            if status == .checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在檢查更新…")
                }
                .foregroundStyle(.secondary)
            }

            if let caption = ClientUpdateUI.statusCaption(status) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if ClientUpdateUI.showsCheckButton(status) {
                Button {
                    model.checkClientUpdate()
                } label: {
                    Label("檢查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }

            if ClientUpdateUI.showsPrimaryUpdateButton(status) {
                Button {
                    if game.id == GameDefinition.mapleStoryClassic.id {
                        model.updateClassicClient()
                    } else {
                        model.updateMapleStoryClient()
                    }
                } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }

            if case .maintenanceOrError = status {
                Button("再試一次") {
                    model.checkClientUpdate()
                }
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }

            if ClientUpdateUI.showsForceUpdateButton(status) {
                Button {
                    model.forceUpdateClient()
                } label: {
                    Text(ClientUpdateUI.forceUpdateButtonTitle(gameID: game.id))
                }
                .buttonStyle(.bordered)
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }
        }
    }
}
```

Prefer idiomatic SwiftUI without `AnyView` if the file style uses `@ViewBuilder` + `Group` — match nearby patterns.

- [ ] **Step 2: Replace existing download-only gates**

In `standardWelcomeView`, `welcomeView`, and `classicView`, replace the `if !model.hasValidExecutable { … download … }` blocks with:

```swift
ClientUpdateActionsSection(model: model)
```

Do not duplicate MapleStory-only filters incorrectly for classic — the section handles both.

- [ ] **Step 3: Build / smoke**

Run: `./test.sh`  
Expected: pass.

If a full app build script exists (`./build.sh` or Xcode scheme), run the narrowest available Modern build as well.

- [ ] **Step 4: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "$(cat <<'EOF'
feat: show check-update actions when executable path is valid

EOF
)"
```

---

### Task 5: Spec coverage smoke + docs touch (optional small)

**Files:**
- Modify (optional): `docs/cmsdl-maplestory-download.md` — one short note that App UI supports check/update + integrity file names
- Modify (optional): `docs/nxdl-classic-download.md` — note that force path is labeled 「完整下載」 because nxdl re-downloads

- [ ] **Step 1: Manual checklist (record in commit message if no doc change)**

Manual (engineer / user):

1. MapleStory + valid exe → 「檢查更新」 → up to date → 「嘗試更新」 → progress shows file names while verifying.
2. MapleStory → check → update available → only 「更新」.
3. Classic + valid exe → up to date → 「完整下載」 (not 「嘗試更新」).
4. Invalid/missing exe → still 「下載xxx」.

- [ ] **Step 2: Commit docs if edited**

```bash
git add docs/cmsdl-maplestory-download.md docs/nxdl-classic-download.md
git commit -m "$(cat <<'EOF'
docs: note check-update UI and classic full-download label

EOF
)"
```

---

## Spec coverage check

| Spec requirement | Task |
| --- | --- |
| Manual 「檢查更新」 when valid exe | Task 3–4 |
| No auto-check | Task 3–4 (no `onAppear` check) |
| Quick check via manifest + IncrementalSizeCalculator | Task 3 |
| upToDate → 嘗試更新 / 完整下載 | Task 1 + 4 |
| updateAvailable → 「更新」 only | Task 1 + 4 |
| Error → 再試一次 + force | Task 1 + 4 |
| Rename 嘗試深度更新 | Task 3 |
| Integrity file names in progress UI | Task 2 |
| destinationURL wiring | Task 2 |
| Modern only / Legacy OOS | All tasks |
| Tests | Task 1–2 (+ compile AppModel via test.sh in 3–4) |

## Placeholder / consistency notes

- Property remains `classicUpdateStatus` (name historical); helpers live in `ClientUpdateUI`.
- Force API name: `forceUpdateClient()`.
- Check API name: `checkClientUpdate()`.
