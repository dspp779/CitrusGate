# MapleStory Wine Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `MapleStory Wine Helper.app` so BeanfunOTP’s existing `open -n MapleStory.exe --args …` launches Taiwan MapleStory through Nexon MapleStory Launcher Wine after the user sets Open with on that `.exe`.

**Architecture:** Thin Swift AppKit stub receives the document Apple Event plus `--args`, then runs embedded `launch-maplestory.sh`, which sets player-guide Wine env and executes `wine --bottle maplestory`. Failures alert via `osascript` / `NSAlert`; success has no UI.

**Tech Stack:** Swift 5, AppKit, zsh/bash, ad-hoc codesign, existing repo `build.sh` patterns (no new package managers).

## Global Constraints

- Do not change BeanfunOTP `launchGame()` / `open -n` behavior.
- Do not steal system-wide `.exe` default; user sets Open with via Get Info.
- Wine defaults fixed: `CX_ROOT=/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna`, `PATH` includes `$CX_ROOT/MapleStory Launcher`, bottle `maplestory`, `LANG`/`LC_ALL`/`LC_CTYPE=zh_TW.UTF-8`.
- Do not use bottle `default` or `…/bin/wine --wait-children --enable-alt-loader macdrv`.
- No settings UI; no OTP fetching in the helper.
- Stub waits for script; script runs `wine` in the foreground.
- Conventional Commits; Traditional Chinese user-facing alert copy.
- Spec: `docs/superpowers/specs/2026-07-21-maplestory-wine-helper-design.md`.

## File Map

| File | Responsibility |
| --- | --- |
| `Helper/Resources/launch-maplestory.sh` | Validate inputs, resolve Wine, export env, run `wine`, `osascript` on failure |
| `Helper/Tests/test-launch-maplestory.sh` | Fake Wine tree + dry assertions without real Launcher |
| `Helper/Sources/main.swift` | AppKit stub: open document + argv → invoke script |
| `Helper/Info.plist` | Bundle id, `.exe` document types, `LSUIElement`, executable name |
| `build-helper.sh` | Build universal stub, assemble `.app`, codesign → `dist/MapleStory Wine Helper.app` |
| `README.md` | How to build Helper + set Open with |
| `docs/macos-player-guide.md` | Point players at Helper instead of only manual Wine / Cyder for OTP open path |

---

### Task 1: `launch-maplestory.sh` + shell tests

**Files:**
- Create: `Helper/Resources/launch-maplestory.sh`
- Create: `Helper/Tests/test-launch-maplestory.sh`

**Interfaces:**
- Consumes: argv ` <exe> [game-args…] `; optional env `CX_ROOT` override (tests only); `MAPLESTORY_WINE_HELPER_DRY_RUN=1` prints the wine argv line and exits 0 without executing
- Produces: exit 0 on success / dry-run; non-zero + `osascript` alert on failure (skip `osascript` when `MAPLESTORY_WINE_HELPER_TEST=1`)

- [ ] **Step 1: Write the failing test harness**

Create `Helper/Tests/test-launch-maplestory.sh`:

```zsh
#!/bin/zsh
set -euo pipefail

root="${0:A:h}/../.."
script="$root/Helper/Resources/launch-maplestory.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*" }

# Missing exe → non-zero (test mode: no dialog)
if MAPLESTORY_WINE_HELPER_TEST=1 "$script" 2>/dev/null; then
  fail "expected failure with no args"
fi
pass "no args fails"

# Fake CX_ROOT without wine binary
fake_root="$tmpdir/maplestoryna"
mkdir -p "$fake_root/MapleStory Launcher"
exe="$tmpdir/game/MapleStory.exe"
mkdir -p "$tmpdir/game"
touch "$exe"

if CX_ROOT="$fake_root" MAPLESTORY_WINE_HELPER_TEST=1 "$script" "$exe" a b 2>/dev/null; then
  fail "expected failure when wine missing"
fi
pass "missing wine fails"

# Fake wine that records argv
cat > "$fake_root/MapleStory Launcher/wine" <<'EOF'
#!/bin/zsh
printf '%s\n' "$@" > "${WINE_ARGV_LOG:?}"
EOF
chmod +x "$fake_root/MapleStory Launcher/wine"
export WINE_ARGV_LOG="$tmpdir/wine-argv.txt"

CX_ROOT="$fake_root" MAPLESTORY_WINE_HELPER_TEST=1 \
  "$script" "$exe" tw.login.maplestory.beanfun.com 8484 BeanFun T9ACCOUNT 12345678

expected=(
  --bottle maplestory
  --workdir "$tmpdir/game"
  "$exe"
  tw.login.maplestory.beanfun.com
  8484
  BeanFun
  T9ACCOUNT
  12345678
)
got=("${(@f)$(<"$WINE_ARGV_LOG")}")
[[ "${got[*]}" == "${expected[*]}" ]] || fail "wine argv mismatch\n got: ${got[*]}\n want: ${expected[*]}"
pass "wine argv matches player guide"

# Dry-run does not require wine on PATH beyond CX_ROOT check — still needs wine file
out="$(CX_ROOT="$fake_root" MAPLESTORY_WINE_HELPER_DRY_RUN=1 MAPLESTORY_WINE_HELPER_TEST=1 \
  "$script" "$exe" x y)"
print -r -- "$out" | grep -q -- "--bottle maplestory" || fail "dry-run missing bottle"
pass "dry-run prints command"

echo "All launch-maplestory.sh tests passed."
```

- [ ] **Step 2: Run tests — expect FAIL (script missing)**

Run: `zsh Helper/Tests/test-launch-maplestory.sh`  
Expected: FAIL opening/running missing `Helper/Resources/launch-maplestory.sh`

- [ ] **Step 3: Implement `Helper/Resources/launch-maplestory.sh`**

```zsh
#!/bin/zsh
set -euo pipefail

alert() {
  local message="$1"
  if [[ "${MAPLESTORY_WINE_HELPER_TEST:-}" == "1" ]]; then
    print -r -- "$message" >&2
    return 0
  fi
  local quoted
  quoted="$(printf '%s' "$message" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  /usr/bin/osascript -e "display alert \"MapleStory Wine Helper\" message $quoted" >/dev/null 2>&1 || true
}

default_cx_root="/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
cx_root="${CX_ROOT:-$default_cx_root}"
wine_dir="$cx_root/MapleStory Launcher"
wine_bin="$wine_dir/wine"

if [[ $# -lt 1 ]]; then
  alert "請透過「打開方式」開啟 MapleStory.exe，或由 Beanfun OTP 啟動。"
  exit 1
fi

exe="$1"
shift

if [[ ! -f "$exe" ]]; then
  alert "找不到遊戲主程式：$exe"
  exit 1
fi

if [[ ! -x "$wine_bin" ]]; then
  alert "找不到美版 MapleStory Launcher 的 Wine。請先安裝並開啟過 MapleStory Launcher。預期路徑：$wine_bin"
  exit 1
fi

workdir="${exe:h}"
export CX_ROOT="$cx_root"
export PATH="$wine_dir:$PATH"
export LANG=zh_TW.UTF-8
export LC_ALL=zh_TW.UTF-8
export LC_CTYPE=zh_TW.UTF-8

if [[ "${MAPLESTORY_WINE_HELPER_DRY_RUN:-}" == "1" ]]; then
  print -r -- "wine --bottle maplestory --workdir $workdir $exe $*"
  exit 0
fi

set +e
wine --bottle maplestory --workdir "$workdir" "$exe" "$@"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  alert "Wine 啟動失敗（結束代碼 $status）。"
  exit "$status"
fi
exit 0
```

Make executable: `chmod +x Helper/Resources/launch-maplestory.sh Helper/Tests/test-launch-maplestory.sh`

- [ ] **Step 4: Run tests — expect PASS**

Run: `zsh Helper/Tests/test-launch-maplestory.sh`  
Expected: `All launch-maplestory.sh tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Helper/Resources/launch-maplestory.sh Helper/Tests/test-launch-maplestory.sh
git commit -m "$(cat <<'EOF'
feat: add MapleStory Wine launch shell script

EOF
)"
```

---

### Task 2: Helper `Info.plist` + Swift stub that runs the script

**Files:**
- Create: `Helper/Info.plist`
- Create: `Helper/Sources/main.swift`

**Interfaces:**
- Consumes: Apple Event open URLs; `CommandLine.arguments` after filtering `-psn_*`; script at `Bundle.main.url(forResource:withExtension:)` → `launch-maplestory.sh`
- Produces: process exit after script returns; `NSAlert` only if script URL missing or cannot start `Process`

- [ ] **Step 1: Create `Helper/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_TW</string>
    <key>CFBundleDisplayName</key>
    <string>MapleStory Wine Helper</string>
    <key>CFBundleExecutable</key>
    <string>MapleStoryWineHelper</string>
    <key>CFBundleIdentifier</key>
    <string>local.ogom.maplestory-wine-helper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MapleStory Wine Helper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>exe</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Windows Executable</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.windows-executable</string>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Implement `Helper/Sources/main.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var gameArguments: [String] = []
    private var didHandleOpen = false
    private var launchWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        gameArguments = CommandLine.arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-psn_") }
            .map { String($0) }

        // If Launch Services never delivers a document, fail after a short wait.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.didHandleOpen else { return }
            self.failAndTerminate("請透過「打開方式」開啟 MapleStory.exe，或由 Beanfun OTP 啟動。")
        }
        launchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchWorkItem?.cancel()
        guard !didHandleOpen else { return }
        didHandleOpen = true

        guard let exeURL = urls.first(where: { $0.pathExtension.lowercased() == "exe" }) ?? urls.first else {
            failAndTerminate("請透過「打開方式」開啟 MapleStory.exe，或由 Beanfun OTP 啟動。")
            return
        }
        runScript(executablePath: exeURL.path, arguments: gameArguments)
    }

    private func runScript(executablePath: String, arguments: [String]) {
        guard let scriptURL = Bundle.main.url(forResource: "launch-maplestory", withExtension: "sh") else {
            failAndTerminate("找不到內嵌啟動腳本 launch-maplestory.sh。")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, executablePath] + arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()
            NSApp.terminate(nil)
            exit(process.terminationStatus)
        } catch {
            failAndTerminate("無法執行啟動腳本：\(error.localizedDescription)")
        }
    }

    private func failAndTerminate(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MapleStory Wine Helper"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
        NSApp.terminate(nil)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 3: Sanity-compile the stub**

Run:

```zsh
sdk="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -sdk "$sdk" -target arm64-apple-macosx13.0 \
  -framework AppKit -parse-as-library \
  Helper/Sources/main.swift -o /tmp/MapleStoryWineHelper-test
```

Expected: compiles with exit 0.

- [ ] **Step 4: Commit**

```bash
git add Helper/Info.plist Helper/Sources/main.swift
git commit -m "$(cat <<'EOF'
feat: add MapleStory Wine Helper AppKit stub

EOF
)"
```

---

### Task 3: `build-helper.sh` → `dist/MapleStory Wine Helper.app`

**Files:**
- Create: `build-helper.sh`

**Interfaces:**
- Consumes: `Helper/Sources/main.swift`, `Helper/Info.plist`, `Helper/Resources/launch-maplestory.sh`
- Produces: `dist/MapleStory Wine Helper.app` (universal arm64 + x86_64), ad-hoc signed

- [ ] **Step 1: Write `build-helper.sh`**

Mirror `build.sh` style:

```zsh
#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
helper_dir="$project_dir/Helper"
source_dir="$helper_dir/Sources"
resource_dir="$helper_dir/Resources"
build_dir="$project_dir/.build/helper"
app_dir="$project_dir/dist/MapleStory Wine Helper.app"
module_cache="$build_dir/module-cache"

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
  sdk="$preferred_sdk"
else
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_dir/arm64" "$build_dir/x86_64" "$module_cache"

common_flags=(
  -swift-version 5
  -sdk "$sdk"
  -module-cache-path "$module_cache"
  -framework AppKit
  -parse-as-library
)

echo "Building MapleStory Wine Helper (arm64)…"
swiftc "${common_flags[@]}" -target arm64-apple-macosx13.0 \
  -o "$build_dir/arm64/MapleStoryWineHelper" "$source_dir/main.swift"

echo "Building MapleStory Wine Helper (x86_64)…"
swiftc "${common_flags[@]}" -target x86_64-apple-macosx13.0 \
  -o "$build_dir/x86_64/MapleStoryWineHelper" "$source_dir/main.swift"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$helper_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$resource_dir/launch-maplestory.sh" "$app_dir/Contents/Resources/launch-maplestory.sh"
chmod 755 "$app_dir/Contents/Resources/launch-maplestory.sh"

lipo -create \
  "$build_dir/arm64/MapleStoryWineHelper" \
  "$build_dir/x86_64/MapleStoryWineHelper" \
  -output "$app_dir/Contents/MacOS/MapleStoryWineHelper"
chmod 755 "$app_dir/Contents/MacOS/MapleStoryWineHelper"

codesign --force --sign - "$app_dir"
echo "Built: $app_dir"
```

`chmod +x build-helper.sh`

- [ ] **Step 2: Build**

Run: `./build-helper.sh`  
Expected: `Built: …/dist/MapleStory Wine Helper.app`

- [ ] **Step 3: Verify bundle contents**

Run:

```zsh
test -x "dist/MapleStory Wine Helper.app/Contents/MacOS/MapleStoryWineHelper"
test -x "dist/MapleStory Wine Helper.app/Contents/Resources/launch-maplestory.sh"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "dist/MapleStory Wine Helper.app/Contents/Info.plist"
```

Expected: identifier `local.ogom.maplestory-wine-helper`

- [ ] **Step 4: Smoke — missing document alert path**

Run: `open -n "dist/MapleStory Wine Helper.app"`  
Expected: system alert (Chinese copy about opening MapleStory.exe), then app exits. Dismiss the alert manually during verification.

- [ ] **Step 5: Commit**

```bash
git add build-helper.sh
git commit -m "$(cat <<'EOF'
feat: add build-helper.sh for MapleStory Wine Helper app

EOF
)"
```

Do **not** commit `dist/` unless the repo already tracks built apps (it should not).

---

### Task 4: Documentation (README + player guide)

**Files:**
- Modify: `README.md`
- Modify: `docs/macos-player-guide.md`

**Interfaces:**
- Consumes: built Helper path, Open with steps, Wine defaults from spec
- Produces: user-facing Traditional Chinese instructions; no BeanfunOTP code changes

- [ ] **Step 1: Update `README.md`**

Add a short section after 建置與測試 (or within it), for example:

```markdown
## MapleStory Wine Helper

台版楓之谷若要以美版 MapleStory Launcher 的 Wine 啟動，可另建獨立 Helper：

```sh
./build-helper.sh
```

輸出：`dist/MapleStory Wine Helper.app`。

1. 將 App 放到好找的位置（例如 `/Applications`）。
2. 在 Finder 對 `MapleStory.exe` 按「取得資訊」→「打開方式」選 **MapleStory Wine Helper**（只需針對該檔；不必「全部變更」，除非你接受影響同類型關聯）。
3. 在 Beanfun OTP 取得 OTP 後按啟動；App 仍使用 `open -n`，會走你為該 `.exe` 指定的 Helper，由 Helper 呼叫 Launcher Wine（bottle `maplestory`、`zh_TW.UTF-8`）。

其他遊戲若使用 Cyder，請繼續為那些 `.exe` 保留 Cyder，不要把 Helper 設成全系統 `.exe` 預設。
```

Adjust wording to match surrounding README tone; keep Cyder notes for non-MapleStory games accurate.

- [ ] **Step 2: Update `docs/macos-player-guide.md`**

In 「步驟 4」／啟動相關段落，加入 Helper 選項：建置、`取得資訊 → 打開方式`、再以 CitrusGate／Beanfun OTP `open -n` 啟動。保留手動 `wine` 指令作為備援。註明 Helper 不會搶全系統 `.exe` 預設。

- [ ] **Step 3: Re-run shell tests + helper build**

```zsh
zsh Helper/Tests/test-launch-maplestory.sh
./build-helper.sh
```

Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/macos-player-guide.md
git commit -m "$(cat <<'EOF'
docs: document MapleStory Wine Helper open-with flow

EOF
)"
```

---

### Task 5: Manual integration checklist (no code)

**Files:** none (verification only)

- [ ] **Step 1: Prerequisites**

Confirm on the test Mac:

- `/Applications/MapleStory Launcher.app` installed and opened once (bottle exists)
- Taiwan `MapleStory.exe` path known
- Helper built via `./build-helper.sh`

- [ ] **Step 2: Assign Open with**

Finder → Get Info on `MapleStory.exe` → Open with → MapleStory Wine Helper.

- [ ] **Step 3: Launch with dummy args (expect game/login error, not Wine-not-found)**

```zsh
open -n '/path/to/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun T9TEST 00000000
```

Expected: Wine/game process starts (may fail login with bad OTP). Must **not** show “找不到 … Wine”.

- [ ] **Step 4: Launch via Beanfun OTP**

Use real OTP for 新楓之谷; press in-app launch. Expected: same Wine path as player guide.

- [ ] **Step 5: Note result in commit message only if follow-up fixes are needed**

If verification finds a bug, fix in a new task/commit; do not leave the helper half-working.

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| Independent `build-helper.sh` → `dist/MapleStory Wine Helper.app` | 3 |
| Thin Swift stub + embedded shell | 1–2 |
| Open with / document types for `.exe` | 2 |
| Player-guide Wine env + bottle `maplestory` | 1 |
| Pass through `--args`; no OTP fetch | 1–2 |
| Alerts on failure; silent success | 1–2 |
| Foreground wine; stub waits | 2 |
| No BeanfunOTP `launchGame()` change | (constraint) |
| README + player guide | 4 |
| Manual integration | 5 |

## Self-review notes

- `CX_ROOT` override is for tests only; production uses the default path.
- `dist/` artifacts stay untracked.
- Stub uses `LSUIElement` + `.accessory` so success stays UI-free aside from failure alerts.
- Shell alerts use `osascript` + Python `json.dumps` for safe quoting (`build.sh` already depends on `python3`).
