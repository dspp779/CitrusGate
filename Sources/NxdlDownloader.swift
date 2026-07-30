import CommonCrypto
import Darwin
import Foundation

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

struct NxdlProgressBarInfo: Equatable {
    let downloadedText: String
    let totalText: String
    let speedText: String
    /// Raw ETA token from nxdl, e.g. `ETA 29s`.
    let etaText: String?
    let elapsedText: String?
    let fraction: Double

    /// Localised remaining time for display, e.g. `29 秒`.
    var remainingTimeText: String? {
        etaText.flatMap(NxdlProgressParser.remainingTimeText(fromETA:))
    }
}

struct NxdlFileProgressInfo: Equatable, Identifiable {
    var id: String { filename }
    let filename: String
    let displayName: String
    let downloadedText: String
    let totalText: String
    let speedText: String
    let fraction: Double
}

/// ConEmu / Ghostty / Windows Terminal OSC 9;4 progress (native title-bar progress).
/// Documented in docs/nxdl-classic-download.md; App UI uses TUI text only.
struct NxdlOSC94Progress: Equatable {
    /// 0=clear, 1=normal, 2=error, 3=indeterminate, 4=paused/warning.
    /// indicatif uses state 4 while actively downloading.
    let state: Int
    /// 0...100 when provided.
    let percent: Int?
}

struct NxdlDownloadProgressState: Equatable {
    var statusMessage: String = ""
    var overall: NxdlProgressBarInfo?
    /// Latest file name from TUI per-file lines (display basename).
    var currentFileName: String?
}

enum NxdlDownloadUpdate: Equatable {
    case message(String)
    case progress(NxdlDownloadProgressState)
}

enum NxdlProgressParser {
    /// Strips CSI and OSC escape sequences from nxdl / indicatif output.
    static func stripANSI(_ text: String) -> String {
        var result = text
        // OSC ... BEL or ST  (includes OSC 9;4 progress)
        result = result.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        )
        // CSI sequences
        result = result.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        return result
    }

    /// Removes and returns all OSC 9;4 sequences from `buffer`.
    static func consumeOSC94(from buffer: inout String) -> [NxdlOSC94Progress] {
        var results: [NxdlOSC94Progress] = []
        // Not a raw string: \u escapes must be real ESC/BEL bytes for NSRegularExpression.
        let pattern = "\u{001B}\\]9;4;(\\d+)(?:;(\\d+))?(?:\u{0007}|\u{001B}\\\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return results }

        while true {
            let range = NSRange(buffer.startIndex..., in: buffer)
            guard let match = regex.firstMatch(in: buffer, range: range),
                  let fullRange = Range(match.range, in: buffer),
                  let stateRange = Range(match.range(at: 1), in: buffer),
                  let state = Int(buffer[stateRange])
            else {
                break
            }

            var percent: Int?
            if match.numberOfRanges >= 3, let percentRange = Range(match.range(at: 2), in: buffer) {
                percent = Int(buffer[percentRange])
            }
            results.append(NxdlOSC94Progress(state: state, percent: percent))
            buffer.removeSubrange(fullRange)
        }
        return results
    }

    static func parseOSC94(_ raw: String) -> NxdlOSC94Progress? {
        var copy = raw
        return consumeOSC94(from: &copy).last
    }

    /// Formats a single stderr chunk from nxdl into user-facing progress text.
    static func formatProgressLine(_ raw: String) -> String? {
        let cleaned = stripANSI(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if let overall = parseOverallProgress(raw) {
            var text = "下載中：\(overall.downloadedText) / \(overall.totalText)（\(overall.speedText)"
            if let eta = overall.etaText {
                text += "，\(eta)"
            }
            text += "）"
            return text
        }

        if let file = parseFileProgress(raw) {
            return "下載中：\(file.downloadedText) / \(file.totalText)（\(file.speedText)）— \(file.displayName)"
        }

        if cleaned.hasPrefix("nxdl:") || cleaned.hasPrefix("Error:") {
            return cleaned
        }

        if isStatusLine(cleaned) {
            return cleaned
        }

        if let parsed = parseGenericProgressBar(cleaned) {
            if let filename = parsed.filename, !filename.isEmpty {
                return "下載中：\(parsed.downloadedText) / \(parsed.totalText)（\(parsed.speedText)）— \(displayName(for: filename))"
            }
            return "下載中：\(parsed.downloadedText) / \(parsed.totalText)（\(parsed.speedText)）"
        }

        return cleaned
    }

    static func ingestLine(_ raw: String, into tracker: NxdlProgressTracker) -> NxdlDownloadUpdate? {
        let cleaned = stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if let overall = parseOverallProgress(raw) {
            tracker.setOverall(overall)
            return .progress(tracker.state)
        }

        if let file = parseFileProgress(raw) {
            tracker.upsert(file)
            return .progress(tracker.state)
        }

        if isStatusLine(cleaned) || cleaned.hasPrefix("nxdl:") || cleaned.hasPrefix("Error:") {
            tracker.setStatusMessage(cleaned)
            return .progress(tracker.state)
        }

        return nil
    }

    /// Parses nxdl's aggregate bar, e.g.
    /// `⠙ [00:00:14] [====>----] 950.77 MiB/2.76 GiB (65.06 MiB/s, ETA 29s)`.
    ///
    /// The bar must follow the elapsed timestamp: a redraw frame can leave a
    /// per-file fragment glued in front of the overall line, and parsing the
    /// first bar in the line would then report that file's bytes as the total.
    static func parseOverallProgress(_ raw: String) -> NxdlProgressBarInfo? {
        let cleaned = stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard let elapsedRange = cleaned.range(
            of: #"\[\d{2}:\d{2}(:\d{2})?\]"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let afterElapsed = String(cleaned[elapsedRange.upperBound...])
        guard let parsed = parseProgressBar(
            afterElapsed,
            filename: nil,
            defaultElapsed: extractElapsed(from: cleaned)
        ) else {
            return nil
        }

        return NxdlProgressBarInfo(
            downloadedText: parsed.downloadedText,
            totalText: parsed.totalText,
            speedText: parsed.speedText,
            etaText: parsed.etaText,
            elapsedText: parsed.elapsedText,
            fraction: parsed.fraction
        )
    }

    /// Parses an indented per-file bar. Lines carrying an elapsed timestamp
    /// belong to the aggregate bar and are rejected here.
    static func parseFileProgress(_ raw: String) -> NxdlFileProgressInfo? {
        let cleaned = stripANSI(raw)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard cleaned.first == " " || cleaned.first == "\t" else { return nil }
        guard trimmed.range(of: #"\[\d{2}:\d{2}(:\d{2})?\]"#, options: .regularExpression) == nil else {
            return nil
        }
        guard let parsed = parseGenericProgressBar(trimmed),
              let filename = parsed.filename, !filename.isEmpty else {
            return nil
        }
        return NxdlFileProgressInfo(
            filename: filename,
            displayName: displayName(for: filename),
            downloadedText: parsed.downloadedText,
            totalText: parsed.totalText,
            speedText: parsed.speedText,
            fraction: parsed.fraction
        )
    }

    private static func parseGenericProgressBar(_ line: String) -> ParsedProgressBar? {
        parseProgressBar(line, filename: nil, defaultElapsed: extractElapsed(from: line))
    }

    private struct ParsedProgressBar {
        let downloadedText: String
        let totalText: String
        let speedText: String
        let etaText: String?
        let elapsedText: String?
        let fraction: Double
        let filename: String?
    }

    private static func parseProgressBar(
        _ line: String,
        filename: String?,
        defaultElapsed: String?
    ) -> ParsedProgressBar? {
        let pattern =
            #"\[([=#>-]+)\]\s+([\d.]+\s*(?:B|KiB|MiB|GiB|TiB))\s*/\s*([\d.]+\s*(?:B|KiB|MiB|GiB|TiB))\s*\(([^)]+)\)\s*(.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 5,
              let barRange = Range(match.range(at: 1), in: line),
              let downloadedRange = Range(match.range(at: 2), in: line),
              let totalRange = Range(match.range(at: 3), in: line),
              let speedRange = Range(match.range(at: 4), in: line)
        else {
            return nil
        }

        let bar = String(line[barRange])
        let downloadedText = String(line[downloadedRange])
        let totalText = String(line[totalRange])
        let speedSection = String(line[speedRange]).trimmingCharacters(in: .whitespaces)
        var trailingFilename = filename
        if match.numberOfRanges >= 6, let messageRange = Range(match.range(at: 5), in: line) {
            let trailing = String(line[messageRange]).trimmingCharacters(in: .whitespaces)
            if !trailing.isEmpty {
                trailingFilename = trailing
            }
        }

        let (speedText, etaText) = splitSpeedSection(speedSection)
        return ParsedProgressBar(
            downloadedText: downloadedText,
            totalText: totalText,
            speedText: speedText,
            etaText: etaText,
            elapsedText: defaultElapsed,
            fraction: fraction(downloadedText: downloadedText, totalText: totalText, barFallback: bar),
            filename: trailingFilename
        )
    }

    private static func splitSpeedSection(_ section: String) -> (String, String?) {
        let parts = section.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else {
            return (section, nil)
        }
        let eta = parts[1]
        return (parts[0], eta)
    }

    /// Converts nxdl's ETA token (`ETA 1m 5s`) into Chinese units (`1 分 5 秒`).
    /// Falls back to the raw value when the format is unrecognised.
    static func remainingTimeText(fromETA eta: String) -> String? {
        var text = eta.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("eta") {
            text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }

        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*([dhms])"#) else {
            return text
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        let units: [String: String] = ["d": "天", "h": "小時", "m": "分", "s": "秒"]
        var parts: [String] = []
        for match in matches {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let unit = units[String(text[unitRange]).lowercased()] else {
                continue
            }
            parts.append("\(text[valueRange]) \(unit)")
        }
        return parts.isEmpty ? text : parts.joined(separator: " ")
    }

    private static func extractElapsed(from line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{2}:\d{2}(:\d{2})?)\]"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }

    /// Prefer `downloaded/total` byte counts (e.g. `950.77 MiB` / `2.76 GiB`).
    /// Fall back to the ASCII bar width when sizes cannot be parsed.
    static func fraction(downloadedText: String, totalText: String, barFallback: String) -> Double {
        if let downloaded = parseByteCount(downloadedText),
           let total = parseByteCount(totalText),
           total > 0 {
            return min(1, max(0, downloaded / total))
        }
        return fraction(from: barFallback)
    }

    /// Parses indicatif-style sizes (`950.77 MiB`, `2.76 GiB`) into bytes.
    static func parseByteCount(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(
            pattern: #"^([\d.]+)\s*(B|KiB|MiB|GiB|TiB)$"#
        ),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let valueRange = Range(match.range(at: 1), in: trimmed),
              let unitRange = Range(match.range(at: 2), in: trimmed),
              let value = Double(trimmed[valueRange])
        else {
            return nil
        }

        let multipliers: [String: Double] = [
            "B": 1,
            "KiB": 1_024,
            "MiB": 1_024 * 1_024,
            "GiB": 1_024 * 1_024 * 1_024,
            "TiB": 1_024 * 1_024 * 1_024 * 1_024,
        ]
        guard let multiplier = multipliers[String(trimmed[unitRange])] else { return nil }
        return value * multiplier
    }

    static func fraction(from bar: String) -> Double {
        let filled = bar.filter { $0 == "=" || $0 == ">" }.count
        let total = bar.filter { $0 == "=" || $0 == ">" || $0 == "-" }.count
        guard total > 0 else { return 0 }
        return Double(filled) / Double(total)
    }

    private static func displayName(for path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return (normalized as NSString).lastPathComponent
    }

    private static func isStatusLine(_ line: String) -> Bool {
        line.hasPrefix("Game:")
            || line.contains("Manifest loaded:")
            || line.contains("Manifest URL:")
            || line.contains("After filtering:")
            || line.contains("target_path")
            || line.hasPrefix("nxdl v")
    }
}

/// Splits raw PTY output into lines and turns them into UI updates.
/// Shared by `NxdlDownloader` and the parser tests so both see identical framing.
final class NxdlOutputStreamParser {
    private let tracker = NxdlProgressTracker()
    private var buffer = ""

    var state: NxdlDownloadProgressState { tracker.state }

    /// Feeds one chunk and returns the updates it produced, oldest first.
    func ingest(_ chunk: String) -> [NxdlDownloadUpdate] {
        buffer += chunk
        // Strip OSC 9;4 so it does not pollute TUI line parsing.
        // App UI is driven only by TUI overall / file progress text.
        _ = NxdlProgressParser.consumeOSC94(from: &buffer)

        var updates: [NxdlDownloadUpdate] = []
        // `isNewline` also covers CRLF, which a PTY produces via ONLCR and which
        // Swift stores as a single Character — comparing against "\n" or "\r"
        // would miss it and glue every rendered line into one segment.
        while let breakIndex = buffer.firstIndex(where: { $0.isNewline }) {
            let segment = String(buffer[..<breakIndex])
            buffer.removeSubrange(...breakIndex)
            guard !segment.isEmpty else { continue }
            if let update = updateForLine(segment) {
                updates.append(update)
            }
        }
        return updates
    }

    /// Flushes any trailing partial line once the process has exited.
    func finish() -> [NxdlDownloadUpdate] {
        guard !buffer.isEmpty else { return [] }
        let segment = buffer
        buffer = ""
        return updateForLine(segment).map { [$0] } ?? []
    }

    private func updateForLine(_ segment: String) -> NxdlDownloadUpdate? {
        if let update = NxdlProgressParser.ingestLine(segment, into: tracker) {
            return update
        }
        if let formatted = NxdlProgressParser.formatProgressLine(segment) {
            return .message(formatted)
        }
        return nil
    }
}

final class NxdlProgressTracker {
    private(set) var state = NxdlDownloadProgressState()

    func setOverall(_ overall: NxdlProgressBarInfo) {
        state.overall = overall
    }

    func upsert(_ file: NxdlFileProgressInfo) {
        state.currentFileName = file.displayName
    }

    func setStatusMessage(_ message: String) {
        state.statusMessage = message
    }

    func messageUpdate(_ message: String) -> NxdlDownloadUpdate {
        state.statusMessage = message
        return .message(message)
    }
}

enum NxdlDownloaderError: LocalizedError {
    case binaryDownloadFailed(String)
    case binaryNotExecutable(String)
    case binaryChecksumMismatch(expected: String, actual: String)
    case processFailed(Int32, String)
    case pathNormalizeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .binaryDownloadFailed(message):
            return "無法下載 nxdl 工具：\(message)"
        case let .binaryNotExecutable(path):
            return "nxdl 工具無法執行：\(path)"
        case let .binaryChecksumMismatch(expected, actual):
            return "nxdl 工具校驗失敗（預期 \(expected)，實際 \(actual)）"
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

/// SHA-256 helpers for the pinned `nxdl_darwin` binary (CommonCrypto → macOS 10.12+).
enum NxdlBinaryIntegrity {
    /// `shasum -a 256` of HikariCalyx/nxdl `v0.1.2-prerelease2` / `nxdl_darwin`.
    static let expectedSHA256Hex = "a0cf22ae06f94268a33d3bed847619f70842fbd3b0ee758cd0c607782d31a1f7"

    static func sha256Hex(of data: Data) -> String {
        data.withUnsafeBytes { rawBuffer -> String in
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(rawBuffer.baseAddress, CC_LONG(data.count), &digest)
            return hexString(digest)
        }
    }

    static func sha256Hex(ofFileAt path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw NxdlDownloaderError.binaryDownloadFailed("無法讀取 nxdl：\(path)")
        }
        defer { handle.closeFile() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { rawBuffer in
                _ = CC_SHA256_Update(&context, rawBuffer.baseAddress, CC_LONG(chunk.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return hexString(digest)
    }

    static func verifyFile(at path: String, expectedSHA256Hex: String = expectedSHA256Hex) throws {
        let actual = try sha256Hex(ofFileAt: path)
        guard actual == expectedSHA256Hex else {
            throw NxdlDownloaderError.binaryChecksumMismatch(
                expected: expectedSHA256Hex,
                actual: actual
            )
        }
    }

    private static func hexString(_ digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Picks a useful failure message from nxdl output, preferring Error / nxdl lines
/// over the last progress frame.
enum NxdlFailureMessage {
    static func preferred(from outputLines: [String], lastProgressLine: String) -> String {
        let cleaned = outputLines
            .map { NxdlProgressParser.stripANSI($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let errorLine = cleaned.last(where: isErrorLike) {
            return errorLine
        }
        if !lastProgressLine.isEmpty {
            return lastProgressLine
        }
        return cleaned.joined(separator: "\n")
    }

    static func isErrorLike(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Error:") || trimmed.hasPrefix("nxdl:") {
            return true
        }
        let lower = trimmed.lowercased()
        return lower.contains("error:") || lower.contains("failed")
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
    /// Must match `NxdlBinaryIntegrity.expectedSHA256Hex` for this releaseTag.
    static let binarySHA256Hex = NxdlBinaryIntegrity.expectedSHA256Hex
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
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let progressLock = NSLock()
        var lastProgress = NxdlDownloadProgressState()
        let track: (NxdlDownloadUpdate) -> Void = { update in
            if case let .progress(state) = update {
                progressLock.lock()
                lastProgress = state
                progressLock.unlock()
            }
            onUpdate(update)
        }

        ensureBinary(onUpdate: track) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(binary):
                self.runDownload(binary: binary, destination: destination, onUpdate: track) { downloadResult in
                    switch downloadResult {
                    case let .failure(error):
                        completion(.failure(error))
                    case .success:
                        progressLock.lock()
                        var restoring = lastProgress
                        progressLock.unlock()
                        restoring.statusMessage = "正在還原檔案路徑…"
                        restoring.currentFileName = nil
                        track(.progress(restoring))
                        do {
                            let restored = try self.normalizeWindowsPathFilenames(in: destination)
                            if restored > 0 {
                                self.log("已還原 \(restored) 個含反斜線的檔名為目錄結構：\(destination.path)")
                                progressLock.lock()
                                var done = lastProgress
                                progressLock.unlock()
                                done.statusMessage = "已還原 \(restored) 個檔案路徑"
                                done.currentFileName = nil
                                track(.progress(done))
                            }
                            completion(.success(()))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    @available(macOS 10.15, *)
    func downloadClassicClient(
        to destination: URL,
        onUpdate: @escaping @Sendable (NxdlDownloadUpdate) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            downloadClassicClient(to: destination, onUpdate: onUpdate) { result in
                continuation.resume(with: result)
            }
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

    private func ensureBinary(
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let url = binaryURL
        if fileManager.isExecutableFile(atPath: url.path) {
            do {
                try NxdlBinaryIntegrity.verifyFile(at: url.path)
                // Always clear quarantine before reuse: GateKeeper may still block a
                // cached binary that retained or regained com.apple.quarantine.
                try prepareBinaryForExecution(at: url.path)
                completion(.success(url))
                return
            } catch let error as NxdlDownloaderError {
                if case .binaryChecksumMismatch = error {
                    log("快取的 nxdl 校驗失敗，將重新下載：\(error.localizedDescription)")
                    try? fileManager.removeItem(at: url)
                    // Fall through to download.
                } else {
                    completion(.failure(error))
                    return
                }
            } catch {
                completion(.failure(error))
                return
            }
        }

        onUpdate(.message("正在下載 nxdl 工具（\(Self.releaseTag)）…"))
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        let task = session.downloadTask(with: Self.binaryRemoteURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let tempURL else {
                completion(.failure(NxdlDownloaderError.binaryDownloadFailed("無回應")))
                return
            }

            defer { try? self.fileManager.removeItem(at: tempURL) }

            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                completion(.failure(NxdlDownloaderError.binaryDownloadFailed("HTTP \(http.statusCode)")))
                return
            }

            do {
                try NxdlBinaryIntegrity.verifyFile(at: tempURL.path)

                if self.fileManager.fileExists(atPath: url.path) {
                    try self.fileManager.removeItem(at: url)
                }
                try self.fileManager.moveItem(at: tempURL, to: url)
                try self.prepareBinaryForExecution(at: url.path)

                guard self.fileManager.isExecutableFile(atPath: url.path) else {
                    completion(.failure(NxdlDownloaderError.binaryNotExecutable(url.path)))
                    return
                }

                self.log("nxdl 工具已就緒：\(url.path)")
                completion(.success(url))
            } catch {
                try? self.fileManager.removeItem(at: url)
                completion(.failure(error))
            }
        }
        task.resume()
    }

    private func runDownload(
        binary: URL,
        destination: URL,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            // Clear again immediately before Process.run in case LaunchServices or
            // another agent re-applied quarantine after ensureBinary returned.
            try prepareBinaryForExecution(at: binary.path)
        } catch {
            completion(.failure(error))
            return
        }

        onUpdate(.message("正在下載新楓之谷：經典版客戶端…"))

        // indicatif only emits TUI / OSC 9;4 progress when stdout is a TTY.
        // A pipe gets status text on stdout and no live progress — use a PTY.
        let pty: (master: FileHandle, slave: FileHandle)
        do {
            pty = try Self.openPseudoTerminal()
        } catch {
            completion(.failure(error))
            return
        }

        let process = Process()
        process.launchPath = binary.path
        process.currentDirectoryPath = supportDirectory.path
        process.arguments = [Self.gameAlias, "--download", destination.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pty.slave
        process.standardError = pty.slave

        let masterHandle = pty.master
        var lastProgressLine = ""
        var outputLines: [String] = []
        let streamParser = NxdlOutputStreamParser()
        // PTY reads can split a multi-byte UTF-8 sequence across callbacks;
        // hold incomplete trailing bytes until the next chunk arrives.
        let utf8Lock = NSLock()
        var utf8Carry = Data()

        let emit: ([NxdlDownloadUpdate]) -> Void = { updates in
            for update in updates {
                onUpdate(update)
                switch update {
                case let .progress(state):
                    if let overall = state.overall {
                        lastProgressLine = "\(overall.downloadedText)/\(overall.totalText)"
                    }
                    if !state.statusMessage.isEmpty {
                        outputLines.append(state.statusMessage)
                    }
                case let .message(message):
                    lastProgressLine = message
                    outputLines.append(message)
                }
            }
        }

        masterHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk: String = {
                utf8Lock.lock()
                defer { utf8Lock.unlock() }
                utf8Carry.append(data)
                return Self.drainDecodableUTF8(from: &utf8Carry)
            }()
            guard !chunk.isEmpty else { return }
            emit(streamParser.ingest(chunk))
        }

        runningProcess = process
        process.terminationHandler = { [weak self] finished in
            masterHandle.readabilityHandler = nil
            let remaining = masterHandle.readDataToEndOfFile()
            let tailChunk: String = {
                utf8Lock.lock()
                defer { utf8Lock.unlock() }
                if !remaining.isEmpty {
                    utf8Carry.append(remaining)
                }
                guard !utf8Carry.isEmpty else { return "" }
                // Final flush: replace any still-incomplete bytes so we do not drop
                // an otherwise-valid trailing progress frame.
                let tail = String(data: utf8Carry, encoding: .utf8)
                    ?? String(decoding: utf8Carry, as: UTF8.self)
                utf8Carry.removeAll()
                return tail
            }()
            if !tailChunk.isEmpty {
                emit(streamParser.ingest(tailChunk))
            }
            emit(streamParser.finish())

            masterHandle.closeFile()
            self?.runningProcess = nil

            if finished.terminationReason == .uncaughtSignal {
                completion(.failure(NxdlDownloaderError.cancelled))
                return
            }

            if finished.terminationStatus == 0 {
                completion(.success(()))
            } else {
                let message = NxdlFailureMessage.preferred(
                    from: outputLines,
                    lastProgressLine: lastProgressLine
                )
                completion(.failure(NxdlDownloaderError.processFailed(
                    finished.terminationStatus,
                    message
                )))
            }
        }

        process.launch()
        // Close slave in the parent so we get EOF on master when the child exits.
        pty.slave.closeFile()
    }

    /// Returns the longest UTF-8 prefix of `buffer`, leaving incomplete trailing
    /// bytes in place for the next read.
    private static func drainDecodableUTF8(from buffer: inout Data) -> String {
        if buffer.isEmpty { return "" }
        if let full = String(data: buffer, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: true)
            return full
        }

        let maxIncomplete = min(3, buffer.count)
        for drop in 1...maxIncomplete {
            let end = buffer.count - drop
            let prefix = buffer.prefix(end)
            if let text = String(data: prefix, encoding: .utf8) {
                buffer.removeSubrange(0..<end)
                return text
            }
        }

        // Completely invalid leading byte — discard one to avoid stalling forever.
        buffer.removeFirst()
        return drainDecodableUTF8(from: &buffer)
    }

    private static func openPseudoTerminal() throws -> (master: FileHandle, slave: FileHandle) {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        // A zero-sized terminal makes indicatif truncate file names mid-word,
        // so request a wide window.
        var size = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            throw NxdlDownloaderError.processFailed(-1, "無法建立虛擬終端機以擷取下載進度")
        }
        return (
            FileHandle(fileDescriptor: masterFD, closeOnDealloc: true),
            FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        )
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
