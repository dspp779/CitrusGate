import AppKit
import Darwin
import Foundation
import CommonCrypto
import zlib

/// The full-client manifest deliberately describes the pristine executable,
/// while the game can update just MapleStory.exe without changing Base.wz.
/// Keep a structurally valid changed executable only within that same known
/// base generation; an incomplete download must never qualify for retention.
enum TMSExecutablePolicy {
    static func hasCurrentBase(in directory: URL, manifest: [String: Any]) throws -> Bool {
        guard let files = manifest["files"] as? [[String: Any]],
              let entry = files.first(where: { normalized($0["path"] as? String) == "data/base/base.wz" }),
              let expected = entry["sha256"] as? String else { throw ClientCheckError.invalidJSON }
        let file = directory.appendingPathComponent("Data/Base/Base.wz")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try NxdlBinaryIntegrity.sha256Hex(ofFileAt: file.path).lowercased() == expected.lowercased()
    }

    static func shouldRetainExecutable(in directory: URL, manifest: [String: Any]) throws -> Bool {
        guard try hasCurrentBase(in: directory, manifest: manifest),
              let files = manifest["files"] as? [[String: Any]],
              let entry = files.first(where: { normalized($0["path"] as? String) == "maplestory.exe" }),
              let pristine = entry["sha256"] as? String else { return false }
        let exe = directory.appendingPathComponent("MapleStory.exe")
        guard !FileManager.default.fileExists(atPath: exe.path + ".cmsdl"),
              isPortableExecutable(exe) else { return false }
        return try NxdlBinaryIntegrity.sha256Hex(ofFileAt: exe.path).lowercased() != pristine.lowercased()
    }

    private static func normalized(_ path: String?) -> String {
        (path ?? "").replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    static func isPortableExecutable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 4096,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 64)
        guard header.count == 64, header[0] == 0x4d, header[1] == 0x5a else { return false }
        let offset = (0..<4).reduce(0) { $0 | Int(header[0x3c + $1]) << ($1 * 8) }
        guard offset >= 64, offset <= 1024 * 1024, offset + 26 <= size else { return false }
        handle.seek(toFileOffset: UInt64(offset))
        let pe = handle.readData(ofLength: 26)
        guard pe.count == 26, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { return false }
        let machine = Int(pe[4]) | Int(pe[5]) << 8
        let sections = Int(pe[6]) | Int(pe[7]) << 8
        let optionalSize = Int(pe[20]) | Int(pe[21]) << 8
        let magic = Int(pe[24]) | Int(pe[25]) << 8
        return [0x14c, 0x8664].contains(machine) && (1...96).contains(sections)
            && optionalSize >= 96 && offset + 24 + optionalSize <= size && [0x10b, 0x20b].contains(magic)
    }
}

/// Compatibility decoder for authenticated NGM streams left behind when the
/// pinned nxdl encounters an unsupported opcode. Always read from the intact
/// original tree; the caller verifies the complete target manifest afterwards.
enum NGMDeltaCompatibility {
    static func apply(source: URL, patch: URL, output: URL, expectedSize: UInt64,
                      checkCancelled: () throws -> Void) throws {
        guard #available(macOS 10.15.4, *) else { throw NxdlDownloaderError.incompleteUpdate("差分相容處理需要較新的 macOS。") }
        let input = try FileHandle(forReadingFrom: source)
        let delta = try FileHandle(forReadingFrom: patch)
        defer { input.closeFile(); delta.closeFile() }
        let sourceSize = input.seekToEndOfFile()
        input.seek(toFileOffset: 0)
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        guard fm.createFile(atPath: output.path, contents: nil) else { throw ClientCheckError.invalidJSON }
        let target = try FileHandle(forWritingTo: output)
        var complete = false
        defer { target.closeFile(); if !complete { try? fm.removeItem(at: output) } }
        var written: UInt64 = 0
        func integer(_ bytes: Int) throws -> UInt64 {
            let data = try delta.read(upToCount: bytes) ?? Data()
            guard data.count == bytes else { throw NxdlDownloaderError.incompleteUpdate("差分指令不完整；原安裝仍保留。") }
            return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        func copy(_ handle: FileHandle, count: UInt64) throws {
            guard count <= expectedSize - written else { throw NxdlDownloaderError.incompleteUpdate("差分輸出超出官方清單大小。") }
            var remaining = count
            while remaining > 0 {
                try checkCancelled()
                let count = Int(min(remaining, 64 * 1024))
                let copied: Int = try autoreleasepool {
                    let data = try handle.read(upToCount: count) ?? Data()
                    try target.write(contentsOf: data)
                    return data.count
                }
                guard copied == count else { throw NxdlDownloaderError.incompleteUpdate("差分來源資料不完整。") }
                remaining -= UInt64(copied); written += UInt64(copied)
            }
        }
        while true {
            try checkCancelled()
            let byte = try delta.read(upToCount: 1) ?? Data()
            guard let opcode = byte.first, opcode != 0 else { break }
            let widths: (Int, Int)?
            switch opcode {
            case 0x04: widths = (1, 2)
            case 0x10: widths = (2, 1)
            case 0x14: widths = (2, 2)
            case 0x18: widths = (2, 4)
            case 0x20: widths = (4, 1)
            case 0x24: widths = (4, 2)
            case 0x28: widths = (4, 4)
            case 0x40, 0x44, 0x48:
                let count = try integer(opcode == 0x40 ? 1 : opcode == 0x44 ? 2 : 4)
                try copy(delta, count: count)
                continue
            default: throw NxdlDownloaderError.incompleteUpdate(String(format: "尚未支援差分指令 0x%02x；原安裝仍保留。", opcode))
            }
            if let widths {
                let offset = try integer(widths.0), count = try integer(widths.1)
                guard offset <= sourceSize, count <= sourceSize - offset else {
                    throw NxdlDownloaderError.incompleteUpdate("差分指令超出原檔案範圍。")
                }
                input.seek(toFileOffset: offset)
                try copy(input, count: count)
            }
        }
        guard written == expectedSize else { throw NxdlDownloaderError.incompleteUpdate("差分結果大小與官方清單不符。") }
        complete = true
    }
}

/// NGM publishes delta streams only for some changed files. New assets and
/// remaining changed objects must be synchronized from the full manifest too.
enum NGMClientSynchronization {
    static func synchronize(directory: URL, scratch: URL, manifest: [String: Any],
                            fetch: (URL) throws -> Data, checkCancelled: () throws -> Void,
                            report: (String) -> Void) throws -> (files: Int, objects: Int) {
        guard #available(macOS 10.15.4, *),
              let chunkSize = manifest["chunk_size"] as? Int, chunkSize > 0, chunkSize <= 16 * 1024 * 1024,
              let files = manifest["files"] as? [String: [String: Any]], !files.isEmpty else { throw ClientCheckError.invalidJSON }
        let fm = FileManager.default
        var repaired = 0, downloaded = 0
        for (encoded, entry) in files.sorted(by: { $0.key < $1.key }) {
            try checkCancelled()
            guard let decoded = Data(base64Encoded: encoded), let path = String(data: decoded, encoding: .utf8),
                  let objects = entry["objects"] as? [String: String],
                  let size = entry["uncompressed_size"] as? Int, size >= 0 else { throw ClientCheckError.invalidJSON }
            let parts = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else { throw ClientCheckError.invalidJSON }
            let output = parts.reduce(directory) { $0.appendingPathComponent($1) }
            guard output.resolvingSymlinksInPath().path == output.standardizedFileURL.path else { throw ClientCheckError.invalidJSON }
            if objects.isEmpty || objects.values.contains("__DIR__") {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                continue
            }
            let ordered = objects.compactMap { key, hash -> (Int, String)? in
                guard let index = Int(key), index >= 0,
                      hash.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { return nil }
                return (index, hash.lowercased())
            }.sorted { $0.0 < $1.0 }
            let expectedCount = max(1, size / chunkSize + (size % chunkSize == 0 ? 0 : 1))
            guard ordered.count == objects.count, ordered.count == expectedCount,
                  ordered.enumerated().allSatisfy({ $0.offset == $0.element.0 }) else { throw ClientCheckError.invalidJSON }
            var unchanged = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size
            let source = try? FileHandle(forReadingFrom: output)
            if let source, unchanged {
                for (_, hash) in ordered {
                    try checkCancelled()
                    let block: Data = try autoreleasepool { try source.read(upToCount: chunkSize) ?? Data() }
                    if sha1(block) != hash { unchanged = false; break }
                }
            } else { unchanged = false }
            if unchanged { source?.closeFile(); continue }
            defer { source?.closeFile() }
            report("正在補齊新增或變更檔案：" + parts.joined(separator: "/"))
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = scratch.appendingPathComponent("ngm-sync-\(UUID().uuidString)")
            guard fm.createFile(atPath: temporary.path, contents: nil) else { throw ClientCheckError.invalidJSON }
            let target = try FileHandle(forWritingTo: temporary)
            var installed = false
            var closed = false
            defer { if !closed { target.closeFile() }; if !installed { try? fm.removeItem(at: temporary) } }
            for (index, hash) in ordered {
                try checkCancelled()
                let offset = index * chunkSize
                let length = min(chunkSize, size - offset)
                var block = Data()
                if let source {
                    try source.seek(toOffset: UInt64(offset))
                    block = try autoreleasepool { try source.read(upToCount: length) ?? Data() }
                }
                if block.count != length || sha1(block) != hash {
                    let url = URL(string: "https://tw-ngm.maplestoryclassic.games.gamania.com/\(encoded).\(index).\(hash).nxgz")!
                    let compressed = try fetch(url)
                    guard compressed.count <= 32 * 1024 * 1024 else { throw ClientCheckError.invalidJSON }
                    var bytes = [UInt8](repeating: 0, count: max(1, length))
                    var written = uLongf(bytes.count)
                    let status = compressed.withUnsafeBytes { raw in
                        uncompress(&bytes, &written, raw.bindMemory(to: Bytef.self).baseAddress, uLong(compressed.count))
                    }
                    guard status == Z_OK, written == length else { throw NxdlDownloaderError.incompleteUpdate("官方物件解壓縮失敗：\(path)") }
                    block = Data(bytes.prefix(length))
                    guard sha1(block) == hash else { throw NxdlDownloaderError.incompleteUpdate("官方物件 SHA-1 不符：\(path)") }
                    downloaded += 1
                }
                try checkCancelled()
                try target.write(contentsOf: block)
            }
            try target.close()
            closed = true
            try checkCancelled()
            if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
            try fm.moveItem(at: temporary, to: output)
            installed = true; repaired += 1
        }
        return (repaired, downloaded)
    }

    static func sha1(_ data: Data) -> String {
        var bytes = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in _ = CC_SHA1(raw.baseAddress, CC_LONG(data.count), &bytes) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Patchers may commit individual files before reporting failure. Work on a
/// private copy and exchange directories only after verification. A durable
/// receipt distinguishes a crash before the exchange from one after it.
final class ClientUpdateTransaction {
    private let fm = FileManager.default
    let destination: URL
    let workspace: URL
    let working: URL
    private let token: String
    private var lockDescriptor: Int32 = -1
    private var sourceState: [String: String] = [:]
    private static let receipt = ".beanfun-update-commit.json"

    init(destination: URL, checkCancelled: () throws -> Void) throws {
        self.destination = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        workspace = self.destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).beanfun-update", isDirectory: true)
        working = workspace.appendingPathComponent("client", isDirectory: true)
        let owner = workspace.appendingPathComponent("owner.json")
        token = UUID().uuidString
        guard self.destination.path != "/", (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw NxdlDownloaderError.incompleteUpdate("更新資料夾不能透過符號連結，請選擇實際遊戲資料夾。")
        }
        let lockPath = workspace.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw NxdlDownloaderError.incompleteUpdate("無法建立更新鎖定檔。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NxdlDownloaderError.incompleteUpdate("另一個更新作業正在使用這個遊戲資料夾，請等候它完成。")
        }
        lockDescriptor = descriptor
        var initialized = false
        defer { if !initialized { releaseLock() } }
        try Self.cleanWorkspace(destination: self.destination, workspace: workspace)
        try checkCancelled()
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        let record = try JSONSerialization.data(withJSONObject: ["destination": self.destination.path, "token": token])
        try record.write(to: owner, options: .atomic)
        do {
            sourceState = try Self.snapshot(self.destination, checkCancelled: checkCancelled)
            try Self.copyTree(self.destination, to: working, checkCancelled: checkCancelled)
        } catch { discard(); throw error }
        initialized = true
    }

    /// Reclaim an abandoned private tree before the disk-space check, otherwise
    /// its allocation could prevent the very retry which would remove it.
    static func reclaimAbandoned(destination: URL) throws {
        let root = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        let workspace = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).beanfun-update", isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspace.path) else { return }
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw NxdlDownloaderError.incompleteUpdate("更新資料夾不能透過符號連結。")
        }
        let descriptor = open(workspace.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw NxdlDownloaderError.incompleteUpdate("無法開啟更新鎖定檔。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw NxdlDownloaderError.incompleteUpdate("另一個更新作業正在使用這個遊戲資料夾。")
        }
        defer { flock(descriptor, LOCK_UN) }
        try cleanWorkspace(destination: root, workspace: workspace)
    }

    private static func cleanWorkspace(destination: URL, workspace: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: workspace.path) {
            let owner = workspace.appendingPathComponent("owner.json")
            guard workspace.resolvingSymlinksInPath().path == workspace.path,
                  let data = try? Data(contentsOf: owner),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  record["destination"] == destination.path,
                  let oldToken = record["token"] else {
                throw NxdlDownloaderError.incompleteUpdate("更新暫存資料夾無法辨識，已停止以保留檔案：\(workspace.path)")
            }
            let receipt = destination.appendingPathComponent(Self.receipt)
            if (try? String(contentsOf: receipt, encoding: .utf8)) == oldToken {
                // The exchange already committed. Only the private old copy
                // remains; never swap it back over the verified new install.
                try fm.removeItem(at: receipt)
            }
            try fm.removeItem(at: workspace)
        }
    }

    deinit { releaseLock() }

    private func releaseLock() {
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor); lockDescriptor = -1 }
    }

    func discard() {
        let owner = workspace.appendingPathComponent("owner.json")
        if let data = try? Data(contentsOf: owner),
           let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           record["token"] == token {
            try? fm.removeItem(at: workspace)
        }
        releaseLock()
    }

    private static func snapshot(_ root: URL, checkCancelled: () throws -> Void) throws -> [String: String] {
        let fm = FileManager.default
        var entries: [String: String] = [:]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw NxdlDownloaderError.incompleteUpdate("無法讀取原安裝資料夾。")
        }
        for case let file as URL in enumerator {
            try checkCancelled()
            let values = try fm.attributesOfItem(atPath: file.path)
            let modified = (values[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            entries[file.path] = "\(values[.type] ?? "")|\(values[.size] ?? 0)|\(modified)|\(values[.systemFileNumber] ?? 0)|\(values[.posixPermissions] ?? 0)"
        }
        return entries
    }

    private static func copyTree(_ source: URL, to target: URL, checkCancelled: () throws -> Void) throws {
        let fm = FileManager.default
        try checkCancelled()
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        // A link inside the client could let the external patcher write outside
        // the private copy. Reject it before launching either tool.
        guard values.isSymbolicLink != true else {
            throw NxdlDownloaderError.incompleteUpdate("遊戲資料夾含有符號連結，請使用完整且獨立的安裝資料夾。")
        }
        if values.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(child, to: target.appendingPathComponent(child.lastPathComponent), checkCancelled: checkCancelled)
            }
        } else {
            guard values.isRegularFile == true else {
                throw NxdlDownloaderError.incompleteUpdate("遊戲資料夾含有不支援的特殊檔案。")
            }
            // APFS copy-on-write; other volumes fall back to a normal copy.
            if clonefile(source.path, target.path, 0) != 0 { try fm.copyItem(at: source, to: target) }
        }
    }

    func commit(checkCancelled: () throws -> Void) throws {
        try checkCancelled()
        guard try Self.snapshot(destination, checkCancelled: checkCancelled) == sourceState else {
            throw NxdlDownloaderError.incompleteUpdate("更新期間原安裝已被其他程式修改，已停止切換。請關閉遊戲後重試。")
        }
        try token.write(to: working.appendingPathComponent(Self.receipt), atomically: true, encoding: .utf8)
        try checkCancelled()
        guard renameatx_np(AT_FDCWD, destination.path, AT_FDCWD, working.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "無法切換已驗證的更新；原遊戲資料夾仍保留。"])
        }
        // After the atomic exchange the update is committed, even if cleanup
        // fails or the app is terminated. The next transaction can finish it.
        try? fm.removeItem(at: destination.appendingPathComponent(Self.receipt))
        try? fm.removeItem(at: workspace)
        releaseLock()
    }
}

/// An update route is separate from a file-size estimate. A matching size is
/// never proof that an installed file is current or intact.
struct ClientUpdatePlan: Equatable {
    enum Operation: Equatable { case download, patch }
    let operation: Operation
    let isCurrent: Bool
    let detail: String
    let downloadBytes: UInt64?
    let temporaryBytes: UInt64?

    static func fullDownload(_ detail: String) -> ClientUpdatePlan {
        ClientUpdatePlan(operation: .download, isCurrent: false, detail: detail,
                         downloadBytes: nil, temporaryBytes: nil)
    }
}

enum ClientUpdateInspection {
    static func classicMarker(in directory: URL) -> String? {
        let marker = directory.appendingPathComponent("2982.manifest.hash")
        guard let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let raw = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let hash = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hash.range(of: #"^(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#,
                         options: .regularExpression) != nil else { return nil }
        return hash
    }

    static func classic(json: String, directory: URL) throws -> ClientUpdatePlan {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifest = object["manifest_url"] as? String,
              let remote = URL(string: manifest)?.lastPathComponent, !remote.isEmpty else {
            throw ClientCheckError.invalidJSON
        }
        guard let local = classicMarker(in: directory) else {
            return .fullDownload("舊安裝沒有可靠的版本紀錄，請下載以建立可供後續差分更新的紀錄。")
        }
        // nxdl writes the marker only after successful completion. Interrupted
        // patch data must be resumed before claiming the install is current.
        let interrupted = FileManager.default.fileExists(atPath: directory.appendingPathComponent("patchdata").path)
        return ClientUpdatePlan(operation: .patch, isCurrent: local == remote && !interrupted,
            detail: local == remote && !interrupted ? "版本紀錄與伺服器一致；可另外執行完整下載。" : "可使用經典版差分更新。",
            downloadBytes: nil, temporaryBytes: nil)
    }

    static func cmsdl(exitCode: Int32, output: String) throws -> ClientUpdatePlan {
        switch exitCode {
        case 1, 2, 3:
            let reason = exitCode == 1 ? "沒有適用的補丁路線" : exitCode == 2 ? "補丁下載量大於完整客戶端" : "無法辨識本機版本"
            return .fullDownload(reason + "，改以完整檔案檢查與下載處理。")
        case 4:
            throw NxdlDownloaderError.processFailed(exitCode, "本機版本比伺服器目標新，已停止以避免降版。")
        case 100:
            throw NxdlDownloaderError.processFailed(exitCode, "無法連線至更新伺服器，請稍後重試。")
        case 0: break
        default: throw NxdlDownloaderError.processFailed(exitCode, output)
        }
        // These are upstream's diagnostic labels, exercised by pinned-binary
        // smoke tests. Fail closed when a future output format is unrecognised.
        guard output.contains("current version:"), output.contains("target version:"),
              let count = capture(#"(?m)^patches needed:\s+(\d+)"#, output).flatMap(Int.init),
              let current = capture(#"(?m)^current version:\s+(\d+)"#, output),
              let target = capture(#"(?m)^target version:\s+(\d+)"#, output) else {
            throw NxdlDownloaderError.processFailed(-1, "無法辨識更新路線；未更動遊戲檔案。")
        }
        let minor = output.contains("minor patch:")
        let currentAndComplete = current == target && count == 0 && !minor
        let sizes = output.components(separatedBy: .newlines).filter {
            $0.hasPrefix("patches needed:") || $0.hasPrefix("minor patch:")
        }.compactMap { line -> UInt64? in
            guard let amount = capture(#"\(([0-9.,]+\s*(?:[KMGT]i?B|B))\)"#, line),
                  let value = NxdlProgressParser.parseByteCount(amount), value.isFinite, value >= 0 else { return nil }
            // Printed units are rounded. Reserve extra space; never round down.
            let reserved = ceil(value * 1.01)
            guard reserved.isFinite, reserved < Double(Int64.max) else { return nil }
            return UInt64(reserved)
        }
        let bytes = sizes.reduce(UInt64(0)) { DiskSpaceGate.reserve(total: $0, patch: $1) }
        return ClientUpdatePlan(operation: .patch, isCurrent: currentAndComplete,
            detail: currentAndComplete ? "主版本一致；仍可重新檢查小更新與遊戲檔案。" : "V\(current) → V\(target)" + (minor ? "，包含主程式小更新" : "，使用差分更新"),
            downloadBytes: bytes > 0 ? bytes : nil, temporaryBytes: nil)
    }

    static func capture(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Applied at the logging boundary, regardless of caller. Protocol URLs and
/// command-line arguments can contain opaque tickets with no recognizable key.
enum DiagnosticRedactor {
    static func redact(_ text: String) -> String {
        var value = text
        let rules: [(String, String)] = [
            (#"(?i)(?:nexonplug|gamaniagames|beanfun|ggmwebstart)://[^\s<>\"']+"#, "[啟動連結已遮蔽]"),
            (#"(?i)(\b(?:args|arguments|passarg)\s*=).*"#, "$1[redacted]"),
            (#"(?i)(\b(?:authorization|set-cookie|cookie)\s*[:=]).*"#, "$1 [redacted]"),
            (#"(?i)([\"']?(?:bfWebToken|WebToken|SecretCode|OTP|password|access_token|session_key|verification_token|Data)[\"']?\s*[:=]\s*)(?:[\"'][^\"']*[\"']|[^\s&;,]+)"#, "$1[redacted]"),
            (#"(?i)([?&](?:token|web_token|webtoken|secretcode|otp|data|session_key|verification_token)=)[^&#\s]+"#, "$1[redacted]")
        ]
        for (pattern, replacement) in rules {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // Home paths can reveal the local user's name in shared diagnostics.
        value = value.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return value
    }
}

struct LaunchReadinessItem: Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let isReady: Bool
}

enum LaunchPreflight {
    static func destinationProblem(_ directory: URL) -> String? {
        let fm = FileManager.default
        var parent = directory
        while !fm.fileExists(atPath: parent.path) && parent.path != "/" {
            parent.deleteLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isWritableFile(atPath: parent.path) else {
            return "無法寫入目的地，請選擇有寫入權限的資料夾。"
        }
        return nil
    }

    static func fileProblem(path: String, expectedName: String) -> String? {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard !path.isEmpty else { return "請先選擇 \(expectedName)。" }
        guard fm.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else {
            return "找不到主程式，請重新選擇 \(expectedName)。"
        }
        guard URL(fileURLWithPath: path).lastPathComponent.lowercased() == expectedName.lowercased() else {
            return "選到的檔案不符合此遊戲，請選擇 \(expectedName)。"
        }
        guard fm.isReadableFile(atPath: path) else { return "無法讀取主程式，請檢查檔案權限或選擇其他位置。" }
        return nil
    }

    static func application(for launcher: OpenLauncher, executable: String) -> URL? {
        switch launcher {
        case .defaultApplication:
            let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: executable))
            guard app?.bundleURLIdentifier != Bundle.main.bundleIdentifier else { return nil }
            return app
        case .cyder: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: OpenLauncher.cyderBundleIdentifier)
        case .cyderMapleStoryOEM: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: OpenLauncher.cyderMapleStoryOEMBundleIdentifier)
        }
    }
}

private extension URL {
    var bundleURLIdentifier: String? { Bundle(url: self)?.bundleIdentifier }
}
