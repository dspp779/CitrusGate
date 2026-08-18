# GGM Manifest Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the baked-in MapleStory GGM `CV`/`Hash` constants with a startup-refreshed manifest that updates from a fixed GitHub raw URL, caches locally, and keeps OTP working offline.

**Architecture:** Add a small manifest domain model plus a local store and startup updater. `BeanfunClient` should only read the active in-memory manifest, while app startup owns fallback loading, cache loading, conditional HTTP refresh, and cache persistence.

**Tech Stack:** Swift 5, AppKit, Foundation `URLSession`, local JSON files in Application Support, existing `CoreTests` executable test harness.

## Global Constraints

- Do not add new dependencies.
- Keep the built-in manifest as a fallback only; never overwrite bundle resources at runtime.
- Use a fixed raw GitHub URL, not `latest` release parsing.
- Use `ETag` as the primary validator and `Last-Modified` as secondary.
- OTP retrieval must not block on manifest network fetches.
- MapleStory native otp_v2 must read `CV` and `Hash` from the active manifest.
- Manifest update failures must never break app launch or OTP retrieval.

---

### Task 1: Add Manifest Model And Tests

**Files:**
- Create: `Sources/GGMManifest.swift`
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes: none
- Produces:
  - `struct GGMManifest: Codable, Equatable`
  - `struct GGMManifest.MapleStoryConfig: Codable, Equatable`
  - `static func fallback() -> GGMManifest`
  - `var isValid: Bool { get }`
  - `func isNewer(than other: GGMManifest) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
private static func testGGMManifestValidationAndOrdering() throws {
    let fallback = GGMManifest.fallback()
    try expect(fallback.isValid, "fallback manifest must be valid")
    try expect(
        fallback.mapleStory.ggmWebStartDllSha256.count == 64,
        "fallback hash must be 64 hex chars"
    )

    let newer = GGMManifest(
        schemaVersion: 1,
        updatedAt: "2026-08-19T00:00:00Z",
        mapleStory: .init(
            ggmClientVersion: "1.5.0.3",
            ggmWebStartDllSha256: String(repeating: "a", count: 64)
        )
    )
    try expect(newer.isValid, "newer manifest should validate")
    try expect(newer.isNewer(than: fallback), "newer manifest ordering")

    let invalid = GGMManifest(
        schemaVersion: 1,
        updatedAt: "not-a-date",
        mapleStory: .init(
            ggmClientVersion: "",
            ggmWebStartDllSha256: "xyz"
        )
    )
    try expect(invalid.isValid == false, "invalid manifest should fail validation")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`
Expected: FAIL because `GGMManifest` and `testGGMManifestValidationAndOrdering()` do not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct GGMManifest: Codable, Equatable {
    struct MapleStoryConfig: Codable, Equatable {
        let ggmClientVersion: String
        let ggmWebStartDllSha256: String
    }

    let schemaVersion: Int
    let updatedAt: String
    let mapleStory: MapleStoryConfig

    static func fallback() -> GGMManifest {
        GGMManifest(
            schemaVersion: 1,
            updatedAt: "2026-08-18T00:00:00Z",
            mapleStory: .init(
                ggmClientVersion: "1.5.0.2",
                ggmWebStartDllSha256: "dfd568a69d87abcd8f4a93d1a4481ebb57712d1d28ab0b6fc018fcf140101e06"
            )
        )
    }

    var isValid: Bool {
        schemaVersion == 1
            && ISO8601DateFormatter().date(from: updatedAt) != nil
            && !mapleStory.ggmClientVersion.isEmpty
            && mapleStory.ggmWebStartDllSha256.count == 64
            && mapleStory.ggmWebStartDllSha256.allSatisfy(\.isHexDigit)
    }

    func isNewer(than other: GGMManifest) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let lhs = formatter.date(from: updatedAt),
              let rhs = formatter.date(from: other.updatedAt) else { return false }
        return lhs > rhs
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test.sh`
Expected: PASS, including the new manifest validation test.

- [ ] **Step 5: Commit**

```bash
git add Sources/GGMManifest.swift Tests/CoreTests.swift
git commit -m "feat: add GGM manifest model"
```

### Task 2: Add Manifest Store For Bundle Fallback And Local Cache

**Files:**
- Create: `Sources/GGMManifestStore.swift`
- Create: `Resources/ggm-manifest.json`
- Modify: `build.sh`
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes:
  - `GGMManifest`
- Produces:
  - `struct GGMManifestCacheMetadata: Codable, Equatable`
  - `final class GGMManifestStore`
  - `func loadFallbackManifest() throws -> GGMManifest`
  - `func loadCachedManifest() throws -> GGMManifest?`
  - `func loadCachedMetadata() throws -> GGMManifestCacheMetadata?`
  - `func saveCachedManifest(_ manifest: GGMManifest, metadata: GGMManifestCacheMetadata) throws`
  - `func appSupportDirectory() throws -> URL`

- [ ] **Step 1: Write the failing test**

```swift
private static func testGGMManifestStoreRoundTrip() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let store = GGMManifestStore(
        fallbackManifestLoader: { .fallback() },
        appSupportRoot: root
    )
    try expect(try store.loadCachedManifest() == nil, "cache starts empty")

    let manifest = GGMManifest(
        schemaVersion: 1,
        updatedAt: "2026-08-19T00:00:00Z",
        mapleStory: .init(
            ggmClientVersion: "1.5.0.3",
            ggmWebStartDllSha256: String(repeating: "b", count: 64)
        )
    )
    let metadata = GGMManifestCacheMetadata(
        etag: "\"etag-1\"",
        lastModified: "Tue, 18 Aug 2026 09:20:00 GMT",
        fetchedAt: "2026-08-18T17:30:00Z"
    )
    try store.saveCachedManifest(manifest, metadata: metadata)

    try expect(try store.loadCachedManifest() == manifest, "manifest cache round-trip")
    try expect(try store.loadCachedMetadata() == metadata, "metadata cache round-trip")
    try expect(try store.loadFallbackManifest().isValid, "fallback manifest should load")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`
Expected: FAIL because `GGMManifestStore` and `GGMManifestCacheMetadata` do not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct GGMManifestCacheMetadata: Codable, Equatable {
    let etag: String?
    let lastModified: String?
    let fetchedAt: String
}

final class GGMManifestStore {
    private let fallbackManifestLoader: () throws -> GGMManifest
    private let appSupportRoot: URL

    init(
        fallbackManifestLoader: @escaping () throws -> GGMManifest,
        appSupportRoot: URL
    ) {
        self.fallbackManifestLoader = fallbackManifestLoader
        self.appSupportRoot = appSupportRoot
    }

    func loadFallbackManifest() throws -> GGMManifest {
        try fallbackManifestLoader()
    }

    func appSupportDirectory() throws -> URL {
        let dir = appSupportRoot.appendingPathComponent("Beanfun OTP", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func loadCachedManifest() throws -> GGMManifest? {
        let url = try appSupportDirectory().appendingPathComponent("ggm-manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GGMManifest.self, from: data)
    }

    func loadCachedMetadata() throws -> GGMManifestCacheMetadata? {
        let url = try appSupportDirectory().appendingPathComponent("ggm-manifest.metadata.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GGMManifestCacheMetadata.self, from: data)
    }

    func saveCachedManifest(_ manifest: GGMManifest, metadata: GGMManifestCacheMetadata) throws {
        let dir = try appSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("ggm-manifest.json"))
        try encoder.encode(metadata).write(to: dir.appendingPathComponent("ggm-manifest.metadata.json"))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test.sh`
Expected: PASS, including cache round-trip coverage.

- [ ] **Step 5: Commit**

```bash
git add Sources/GGMManifestStore.swift Resources/ggm-manifest.json build.sh Tests/CoreTests.swift
git commit -m "feat: add GGM manifest cache store"
```

### Task 3: Add Conditional Remote Updater

**Files:**
- Create: `Sources/GGMManifestUpdater.swift`
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes:
  - `GGMManifest`
  - `GGMManifestStore`
  - `GGMManifestCacheMetadata`
- Produces:
  - `enum GGMManifestUpdateResult`
  - `final class GGMManifestUpdater`
  - `func refreshIfNeeded(current: GGMManifest) async -> GGMManifest`

- [ ] **Step 1: Write the failing test**

```swift
private static func testGGMManifestUpdaterUsesETag304AndNewer200() async throws {
    final class URLProtocolStub: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (response, data) = try Self.handler?(request) ?? {
                    throw URLError(.badServerResponse)
                }()
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`
Expected: FAIL because `GGMManifestUpdater` does not exist and the async updater path is unimplemented.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum GGMManifestUpdateResult {
    case notModified
    case updated(GGMManifest)
    case ignored
}

final class GGMManifestUpdater {
    private let manifestURL: URL
    private let session: URLSession
    private let store: GGMManifestStore
    private let log: (String) -> Void

    init(manifestURL: URL, session: URLSession, store: GGMManifestStore, log: @escaping (String) -> Void) {
        self.manifestURL = manifestURL
        self.session = session
        self.store = store
        self.log = log
    }

    func refreshIfNeeded(current: GGMManifest) async -> GGMManifest {
        do {
            var request = URLRequest(url: manifestURL)
            if let metadata = try store.loadCachedMetadata() {
                if let etag = metadata.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let lastModified = metadata.lastModified {
                    request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
                }
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return current }
            if http.statusCode == 304 { return current }
            guard http.statusCode == 200 else { return current }

            let remote = try JSONDecoder().decode(GGMManifest.self, from: data)
            guard remote.isValid, remote.isNewer(than: current) else { return current }

            let metadata = GGMManifestCacheMetadata(
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                fetchedAt: ISO8601DateFormatter().string(from: Date())
            )
            try store.saveCachedManifest(remote, metadata: metadata)
            return remote
        } catch {
            log("GGM manifest update skipped: \(error.localizedDescription)")
            return current
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test.sh`
Expected: PASS with explicit coverage for `304`, `200 newer`, and invalid remote JSON ignoring updates.

- [ ] **Step 5: Commit**

```bash
git add Sources/GGMManifestUpdater.swift Tests/CoreTests.swift
git commit -m "feat: add GGM manifest updater"
```

### Task 4: Wire Active Manifest Into App Startup And OTP

**Files:**
- Modify: `Sources/AppModel.swift`
- Modify: `Sources/BeanfunClient.swift`
- Modify: `Tests/CoreTests.swift`

**Interfaces:**
- Consumes:
  - `GGMManifest`
  - `GGMManifestStore`
  - `GGMManifestUpdater`
- Produces:
  - `AppModel` startup manifest bootstrap
  - `BeanfunClient` use of active manifest rather than hard-coded `CV`/`Hash`

- [ ] **Step 1: Write the failing test**

```swift
private static func testOTPV2RequestUsesManifestValues() throws {
    let manifest = GGMManifest(
        schemaVersion: 1,
        updatedAt: "2026-08-19T00:00:00Z",
        mapleStory: .init(
            ggmClientVersion: "1.5.0.3",
            ggmWebStartDllSha256: String(repeating: "c", count: 64)
        )
    )
    let body = BeanfunWebStartOTP.otpV2RequestBody(
        sn: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        launchTicket: String(repeating: "a", count: 64),
        hash: manifest.mapleStory.ggmWebStartDllSha256,
        cv: manifest.mapleStory.ggmClientVersion
    )
    let json = String(data: body, encoding: .utf8) ?? ""
    try expect(json.contains("\"CV\":\"1.5.0.3\""), "must use manifest CV")
    try expect(json.contains(String(repeating: "c", count: 64)), "must use manifest Hash")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`
Expected: FAIL because startup still uses only baked-in values and there is no active manifest plumbing.

- [ ] **Step 3: Write minimal implementation**

```swift
// In AppModel:
// - load fallback manifest during init
// - replace with cached manifest if valid and newer
// - spawn startup Task that calls updater.refreshIfNeeded(current:)
// - hand active manifest into BeanfunClient

// In BeanfunClient:
// - replace hard-coded MapleStory CV/Hash reads with injected active manifest values
// - keep fallback behavior purely in manifest loading, not in OTP request code
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test.sh`
Expected: PASS, and manual MapleStory OTP path still succeeds when offline if cache or fallback is present.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppModel.swift Sources/BeanfunClient.swift Tests/CoreTests.swift
git commit -m "feat: load MapleStory GGM manifest at startup"
```

### Task 5: Add Remote Manifest File And Documentation

**Files:**
- Create: `metadata/ggm-manifest.json`
- Modify: `docs/ggm-webstart-otp-protocol.md`
- Modify: `docs/macos-player-guide.md`

**Interfaces:**
- Consumes:
  - `GGMManifest` JSON schema
- Produces:
  - repo-hosted manifest file at the agreed fixed URL path
  - user-facing docs for fallback/cache/remote update behavior

- [ ] **Step 1: Write the failing test**

```swift
private static func testBundledManifestMatchesRemoteSchema() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: "/Users/jjc/BeanfunOTP/metadata/ggm-manifest.json"))
    let manifest = try JSONDecoder().decode(GGMManifest.self, from: data)
    try expect(manifest.isValid, "repo manifest must be valid")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test.sh`
Expected: FAIL because `metadata/ggm-manifest.json` does not yet exist.

- [ ] **Step 3: Write minimal implementation**

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-08-18T17:20:00Z",
  "maplestory": {
    "ggmClientVersion": "1.5.0.2",
    "ggmWebStartDllSha256": "dfd568a69d87abcd8f4a93d1a4481ebb57712d1d28ab0b6fc018fcf140101e06"
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test.sh`
Expected: PASS, and docs explain that the app checks manifest updates only at startup.

- [ ] **Step 5: Commit**

```bash
git add metadata/ggm-manifest.json docs/ggm-webstart-otp-protocol.md docs/macos-player-guide.md Tests/CoreTests.swift
git commit -m "docs: add hosted GGM manifest update flow"
```
