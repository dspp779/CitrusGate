# MapleStory Classic Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 楓之谷：經典版 to Beanfun OTP Modern: web login + `NexonPlug://` receive, launch via `open -n … --args`, forward non-2982 URLs to official NexonPlug.

**Architecture:** Pure `NexonPlugURLParser` + Classic `open` argv helper; extend `GameDefinition` with `GameAuthFlow.webNexonPlug` and `AppScreen.classic`; `AppModel` owns path, pending passarg, launch/forward/handler; SwiftUI Classic screen; `Info.plist` registers `NexonPlug`.

**Tech Stack:** Swift 5, SwiftUI/AppKit, Foundation, CoreServices (`LSSetDefaultHandlerForURLScheme`), existing `/usr/bin/open` launch pattern, `./test.sh` CoreTests.

## Global Constraints

- Modern only (macOS 13+); do not change Legacy sources in this plan.
- No QR / Beanfun OTP for Classic; login URL is `https://maplestoryclassic.beanfun.com/Main`.
- Classic gameCode is `2982` (prefix before `@` in `game` query).
- Launch: `open -n <Maplestory_Classic.exe> --args` + split `passarg` tokens (Cyder as `.exe` handler).
- Forward other `NexonPlug` URLs to `/Library/Application Support/Nexon/Plug/NexonPlug.app` with full URL.
- Missing exe → immediate file picker; cancel discards pending passarg; success launches with this URL’s tokens.
- User-facing copy in Traditional Chinese.
- Spec: `docs/superpowers/specs/2026-07-24-maplestory-classic-integration-design.md`.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/NexonPlugURLParser.swift` | Parse `NexonPlug` URLs; Classic open argv helper |
| `Sources/Models.swift` | `GameAuthFlow`, Classic `GameDefinition`, `AppScreen.classic` |
| `Sources/AppModel.swift` | Classic select/UI actions, URL route, launch, forward, handler |
| `Sources/ContentView.swift` | Classic screen UI (standard + advanced) |
| `Sources/BeanfunOTPApp.swift` | Deliver opened URLs into `AppModel` |
| `Resources/Info.plist` | Register `NexonPlug` scheme |
| `Resources/GameImages/maplestory-classic.jpg` | Tile image (copy from `maplestory.jpg` placeholder) |
| `Tests/CoreTests.swift` | Parser + catalog + Classic open argv tests |
| `README.md` | Short Classic + NexonPlug handler note |

---

### Task 1: `NexonPlugURLParser` + unit tests

**Files:**
- Create: `Sources/NexonPlugURLParser.swift`
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes: `URL` with scheme `NexonPlug` / `nexonplug`
- Produces:
  - `struct NexonPlugURLParser.Parsed: Equatable { let gameCode: String; let obdTag: String?; let passargTokens: [String] }`
  - `static func parse(_ url: URL) -> Parsed?`
  - `static func isMapleStoryClassic(gameCode: String) -> Bool` → `gameCode == "2982"`
  - `static func classicOpenArguments(executablePath: String, passargTokens: [String]) -> [String]`

- [ ] **Step 1: Add failing tests to `Tests/CoreTests.swift`**

In `main()`, call two new tests after existing ones; bump the printed pass count.

```swift
try testNexonPlugURLParser()
try testClassicOpenArguments()
print("CoreTests: 11 tests passed")
```

Add:

```swift
private static func testNexonPlugURLParser() throws {
    let url = try require(
        URL(string: "nexonplug://?game=2982@2141&passarg=4554314%20sessabc%202373%20944"),
        "classic url"
    )
    let parsed = try require(NexonPlugURLParser.parse(url), "parse classic")
    try expect(parsed.gameCode == "2982", "gameCode")
    try expect(parsed.obdTag == "2141", "obdTag")
    try expect(
        parsed.passargTokens == ["4554314", "sessabc", "2373", "944"],
        "passarg tokens"
    )
    try expect(NexonPlugURLParser.isMapleStoryClassic(gameCode: parsed.gameCode), "is classic")

    let plus = try require(
        URL(string: "NexonPlug://?game=2982@1&passarg=a+b"),
        "plus url"
    )
    let plusParsed = try require(NexonPlugURLParser.parse(plus), "parse plus")
    try expect(plusParsed.passargTokens == ["a", "b"], "plus as space")

    let other = try require(URL(string: "nexonplug://?game=9999@1&passarg=x"), "other")
    let otherParsed = try require(NexonPlugURLParser.parse(other), "parse other")
    try expect(!NexonPlugURLParser.isMapleStoryClassic(gameCode: otherParsed.gameCode), "not classic")

    try expect(NexonPlugURLParser.parse(URL(string: "https://example.com")!) == nil, "wrong scheme")
    try expect(NexonPlugURLParser.parse(URL(string: "nexonplug://?passarg=x")!) == nil, "missing game")
}

private static func testClassicOpenArguments() throws {
    let args = NexonPlugURLParser.classicOpenArguments(
        executablePath: "/Games/Classic/Maplestory_Classic.exe",
        passargTokens: ["4554314", "sessabc", "2373", "944"]
    )
    try expect(args == [
        "-n",
        "/Games/Classic/Maplestory_Classic.exe",
        "--args",
        "4554314",
        "sessabc",
        "2373",
        "944",
    ], "classic open argv")
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `./test.sh`  
Expected: compile error / missing `NexonPlugURLParser`

- [ ] **Step 3: Implement `Sources/NexonPlugURLParser.swift`**

```swift
import Foundation

enum NexonPlugURLParser {
    struct Parsed: Equatable {
        let gameCode: String
        let obdTag: String?
        let passargTokens: [String]
    }

    static func isMapleStoryClassic(gameCode: String) -> Bool {
        gameCode == "2982"
    }

    static func parse(_ url: URL) -> Parsed? {
        guard let scheme = url.scheme?.lowercased(), scheme == "nexonplug" else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let game = value("game"), !game.isEmpty else { return nil }
        let parts = game.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let gameCode = String(parts[0])
        guard !gameCode.isEmpty else { return nil }
        let obdTag = parts.count > 1 ? String(parts[1]) : nil
        let rawPassarg = value("passarg") ?? ""
        let tokens = rawPassarg
            .split { $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
        return Parsed(gameCode: gameCode, obdTag: obdTag, passargTokens: tokens)
    }

    static func classicOpenArguments(executablePath: String, passargTokens: [String]) -> [String] {
        if passargTokens.isEmpty {
            return ["-n", executablePath]
        }
        return ["-n", executablePath, "--args"] + passargTokens
    }
}
```

Note: `URLComponents` decodes `%20` and typically treats `+` in query values as space depending on Foundation version; if `test` with `a+b` fails, normalize with `replacingOccurrences(of: "+", with: " ")` on the raw passarg string before splitting.

- [ ] **Step 4: Run tests — expect PASS**

Run: `./test.sh`  
Expected: `CoreTests: 11 tests passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/NexonPlugURLParser.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add NexonPlug URL parser and Classic open argv helper

EOF
)"
```

---

### Task 2: Classic game model + catalog

**Files:**
- Modify: `Sources/Models.swift`
- Modify: `Tests/CoreTests.swift` (`testMultiGameCatalog`)
- Create: `Resources/GameImages/maplestory-classic.jpg` (copy of `maplestory.jpg`)

**Interfaces:**
- Consumes: existing `GameDefinition` shape
- Produces:
  - `enum GameAuthFlow { case beanfunQR, webNexonPlug }`
  - `GameDefinition.authFlow: GameAuthFlow` (default `.beanfunQR` for all current games)
  - `GameDefinition.loginURL: URL?` (nil for QR games; Classic returns Main URL)
  - `GameDefinition.mapleStoryClassic` + include in `all` (first or after 新楓之谷)
  - `AppScreen.classic`

- [ ] **Step 1: Update catalog test to expect Classic**

In `testMultiGameCatalog`:

```swift
try expect(games.count == 10, "expected ten games including Classic")
try expect(games.contains { $0.id == "maplestory-classic" }, "Classic missing")
let classic = try require(games.first { $0.id == "maplestory-classic" }, "classic")
try expect(classic.authFlow == .webNexonPlug, "classic auth flow")
try expect(classic.executableName == "Maplestory_Classic.exe", "classic exe name")
try expect(
    classic.loginURL?.absoluteString == "https://maplestoryclassic.beanfun.com/Main",
    "classic login url"
)
```

- [ ] **Step 2: Run — expect FAIL** (missing `authFlow` / count)

Run: `./test.sh`

- [ ] **Step 3: Extend `Sources/Models.swift`**

Add:

```swift
enum GameAuthFlow: String, Hashable {
    case beanfunQR
    case webNexonPlug
}
```

Add to `GameDefinition`:

```swift
let authFlow: GameAuthFlow

var loginURL: URL? {
    switch authFlow {
    case .beanfunQR:
        return nil
    case .webNexonPlug:
        return URL(string: "https://maplestoryclassic.beanfun.com/Main")
    }
}

var usesBeanfunQR: Bool { authFlow == .beanfunQR }
```

Update every existing `GameDefinition(...)` initializer call to include `authFlow: .beanfunQR`.

Add Classic after `mapleStory` in `all`:

```swift
static let mapleStoryClassic = GameDefinition(
    id: "maplestory-classic",
    name: "楓之谷：經典版",
    serviceCode: "2982",
    serviceRegion: "CL",
    imageName: "maplestory-classic.jpg",
    executableName: "Maplestory_Classic.exe",
    launchStyle: .manual,
    accountFlow: .gameZone,
    authFlow: .webNexonPlug
)
```

Insert `mapleStoryClassic` into `all` immediately after `mapleStory`.

Extend:

```swift
enum AppScreen: Equatable {
    case games
    case welcome
    case qr
    case accounts
    case otp
    case classic
}
```

- [ ] **Step 4: Copy placeholder artwork**

```bash
cp Resources/GameImages/maplestory.jpg Resources/GameImages/maplestory-classic.jpg
```

- [ ] **Step 5: Run tests — expect PASS**

Run: `./test.sh`  
Expected: `CoreTests: 11 tests passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/Models.swift Tests/CoreTests.swift Resources/GameImages/maplestory-classic.jpg
git commit -m "$(cat <<'EOF'
feat: add MapleStory Classic game definition and auth flow

EOF
)"
```

---

### Task 3: `AppModel` Classic launch, forward, handler, URL entry

**Files:**
- Modify: `Sources/AppModel.swift`
- Modify: `Sources/BeanfunOTPApp.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: `NexonPlugURLParser`, `GameDefinition.mapleStoryClassic`
- Produces:
  - `func selectGame` → `.classic` when `authFlow == .webNexonPlug`
  - `func openClassicLoginPage()`
  - `func claimNexonPlugHandler()`
  - `func handleOpenedURL(_ url: URL)`
  - private pending `[String]?` for Classic passarg
  - `func launchClassic(passargTokens: [String])` via `/usr/bin/open`

- [ ] **Step 1: Register scheme in `Resources/Info.plist`**

Add inside the root dict (alongside existing keys):

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>NexonPlug</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>NexonPlug</string>
        </array>
    </dict>
</array>
```

- [ ] **Step 2: Wire URL delivery in `BeanfunOTPApp.swift`**

Use both `AppDelegate.application(_:open:)` (cold start) and `.onOpenURL` (warm). Add to `AppDelegate`:

```swift
var onOpenURLs: (([URL]) -> Void)?

func application(_ application: NSApplication, open urls: [URL]) {
    onOpenURLs?(urls)
}
```

In `BeanfunOTPApp`:

```swift
@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
@StateObject private var model = AppModel()

var body: some Scene {
    WindowGroup {
        ContentView(model: model)
            .onAppear {
                appDelegate.onOpenURLs = { urls in
                    urls.forEach { model.handleOpenedURL($0) }
                }
            }
            .onOpenURL { model.handleOpenedURL($0) }
    }
    // …keep existing window chrome and commands…
}
```
- [ ] **Step 3: Implement AppModel Classic behavior**

Add properties:

```swift
private var pendingClassicPassargTokens: [String]?
private static let officialNexonPlugAppPath =
    "/Library/Application Support/Nexon/Plug/NexonPlug.app"
private static let nexonPlugScheme = "NexonPlug"
private static let beanfunOTPBundleID = "local.ogom.beanfunotp"
```

Change `selectGame`:

```swift
func selectGame(_ game: GameDefinition) {
    // …existing cancel/reset…
    selectedGameID = game.id
    executablePath = defaults.string(forKey: executablePathKey(for: game)) ?? ""
    resetGameSession()
    if game.authFlow == .webNexonPlug {
        screen = .classic
        statusMessage = "已選擇\(game.name)。請選擇主程式並開啟登入網頁。"
        if mode == .standard, normalizedExecutablePath.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, self.selectedGameID == game.id else { return }
                self.chooseExecutable()
            }
        }
    } else {
        screen = .welcome
        statusMessage = "已選擇\(game.name)"
        // …existing standard empty-path picker…
    }
}
```

Ensure `startLogin()` rejects Classic:

```swift
guard game.usesBeanfunQR else {
    errorMessage = "楓之谷：經典版請使用網頁登入"
    screen = .classic
    return
}
```

Add:

```swift
func openClassicLoginPage() {
    guard let game = selectedGame, game.authFlow == .webNexonPlug,
          let url = game.loginURL else {
        errorMessage = "無法開啟登入網頁"
        return
    }
    NSWorkspace.shared.open(url)
    statusMessage = "已開啟\(game.name)登入網頁"
}

func claimNexonPlugHandler() {
    let status = LSSetDefaultHandlerForURLScheme(
        Self.nexonPlugScheme as NSString,
        Self.beanfunOTPBundleID as NSString
    )
    if status == noErr {
        statusMessage = "已將 NexonPlug 設為由 Beanfun OTP 處理"
    } else {
        errorMessage = "設定 NexonPlug 處理程式失敗（代碼 \(status)）"
    }
}

func handleOpenedURL(_ url: URL) {
    guard let parsed = NexonPlugURLParser.parse(url) else {
        // Ignore unrelated schemes silently or log.
        appendLog("忽略非 NexonPlug URL：\(url.absoluteString)")
        return
    }
    if NexonPlugURLParser.isMapleStoryClassic(gameCode: parsed.gameCode) {
        handleClassicNexonPlug(parsed)
    } else {
        forwardNexonPlug(url)
    }
}

private func handleClassicNexonPlug(_ parsed: NexonPlugURLParser.Parsed) {
    guard !parsed.passargTokens.isEmpty else {
        errorMessage = "NexonPlug 連結缺少 passarg，無法啟動經典版"
        selectGame(GameDefinition.mapleStoryClassic)
        return
    }
    selectGame(GameDefinition.mapleStoryClassic)
    if normalizedExecutablePath.isEmpty || !FileManager.default.fileExists(atPath: normalizedExecutablePath) {
        pendingClassicPassargTokens = parsed.passargTokens
        chooseExecutable()
        if normalizedExecutablePath.isEmpty {
            // chooseExecutable cancelled
            pendingClassicPassargTokens = nil
            statusMessage = "已取消"
            return
        }
    }
    let tokens = pendingClassicPassargTokens ?? parsed.passargTokens
    pendingClassicPassargTokens = nil
    launchClassic(passargTokens: tokens)
}

private func launchClassic(passargTokens: [String]) {
    let path = normalizedExecutablePath
    guard !path.isEmpty else {
        errorMessage = "請先選擇 Maplestory_Classic.exe"
        return
    }
    let process = Process()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = NexonPlugURLParser.classicOpenArguments(
        executablePath: path,
        passargTokens: passargTokens
    )
    process.standardError = standardError
    process.terminationHandler = { [weak self] process in
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            guard let self else { return }
            self.isBusy = false
            if process.terminationStatus == 0 {
                self.statusMessage = "已透過 Cyder 啟動楓之谷：經典版"
                self.appendLog("執行 open -n：classic executable=\(path) args=\(passargTokens.joined(separator: " "))")
            } else {
                let message = errorText.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "open 結束代碼 \(process.terminationStatus)"
                self.present(BeanfunError.rejected(message))
            }
        }
    }
    isBusy = true
    statusMessage = "正在以 open -n 透過 Cyder 啟動楓之谷：經典版…"
    do {
        try process.run()
    } catch {
        isBusy = false
        present(error)
    }
}

private func forwardNexonPlug(_ url: URL) {
    let plugPath = Self.officialNexonPlugAppPath
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: plugPath, isDirectory: &isDir) else {
        errorMessage = "找不到 NexonPlug.app，無法轉發其他遊戲的 NexonPlug 連結"
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", plugPath, url.absoluteString]
    do {
        try process.run()
        statusMessage = "已將 NexonPlug 連結轉發給官方 NexonPlug"
        appendLog("forward NexonPlug → \(plugPath): \(url.absoluteString)")
    } catch {
        present(error)
    }
}
```

Import `CoreServices` at top of `AppModel.swift` for `LSSetDefaultHandlerForURLScheme`.

Fix typo in status string: use「轉發給」not「转发给」if that slips in — Traditional Chinese「轉發給」.

Important: `chooseExecutable()` currently returns void and clears nothing on cancel. After `runModal`, if user cancels, `executablePath` unchanged. The flow above is correct if empty path remains empty.

Avoid calling `selectGame` recursively in a way that clears pending tokens — set `pendingClassicPassargTokens` **after** `selectGame`, or teach `selectGame` not to clear pending. Prefer:

```swift
private func handleClassicNexonPlug(_ parsed: NexonPlugURLParser.Parsed) {
    guard !parsed.passargTokens.isEmpty else { … }
    pendingClassicPassargTokens = parsed.passargTokens
    if selectedGameID != GameDefinition.mapleStoryClassic.id {
        selectGame(GameDefinition.mapleStoryClassic)
    } else {
        screen = .classic
        executablePath = defaults.string(forKey: executablePathKey(for: GameDefinition.mapleStoryClassic)) ?? ""
    }
    if normalizedExecutablePath.isEmpty {
        chooseExecutable()
    }
    guard !normalizedExecutablePath.isEmpty, let tokens = pendingClassicPassargTokens else {
        pendingClassicPassargTokens = nil
        if normalizedExecutablePath.isEmpty {
            statusMessage = "已取消"
        }
        return
    }
    pendingClassicPassargTokens = nil
    launchClassic(passargTokens: tokens)
}
```

And ensure `resetGameSession()` / `selectGame` do **not** clear `pendingClassicPassargTokens` (only clear on launch success/cancel as above).

- [ ] **Step 4: Build Modern app**

Run: `./build.sh`  
Expected: success, `dist/Beanfun OTP.app` updated.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppModel.swift Sources/BeanfunOTPApp.swift Resources/Info.plist
git commit -m "$(cat <<'EOF'
feat: handle NexonPlug URLs and launch MapleStory Classic

EOF
)"
```

---

### Task 4: Classic SwiftUI screen + README

**Files:**
- Modify: `Sources/ContentView.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `model.screen == .classic`, `openClassicLoginPage`, `claimNexonPlugHandler`, `chooseExecutable`
- Produces: Classic UI in standard + advanced layouts

- [ ] **Step 1: Add Classic views to `ContentView.swift`**

In `standardContent` and `advancedContent` switches, add:

```swift
case .classic:
    classicView
```

Hide「重新登入」on Classic (treat like games): update header condition so `.classic` does not show 重新登入 — e.g. only show when screen is `.qr` / `.accounts` / `.otp` / `.welcome`.

Implement:

```swift
private var classicView: some View {
    VStack(spacing: 14) {
        if let game = model.selectedGame {
            GameArtwork(game: game)
                .frame(width: 132, height: 88)
            Text(game.name)
                .font(.title2.bold())
        }
        Text("此遊戲使用網頁登入。登入後網站會開啟 NexonPlug://，由 Beanfun OTP 啟動遊戲。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        Text(model.executablePath.isEmpty ? "尚未選擇 Maplestory_Classic.exe" : model.executablePath)
            .font(.caption)
            .lineLimit(2)
            .multilineTextAlignment(.center)
        Button("選擇主程式…") { model.chooseExecutable() }
        Button {
            model.openClassicLoginPage()
        } label: {
            Label("開啟登入網頁", systemImage: "safari")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.isBusy)
        Button("將 NexonPlug 設為由 Beanfun OTP 處理") {
            model.claimNexonPlugHandler()
        }
        .buttonStyle(.link)
        if model.mode == .standard {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        Button("選擇其他遊戲") { model.showGamePicker() }
            .buttonStyle(.link)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(model.mode == .standard ? 0 : 0)
}
```

For advanced mode, wrap in `GroupBox` if other screens do; keep consistent spacing with `welcomeView`.

- [ ] **Step 2: README note**

In `README.md`「一般模式」or games list section, add a short paragraph:

```markdown
另支援**楓之谷：經典版**：無 QR。選擇 `Maplestory_Classic.exe` 後開啟官方登入網頁；網頁透過 `NexonPlug://` 回傳參數，App 以 `open -n … --args` 啟動（預設走 Cyder）。請在經典版畫面將 `NexonPlug` 設為由 Beanfun OTP 處理；其他 gameCode 會轉發官方 NexonPlug.app。測完可改回 `com.nexon.plug`。
```

- [ ] **Step 3: Run tests + build**

```bash
./test.sh
./build.sh
```

Expected: tests pass; app builds.

- [ ] **Step 4: Manual smoke (interactive)**

```bash
# After opening dist app once:
swift -e 'import Foundation; import CoreServices; print(LSSetDefaultHandlerForURLScheme("NexonPlug" as NSString, "local.ogom.beanfunotp" as NSString))'
open 'nexonplug://?game=2982@2141&passarg=a%20b%20c'
```

Expected: Classic UI / picker / `open` attempt (game may fail login with dummy args).

```bash
open 'nexonplug://?game=9999@1&passarg=x'
```

Expected: official NexonPlug opens (or clear error if missing).

- [ ] **Step 5: Commit**

```bash
git add Sources/ContentView.swift README.md
git commit -m "$(cat <<'EOF'
feat: add MapleStory Classic web-login UI

EOF
)"
```

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| Modern Classic game entry | 2 |
| No QR / web login URL | 2, 4 |
| Parse `game` / `passarg` | 1 |
| Route 2982 vs forward | 3 |
| `open -n … --args` | 1, 3 |
| Missing exe → picker → launch | 3 |
| Register `NexonPlug` | 3 |
| Claim handler button | 3, 4 |
| Classic UI | 4 |
| Unit tests for parse | 1 |
| Legacy unchanged | Global Constraints |
| README note | 4 |
