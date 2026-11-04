import CommonCrypto
import Darwin
import Foundation

/// Regression cases for the release contract: updates must not be inferred
/// from aggregate size, migration must preserve data, and logs must be shareable.
enum ReleaseTests {
    private struct Failure: Error { let message: String }
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-release-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["-1", "true", "1.5", "18446744073709551615"] {
            do { _ = try ClientCheckJSONParser.totalSizeBytes(fromJSONText: "{\"total_size\":\(bad)}"); throw Failure(message: "invalid byte size accepted") }
            catch is ClientCheckError { }
        }
        try check(DiskSpaceGate.evaluate(totalBytes: UInt64.max, freeBytes: UInt64.max).verdict == .blocked, "overflow must block")
        try check(DiskSpaceGate.reserve(total: UInt64.max, patch: 1) == UInt64.max, "reserve saturates instead of trapping")
        try check(DiskSpaceGate.updateReserve(total: 100, patch: 7) == 207, "reserve private tree and patch scratch on non-cloning volumes")
        let exeRoot = root.appendingPathComponent("exe-policy")
        try FileManager.default.createDirectory(at: exeRoot.appendingPathComponent("Data/Base"), withIntermediateDirectories: true)
        let baseBytes = Data("known current generation".utf8)
        try baseBytes.write(to: exeRoot.appendingPathComponent("Data/Base/Base.wz"))
        var pe = Data(repeating: 0, count: 4096)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[0x3c] = 128
        pe[128] = 0x50; pe[129] = 0x45
        pe[132] = 0x64; pe[133] = 0x86; pe[134] = 1
        pe[148] = 240; pe[152] = 0x0b; pe[153] = 2
        let exeManifest: [String: Any] = ["files": [
            ["path": "Data/Base/Base.wz", "sha256": NxdlBinaryIntegrity.sha256Hex(of: baseBytes)],
            ["path": "MapleStory.exe", "sha256": NxdlBinaryIntegrity.sha256Hex(of: pe)]
        ]]
        let policyExe = exeRoot.appendingPathComponent("MapleStory.exe")
        try pe.write(to: policyExe)
        try check(!(try TMSExecutablePolicy.shouldRetainExecutable(in: exeRoot, manifest: exeManifest)), "pristine EXE still receives minor update")
        pe[4095] = 1
        try pe.write(to: policyExe)
        try check(try TMSExecutablePolicy.shouldRetainExecutable(in: exeRoot, manifest: exeManifest), "same-generation changed EXE must survive routine check")
        let sidecar = exeRoot.appendingPathComponent("MapleStory.exe.cmsdl")
        try Data().write(to: sidecar)
        try check(!(try TMSExecutablePolicy.shouldRetainExecutable(in: exeRoot, manifest: exeManifest)), "unfinished EXE must not be retained")
        try FileManager.default.removeItem(at: sidecar)
        try Data("old generation".utf8).write(to: exeRoot.appendingPathComponent("Data/Base/Base.wz"))
        try check(!(try TMSExecutablePolicy.shouldRetainExecutable(in: exeRoot, manifest: exeManifest)), "old major EXE must not survive cross-major repair")
        try baseBytes.write(to: exeRoot.appendingPathComponent("Data/Base/Base.wz"))
        try Data(repeating: 0, count: 4096).write(to: policyExe)
        try check(!(try TMSExecutablePolicy.shouldRetainExecutable(in: exeRoot, manifest: exeManifest)), "same-size zero placeholder must be replaced")
        try check(NxdlProgressParser.formatProgressLine("[-------------------------] 0 B/0 B (0 B/s)") == nil, "idle worker bars must not replace real progress")
        let jsonWithWarning = "{\"total_size\":42}\nwarning: temporary diagnostic\n"
        guard let extracted = ClientCheckJSONParser.extractJSONObjectText(from: jsonWithWarning) else { throw Failure(message: "JSON followed by stderr warning lost") }
        try check(try ClientCheckJSONParser.totalSizeBytes(fromJSONText: extracted) == 42, "extract valid JSON from merged output")
        try check(ClientCheckJSONParser.extractJSONObjectText(from: "{broken}\nwarning") == nil, "do not accept invalid JSON fragments")
        let minor = """
        current version: 283
        target version:  283
        patches needed:  0 (0 B)
        minor patch:     V283 ExePatch.dat (176.88 MiB)
        full client:     version V283 (68.27 GiB)
        """
        let plan = try ClientUpdateInspection.cmsdl(exitCode: 0, output: minor)
        try check(plan.operation == .patch && !plan.isCurrent, "same major version must not skip minor patch")
        try check((plan.downloadBytes ?? 0) > 185_472_992, "rounded upstream sizes need conservative allowance")
        for code: Int32 in [1, 2, 3] {
            let fallback = try ClientUpdateInspection.cmsdl(exitCode: code, output: "")
            try check(fallback.operation == .download && !fallback.isCurrent, "explicit full download fallback")
        }
        for code: Int32 in [4, 100, 127] {
            do { _ = try ClientUpdateInspection.cmsdl(exitCode: code, output: minor); throw Failure(message: "unsafe exit accepted") }
            catch is NxdlDownloaderError { }
        }
        do { _ = try ClientUpdateInspection.cmsdl(exitCode: 0, output: "unknown output"); throw Failure(message: "unknown format accepted") }
        catch is NxdlDownloaderError { }
        let noMinor = "current version: 283\ntarget version: 283\npatches needed: 0 (0 B)"
        try check(tryCurrent(noMinor), "current only when no major/minor is offered")
        let json = #"{"manifest_url":"https://example.invalid/af9e2524da1d4adc8f9fb4c44004e615","total_size":5}"#
        try check(try ClientUpdateInspection.classic(json: json, directory: root).operation == .download,
                  "old client without marker must not attempt differential patch")
        let marker = root.appendingPathComponent("2982.manifest.hash")
        try "not-a-version".write(to: marker, atomically: true, encoding: .utf8)
        try check(ClientUpdateInspection.classicMarker(in: root) == nil, "reject malformed marker before contacting CDN")
        try "af9e2524da1d4adc8f9fb4c44004e615".write(to: marker, atomically: true, encoding: .utf8)
        try check(try ClientUpdateInspection.classic(json: json, directory: root).isCurrent, "latest valid marker")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("patchdata"), withIntermediateDirectories: true)
        try check(!(try ClientUpdateInspection.classic(json: json, directory: root)).isCurrent, "interrupted patch not current")

        let transactionRoot = root.appendingPathComponent("transaction-client")
        try FileManager.default.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: transactionRoot.appendingPathComponent("game.dat"))
        var interrupted: ClientUpdateTransaction? = try ClientUpdateTransaction(destination: transactionRoot, checkCancelled: {})
        try Data("mixed".utf8).write(to: interrupted!.working.appendingPathComponent("game.dat"))
        try check(try String(contentsOf: transactionRoot.appendingPathComponent("game.dat")) == "old", "interrupted patch must preserve source")
        do { _ = try ClientUpdateTransaction(destination: transactionRoot, checkCancelled: {}); throw Failure(message: "concurrent update acquired same client") }
        catch is NxdlDownloaderError { }
        do { try ClientUpdateTransaction.reclaimAbandoned(destination: transactionRoot); throw Failure(message: "cleanup removed active update") }
        catch is NxdlDownloaderError { }
        interrupted = nil // Simulate process exit: release lock, leave journal.
        try ClientUpdateTransaction.reclaimAbandoned(destination: transactionRoot)
        try check(!FileManager.default.fileExists(atPath: transactionRoot.deletingLastPathComponent().appendingPathComponent(".transaction-client.beanfun-update").path), "reclaim abandoned allocation before disk preflight")
        let restarted = try ClientUpdateTransaction(destination: transactionRoot, checkCancelled: {})
        try check(try String(contentsOf: restarted.working.appendingPathComponent("game.dat")) == "old", "restart must discard partially applied delta")
        try Data("verified-new".utf8).write(to: restarted.working.appendingPathComponent("game.dat"))
        try restarted.commit(checkCancelled: {})
        try check(try String(contentsOf: transactionRoot.appendingPathComponent("game.dat")) == "verified-new", "atomic exchange commits verified client")
        try check(!FileManager.default.fileExists(atPath: restarted.workspace.path), "committed backup cleaned")
        let linkedClient = root.appendingPathComponent("linked-client")
        try FileManager.default.createSymbolicLink(at: linkedClient, withDestinationURL: transactionRoot)
        do { _ = try ClientUpdateTransaction(destination: linkedClient, checkCancelled: {}); throw Failure(message: "symlink update accepted") }
        catch is NxdlDownloaderError { }
        let interruptedAgain = try ClientUpdateTransaction(destination: transactionRoot, checkCancelled: {})
        do { try interruptedAgain.commit(checkCancelled: { throw NxdlDownloaderError.cancelled }); throw Failure(message: "cancelled commit accepted") }
        catch is NxdlDownloaderError { }
        try check(try String(contentsOf: transactionRoot.appendingPathComponent("game.dat")) == "verified-new", "cancellation before exchange keeps source")
        interruptedAgain.discard()
        let lateCancel = try ClientUpdateTransaction(destination: transactionRoot, checkCancelled: {})
        do {
            try lateCancel.commit(checkCancelled: {
                if FileManager.default.fileExists(atPath: lateCancel.working.appendingPathComponent(".beanfun-update-commit.json").path) {
                    throw NxdlDownloaderError.cancelled
                }
            })
            throw Failure(message: "cancel immediately before exchange accepted")
        } catch is NxdlDownloaderError { }
        try check(try String(contentsOf: transactionRoot.appendingPathComponent("game.dat")) == "verified-new", "late cancellation after snapshot still preserves source")
        lateCancel.discard()
        let concurrent = try ClientUpdateTransaction(destination: transactionRoot, checkCancelled: {})
        try Data("user-change".utf8).write(to: transactionRoot.appendingPathComponent("game.dat"))
        do { try concurrent.commit(checkCancelled: {}); throw Failure(message: "overwrote concurrent source modification") }
        catch is NxdlDownloaderError { }
        try check(try String(contentsOf: transactionRoot.appendingPathComponent("game.dat")) == "user-change", "preserve concurrent source changes")
        concurrent.discard()
        var crashedCommit: ClientUpdateTransaction? = try ClientUpdateTransaction(destination: transactionRoot, checkCancelled: {})
        let crashWorking = crashedCommit!.working
        let crashWorkspace = crashedCommit!.workspace
        let ownerData = try Data(contentsOf: crashWorkspace.appendingPathComponent("owner.json"))
        let owner = try JSONSerialization.jsonObject(with: ownerData) as! [String: String]
        try Data("committed-before-crash".utf8).write(to: crashWorking.appendingPathComponent("game.dat"))
        try owner["token"]!.write(to: crashWorking.appendingPathComponent(".beanfun-update-commit.json"), atomically: true, encoding: .utf8)
        try check(renameatx_np(AT_FDCWD, transactionRoot.path, AT_FDCWD, crashWorking.path, UInt32(RENAME_SWAP)) == 0, "simulate crash immediately after atomic exchange")
        crashedCommit = nil
        try ClientUpdateTransaction.reclaimAbandoned(destination: transactionRoot)
        try check(try String(contentsOf: transactionRoot.appendingPathComponent("game.dat")) == "committed-before-crash", "crash cleanup must not restore old backup over committed client")
        try check(!FileManager.default.fileExists(atPath: crashWorkspace.path), "crash cleanup removes private backup")

        let verifyRoot = root.appendingPathComponent("verify-client")
        try FileManager.default.createDirectory(at: verifyRoot, withIntermediateDirectories: true)
        let remoteHash = String(repeating: "a", count: 32)
        try remoteHash.write(to: verifyRoot.appendingPathComponent("2982.manifest.hash"), atomically: true, encoding: .utf8)
        let fixtureFile = verifyRoot.appendingPathComponent("game.bin")
        try Data("abcde".utf8).write(to: fixtureFile)
        func sha1(_ value: String) -> String {
            let data = Data(value.utf8)
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { raw in _ = CC_SHA1(raw.baseAddress, CC_LONG(data.count), &digest) }
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let encoded = Data("game.bin".utf8).base64EncodedString()
        VerificationURLProtocol.payloads = [
            "/game-info/2982@2141": try JSONSerialization.data(withJSONObject: ["manifest_name": remoteHash]),
            "/\(remoteHash)": try JSONSerialization.data(withJSONObject: ["chunk_size": 4, "files": [encoded: [
                "objects": ["0": sha1("abcd"), "1": sha1("e")], "hash": "not-the-uncompressed-file-hash"
            ]]]),
            "/maplestory/productInfo.json": try JSONSerialization.data(withJSONObject: ["files": [
                ["path": "game.bin", "sha256": NxdlBinaryIntegrity.sha256Hex(of: Data("abcde".utf8))]
            ]])
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerificationURLProtocol.self]
        let verifier = NxdlDownloader(session: URLSession(configuration: configuration))
        try verifier.verifyUpdatedClient(config: .nxdlClassic, directory: verifyRoot, checkCancelled: {})
        try verifier.verifyUpdatedClient(config: .cmsdlMapleStory, directory: verifyRoot, checkCancelled: {})
        let sync = root.appendingPathComponent("sync-client")
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let syncFile = sync.appendingPathComponent("game.bin")
        try Data("abcdX".utf8).write(to: syncFile)
        let syncManifest: [String: Any] = ["chunk_size": 4, "files": [encoded: [
            "uncompressed_size": 5, "objects": ["0": sha1("abcd"), "1": sha1("e")]
        ]]]
        var requests = 0
        let synchronized = try NGMClientSynchronization.synchronize(directory: sync, scratch: root, manifest: syncManifest,
            fetch: { _ in requests += 1; return Data([120, 156, 75, 5, 0, 0, 102, 0, 102]) }, checkCancelled: {}, report: { _ in })
        try check(try Data(contentsOf: syncFile) == Data("abcde".utf8), "NGM sync repairs changed object")
        try check(requests == 1 && synchronized.objects == 1, "NGM sync reuses authenticated unchanged object")
        _ = try NGMClientSynchronization.synchronize(directory: sync, scratch: root, manifest: syncManifest,
            fetch: { _ in throw Failure(message: "unchanged NGM file downloaded again") }, checkCancelled: {}, report: { _ in })
        try Data("abcdX".utf8).write(to: syncFile)
        do {
            _ = try NGMClientSynchronization.synchronize(directory: sync, scratch: root, manifest: syncManifest,
                fetch: { _ in Data([120, 156, 83, 4, 0, 0, 34, 0, 34]) }, checkCancelled: {}, report: { _ in })
            throw Failure(message: "unauthenticated NGM object accepted")
        } catch is NxdlDownloaderError { }
        try check(try Data(contentsOf: syncFile) == Data("abcdX".utf8), "failed object authentication preserves file")
        let deltaSource = root.appendingPathComponent("delta-source")
        let deltaFile = root.appendingPathComponent("delta-stream")
        let deltaOutput = root.appendingPathComponent("delta-result")
        try Data("ABCDEFGH".utf8).write(to: deltaSource)
        try Data([0x18, 2, 0, 4, 0, 0, 0, 0x40, 1, 0x21, 0]).write(to: deltaFile)
        try NGMDeltaCompatibility.apply(source: deltaSource, patch: deltaFile, output: deltaOutput, expectedSize: 5, checkCancelled: {})
        try check(try Data(contentsOf: deltaOutput) == Data("CDEF!".utf8), "NGM 0x18 reads u16 offset and u32 count")
        try Data([0x18, 7, 0, 4, 0, 0, 0, 0]).write(to: deltaFile)
        do { try NGMDeltaCompatibility.apply(source: deltaSource, patch: deltaFile, output: deltaOutput, expectedSize: 4, checkCancelled: {}); throw Failure(message: "out-of-range NGM copy accepted") }
        catch is NxdlDownloaderError { }
        try check(!FileManager.default.fileExists(atPath: deltaOutput.path), "failed NGM decode removes partial output")
        try Data("abXde".utf8).write(to: fixtureFile)
        for config in [GameClientToolConfig.nxdlClassic, .cmsdlMapleStory] {
            do { try verifier.verifyUpdatedClient(config: config, directory: verifyRoot, checkCancelled: {}); throw Failure(message: "accepted corrupt target despite successful marker") }
            catch is NxdlDownloaderError { }
        }

        let canonical = root.appendingPathComponent("Data/Base.wz")
        try FileManager.default.createDirectory(at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("correct".utf8).write(to: canonical)
        let malformed = root.appendingPathComponent(#"Data\Base.wz"#)
        try Data("stale".utf8).write(to: malformed)
        do { _ = try NxdlDownloader().normalizeWindowsPathFilenames(in: root); throw Failure(message: "collision silently overwritten") }
        catch is NxdlDownloaderError { }
        try check(try Data(contentsOf: canonical) == Data("correct".utf8), "preserve canonical file")
        try check(FileManager.default.fileExists(atPath: malformed.path), "preserve conflicting source")
        try check(WindowsPathFilenameNormalizer.relativeComponents(from: #"..\escape\file"#) == nil, "reject traversal")
        try check(WindowsPathFilenameNormalizer.relativeComponents(from: #"C:\escape\file"#) == nil, "reject drive path")
        try FileManager.default.removeItem(at: malformed)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let install = root.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: install.appendingPathComponent("Data"), withDestinationURL: outside)
        try Data("unsafe".utf8).write(to: install.appendingPathComponent(#"Data\Bad.wz"#))
        do { _ = try NxdlDownloader().normalizeWindowsPathFilenames(in: install); throw Failure(message: "symlink escaped install") }
        catch is NxdlDownloaderError { }
        try check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("Bad.wz").path), "no file outside installation")

        let secret = "SYNTHETIC_SECRET_78234"
        for line in ["NexonPlug://launch?opaque=\(secret)", "forward → gamaniagames://start/\(secret)",
                     "args=/N:user /V:\(secret)", "Cookie: bfUID=\(secret)",
                     "\"webToken\": \"\(secret)\"", "OTP=\(secret)",
                     "https://example.invalid/?WebToken=\(secret)&Data=\(secret)"] {
            try check(!DiagnosticRedactor.redact(line).contains(secret), "diagnostic secret leaked")
        }
        let exe = root.appendingPathComponent("MapleStory.exe")
        try Data([0]).write(to: exe)
        try check(LaunchPreflight.fileProblem(path: exe.path, expectedName: "MapleStory.exe") == nil, "readable matching executable")
        try check(LaunchPreflight.fileProblem(path: exe.path, expectedName: "Maplestory_Classic.exe") != nil, "wrong game's executable")
        try check(LaunchPreflight.fileProblem(path: root.path, expectedName: "MapleStory.exe") != nil, "directory is not executable")
        try check(LaunchPreflight.destinationProblem(root) == nil, "writable destination")
        let tracker = NxdlProgressTracker()
        tracker.setStatusMessage("檢查既有檔案")
        tracker.upsert(NxdlFileProgressInfo(filename: "Base.wz", displayName: "Base.wz", downloadedText: "1 MiB", totalText: "2 MiB", speedText: "1 MiB/s", fraction: 0.5))
        try check(tracker.state.phase == .downloading, "real download leaves verification phase")
        var progress = NxdlDownloadProgressState()
        progress.overall = NxdlProgressBarInfo(downloadedText: "1 GiB", totalText: "1 GiB", speedText: "1 MiB/s", etaText: nil, elapsedText: nil, fraction: 1)
        progress.notePhase("[progress] minor_patch(V283, total=185472992)")
        try check(progress.phase == .minorPatch && progress.overall == nil, "reset old 100% progress on minor patch")
        progress.overall = NxdlProgressBarInfo(downloadedText: "1 GiB", totalText: "1 GiB", speedText: "1 MiB/s", etaText: "ETA 0s", elapsedText: nil, fraction: 1)
        progress.currentFileNames = ["old-download.wz"]
        progress.notePhase("[progress] begin_apply(files=978)")
        try check(progress.phase == .patching && progress.overall == nil && progress.currentFileNames.isEmpty, "apply phase must discard download percent and names")
        progress.notePhase("正在驗證更新後的遊戲檔案…")
        try check(progress.phase == .checking && progress.overall == nil, "verification starts with no stale byte total")
        print("ReleaseTests: update routing, migration safety, redaction, preflight and progress regressions passed")
    }
    private static func tryCurrent(_ text: String) -> Bool {
        (try? ClientUpdateInspection.cmsdl(exitCode: 0, output: text).isCurrent) == true
    }
}

private final class VerificationURLProtocol: URLProtocol {
    static var payloads: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let data = Self.payloads[url.path],
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
