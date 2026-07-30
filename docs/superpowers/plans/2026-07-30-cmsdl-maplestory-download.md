# cmsdl MapleStory Download + Shared Disk Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download 新楓之谷 via pinned cmsdl `v0.2.5`, and gate both TMS and classic downloads on a three-tier free-space check from `--check --json`.

**Architecture:** Extract pure disk/JSON helpers; introduce `GameClientToolConfig` for nxdl vs cmsdl; generalize the existing PTY downloader to run any config; wire Modern/Legacy UI with a shared disk-gate flow before download.

**Tech Stack:** Swift 5, Foundation/AppKit, existing PTY + `NxdlProgressParser`, `./test.sh`, `./build-legacy.sh`, CommonCrypto SHA-256 (already used for nxdl).

## Global Constraints

- Modern **and** Legacy (Legacy minos **10.12+**).
- cmsdl pin: tag `v0.2.5`, binary `cmsdl_darwin`, SHA-256 `706efcf17608a807c884e1eb8e0c8b97084f67dfbec29f7664e9aba77d0a0b78`.
- nxdl pin unchanged (`v0.1.2-prerelease2`).
- Disk gate: `free ≥ total×1.05` → silent OK; `total+1GiB ≤ free < total×1.05` → warn +「仍要下載」; `free < total+1GiB` → hard block (1 GiB = `1024³`).
- CLI: cmsdl `tms --check --json` / `tms --download <dir>`; nxdl `tms_cw --check --json` / `tms_cw --download <dir>`.
- Size field: JSON `total_size` (bytes).
- One client download at a time app-wide.
- Prefer small focused changes; Conventional Commits.
- Verification: `./test.sh`; when Legacy files change also `./build-legacy.sh`.

## File Map

| File | Responsibility |
| --- | --- |
| `Sources/GameClientDiskGate.swift` | `ClientCheckJSONParser`, `DiskSpaceEvaluation`, `DiskSpaceGate.evaluate`, volume free-space helper |
| `Sources/NxdlDownloader.swift` | `GameClientToolConfig`, binary integrity per tool, probe + download pipeline parameterized by config; keep classic API wrappers |
| `Sources/AppModel.swift` | Shared disk-gate UI helpers; `downloadMapleStoryClient`; classic path uses gate |
| `Sources/ContentView.swift` | MapleStory download button on welcome / exe area; progress sheet for either download |
| `Legacy/Sources/AppController.swift` | MapleStory download button + disk gate; classic gate |
| `build-legacy.sh` | Compile new `GameClientDiskGate.swift` (+ existing Nxdl) |
| `test.sh` | Compile `GameClientDiskGate.swift` |
| `Tests/CoreTests.swift` | Disk tiers, JSON parse, cmsdl SHA constant |
| `docs/cmsdl-maplestory-download.md` | Maintainer doc |
| `docs/nxdl-classic-download.md` | Disk-gate section |
| `docs/macos-player-guide.md` / `README.md` | Player-facing links |

**Spec:** `docs/superpowers/specs/2026-07-30-cmsdl-maplestory-download-design.md`

---

### Task 1: Disk gate + check JSON parser (TDD)

**Files:**
- Create: `Sources/GameClientDiskGate.swift`
- Modify: `Tests/CoreTests.swift`
- Modify: `test.sh` (add source to compile list)

**Interfaces:**
- Produces:
  - `enum DiskSpaceVerdict: Equatable { case ok; case warn; case blocked }`
  - `struct DiskSpaceEvaluation: Equatable { let verdict: DiskSpaceVerdict; let totalBytes: UInt64; let freeBytes: UInt64; let comfortableBytes: UInt64; let minimumBytes: UInt64 }`
  - `enum DiskSpaceGate { static func evaluate(totalBytes: UInt64, freeBytes: UInt64) -> DiskSpaceEvaluation }`
  - `enum ClientCheckJSONParser { static func totalSizeBytes(fromJSONText text: String) throws -> UInt64 }`
  - Errors: `ClientCheckError.invalidJSON`, `.missingTotalSize` (as `LocalizedError` or nested enum)

- [ ] **Step 1: Write failing tests**

In `CoreTests.main()`, after existing nxdl tests, add:

```swift
try testDiskSpaceGate()
try testClientCheckJSONParser()
```

Bump printed count by +2 (currently 25 → 27).

**For `total = 10 GiB`:** `comfortable = 10.5 GiB`, `minimum = 11 GiB` (warning band empty).  
**For `total = 50 GiB`:** `comfortable = 52.5 GiB`, `minimum = 51 GiB`.

```swift
private static func testDiskSpaceGate() throws {
    let gib: UInt64 = 1_024 * 1_024 * 1_024

    try expect(
        DiskSpaceGate.evaluate(totalBytes: 10 * gib, freeBytes: 12 * gib).verdict == .ok,
        "small plenty → ok"
    )
    try expect(
        DiskSpaceGate.evaluate(totalBytes: 10 * gib, freeBytes: 11 * gib).verdict == .ok,
        "small at +1GiB still ≥ 1.05 → ok"
    )
    try expect(
        DiskSpaceGate.evaluate(totalBytes: 10 * gib, freeBytes: UInt64(10.7 * Double(gib))).verdict == .blocked,
        "small between 1.05 and +1GiB → blocked"
    )

    let largeTotal: UInt64 = 50 * gib
    try expect(
        DiskSpaceGate.evaluate(totalBytes: largeTotal, freeBytes: 53 * gib).verdict == .ok,
        "large comfortable → ok"
    )
    let warn = DiskSpaceGate.evaluate(totalBytes: largeTotal, freeBytes: 52 * gib)
    try expect(warn.verdict == .warn, "large mid band → warn")
    try expect(warn.minimumBytes == largeTotal + gib, "minimum = total + 1GiB")
    try expect(
        DiskSpaceGate.evaluate(totalBytes: largeTotal, freeBytes: 50 * gib + gib / 2).verdict == .blocked,
        "large below minimum → blocked"
    )
}

private static func testClientCheckJSONParser() throws {
    let cmsdl = #"{"region":"tms","build":0,"version":"V280","files":10,"total_size":13245678901}"#
    try expect(try ClientCheckJSONParser.totalSizeBytes(fromJSONText: cmsdl) == 13_245_678_901, "cmsdl total")

    let nxdl = #"{"appid":"2982@2141","game_name":"x","files_to_download":168,"total_size":2962637533}"#
    try expect(try ClientCheckJSONParser.totalSizeBytes(fromJSONText: nxdl) == 2_962_637_533, "nxdl total")

    do {
        _ = try ClientCheckJSONParser.totalSizeBytes(fromJSONText: #"{"files":1}"#)
        throw TestFailure(message: "missing total_size should throw")
    } catch is ClientCheckError {
        // ok
    } catch let error as TestFailure {
        throw error
    } catch {
        throw TestFailure(message: "unexpected error \(error)")
    }
}
```

- [ ] **Step 2: Run tests — expect fail**

Run: `./test.sh 2>&1 | tail -20`  
Expected: compile error `DiskSpaceGate` / `ClientCheckJSONParser` not found.

- [ ] **Step 3: Implement `Sources/GameClientDiskGate.swift`**

```swift
import Foundation

enum ClientCheckError: LocalizedError {
    case invalidJSON
    case missingTotalSize

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "無法解析客戶端大小資訊（JSON 無效）"
        case .missingTotalSize: return "無法解析客戶端大小資訊（缺少 total_size）"
        }
    }
}

enum ClientCheckJSONParser {
    static func totalSizeBytes(fromJSONText text: String) throws -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClientCheckError.invalidJSON
        }
        if let n = obj["total_size"] as? NSNumber {
            let v = n.uint64Value
            return v
        }
        if let i = obj["total_size"] as? Int, i >= 0 {
            return UInt64(i)
        }
        throw ClientCheckError.missingTotalSize
    }
}

enum DiskSpaceVerdict: Equatable {
    case ok
    case warn
    case blocked
}

struct DiskSpaceEvaluation: Equatable {
    let verdict: DiskSpaceVerdict
    let totalBytes: UInt64
    let freeBytes: UInt64
    let comfortableBytes: UInt64
    let minimumBytes: UInt64
}

enum DiskSpaceGate {
    static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

    static func evaluate(totalBytes: UInt64, freeBytes: UInt64) -> DiskSpaceEvaluation {
        let comfortable = UInt64(Double(totalBytes) * 1.05)
        let minimum = totalBytes + gibibyte
        let verdict: DiskSpaceVerdict
        if freeBytes >= comfortable {
            verdict = .ok
        } else if freeBytes >= minimum {
            verdict = .warn
        } else {
            verdict = .blocked
        }
        return DiskSpaceEvaluation(
            verdict: verdict,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            comfortableBytes: comfortable,
            minimumBytes: minimum
        )
    }
}

enum VolumeFreeSpace {
    /// Returns free bytes on the volume containing `url`, or throws if unavailable.
    static func freeBytes(forDirectory url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
            return UInt64(important)
        }
        if let capacity = values.volumeAvailableCapacity, capacity >= 0 {
            return UInt64(capacity)
        }
        // macOS 10.12 fallback
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let free = attrs[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        throw ClientCheckError.invalidJSON // replace with dedicated error in same file:
    }
}
```

Use a dedicated error instead of reusing `invalidJSON`:

```swift
enum VolumeFreeSpaceError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case let .unavailable(path):
            return "無法讀取磁碟剩餘空間：\(path)"
        }
    }
}
```

Note: `volumeAvailableCapacityForImportantUsageKey` needs `@available` / runtime check on 10.12. Prefer:

```swift
static func freeBytes(forDirectory url: URL) throws -> UInt64 {
    if #available(macOS 10.13, *) {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
    }
    let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    if let capacity = values.volumeAvailableCapacity, capacity > 0 {
        return UInt64(capacity)
    }
    let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
    guard let free = attrs[.systemFreeSize] as? NSNumber else {
        throw VolumeFreeSpaceError.unavailable(url.path)
    }
    return free.uint64Value
}
```

Add human-readable helper used by alerts later:

```swift
enum ByteCountFormat {
    static func string(bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
```

- [ ] **Step 4: Wire `test.sh`**

Add `"$project_dir/Sources/GameClientDiskGate.swift"` to the `swiftc` source list (before or after `NxdlDownloader.swift`).

- [ ] **Step 5: Run tests — expect pass**

Run: `./test.sh 2>&1 | rg 'CoreTests|error:'`  
Expected: `CoreTests: 27 tests passed`

- [ ] **Step 6: Commit**

```bash
git add Sources/GameClientDiskGate.swift Tests/CoreTests.swift test.sh
git commit -m "$(cat <<'EOF'
feat: add disk space gate and client check JSON parser

EOF
)"
```

---

### Task 2: `GameClientToolConfig` + cmsdl integrity constants

**Files:**
- Modify: `Sources/NxdlDownloader.swift` (top-level config + integrity)
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Produces:
  - `struct GameClientToolConfig` with `nxdlClassic` and `cmsdlMapleStory` statics
  - `NxdlBinaryIntegrity` generalized **or** `GameClientBinaryIntegrity.expectedSHA256Hex(for:)` — prefer extending with cmsdl constant `CmsdlBinaryIntegrity.expectedSHA256Hex`

- [ ] **Step 1: Failing test for cmsdl SHA**

```swift
try testCmsdlBinaryPin()
```

```swift
private static func testCmsdlBinaryPin() throws {
    try expect(
        GameClientToolConfig.cmsdlMapleStory.releaseTag == "v0.2.5",
        "cmsdl tag"
    )
    try expect(
        GameClientToolConfig.cmsdlMapleStory.sha256Hex
            == "706efcf17608a807c884e1eb8e0c8b97084f67dfbec29f7664e9aba77d0a0b78",
        "cmsdl sha"
    )
    try expect(
        GameClientToolConfig.cmsdlMapleStory.gameAlias == "tms",
        "cmsdl alias"
    )
    try expect(
        GameClientToolConfig.cmsdlMapleStory.primaryExecutableName == "MapleStory.exe",
        "cmsdl exe"
    )
}
```

Bump test count 27 → 28.

- [ ] **Step 2: Run — expect fail** (`GameClientToolConfig` missing)

- [ ] **Step 3: Add config to `NxdlDownloader.swift` (near top, after imports)**

```swift
struct GameClientToolConfig: Equatable {
    let releaseTag: String
    let binaryRemoteURL: URL
    let sha256Hex: String
    let cacheFolderName: String
    let binaryFileName: String
    let gameAlias: String
    let primaryExecutableName: String

    var checkArguments: [String] { [gameAlias, "--check", "--json"] }

    func downloadArguments(destinationPath: String) -> [String] {
        [gameAlias, "--download", destinationPath]
    }

    static let nxdlClassic = GameClientToolConfig(
        releaseTag: NxdlDownloader.releaseTag,
        binaryRemoteURL: NxdlDownloader.binaryRemoteURL,
        sha256Hex: NxdlBinaryIntegrity.expectedSHA256Hex,
        cacheFolderName: "nxdl",
        binaryFileName: "nxdl_darwin",
        gameAlias: NxdlDownloader.gameAlias,
        primaryExecutableName: NxdlDownloader.classicExecutableName
    )

    static let cmsdlMapleStory = GameClientToolConfig(
        releaseTag: "v0.2.5",
        binaryRemoteURL: URL(
            string: "https://github.com/HikariCalyx/cmsdl/releases/download/v0.2.5/cmsdl_darwin"
        )!,
        sha256Hex: "706efcf17608a807c884e1eb8e0c8b97084f67dfbec29f7664e9aba77d0a0b78",
        cacheFolderName: "cmsdl",
        binaryFileName: "cmsdl_darwin",
        gameAlias: "tms",
        primaryExecutableName: "MapleStory.exe"
    )
}
```

Refactor `NxdlBinaryIntegrity.verifyFile` to accept expected hex parameter (defaulting to nxdl constant) **or** add:

```swift
enum GameClientBinaryIntegrity {
    static func verifyFile(at path: String, expectedSHA256Hex: String) throws { ... }
}
```

Keep existing `NxdlBinaryIntegrity.verifyFile(at:)` calling through with nxdl hex so classic tests still pass.

- [ ] **Step 4: Run tests — pass**

- [ ] **Step 5: Commit**

```bash
git add Sources/NxdlDownloader.swift Tests/CoreTests.swift
git commit -m "$(cat <<'EOF'
feat: add GameClientToolConfig for nxdl and cmsdl pins

EOF
)"
```

---

### Task 3: Parameterize downloader — probe size + config-aware ensure/download

**Files:**
- Modify: `Sources/NxdlDownloader.swift`

**Interfaces:**
- Consumes: `GameClientToolConfig`, `ClientCheckJSONParser`, existing PTY download
- Produces:
  - `func probeTotalSize(config:onUpdate:completion:)` → `Result<UInt64, Error>`
  - `func downloadClient(config:to:onUpdate:completion:)` (generalized pipeline)
  - `downloadClassicClient` → calls `downloadClient(config: .nxdlClassic, …)` **without** disk gate yet (gate is UI-layer in Task 4)
  - `downloadMapleStoryClient(to:onUpdate:completion:)` → `downloadClient(config: .cmsdlMapleStory, …)`
  - `findExecutable(named:in:)` or config-driven find
  - `supportDirectory(for:)` / `binaryURL(for:)` per cache folder

- [ ] **Step 1: Refactor paths to be config-based**

Replace single `supportDirectory` / `binaryURL` usage in ensure/download with:

```swift
func supportDirectory(for config: GameClientToolConfig) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
    return base
        .appendingPathComponent(Self.applicationSupportFolderName, isDirectory: true)
        .appendingPathComponent(config.cacheFolderName, isDirectory: true)
}

func binaryURL(for config: GameClientToolConfig) -> URL {
    supportDirectory(for: config).appendingPathComponent(config.binaryFileName)
}
```

Keep computed `supportDirectory` / `binaryURL` as nxdlClassic shortcuts if other code uses them.

- [ ] **Step 2: Generalize `ensureBinary` to take `config` and verify `config.sha256Hex`**

- [ ] **Step 3: Implement `probeTotalSize`**

Run process **without** PTY (pipe is fine): `launchPath = binary`, `arguments = config.checkArguments`, `currentDirectory = supportDirectory(for:)`, capture stdout, strip ANSI, find JSON object line (or whole stdout), parse `total_size`.

On non-zero exit → `NxdlDownloaderError.processFailed`. Prefer reusing / renaming error type later; for now keep `NxdlDownloaderError` messages generic enough ("無法取得客戶端大小…") or add `case checkFailed(String)`.

- [ ] **Step 4: Generalize `runDownload` arguments to `config.downloadArguments(destinationPath:)` and binary from config**

- [ ] **Step 5: `findClassicExecutable` → also `findPrimaryExecutable(config:in:)` using `config.primaryExecutableName`**

- [ ] **Step 6: Wire wrappers**

```swift
func downloadClassicClient(...) {
    downloadClient(config: .nxdlClassic, to: destination, onUpdate: onUpdate, completion: completion)
}
func downloadMapleStoryClient(...) {
    downloadClient(config: .cmsdlMapleStory, to: destination, onUpdate: onUpdate, completion: completion)
}
```

- [ ] **Step 7: Run `./test.sh` and `./build-legacy.sh` (after adding GameClientDiskGate to legacy sources in Task 1 or now)**

Update `build-legacy.sh`:

```bash
sources=("$source_dir"/*.swift \
  "$project_dir/Sources/NxdlDownloader.swift" \
  "$project_dir/Sources/GameClientDiskGate.swift")
```

Expected: tests pass; Legacy builds; minos 10.12.

- [ ] **Step 8: Commit**

```bash
git add Sources/NxdlDownloader.swift build-legacy.sh
git commit -m "$(cat <<'EOF'
feat: parameterize client downloader for cmsdl and size probe

EOF
)"
```

---

### Task 4: AppModel — disk gate + MapleStory download (Modern)

**Files:**
- Modify: `Sources/AppModel.swift`
- Modify: `Sources/ContentView.swift`

**Interfaces:**
- Consumes: `probeTotalSize`, `VolumeFreeSpace`, `DiskSpaceGate`, `downloadMapleStoryClient` / `downloadClassicClient`
- Produces:
  - `isDownloadingGameClient` (or reuse `isDownloadingClassicClient` renamed to cover both — prefer rename to `isDownloadingGameClient` with `private(set)` and update UI bindings)
  - `func downloadMapleStoryClient()`
  - Classic `downloadClassicClient()` inserts gate before download
  - Shared private `func confirmDiskGate(evaluation:) async -> Bool` / callback variant using `NSAlert`

- [ ] **Step 1: Rename busy flag carefully**

Replace `isDownloadingClassicClient` with `isDownloadingGameClient` everywhere in AppModel + ContentView (sheet `interactiveDismissDisabled`, button disables). Keep progress publishers (`classicDownloadProgress` ok to keep names per spec non-goal on rename).

- [ ] **Step 2: Shared gate helper (MainActor)**

```swift
private func presentDiskGate(evaluation: DiskSpaceEvaluation) -> Bool {
    let needed = ByteCountFormat.string(bytes: evaluation.totalBytes)
    let free = ByteCountFormat.string(bytes: evaluation.freeBytes)
    let minimum = ByteCountFormat.string(bytes: evaluation.minimumBytes)
    switch evaluation.verdict {
    case .ok:
        return true
    case .blocked:
        let alert = NSAlert()
        alert.messageText = "磁碟空間不足"
        alert.informativeText =
            "下載約需 \(needed)，目的地磁碟剩餘 \(free)。\n至少需要 \(minimum)（總量 + 1 GB）才能下載。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "確定")
        alert.runModal()
        return false
    case .warn:
        let alert = NSAlert()
        alert.messageText = "磁碟空間偏低"
        alert.informativeText =
            "下載約需 \(needed)，目的地磁碟剩餘 \(free)。\n建議至少保留約 \(ByteCountFormat.string(bytes: evaluation.comfortableBytes))（總量的 105%）。仍要繼續嗎？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "仍要下載")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
```

- [ ] **Step 3: Classic download flow**

After panel OK, before setting busy/download:

```swift
// ensure tool + probe (can show brief status)
// ensureBinary + probeTotalSize (async wrappers on downloader)
let total = try await self.nxdlDownloader.probeTotalSize(config: .nxdlClassic) { _ in } 
let free = try VolumeFreeSpace.freeBytes(forDirectory: destination)
let evaluation = DiskSpaceGate.evaluate(totalBytes: total, freeBytes: free)
guard presentDiskGate(evaluation: evaluation) else { return }
// then existing download task
```

Because Modern uses async Task, implement callback-based probe via continuation, or add async wrappers on downloader for probe.

Order per spec:

```text
ensureBinary → --check --json → free space → gate → download
```

Show progress sheet only when download actually starts (after gate), or show sheet earlier with "正在檢查大小…" — prefer: status message without sheet until download begins; on warn alert runs modally first.

- [ ] **Step 4: `downloadMapleStoryClient()`**

Mirror classic: guard `selectedGame?.id == GameDefinition.mapleStory.id`, folder panel, gate, `downloadMapleStoryClient`, on success `findPrimaryExecutable` → `executablePath`.

- [ ] **Step 5: ContentView UI**

In `welcomeView` (and/or `ExecutablePickerSection` if that is shared): add button

```swift
if model.selectedGame?.id == GameDefinition.mapleStory.id {
    Button {
        model.downloadMapleStoryClient()
    } label: {
        Label("下載新楓之谷客戶端", systemImage: "arrow.down.circle")
    }
    .disabled(model.isDownloadingGameClient || model.isBusy)
}
```

Bind progress sheet to `isDownloadingGameClient` / `showClassicDownloadProgress` (reuse sheet for both; set `showClassicDownloadProgress = true` for either).

- [ ] **Step 6: Build Modern**

Run: `./build.sh` (ad-hoc OK)  
Expected: success.

- [ ] **Step 7: Commit**

```bash
git add Sources/AppModel.swift Sources/ContentView.swift
git commit -m "$(cat <<'EOF'
feat: add MapleStory download and disk gate in Modern UI

EOF
)"
```

---

### Task 5: Legacy AppController — MapleStory button + disk gate

**Files:**
- Modify: `Legacy/Sources/AppController.swift`
- Modify: `build-legacy.sh` (if not already updated)

**Interfaces:**
- Same downloader APIs (callback style only)
- `NSAlert` for gate (same copy as Modern)

- [ ] **Step 1: Add `downloadMapleStoryButton`**

Title: 「下載新楓之谷客戶端」. Place on welcome / exe area when `selectedGame` is MapleStory (non-classic). Hide on classic screen (classic keeps its own button).

- [ ] **Step 2: Shared Legacy gate method**

Duplicate `presentDiskGate` logic from Modern (Legacy cannot share AppModel).

- [ ] **Step 3: Refactor `handleDownloadClassic`**

After destination chosen:

```swift
nxdlDownloader.ensure… // or expose probe that ensures binary internally
// Implement probe on downloader that calls ensureBinary then check
nxdlDownloader.probeTotalSize(config: .nxdlClassic, onUpdate: { … }) { result in
  DispatchQueue.main.async {
    switch result {
    case .failure(let e): showError(e)
    case .success(let total):
      do {
        let free = try VolumeFreeSpace.freeBytes(forDirectory: destination)
        let evaluation = DiskSpaceGate.evaluate(totalBytes: total, freeBytes: free)
        guard self.presentDiskGate(evaluation: evaluation) else {
          self.finishClassicDownload() // or never started
          return
        }
        self.startClassicDownload(to: destination)
      } catch { self.showError(error) }
    }
  }
}
```

Factor actual PTY download into `startClassicDownload`.

- [ ] **Step 4: `handleDownloadMapleStory`** — same pattern with `.cmsdlMapleStory` and progress window title 「下載新楓之谷」 (pass title into progress window initializer if needed; else keep generic title).

If `ClassicDownloadProgressWindowController` hardcodes classic title, add `title:` parameter defaulting to classic string.

- [ ] **Step 5: One-at-a-time**

`isDownloadingClassicClient` → `isDownloadingGameClient`; disable both download buttons while true.

- [ ] **Step 6: Build**

Run: `./build-legacy.sh`  
Expected: Built; `minos` / version 10.12.

- [ ] **Step 7: Commit**

```bash
git add Legacy/Sources/AppController.swift Legacy/Sources/ClassicDownloadProgressWindow.swift build-legacy.sh
git commit -m "$(cat <<'EOF'
feat: add MapleStory download and disk gate in Legacy UI

EOF
)"
```

---

### Task 6: Documentation

**Files:**
- Create: `docs/cmsdl-maplestory-download.md`
- Modify: `docs/nxdl-classic-download.md`
- Modify: `docs/macos-player-guide.md`
- Modify: `README.md`

- [ ] **Step 1: Write `docs/cmsdl-maplestory-download.md`**

Include: pin table (tag, SHA, alias `tms`, exe), CLI check/download, disk gate table, path restore note, App flow, related files list (mirror nxdl doc structure).

- [ ] **Step 2: Add disk-gate section to `docs/nxdl-classic-download.md`**

Same three-tier rules; command `nxdl_darwin tms_cw --check --json`.

- [ ] **Step 3: Player guide + README**

`macos-player-guide.md`: note App can download client via cmsdl; link maintainer doc.  
`README.md`: short mention + link next to classic nxdl blurb.

- [ ] **Step 4: Commit**

```bash
git add docs/cmsdl-maplestory-download.md docs/nxdl-classic-download.md docs/macos-player-guide.md README.md
git commit -m "$(cat <<'EOF'
docs: document cmsdl MapleStory download and disk gates

EOF
)"
```

---

### Task 7: Final verification

- [ ] **Step 1: Run full checks**

```bash
./test.sh
./build.sh
./build-legacy.sh
```

Expected: tests pass; both apps build; Legacy minos 10.12.

- [ ] **Step 2: Manual smoke (if network allowed)**

1. MapleStory → 下載 → choose folder with huge free space → confirm check runs then progress.  
2. Simulate block: not required if unit tests cover math; optional.  
3. Classic download still gates then progresses.

- [ ] **Step 3: Fix any failures; commit if needed**

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| cmsdl v0.2.5 + SHA | 2 |
| `tms --download` / Modern+Legacy UI | 3, 4, 5 |
| `--check --json` + `total_size` | 1, 3 |
| Three-tier disk gate (+1 GiB block, ×1.05 silent) | 1, 4, 5 |
| Classic also gated | 4, 5 |
| PTY progress reuse | 3 (existing), 4–5 UI |
| Path normalize + find exe | 3 |
| Separate cache dirs | 2–3 |
| Docs | 6 |
| Tests | 1, 2, 7 |
| Legacy 10.12 | 1 (`#available`), 5, 7 |

## Placeholder / consistency review

- No TBD steps; JSON key consistently `total_size`.
- Button label fixed as 「下載新楓之谷客戶端」.
- Busy flag rename `isDownloadingGameClient` called out in Tasks 4–5.
- `probeTotalSize` must ensure binary first (same as download).
