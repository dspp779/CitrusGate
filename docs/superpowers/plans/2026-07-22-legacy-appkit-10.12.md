# Beanfun OTP Legacy AppKit 10.12 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second app, `Beanfun OTP Legacy.app`, that runs on macOS 10.12+ (x86_64) with a pure AppKit UI and only supports select game → QR login → select account → show/copy OTP, without changing the existing macOS 13+ SwiftUI app.

**Architecture:** Keep Modern under `Sources/` / `build.sh`. Add a parallel tree `Legacy/` with copied protocol code rewritten to URLSession completion handlers (no async/await, no SwiftUI, no Combine). `build-legacy.sh` produces an Intel-only `.app` and embeds Swift runtime dylibs for old OS.

**Tech Stack:** Swift 5, AppKit, Foundation, URLSession, CommonCrypto (DES), zsh build scripts, existing `./test.sh` for Modern core tests.

**Spec:** `docs/superpowers/specs/2026-07-22-legacy-appkit-10.12-design.md`

## Global Constraints

- Legacy minimum OS: **10.12**; architecture: **x86_64 only**.
- Legacy bundle ID: `local.ogom.beanfunotp.legacy`; app name: `Beanfun OTP Legacy.app`.
- Legacy must **not** launch games, pick `.exe`, offer advanced mode, auto-refresh OTP, launch-command UI, or Debug Log UI.
- Do **not** modify Modern behavior except README documentation of the dual-app split.
- No shared framework in v1 — copy then adapt under `Legacy/Sources/`.
- No `async`/`await`, `Task`, `@MainActor`, `Combine`, SwiftUI, or `Duration` APIs in Legacy.
- Conventional Commits; Traditional Chinese UI strings.
- After each task: Legacy must still compile with `./build-legacy.sh` once that script exists (Task 1+); Modern `./test.sh` must keep passing when Models/DES/tests are untouched or only README changes.

## File Map

| File | Responsibility |
| --- | --- |
| `Legacy/Resources/Info.plist` | Legacy bundle metadata, `LSMinimumSystemVersion` 10.12 |
| `Legacy/Sources/main.swift` | `NSApplication` entry, window, quit-on-last-window |
| `Legacy/Sources/Models.swift` | Slim models: games, accounts, QR/OTP types, errors (no AppMode / LaunchCommandBuilder) |
| `Legacy/Sources/DESCipher.swift` | Copy of Modern DES helper |
| `Legacy/Sources/BeanfunClient.swift` | Completion-based Beanfun protocol client |
| `Legacy/Sources/AppController.swift` | AppKit flow controller + views (games → QR → accounts → OTP) |
| `build-legacy.sh` | Compile, bundle resources, embed libswift*, codesign |
| `README.md` | Dual-app OS requirements and feature subset |
| `Sources/*` | Modern — leave as-is |

---

### Task 1: Legacy scaffold — plist + stub AppKit app + `build-legacy.sh`

**Files:**
- Create: `Legacy/Resources/Info.plist`
- Create: `Legacy/Sources/main.swift`
- Create: `build-legacy.sh`
- Create: `Legacy/Resources/GameImages/` by copying from `Resources/GameImages/` at build time (script copies; no need to duplicate in git if build copies — prefer **build-time copy** from `Resources/GameImages` and `Resources/AppIcon.png`)

**Interfaces:**
- Consumes: existing `Resources/GameImages/*`, `Resources/AppIcon.png`
- Produces: `dist/Beanfun OTP Legacy.app` that launches a window titled `Beanfun OTP Legacy` on macOS (host may be newer; binary minos 10.12)

- [ ] **Step 1: Create `Legacy/Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_TW</string>
    <key>CFBundleDisplayName</key>
    <string>Beanfun OTP Legacy</string>
    <key>CFBundleExecutable</key>
    <string>BeanfunOTPLegacy</string>
    <key>CFBundleIdentifier</key>
    <string>local.ogom.beanfunotp.legacy</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Beanfun OTP Legacy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.12</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 2: Create stub `Legacy/Sources/main.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Beanfun OTP Legacy"
        window.center()
        window.contentView = NSView(frame: window.contentView!.bounds)
        let label = NSTextField(labelWithString: "Legacy scaffold OK")
        label.frame = NSRect(x: 20, y: 240, width: 380, height: 24)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

Note: if `NSTextField(labelWithString:)` is unavailable at the 10.12 SDK overlay, use:

```swift
let label = NSTextField(frame: NSRect(x: 20, y: 240, width: 380, height: 24))
label.isBezeled = false
label.drawsBackground = false
label.isEditable = false
label.isSelectable = false
label.stringValue = "Legacy scaffold OK"
```

- [ ] **Step 3: Create `build-legacy.sh`**

```zsh
#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_dir="$project_dir/Legacy/Sources"
resource_dir="$project_dir/Legacy/Resources"
modern_resources="$project_dir/Resources"
build_dir="$project_dir/.build/legacy"
app_dir="$project_dir/dist/Beanfun OTP Legacy.app"
module_cache="$build_dir/module-cache"
frameworks_dir="$app_dir/Contents/Frameworks"

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_dir" "$module_cache"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/GameImages" "$frameworks_dir"

sources=("$source_dir"/*.swift)

swiftc -swift-version 5 \
    -sdk "$sdk" \
    -module-cache-path "$module_cache" \
    -target x86_64-apple-macosx10.12 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$build_dir/BeanfunOTPLegacy" \
    "${sources[@]}"

cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$modern_resources/GameImages/"* "$app_dir/Contents/Resources/GameImages/"

# Icon: reuse Modern PNG via sips/iconutil (same pattern as build.sh, simplified)
icon_master="$modern_resources/AppIcon.png"
iconset_dir="$build_dir/AppIcon.iconset"
rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
sips -z 16 16 "$icon_master" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_master" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_master" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_master" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_master" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_master" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_master" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_master" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_master" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_master" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"

cp "$build_dir/BeanfunOTPLegacy" "$app_dir/Contents/MacOS/BeanfunOTPLegacy"
chmod 755 "$app_dir/Contents/MacOS/BeanfunOTPLegacy"

# Embed Swift libs referenced via @rpath
embedded=0
while IFS= read -r lib; do
    base="$(basename "$lib")"
    # Resolve absolute path of linked @rpath libs from the just-built binary's load commands
    true
done < <(otool -L "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | awk '/@rpath\/libswift/{print $1}')

swift_root="$(xcrun --find swiftc)"
swift_root="$(cd "$(dirname "$swift_root")/.." && pwd)"
# Common locations for toolchain macosx swift libs:
for candidate in \
    "$swift_root/lib/swift-5.0/macosx" \
    "$swift_root/lib/swift/macosx" \
    "/Library/Developer/CommandLineTools/usr/lib/swift/macosx" \
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
do
    if [[ -d "$candidate" ]]; then
        SWIFT_LIB_DIR="$candidate"
        break
    fi
done

if [[ -z "${SWIFT_LIB_DIR:-}" ]]; then
    echo "error: could not locate Swift macosx stdlib directory" >&2
    exit 1
fi

otool -L "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | awk '/@rpath\/libswift/{print $1}' | while read -r ref; do
    base="${ref#@rpath/}"
    if [[ -f "$SWIFT_LIB_DIR/$base" ]]; then
        cp "$SWIFT_LIB_DIR/$base" "$frameworks_dir/$base"
        embedded=1
    fi
done

# Also copy transitive libswift deps that appear only after first copy (one extra pass)
for pass in 1 2 3; do
    for f in "$frameworks_dir"/libswift*.dylib; do
        [[ -e "$f" ]] || continue
        otool -L "$f" | awk '/@rpath\/libswift|{print}' | awk '/libswift/{print $1}' | while read -r ref; do
            base="$(basename "$ref")"
            if [[ -f "$SWIFT_LIB_DIR/$base" && ! -f "$frameworks_dir/$base" ]]; then
                cp "$SWIFT_LIB_DIR/$base" "$frameworks_dir/$base"
            fi
        done
    done
done

codesign --force --deep --sign - "$app_dir"
echo "Built: $app_dir"
echo "minos check:"
otool -l "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | rg -A3 "LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION" | head -20
lipo -info "$app_dir/Contents/MacOS/BeanfunOTPLegacy"
```

Make executable: `chmod +x build-legacy.sh`

Fix the awk typo in the transitive pass when implementing: use `otool -L "$f" | awk '/libswift/{print $1}'` only (no broken `|{print}`).

- [ ] **Step 4: Run build and verify**

Run:

```bash
./build-legacy.sh
otool -l "dist/Beanfun OTP Legacy.app/Contents/MacOS/BeanfunOTPLegacy" | rg "minos|version 10"
lipo -info "dist/Beanfun OTP Legacy.app/Contents/MacOS/BeanfunOTPLegacy"
```

Expected:
- Script exits 0
- min OS **10.12**
- architecture **x86_64**
- App launches on the build Mac and shows「Legacy scaffold OK」(Rosetta if host is Apple Silicon)

- [ ] **Step 5: Commit**

```bash
git add Legacy/Resources/Info.plist Legacy/Sources/main.swift build-legacy.sh
git commit -m "$(cat <<'EOF'
feat: scaffold Legacy AppKit app and build-legacy.sh

EOF
)"
```

---

### Task 2: Legacy models + DES (no launch / mode extras)

**Files:**
- Create: `Legacy/Sources/Models.swift`
- Create: `Legacy/Sources/DESCipher.swift` (copy from `Sources/DESCipher.swift`, keep `BeanfunError` references consistent)
- Modify: `build-legacy.sh` already compiles all `Legacy/Sources/*.swift`

**Interfaces:**
- Produces types used by client/UI:
  - `struct GameAccount { let id: String; let sn: String; let displayName: String }`
  - `struct BeanfunQRSession { sessionKey, verificationToken, loginURL, image, deepLink, createdAt }`
  - `enum QRLoginStatus { case waiting(String); case confirmed; case expired }`
  - `struct OTPResult { let value: String; let retrievedAt: Date }` — **no** `commandLine`
  - `enum GameLaunchStyle` / `BeanfunAccountFlow` / `GameDefinition` with `static let all` (9 games) matching Modern service codes
  - `struct GameStartData` (same fields as Modern)
  - `enum BeanfunError` (same cases as Modern)
- Do **not** include `AppMode`, `AdvancedLaunchCommandStyle`, `LaunchCommandBuilder`, `MapleStoryLaunch` in Legacy models

- [ ] **Step 1: Copy DES**

```bash
cp Sources/DESCipher.swift Legacy/Sources/DESCipher.swift
```

Ensure any `Data` hex helper used by DES lives in Legacy (if it is an extension in Modern `DESCipher.swift` or elsewhere, copy that too). Check Modern: hex helpers may be at bottom of `DESCipher.swift` — copy entire file.

- [ ] **Step 2: Write `Legacy/Sources/Models.swift`**

Port from `Sources/Models.swift`:
- Keep: `GameAccount`, `BeanfunQRSession`, `QRLoginStatus`, `OTPResult` (drop `commandLine`), `GameLaunchStyle`, `BeanfunAccountFlow`, `GameDefinition` (+ `all` nine games), `GameStartData`, `BeanfunError`
- Remove: `Identifiable` conformances if they cause availability issues; AppKit UI will not need them
- Remove: `AppMode`, `MapleStoryLaunch`, `AdvancedLaunchCommandStyle`, `LaunchCommandBuilder`
- Keep `GameDefinition.gameArguments` / `openArguments` / `commandLine` **or** delete them — prefer **delete** launch helpers in Legacy `GameDefinition` to avoid dead code (only keep `id`, `name`, `serviceCode`, `serviceRegion`, `imageName`, `executableName`, `launchStyle`, `accountFlow`, `serviceKey`)

Include a tiny sanity check in stub until Task 4 replaces UI — optional `assert(GameDefinition.all.count == 9)` in `applicationDidFinishLaunching` is fine.

- [ ] **Step 3: Build**

```bash
./build-legacy.sh
./test.sh
```

Expected: Legacy builds; Modern tests still pass (unchanged).

- [ ] **Step 4: Commit**

```bash
git add Legacy/Sources/Models.swift Legacy/Sources/DESCipher.swift
git commit -m "$(cat <<'EOF'
feat: add Legacy models and DES cipher copy

EOF
)"
```

---

### Task 3: Completion-based `BeanfunClient`

**Files:**
- Create: `Legacy/Sources/BeanfunClient.swift` (port of `Sources/BeanfunClient.swift`)

**Interfaces:**
- Consumes: Legacy `Models`, `DESCipher`
- Produces:

```swift
final class BeanfunClient {
    var includeSecrets: Bool
    init(log: @escaping (String) -> Void)
    func reset()
    func createQRSession(completion: @escaping (Result<BeanfunQRSession, Error>) -> Void)
    func pollQRLogin(completion: @escaping (Result<QRLoginStatus, Error>) -> Void)
    func completeQRLogin(completion: @escaping (Result<Void, Error>) -> Void)
    func fetchAccounts(for game: GameDefinition, completion: @escaping (Result<[GameAccount], Error>) -> Void)
    func fetchOTP(for account: GameAccount, game: GameDefinition, completion: @escaping (Result<OTPResult, Error>) -> Void)
}
```

- Private HTTP:

```swift
private func request(
    _ url: URL,
    method: String = "GET",
    form: [String: String]? = nil,
    json: [String: Any]? = nil,
    referer: URL? = nil,
    headers: [String: String] = [:],
    sensitiveFormKeys: Set<String> = [],
    completion: @escaping (Result<HTTPResult, Error>) -> Void
)
```

Use `session.dataTask(with: request) { data, response, error in ... }.resume()` instead of `session.data(for:)`.

Dispatch completions to the main queue for UI safety:

```swift
DispatchQueue.main.async { completion(.success(...)) }
```

- [ ] **Step 1: Copy Modern client then strip concurrency**

```bash
cp Sources/BeanfunClient.swift Legacy/Sources/BeanfunClient.swift
```

Then edit Legacy copy:
1. Remove `@MainActor`
2. Replace every `async throws` method with completion-handler form above
3. Replace `try await request(...)` chains with nested `request(...) { result in switch result ... }` **or** a small private serial helper:

```swift
/// Runs asynchronous completion-style steps in order on a private queue.
private func runChain(_ work: @escaping (@escaping (Error?) -> Void) -> Void, completion: @escaping (Error?) -> Void) {
    work { error in
        DispatchQueue.main.async { completion(error) }
    }
}
```

Preferred approach for maintainability: keep the same step comments (`[登入 1/7]` …) and convert each `try await` into the next nested callback. Match Modern URLs, headers, cookies, and parsing **exactly**.

4. Remove `Task.checkCancellation()`; if Legacy needs cancel on re-login, use:

```swift
private var generation: UInt64 = 0
func reset() {
    generation &+= 1
    // invalidate session as Modern does
}
```

Ignore stale completions when `generation` changed.

5. `OTPResult` in Legacy has no `commandLine` — when constructing OTP result, only set `value` + `retrievedAt`.

6. Keep `includeSecrets` default `true` or `false` consistent with useful silent logging; Legacy UI has no debug panel, so default `includeSecrets = false` and still `log` non-secret progress to stdout via the injected logger (AppController can no-op or print).

- [ ] **Step 2: Convert `request` core (template)**

Replace the async body with:

```swift
let task = session.dataTask(with: request) { [weak self] data, response, error in
    guard let self = self else { return }
    if let error = error {
        DispatchQueue.main.async {
            completion(.failure(BeanfunError.network(error.localizedDescription)))
        }
        return
    }
    guard let data = data, let http = response as? HTTPURLResponse else {
        DispatchQueue.main.async {
            completion(.failure(BeanfunError.network("沒有 HTTP response")))
        }
        return
    }
    self.log("  ← HTTP \(http.statusCode)，收到 \(data.count) bytes")
    guard (200..<400).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        DispatchQueue.main.async {
            completion(.failure(BeanfunError.http(http.statusCode, url.absoluteString, body)))
        }
        return
    }
    DispatchQueue.main.async {
        completion(.success(HTTPResult(data: data, response: http)))
    }
}
task.resume()
```

Port helper methods (`capture`, `jsonObject`, `formData`, cookie helpers, DES OTP decrypt path) unchanged aside from availability.

- [ ] **Step 3: Build Legacy**

```bash
./build-legacy.sh
```

Expected: compile success. If Swift version issues with `Result` (available) or `guard let self = self`, use explicit capture.

- [ ] **Step 4: Commit**

```bash
git add Legacy/Sources/BeanfunClient.swift
git commit -m "$(cat <<'EOF'
feat: port BeanfunClient to Legacy completion handlers

EOF
)"
```

---

### Task 4: AppKit UI flow (`AppController`)

**Files:**
- Create: `Legacy/Sources/AppController.swift`
- Modify: `Legacy/Sources/main.swift` (host `AppController` as window content)

**Interfaces:**
- Consumes: `BeanfunClient`, `GameDefinition.all`, pasteboard
- Produces: single-window UI states: `games | qr | accounts | otp`

- [ ] **Step 1: Implement `AppController` as `NSViewController`**

Structure:

```swift
final class AppController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Screen { case games, qr, accounts, otp }

    private let client = BeanfunClient { message in
        NSLog("%@", message)
    }
    private var screen: Screen = .games
    private var games: [GameDefinition] = GameDefinition.all
    private var selectedGame: GameDefinition?
    private var qrImage: NSImage?
    private var qrStatus: String = ""
    private var accounts: [GameAccount] = []
    private var selectedAccountIndex: Int = -1
    private var otpValue: String = ""
    private var pollTimer: Timer?
    private var countdownTimer: Timer?
    private var qrSecondsRemaining: Int = 60

    // outlets created in code: statusLabel, tableView, imageView, primaryButton, secondaryButton, otpField
}
```

Flow wiring:
1. **games**: table of `game.name`; double-click or「下一步」→ set `selectedGame`, call `startLogin()`
2. **startLogin**: `client.createQRSession` → show QR image; start `Timer` every 2s calling `client.pollQRLogin`; on `.confirmed` → `completeQRLogin` then `fetchAccounts`
3. **accounts**: one account → auto `fetchOTP`; many → select +「取得 OTP」
4. **otp**: show OTP string;「複製 OTP」/「複製帳號」via `NSPasteboard.general.clearContents(); setString(_:forType: .string)` — on 10.12 use `NSPPasteboardTypeString` if `.string` unavailable:

```swift
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(value, forType: .string) // or NSPasteboard.PasteboardType.string
```

5. Errors: `NSAlert(error:)` or `NSAlert` with `messageText = "Beanfun OTP Legacy"`, `informativeText = error.localizedDescription`
6.「重新產生」on QR cancels timers and calls `startLogin()` again
7.「選擇其他遊戲」resets to games and `client.reset()`
8. Remember last game id: `UserDefaults.standard.set(game.id, forKey: "LegacyLastGameID")` on select; on launch scroll/select that row if present

UI layout: vertical `NSStackView` (available 10.11+) inside the window content view. Fixed window size ~420×520; disable zoom if easy.

- [ ] **Step 2: Wire `main.swift`**

Replace stub content with:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = AppController()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Beanfun OTP Legacy"
    window.contentViewController = controller
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
}
```

If `contentViewController` is awkward on 10.12, set `window.contentView = controller.view` after `controller.loadView()`.

- [ ] **Step 3: Build and smoke-test on build Mac**

```bash
./build-legacy.sh
open "dist/Beanfun OTP Legacy.app"
```

Manual check (needs Beanfun + Gama Play):
- Game list shows 9 titles
- QR appears after selecting a game
- After scan, accounts then OTP
- Copy buttons work
- No launch / advanced / debug controls exist

- [ ] **Step 4: Commit**

```bash
git add Legacy/Sources/AppController.swift Legacy/Sources/main.swift
git commit -m "$(cat <<'EOF'
feat: add Legacy AppKit OTP login UI flow

EOF
)"
```

---

### Task 5: README dual-app documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Near the top / build section, add a clear split:

```markdown
## 兩個版本

| | Beanfun OTP | Beanfun OTP Legacy |
| --- | --- | --- |
| 系統需求 | macOS 13 以上 | macOS 10.12 以上（Intel） |
| 架構 | Apple Silicon + Intel | 僅 Intel (x86_64) |
| 功能 | 完整（含啟動遊戲、進階模式） | 精簡：QR 登入後複製 OTP |
| 建置 | `./build.sh` | `./build-legacy.sh` |
| 輸出 | `dist/Beanfun OTP.app` | `dist/Beanfun OTP Legacy.app` |

10.12–12 請用 Legacy。13 以上請用一般版。Beanfun 登入協定若變更，兩個版本的 client 都需要同步更新。
```

Adjust any existing sentence that only mentions macOS 13 so it does not contradict Legacy.

- [ ] **Step 2: Verify Modern still documented correctly**

Run:

```bash
./test.sh
./build.sh
./build-legacy.sh
```

Expected: all three succeed.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: document Modern vs Legacy app split

EOF
)"
```

---

## Spec Coverage Check

| Spec item | Task |
| --- | --- |
| Two apps, Legacy 10.12 x86_64 | 1, 5 |
| AppKit-only Legacy UI | 4 |
| OTP-only scope (no launch/advanced/debug) | 4, 5 |
| Copy protocol + completion networking | 3 |
| Embed Swift libs | 1 (`build-legacy.sh`) |
| README dual download guidance | 5 |
| Modern unchanged | All tasks avoid `Sources/` edits except none |
| Games = same 9 | 2 |

## Placeholder / Consistency Review

- Public client method names are fixed in Task 3 and consumed in Task 4.
- `OTPResult` Legacy shape drops `commandLine` — Task 3 must not pass that field.
- `build-legacy.sh` transitive `otool` awk must be corrected when implementing (called out in Task 1).
- No shared framework tasks (matches non-goal).
