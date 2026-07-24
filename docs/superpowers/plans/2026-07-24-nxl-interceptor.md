# NXL Interceptor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build arm64-only `NXL Interceptor.app` that registers the `nxl` URL scheme, shows the full opened URL in an `NSAlert`, then quits.

**Architecture:** Single-file AppKit stub (`Interceptor/Sources/main.swift`) plus `Info.plist` with `CFBundleURLSchemes = nxl`. A minimal `build-nxl-interceptor.sh` compiles arm64 and assembles `dist/NXL Interceptor.app`. No UI beyond `NSAlert`; no Beanfun OTP changes.

**Tech Stack:** Swift 5, AppKit, zsh, `swiftc` (Command Line Tools), no new dependencies.

## Global Constraints

- arm64 only (`-target arm64-apple-macosx13.0`); no universal / Intel binary.
- Bundle ID: `local.ogom.nxlinterceptor`.
- Show first URL’s `absoluteString` only; empty string → fixed fallback message.
- Cold open (no URL): explain that the app intercepts `nxl://`, then quit after OK.
- Do not modify Beanfun OTP sources, `build.sh`, or `build-legacy.sh`.
- No app icon, signing, notarization, log files, or README changes unless later requested.
- User-facing alert copy in Traditional Chinese.
- Spec: `docs/superpowers/specs/2026-07-24-nxl-interceptor-design.md`.

## File Map

| File | Responsibility |
| --- | --- |
| `Interceptor/Resources/Info.plist` | Bundle metadata + `nxl` URL scheme |
| `Interceptor/Sources/main.swift` | AppKit delegate: open URL / cold open → `NSAlert` → terminate |
| `build-nxl-interceptor.sh` | Compile arm64 stub, assemble `dist/NXL Interceptor.app` |

---

### Task 1: Interceptor AppKit stub + Info.plist

**Files:**
- Create: `Interceptor/Resources/Info.plist`
- Create: `Interceptor/Sources/main.swift`

**Interfaces:**
- Consumes: Launch Services `application(_:open:)` URLs; cold launch with no URL
- Produces: modal `NSAlert` then process exit; executable name `NXLInterceptor` matching plist

- [ ] **Step 1: Create `Interceptor/Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_TW</string>
    <key>CFBundleDisplayName</key>
    <string>NXL Interceptor</string>
    <key>CFBundleExecutable</key>
    <string>NXLInterceptor</string>
    <key>CFBundleIdentifier</key>
    <string>local.ogom.nxlinterceptor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NXL Interceptor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>NXL Interceptor</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>nxl</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Create `Interceptor/Sources/main.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledOpenURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.handledOpenURL else { return }
            self.showAndQuit(
                title: "NXL Interceptor",
                message: "此 App 用來攔截 nxl:// 連結。\n請從網頁或終端機開啟 nxl://… 再試。"
            )
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledOpenURL = true
        let text: String
        if let url = urls.first {
            let absolute = url.absoluteString
            text = absolute.isEmpty ? "(empty absoluteString)" : absolute
        } else {
            text = "(no URL)"
        }
        showAndQuit(title: "nxl URL", message: text)
    }

    private func showAndQuit(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "確定")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

- [ ] **Step 3: Commit**

```bash
git add Interceptor/Resources/Info.plist Interceptor/Sources/main.swift
git commit -m "$(cat <<'EOF'
feat: add NXL interceptor AppKit stub and Info.plist

EOF
)"
```

---

### Task 2: Build script + local smoke verification

**Files:**
- Create: `build-nxl-interceptor.sh`

**Interfaces:**
- Consumes: `Interceptor/Sources/*.swift`, `Interceptor/Resources/Info.plist`
- Produces: `dist/NXL Interceptor.app` with `Contents/MacOS/NXLInterceptor` and `Contents/Info.plist`

- [ ] **Step 1: Create `build-nxl-interceptor.sh`**

```zsh
#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_dir="$project_dir/Interceptor/Sources"
resource_dir="$project_dir/Interceptor/Resources"
build_dir="$project_dir/.build-nxl-interceptor"
app_dir="$project_dir/dist/NXL Interceptor.app"
module_cache="$build_dir/module-cache"

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

export TMPDIR="$build_dir/tmp"
mkdir -p "$build_dir" "$module_cache" "$TMPDIR"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

sources=("$source_dir"/*.swift)

echo "Building arm64 NXLInterceptor…"
swiftc \
    -swift-version 5 \
    -sdk "$sdk" \
    -module-cache-path "$module_cache" \
    -target arm64-apple-macosx13.0 \
    -o "$build_dir/NXLInterceptor" \
    "${sources[@]}"

cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$build_dir/NXLInterceptor" "$app_dir/Contents/MacOS/NXLInterceptor"
chmod +x "$app_dir/Contents/MacOS/NXLInterceptor"

echo "Built: $app_dir"
```

- [ ] **Step 2: Make executable and build**

Run:

```bash
chmod +x build-nxl-interceptor.sh
./build-nxl-interceptor.sh
```

Expected: prints `Building arm64 NXLInterceptor…` then `Built: …/dist/NXL Interceptor.app`

Confirm:

```bash
file "dist/NXL Interceptor.app/Contents/MacOS/NXLInterceptor"
/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "dist/NXL Interceptor.app/Contents/Info.plist"
```

Expected: `Mach-O 64-bit executable arm64` and `nxl`.

- [ ] **Step 3: Register and smoke-test URL open**

Run (interactive — will show a modal alert):

```bash
open -a "dist/NXL Interceptor.app" "nxl://test-from-terminal?foo=bar"
```

Expected: alert titled `nxl URL` with informative text containing `nxl://test-from-terminal?foo=bar`; clicking 確定 exits the app.

If another app opens instead, Launch Services still prefers a different `nxl` handler. Register this build explicitly then retry:

```bash
# Force Launch Services to see this bundle
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "dist/NXL Interceptor.app"
open "nxl://test-from-terminal?foo=bar"
```

If a real Nexon Launcher still wins, temporarily move that app aside and retry (diagnostic only).

Optional cold-open check:

```bash
open "dist/NXL Interceptor.app"
```

Expected: Traditional Chinese waiting message; 確定 quits.

- [ ] **Step 4: Commit**

```bash
git add build-nxl-interceptor.sh
git commit -m "$(cat <<'EOF'
feat: add arm64 build script for NXL Interceptor

EOF
)"
```

Do **not** commit `dist/` or `.build-nxl-interceptor/` unless the repo already tracks similar build products (it should not).

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| Independent `NXL Interceptor.app` | Task 2 |
| Register `nxl` scheme | Task 1 Info.plist |
| `NSAlert` with full `absoluteString` | Task 1 `main.swift` |
| Quit after OK | Task 1 `showAndQuit` |
| Cold open message then quit | Task 1 `applicationDidFinishLaunching` |
| arm64 only | Task 2 `swiftc` flags |
| Bundle ID `local.ogom.nxlinterceptor` | Task 1 Info.plist |
| No Beanfun OTP changes | File map / Global Constraints |
| Launch Services conflict verification | Task 2 Step 3 |
