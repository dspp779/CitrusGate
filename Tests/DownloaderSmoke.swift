import Foundation
import Darwin

@main
enum DownloaderSmoke {
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let cache = root.appendingPathComponent("smoke-cache")
        let historicalClassic = CommandLine.arguments.dropFirst(2).first == "nx-official"
        let downloader = NxdlDownloader(supportRoot: cache,
            classicManifestTarget: historicalClassic ? "457e2f2938a243aba86bb472828d6fb8" : nil)
        for config in [GameClientToolConfig.nxdlClassic, .cmsdlMapleStory] {
            let binary = downloader.binaryURL(for: config)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: binary.path) { try FileManager.default.removeItem(at: binary) }
            try FileManager.default.copyItem(at: root.appendingPathComponent(config.binaryFileName), to: binary)
            try NxdlBinaryIntegrity.verifyFile(at: binary.path, expectedSHA256Hex: config.sha256Hex)
        }
        if let mode = CommandLine.arguments.dropFirst(2).first, mode == "delta" || mode == "delta-full" {
            try await classicDelta(downloader, root: root, operation: mode == "delta-full" ? .download : .patch)
            return
        }
        if CommandLine.arguments.dropFirst(2).first == "cms-interrupt" {
            try await cmsInterrupt(downloader, root: root)
            return
        }
        if CommandLine.arguments.dropFirst(2).first == "cms-preserve" {
            let client = root.appendingPathComponent("tms-clone")
            let exe = client.appendingPathComponent("MapleStory.exe")
            let expected = try NxdlBinaryIntegrity.sha256Hex(ofFileAt: exe.path)
            _ = try await downloader.inspectClient(config: .cmsdlMapleStory, destination: client)
            guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: exe.path) == expected else { throw Failure("query changed EXE") }
            for operation in [ClientUpdatePlan.Operation.patch, .patch, .download] {
                try await downloader.downloadClient(config: .cmsdlMapleStory, to: client, operation: operation, onUpdate: { _ in })
                guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: exe.path) == expected else { throw Failure("same-major update replaced client-side EXE") }
                print("PASS: app \(operation) preserves same-major independently changed EXE; full data verification passed")
            }
            return
        }
        if CommandLine.arguments.dropFirst(2).first == "cms-major" {
            try await cmsMajor(downloader, root: root)
            return
        }
        if CommandLine.arguments.dropFirst(2).first == "cms-major-verify" {
            let client = root.appendingPathComponent("tms-major")
            try downloader.verifyUpdatedClient(config: .cmsdlMapleStory, directory: client, checkCancelled: {})
            let reference = try await currentOfficialHotfix()
            guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: client.appendingPathComponent("MapleStory.exe").path) == reference.sha256 else { throw Failure("major result differs from current official hotfix") }
            print("PASS: completed official V282→V283 update; all required data hashes and refreshed official minor-update digest verified")
            return
        }
        if historicalClassic { try await nxOfficial(downloader, root: root); return }
        let classic = root.appendingPathComponent("classic-clone")
        let nxPlan = try await downloader.inspectClient(config: .nxdlClassic, destination: classic)
        guard nxPlan.operation == .patch, nxPlan.isCurrent else { throw Failure("unexpected classic route") }
        let classicExe = classic.appendingPathComponent("Maplestory_Classic.exe")
        let before = try NxdlBinaryIntegrity.sha256Hex(ofFileAt: classicExe.path)
        try await downloader.downloadClient(config: .nxdlClassic, to: classic, operation: .patch, onUpdate: { _ in })
        guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: classicExe.path) == before else { throw Failure("no-op changed executable") }
        print("PASS: app wrapper classic version query + same-version patch no-op")

        let tms = root.appendingPathComponent("tms-clone")
        let cmsPlan = try await downloader.inspectClient(config: .cmsdlMapleStory, destination: tms)
        guard cmsPlan.operation == .patch, !cmsPlan.isCurrent else { throw Failure("minor patch route skipped") }
        let updates = UpdateCollector()
        try await downloader.downloadClient(config: .cmsdlMapleStory, to: tms, operation: .patch, onUpdate: { updates.add($0) })
        guard updates.sawMinorPatch || downloader.completionNote.contains("保留") else { throw Failure("minor patch neither installed nor intentionally retained") }
        print("PASS: app wrapper TMS minor patch installation/retention policy + progress phase")

        // A real child process producing PTY output, cancelled through Swift Task.
        let fixture = GameClientToolConfig(releaseTag: "fixture", binaryRemoteURL: URL(string: "https://example.invalid/unused")!,
            sha256Hex: NxdlBinaryIntegrity.sha256Hex(of: Data(script.utf8)), cacheFolderName: "fixture", binaryFileName: "fixture-tool",
            gameAlias: "fixture", primaryExecutableName: "fixture.exe")
        let binary = downloader.binaryURL(for: fixture)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let task = Task {
            try await downloader.downloadClient(config: fixture, to: root.appendingPathComponent("cancel-fixture"), onUpdate: { _ in })
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do { try await task.value; throw Failure("cancellation reported success") }
        catch let error as NxdlDownloaderError {
            guard case .cancelled = error else { throw error }
        }
        // A cancelled operation must not poison the next inspection.
        _ = try await downloader.inspectClient(config: .nxdlClassic, destination: classic)
        print("PASS: PTY process cancellation + next-operation recovery")
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    private static func classicDelta(_ downloader: NxdlDownloader, root: URL, operation: ClientUpdatePlan.Operation) async throws {
        let directory = root.appendingPathComponent("classic-update")
        let marker = directory.appendingPathComponent("2982.manifest.hash")
        let before = try String(contentsOf: marker)
        guard before == "955e603d8db04552a647fe8bd3cf6922" else { throw Failure("requires verified historical source") }
        let beforeFiles = try fingerprints(directory)
        let task = Task {
            try await downloader.downloadClient(config: .nxdlClassic, to: directory, operation: operation, onUpdate: { update in
                if case let .message(message) = update { print(message) }
            })
        }
        let working = directory.deletingLastPathComponent().appendingPathComponent(".classic-update.beanfun-update/client")
        var sawDownload = false
        for _ in 0..<1200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let enumerator = FileManager.default.enumerator(atPath: working.path)
            if let paths = enumerator?.allObjects as? [String], paths.contains(where: { $0.hasSuffix(".ngmdl") }) {
                sawDownload = true; break
            }
        }
        guard sawDownload else { task.cancel(); _ = try? await task.value; throw Failure("actual download did not start") }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do { try await task.value; throw Failure("cancel unexpectedly succeeded") }
        catch let error as NxdlDownloaderError { guard case .cancelled = error else { throw error } }
        guard try fingerprints(directory) == beforeFiles else { throw Failure("interrupted update changed original client") }
        print("PASS: actual historical client + \(operation == .patch ? "unavailable delta route" : "explicit full repair") + real CDN download cancellation preserves every original file")
        try await downloader.downloadClient(config: .nxdlClassic, to: directory, operation: operation, onUpdate: { update in
            if case let .message(message) = update { print(message) }
        })
        guard try String(contentsOf: marker) != before else { throw Failure("target marker not advanced") }
        guard !FileManager.default.fileExists(atPath: working.path) else { throw Failure("private backup not cleaned") }
        print("PASS: restart from intact historical client + full-file update + all target object digests verified + atomic commit")
    }

    private static func fingerprints(_ directory: URL) throws -> [String: String] {
        let paths = FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] ?? []
        var result: [String: String] = [:]
        for path in paths {
            let file = directory.appendingPathComponent(path)
            if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                result[path] = try NxdlBinaryIntegrity.sha256Hex(ofFileAt: file.path)
            }
        }
        return result
    }

    private static func cmsInterrupt(_ downloader: NxdlDownloader, root: URL) async throws {
        let directory = root.appendingPathComponent("tms-clone")
        let exe = directory.appendingPathComponent("MapleStory.exe")
        let before = try NxdlBinaryIntegrity.sha256Hex(ofFileAt: exe.path)
        let base = directory.appendingPathComponent("Data/Base/Base.wz")
        let beforeBase = try Data(contentsOf: base)
        let initialReference = try await currentOfficialHotfix()
        // Reproduce a killed segmented download's same-length placeholder.
        let stale = directory.appendingPathComponent("ExePatch.dat")
        FileManager.default.createFile(atPath: stale.path, contents: nil)
        let placeholder = try FileHandle(forWritingTo: stale)
        placeholder.truncateFile(atOffset: initialReference.bytes)
        placeholder.closeFile()
        let working = directory.deletingLastPathComponent().appendingPathComponent(".tms-clone.beanfun-update/client/ExePatch.dat")
        let task = Task {
            try await downloader.downloadClient(config: .cmsdlMapleStory, to: directory, operation: .patch, onUpdate: { _ in })
        }
        var sawNewDownload = false
        // The stale placeholder is copied briefly, then removed by the wrapper.
        // Wait for the actual downloader's phase rather than its mere presence.
        for _ in 0..<1200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if FileManager.default.fileExists(atPath: working.path),
               let handle = FileHandle(forReadingAtPath: working.path) {
                let prefix = handle.readData(ofLength: 1024)
                handle.closeFile()
                if prefix.contains(where: { $0 != 0 }) { sawNewDownload = true; break }
            }
        }
        task.cancel()
        do { try await task.value; throw Failure("cms cancel unexpectedly succeeded") }
        catch let error as NxdlDownloaderError { guard case .cancelled = error else { throw error } }
        guard sawNewDownload else { throw Failure("actual hotfix download did not start") }
        guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: exe.path) == before,
              try Data(contentsOf: base) == beforeBase else { throw Failure("cancel changed original TMS client") }
        print("PASS: actual cmsdl hotfix download interrupted; original executable and Base.wz preserved")
        try await downloader.downloadClient(config: .cmsdlMapleStory, to: directory, operation: .patch, onUpdate: { _ in })
        let currentHotfix = try await currentOfficialHotfix()
        guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: exe.path) == currentHotfix.sha256 else {
            throw Failure("hotfix does not match independently downloaded official V283 hotfix")
        }
        guard !FileManager.default.fileExists(atPath: stale.path) else { throw Failure("stale preallocated hotfix survived commit") }
        print("PASS: cmsdl retry discards same-length stale hotfix; expected executable digest + all manifest data hashes verified")
    }

    private static func cmsMajor(_ downloader: NxdlDownloader, root: URL) async throws {
        let directory = root.appendingPathComponent("tms-major")
        let base = directory.appendingPathComponent("Data/Base/Base.wz")
        guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: base.path) == "d669c238a8434155cd3c9f33ee80925ce119bdd361a7ace841f4ba18c8c56b21" else {
            throw Failure("requires authenticated official V282 source")
        }
        let beforeFiles = try fingerprints(directory)
        let plan = try await downloader.inspectClient(config: .cmsdlMapleStory, destination: directory)
        guard plan.operation == .patch, plan.detail.contains("V282"), plan.detail.contains("V283") else { throw Failure("unexpected actual major-update route: " + plan.detail) }
        print("PASS: actual cmsdl route " + plan.detail)
        let working = directory.deletingLastPathComponent().appendingPathComponent(".tms-major.beanfun-update/client")
        func start(_ collector: UpdateCollector) -> Task<Void, Error> {
            Task {
                do {
                    try await downloader.downloadClient(config: .cmsdlMapleStory, to: directory, operation: .patch, onUpdate: { update in
                        collector.add(update)
                        if case let .message(text) = update { print(text) }
                    })
                    collector.finish(.success(()))
                } catch { collector.finish(.failure(error)); throw error }
            }
        }
        let downloadCollector = UpdateCollector()
        let downloading = start(downloadCollector)
        let patch = working.appendingPathComponent("patchdata/00282to00283.patch")
        var downloadedBytes = false
        for _ in 0..<1800 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if downloadCollector.hasFinished { try await downloading.value; throw Failure("update completed before download interruption boundary") }
            if let handle = FileHandle(forReadingAtPath: patch.path) {
                let prefix = handle.readData(ofLength: 128); handle.closeFile()
                if prefix.contains(where: { $0 != 0 }) { downloadedBytes = true; break }
            }
        }
        downloading.cancel()
        do { try await downloading.value; throw Failure("download cancellation succeeded unexpectedly") }
        catch let error as NxdlDownloaderError { guard case .cancelled = error else { throw error } }
        guard downloadedBytes, try fingerprints(directory) == beforeFiles else { throw Failure("major download cancellation did not preserve original V282") }
        print("PASS: actual V282→V283 patch download interrupted; all original V282 file digests preserved")

        let collector = UpdateCollector()
        let applying = start(collector)
        let watched = working.appendingPathComponent("Data/Character/Accessory/Accessory_000.wz")
        let originalHash = try NxdlBinaryIntegrity.sha256Hex(ofFileAt: directory.appendingPathComponent("Data/Character/Accessory/Accessory_000.wz").path)
        var replaced = false
        for _ in 0..<12000 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if collector.hasFinished { try await applying.value; throw Failure("update completed before apply interruption boundary") }
            if FileManager.default.fileExists(atPath: watched.path),
               let hash = try? NxdlBinaryIntegrity.sha256Hex(ofFileAt: watched.path), hash != originalHash {
                replaced = true; break
            }
        }
        applying.cancel()
        do { try await applying.value; throw Failure("apply cancellation succeeded unexpectedly") }
        catch let error as NxdlDownloaderError { guard case .cancelled = error else { throw error } }
        guard replaced, try fingerprints(directory) == beforeFiles else { throw Failure("major apply cancellation did not preserve original V282") }
        print("PASS: actual official patch interrupted after replacing WZ data in private copy; all original V282 digests preserved")

        try await start(UpdateCollector()).value
        let currentHotfix = try await currentOfficialHotfix()
        guard try NxdlBinaryIntegrity.sha256Hex(ofFileAt: base.path) == "bb976af4052e0e8d1211600e89923402d6dd977baf8755e9fa3ea0144c2c0a66",
              try NxdlBinaryIntegrity.sha256Hex(ofFileAt: directory.appendingPathComponent("MapleStory.exe").path) == currentHotfix.sha256 else {
            throw Failure("major update did not reach authenticated V283 plus current official hotfix")
        }
        print("PASS: actual official V282→V283 delta + minor update + all target manifest data hashes + atomic commit")
    }

    private static func currentOfficialHotfix() async throws -> (sha256: String, bytes: UInt64) {
        let url = URL(string: "http://tw.cdnpatch.maplestory.beanfun.com/maplestory/patch/patchdir/00283/ExePatch.dat")!
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("official hotfix reference unavailable") }
        let hash = try NxdlBinaryIntegrity.sha256Hex(ofFileAt: temporary.path)
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.uint64Value ?? 0
        print("REFERENCE current official V283 ExePatch.dat SHA-256: " + hash)
        return (hash, size)
    }

    private static func nxOfficial(_ downloader: NxdlDownloader, root: URL) async throws {
        let directory = root.appendingPathComponent("classic-major")
        let working = directory.deletingLastPathComponent().appendingPathComponent(".classic-major.beanfun-update/client")
        let source = "9ae5648c8ec84da1ac5d6d94c8993b68"
        let target = "457e2f2938a243aba86bb472828d6fb8"
        guard ClientUpdateInspection.classicMarker(in: directory) == source else { throw Failure("requires authenticated classic 1.10.0") }
        let baseline = try fingerprints(directory)
        func start(_ collector: UpdateCollector) -> Task<Void, Error> {
            Task {
                do {
                    try await downloader.downloadClient(config: .nxdlClassic, to: directory, operation: .patch, onUpdate: { update in
                        collector.add(update)
                        if case let .message(text) = update { print(text) }
                    })
                    collector.finish(.success(()))
                } catch { collector.finish(.failure(error)); throw error }
            }
        }
        let downloadingCollector = UpdateCollector()
        let downloading = start(downloadingCollector)
        var received = false
        for _ in 0..<12000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if downloadingCollector.hasFinished { try await downloading.value; throw Failure("missed NX download boundary") }
            if let paths = FileManager.default.enumerator(atPath: working.appendingPathComponent("patchdata/patches").path)?.allObjects as? [String],
               paths.contains(where: { $0.hasSuffix(".nxdlpatch") }) { received = true; break }
        }
        downloading.cancel()
        do { try await downloading.value; throw Failure("NX cancellation succeeded unexpectedly") }
        catch let error as NxdlDownloaderError { guard case .cancelled = error else { throw error } }
        guard received, try fingerprints(directory) == baseline else { throw Failure("NX download interruption changed source") }
        print("PASS: official classic 1.10.0→1.13.1 patch download interrupted; every source digest preserved")

        let applyingCollector = UpdateCollector()
        let applying = start(applyingCollector)
        let name = "Maplestory_Classic.exe"
        let before = baseline[name]!
        var replaced = false
        for _ in 0..<120000 {
            try await Task.sleep(nanoseconds: 1_000_000)
            if applyingCollector.hasFinished { try await applying.value; throw Failure("missed NX apply boundary") }
            let file = working.appendingPathComponent(name)
            if let hash = try? NxdlBinaryIntegrity.sha256Hex(ofFileAt: file.path), hash != before,
               ClientUpdateInspection.classicMarker(in: working) == source { replaced = true; break }
        }
        applying.cancel()
        do { try await applying.value; throw Failure("NX apply cancellation succeeded unexpectedly") }
        catch let error as NxdlDownloaderError { guard case .cancelled = error else { throw error } }
        guard replaced, try fingerprints(directory) == baseline else { throw Failure("NX apply interruption changed source") }
        print("PASS: official classic patch interrupted after replacing EXE and before version-marker commit; every source digest preserved")

        let syncCollector = UpdateCollector()
        let syncing = start(syncCollector)
        var synchronizedObjects = false
        for _ in 0..<12000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if syncCollector.hasFinished { try await syncing.value; throw Failure("missed object-sync interruption boundary") }
            if syncCollector.sawObjectSync {
                try await Task.sleep(nanoseconds: 300_000_000)
                synchronizedObjects = true; break
            }
        }
        syncing.cancel()
        do { try await syncing.value; throw Failure("NX object-sync cancellation succeeded unexpectedly") }
        catch let error as NxdlDownloaderError { guard case .cancelled = error else { throw error } }
        guard synchronizedObjects, try fingerprints(directory) == baseline else { throw Failure("NGM object-sync interruption changed source") }
        print("PASS: official NGM object-sync phase interrupted; every source digest preserved")

        try await start(UpdateCollector()).value
        guard ClientUpdateInspection.classicMarker(in: directory) == target else { throw Failure("NX target marker not reached") }
        print("PASS: official classic 1.10.0→1.13.1 delta; all target object hashes + atomic commit verified")
    }
    private static let script = "#!/bin/sh\ntrap 'exit 130' TERM\nprintf 'fixture is running\\n'\nwhile :; do sleep 0.1; done\n"
}

private final class UpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var minor = false
    private var applying = false
    private var objectSync = false
    private var result: Result<Void, Error>?
    var hasFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func finish(_ result: Result<Void, Error>) { lock.lock(); defer { lock.unlock() }; self.result = result }
    var sawMinorPatch: Bool { lock.lock(); defer { lock.unlock() }; return minor }
    var sawApply: Bool { lock.lock(); defer { lock.unlock() }; return applying }
    var sawObjectSync: Bool { lock.lock(); defer { lock.unlock() }; return objectSync }
    func add(_ update: NxdlDownloadUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case let .message(text):
            if text.contains("minor_patch") || text.contains("Minor Patch") { minor = true }
            if text.contains("apply_progress(") { applying = true }
            if text.contains("補齊新增或變更檔案") { objectSync = true }
        case let .progress(state):
            if state.phase == .minorPatch { minor = true }
            if state.statusMessage.contains("apply_progress(") { applying = true }
            if state.statusMessage.contains("補齊新增或變更檔案") { objectSync = true }
        }
    }
}
