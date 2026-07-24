# Single-Instance + Cold-Start NexonPlug Quit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure Beanfun OTP (Modern) is a single process/window for `NexonPlug://`, and auto-quit only after a cold-start Classic Cyder/`open` succeeds.

**Architecture:** `LSMultipleInstancesProhibited` stops a second process. Replace `WindowGroup` with a single `Window` so URL delivery cannot spawn another SwiftUI window. `AppDelegate` tracks a short “still launching” window; URLs handled in that window set `AppModel.quitAfterSuccessfulClassicLaunch`. `launchClassic` calls `NSApp.terminate(nil)` only on `open` exit 0 when that flag is set.

**Tech Stack:** Swift 5, SwiftUI `Window` (macOS 13+), AppKit `NSApplicationDelegate`, existing `NexonPlug` URL handling in `AppModel`.

## Global Constraints

- Modern only; do not change Legacy.
- Single process via `LSMultipleInstancesProhibited = true`.
- Single main window (no `WindowGroup` multi-window for URL opens).
- Auto-quit **only** on cold-start Classic `open` success (`terminationStatus == 0`).
- Cold-start failure / cancel picker: stay open; keep quit-after-success flag for retry.
- Warm URL (app already running): handle in existing instance; do **not** set quit flag; do **not** quit.
- Non-Classic forward to official NexonPlug: no auto-quit in this iteration.
- User-facing copy in Traditional Chinese (reuse existing strings; no new English UI).
- Spec: `docs/superpowers/specs/2026-07-24-single-instance-nexonplug-design.md`.

## File Map

| File | Responsibility |
| --- | --- |
| `Resources/Info.plist` | `LSMultipleInstancesProhibited` |
| `Sources/BeanfunOTPApp.swift` | Single `Window`; launch-phase flag; pass cold-start into URL handler |
| `Sources/AppModel.swift` | `quitAfterSuccessfulClassicLaunch`; quit on Classic success |
| `README.md` | Optional one-line note on single-instance / cold-start quit |

---

### Task 1: Single process + single window

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `Sources/BeanfunOTPApp.swift`

**Interfaces:**
- Consumes: existing `AppDelegate` URL buffer / `onOpenURLs`, `ContentView`, `AppModel`
- Produces:
  - Info.plist key `LSMultipleInstancesProhibited` = `true`
  - Scene: `Window("Beanfun OTP", id: "main") { … }` instead of `WindowGroup`
  - `AppDelegate.isWithinColdStartURLWindow` (or equivalent) available for Task 2 — **stub the property and settle timing in this task** so Task 2 only wires the quit flag

- [ ] **Step 1: Add Info.plist key**

In `Resources/Info.plist`, after `LSMinimumSystemVersion` (or adjacent Launch Services keys), add:

```xml
    <key>LSMultipleInstancesProhibited</key>
    <true/>
```

- [ ] **Step 2: Replace WindowGroup with Window + cold-start window tracking**

Update `Sources/BeanfunOTPApp.swift` `AppDelegate`:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)? {
        didSet {
            guard onOpenURLs != nil, !pendingURLs.isEmpty else { return }
            let urls = pendingURLs
            pendingURLs = []
            onOpenURLs?(urls)
        }
    }
    private var pendingURLs: [URL] = []

    /// True from launch until a short settle after first activation.
    /// URLs delivered while true are treated as cold-start by AppModel (Task 2).
    private(set) var isWithinColdStartURLWindow = true
    private var didScheduleColdStartWindowEnd = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let removedMenus = Set(["Edit", "View", "Window", "編輯", "顯示方式", "視窗"])
        DispatchQueue.main.async {
            guard let mainMenu = NSApp.mainMenu else { return }
            mainMenu.items
                .filter { removedMenus.contains($0.title) }
                .forEach { mainMenu.removeItem($0) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !didScheduleColdStartWindowEnd else { return }
        didScheduleColdStartWindowEnd = true
        // Allow Launch Services to deliver cold-start open: slightly after activate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.isWithinColdStartURLWindow = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpenURLs {
            onOpenURLs(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}
```

Replace the scene:

```swift
    var body: some Scene {
        Window("Beanfun OTP", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        urls.forEach { model.handleOpenedURL($0) }
                    }
                }
                .onOpenURL { model.handleOpenedURL($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 440)
        .windowResizability(.contentSize)
        .commandsRemoved()
        .commands {
            // keep existing CommandGroup / CommandMenu bodies unchanged
        }
    }
```

Keep all existing `.commands { … }` content identical; only change `WindowGroup` → `Window("Beanfun OTP", id: "main")`.

Task 2 will change the `handleOpenedURL` call sites to pass cold-start; for this task, leave signatures unchanged so the app still builds.

- [ ] **Step 3: Build**

Run: `./build.sh`  
Expected: arm64 + x86_64 build succeeds; app at `dist/Beanfun OTP.app`.

Manual smoke (optional in this task): launch app from Finder — one window; Cmd-Q quits.

- [ ] **Step 4: Commit**

```bash
git add Resources/Info.plist Sources/BeanfunOTPApp.swift
git commit -m "$(cat <<'EOF'
feat: enforce single Beanfun OTP process and window

EOF
)"
```

---

### Task 2: Cold-start quit after Classic `open` success

**Files:**
- Modify: `Sources/AppModel.swift`
- Modify: `Sources/BeanfunOTPApp.swift` (pass cold-start into `handleOpenedURL`)
- Modify: `README.md` (short note under Classic / NexonPlug if a fitting section exists)

**Interfaces:**
- Consumes: `AppDelegate.isWithinColdStartURLWindow`
- Produces:
  - `AppModel.quitAfterSuccessfulClassicLaunch: Bool` (internal / package-visible as needed)
  - `func handleOpenedURL(_ url: URL, fromColdStart: Bool = false)`
  - On Classic `open` success: if flag, `NSApp.terminate(nil)`
  - Failure / cancel: do not clear flag; do not terminate

- [ ] **Step 1: Extend handleOpenedURL and set the flag**

In `Sources/AppModel.swift`, add:

```swift
/// Set when a NexonPlug URL arrives during cold-start; cleared only by process exit.
var quitAfterSuccessfulClassicLaunch = false
```

Change:

```swift
func handleOpenedURL(_ url: URL, fromColdStart: Bool = false) {
    if fromColdStart {
        quitAfterSuccessfulClassicLaunch = true
    }
    // existing dedupe + parse + classic/forward unchanged
```

Do **not** set the flag to `false` on warm URLs (leave previous value; warm after interactive launch starts with `false`).

- [ ] **Step 2: Wire cold-start from AppDelegate**

In `BeanfunOTPApp` `onAppear` / `onOpenURL`:

```swift
.onAppear {
    appDelegate.onOpenURLs = { [appDelegate] urls in
        let cold = appDelegate.isWithinColdStartURLWindow
        urls.forEach { model.handleOpenedURL($0, fromColdStart: cold) }
    }
}
.onOpenURL { url in
    model.handleOpenedURL(url, fromColdStart: appDelegate.isWithinColdStartURLWindow)
}
```

Note: `onOpenURLs` may fire when flushing `pendingURLs` during `.onAppear` while still within the cold-start window — that must set the flag.

- [ ] **Step 3: Quit on Classic open success**

In `launchClassic` terminationHandler success branch (`terminationStatus == 0`), after status/log updates:

```swift
if process.terminationStatus == 0 {
    self.statusMessage = "已透過 Cyder 啟動楓之谷：經典版"
    self.appendLog("執行 open -n：classic executable=\(path) args=\(passargTokens.joined(separator: " "))")
    if self.quitAfterSuccessfulClassicLaunch {
        NSApp.terminate(nil)
    }
} else {
    // existing present(error) — no terminate
}
```

Ensure `import AppKit` is available in `AppModel.swift` (already used elsewhere via AppKit types, or add if needed).

Do **not** terminate in:
- `catch` of `process.run()`
- invalid path / empty passarg / cancelled picker paths
- `forwardNexonPlug`
- Cyder / Wine MapleStory launchers

- [ ] **Step 4: README note**

Near Classic / NexonPlug documentation (if present), add one short Traditional Chinese sentence, e.g.:

```markdown
Beanfun OTP 僅允許單一實例；若由網頁 `NexonPlug://` 冷啟動並成功開啟經典版，啟動完成後會自動結束。
```

If no suitable section, add under 一般模式 / 經典版 bullets without inventing a new top-level chapter.

- [ ] **Step 5: Build + tests**

Run: `./test.sh && ./build.sh`  
Expected: CoreTests pass; app builds.

Manual checklist (required before calling the task done):

1. Quit all Beanfun OTP → Classic web login → one window → game starts → app quits.
2. Cold start without exe → picker/error → stays → pick exe → launch OK → quits.
3. App already open → Classic web login → no second window/process → does **not** quit after launch.
4. Interactive launch (Dock) with no URL → never auto-quits from this feature.

- [ ] **Step 6: Commit**

```bash
git add Sources/AppModel.swift Sources/BeanfunOTPApp.swift README.md
git commit -m "$(cat <<'EOF'
feat: quit after cold-start Classic NexonPlug launch success

EOF
)"
```

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| `LSMultipleInstancesProhibited` | 1 |
| Single `Window` (no multi-window URL) | 1 |
| Cold-start flag via launching window | 1 + 2 |
| Quit only on Classic `open` success + flag | 2 |
| Failure stays open; flag kept for retry | 2 |
| Warm URL no quit | 2 |
| Non-Classic forward no auto-quit | 2 (explicit non-change) |
| Legacy untouched | Global Constraints |
| Manual test matrix | 2 |
