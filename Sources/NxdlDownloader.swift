import Foundation

enum NxdlProgressParser {
    /// Strips ANSI escape sequences from nxdl / indicatif output.
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    /// Formats a single stderr chunk from nxdl into user-facing progress text.
    static func formatProgressLine(_ raw: String) -> String? {
        let cleaned = stripANSI(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if let parsed = parseIndicatifProgress(cleaned) {
            return parsed
        }

        if cleaned.hasPrefix("nxdl:") || cleaned.hasPrefix("Error:") {
            return cleaned
        }

        return cleaned
    }

    private static func parseIndicatifProgress(_ line: String) -> String? {
        // Example: [=========>          ]  1234567890/ 9876543210 (  1.2 MiB/s) filename
        let pattern = #"\]\s*(\S+)\s*/\s*(\S+)\s*\(([^)]+)\)\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 4,
              let downloadedRange = Range(match.range(at: 1), in: line),
              let totalRange = Range(match.range(at: 2), in: line),
              let speedRange = Range(match.range(at: 3), in: line)
        else {
            return nil
        }

        let downloaded = String(line[downloadedRange])
        let total = String(line[totalRange])
        let speed = String(line[speedRange]).trimmingCharacters(in: .whitespaces)
        var message = ""
        if match.numberOfRanges >= 5, let messageRange = Range(match.range(at: 4), in: line) {
            message = String(line[messageRange]).trimmingCharacters(in: .whitespaces)
        }

        if message.isEmpty {
            return "下載中：\(downloaded) / \(total)（\(speed)）"
        }
        return "下載中：\(downloaded) / \(total)（\(speed)）— \(message)"
    }
}

enum NxdlDownloaderError: LocalizedError {
    case binaryDownloadFailed(String)
    case binaryNotExecutable(String)
    case processFailed(Int32, String)
    case pathNormalizeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .binaryDownloadFailed(message):
            return "無法下載 nxdl 工具：\(message)"
        case let .binaryNotExecutable(path):
            return "nxdl 工具無法執行：\(path)"
        case let .processFailed(code, output):
            if output.isEmpty {
                return "nxdl 下載失敗（結束代碼 \(code)）"
            }
            return "nxdl 下載失敗（結束代碼 \(code)）：\(output)"
        case let .pathNormalizeFailed(message):
            return "無法還原下載檔案路徑：\(message)"
        case .cancelled:
            return "下載已取消"
        }
    }
}

/// nxdl may write Windows-style paths as a single macOS filename containing `\`.
/// Example basename: `Maplestory_Classic_Data\Plugins\x86_64\...\af.pak`
enum WindowsPathFilenameNormalizer {
    /// Splits a basename that embeds `\` into directory + file components.
    /// Returns `nil` when the name does not need rewriting.
    static func relativeComponents(from basename: String) -> [String]? {
        guard basename.contains("\\") else { return nil }
        let parts = basename
            .split(separator: "\\", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard parts.count >= 2 else { return nil }
        return parts
    }
}

final class NxdlDownloader {
    static let releaseTag = "v0.1.2-prerelease2"
    static let binaryRemoteURL = URL(
        string: "https://github.com/HikariCalyx/nxdl/releases/download/v0.1.2-prerelease2/nxdl_darwin"
    )!
    static let gameAlias = "tms_cw"
    static let classicExecutableName = "Maplestory_Classic.exe"
    static let applicationSupportFolderName = "local.ogom.beanfunotp"

    private let fileManager: FileManager
    private let session: URLSession
    private let log: (String) -> Void
    private var runningProcess: Process?

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.session = session
        self.log = log
    }

    var supportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent(Self.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("nxdl", isDirectory: true)
    }

    var binaryURL: URL {
        supportDirectory.appendingPathComponent("nxdl_darwin")
    }

    func cancel() {
        runningProcess?.terminate()
    }

    func downloadClassicClient(
        to destination: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let binary = try await ensureBinary(onStatus: onStatus)
        try await runDownload(binary: binary, destination: destination, onStatus: onStatus)
        onStatus("正在還原檔案路徑…")
        let restored = try normalizeWindowsPathFilenames(in: destination)
        if restored > 0 {
            log("已還原 \(restored) 個含反斜線的檔名為目錄結構：\(destination.path)")
            onStatus("已還原 \(restored) 個檔案路徑")
        }
    }

    /// Rewrites files whose basenames contain `\` into real directory trees.
    /// Returns the number of items moved.
    func normalizeWindowsPathFilenames(in root: URL) throws -> Int {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var candidates: [URL] = []
        for case let itemURL as URL in enumerator {
            if WindowsPathFilenameNormalizer.relativeComponents(from: itemURL.lastPathComponent) != nil {
                candidates.append(itemURL)
            }
        }

        // Longer basenames first so nested malformed names are not disrupted mid-pass.
        candidates.sort { $0.lastPathComponent.count > $1.lastPathComponent.count }

        var restored = 0
        for sourceURL in candidates {
            guard let parts = WindowsPathFilenameNormalizer.relativeComponents(
                from: sourceURL.lastPathComponent
            ) else {
                continue
            }
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let parent = sourceURL.deletingLastPathComponent()
            let destinationURL = parts.reduce(parent) { partial, component in
                partial.appendingPathComponent(component)
            }

            if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
                continue
            }

            let destinationParent = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: destinationParent,
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                throw NxdlDownloaderError.pathNormalizeFailed(
                    "\(sourceURL.lastPathComponent) → \(destinationURL.path)：\(error.localizedDescription)"
                )
            }
            restored += 1
        }
        return restored
    }

    func findClassicExecutable(in root: URL) -> String? {
        let direct = root.appendingPathComponent(Self.classicExecutableName).path
        if fileManager.isExecutableFile(atPath: direct) || fileManager.fileExists(atPath: direct) {
            return direct
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.caseInsensitiveCompare(Self.classicExecutableName) == .orderedSame {
                return fileURL.path
            }
            if fileURL.pathComponents.count - root.pathComponents.count > 4 {
                enumerator.skipDescendants()
            }
        }
        return nil
    }

    private func ensureBinary(onStatus: @escaping @Sendable (String) -> Void) async throws -> URL {
        let url = binaryURL
        if fileManager.isExecutableFile(atPath: url.path) {
            // Always clear quarantine before reuse: GateKeeper may still block a
            // cached binary that retained or regained com.apple.quarantine.
            try prepareBinaryForExecution(at: url.path)
            return url
        }

        onStatus("正在下載 nxdl 工具（\(Self.releaseTag)）…")
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let (tempURL, response) = try await session.download(from: Self.binaryRemoteURL)
        defer { try? fileManager.removeItem(at: tempURL) }

        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw NxdlDownloaderError.binaryDownloadFailed("HTTP \(http.statusCode)")
        }

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: tempURL, to: url)
        try prepareBinaryForExecution(at: url.path)

        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw NxdlDownloaderError.binaryNotExecutable(url.path)
        }

        log("nxdl 工具已就緒：\(url.path)")
        return url
    }

    private func runDownload(
        binary: URL,
        destination: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        // Clear again immediately before Process.run in case LaunchServices or
        // another agent re-applied quarantine after ensureBinary returned.
        try prepareBinaryForExecution(at: binary.path)

        onStatus("正在下載新楓之谷：經典版客戶端…")

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = supportDirectory
        process.arguments = [Self.gameAlias, "--download", destination.path]

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let stderrHandle = stderrPipe.fileHandleForReading
        var stderrBuffer = ""
        var lastProgressLine = ""
        var stderrLines: [String] = []

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

            stderrBuffer += chunk
            while let breakIndex = stderrBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let segment = String(stderrBuffer[..<breakIndex])
                stderrBuffer.removeSubrange(...breakIndex)
                if !stderrBuffer.isEmpty,
                   stderrBuffer.first == "\n" || stderrBuffer.first == "\r" {
                    stderrBuffer.removeFirst()
                }

                guard !segment.isEmpty else { continue }
                stderrLines.append(segment)

                guard let formatted = NxdlProgressParser.formatProgressLine(segment) else { continue }
                lastProgressLine = formatted
                onStatus(formatted)
            }
        }

        runningProcess = process

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [weak self] finished in
                stderrHandle.readabilityHandler = nil
                if let tail = String(data: stderrHandle.readDataToEndOfFile(), encoding: .utf8),
                   !tail.isEmpty {
                    stderrBuffer += tail
                }

                if !stderrBuffer.isEmpty {
                    stderrLines.append(stderrBuffer)
                    if let formatted = NxdlProgressParser.formatProgressLine(stderrBuffer) {
                        lastProgressLine = formatted
                    }
                }

                self?.runningProcess = nil

                if finished.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: NxdlDownloaderError.cancelled)
                    return
                }

                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let combined = stderrLines
                        .map { NxdlProgressParser.stripANSI($0) }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = lastProgressLine.isEmpty ? combined : lastProgressLine
                    continuation.resume(
                        throwing: NxdlDownloaderError.processFailed(
                            finished.terminationStatus,
                            message
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                stderrHandle.readabilityHandler = nil
                self.runningProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func prepareBinaryForExecution(at path: String) throws {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try clearQuarantineIfNeeded(at: path)
    }

    private func clearQuarantineIfNeeded(at path: String) throws {
        let length = listxattr(path, nil, 0, 0)
        guard length >= 0 else {
            throw NxdlDownloaderError.binaryNotExecutable(path)
        }
        guard length > 0 else { return }

        var buffer = [CChar](repeating: 0, count: length)
        guard listxattr(path, &buffer, buffer.count, 0) >= 0 else {
            throw NxdlDownloaderError.binaryNotExecutable(path)
        }

        let names = Data(bytes: buffer, count: length)
            .split(separator: 0)
            .compactMap { String(data: Data($0), encoding: .utf8) }

        guard names.contains("com.apple.quarantine") else { return }
        if removexattr(path, "com.apple.quarantine", 0) != 0 {
            throw NxdlDownloaderError.binaryDownloadFailed(
                "無法解除 nxdl quarantine：\(path)"
            )
        }
        log("已解除 nxdl quarantine：\(path)")
    }
}
