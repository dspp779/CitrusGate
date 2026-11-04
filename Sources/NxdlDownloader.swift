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
    var verboseCheckArguments: [String] { [gameAlias, "--check", "-v"] }

    func downloadArguments(destinationPath: String) -> [String] {
        if self == .cmsdlMapleStory {
            return [gameAlias, "--download", destinationPath, "--no-gui"]
        }
        return [gameAlias, "--download", destinationPath]
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
        releaseTag: "v0.2.9",
        binaryRemoteURL: URL(
            string: "https://github.com/HikariCalyx/cmsdl/releases/download/v0.2.9/cmsdl_darwin"
        )!,
        sha256Hex: "9e39d11a4158e322762fef2e32740a064420eeb8c583edf4a1183fbde3c197ff",
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

enum ClientDownloadPhase: String, CaseIterable {
    case preparing = "準備", checking = "檢查檔案", downloading = "下載", patching = "套用補丁", minorPatch = "主程式小更新", finishing = "完成檢查"
}

struct NxdlDownloadProgressState: Equatable {
    var phase: ClientDownloadPhase = .preparing
    mutating func notePhase(_ message: String) {
        let value = message.lowercased()
        let next: ClientDownloadPhase
        if value.contains("minor_patch") || value.contains("minor patch") || value.contains("exepatch") {
            next = .minorPatch
        } else if value.contains("[progress] scanning") || value.contains("verif") || value.contains("檢查") || value.contains("驗證") {
            next = .checking
        } else if value.contains("[progress] patch") || value.contains("[progress] begin_apply") || value.contains("applying") || value.contains("套用") {
            next = .patching
        } else if value.contains("done:") || value.contains("updated.") || value.contains("nothing to do") {
            next = .finishing
        } else if value.contains("starting download") || value.contains("下載中") {
            next = .downloading
        } else { return }
        if phase != next {
            overall = nil
            currentFileNames = []
            isVerifyingExistingFiles = false
        }
        phase = next
    }

    var statusMessage: String = ""
    var overall: NxdlProgressBarInfo?
    var currentFileNames: [String] = []
    var destinationURL: URL? = nil
    /// True while the displayed file names come from nxdl's "already present
    /// and verified" lines rather than active per-file download progress.
    /// Set by `noteVerifiedFile`, cleared by `upsert` (real download progress).
    var isVerifyingExistingFiles: Bool = false

    var currentFileName: String? { currentFileNames.first }

    var currentFileNamesText: String? {
        currentFileNames.isEmpty ? nil : currentFileNames.joined(separator: ", ")
    }

    /// `currentFileNames` stores display basenames (not paths relative to
    /// `destinationURL`), so file existence cannot be used as a signal here —
    /// it would false-positive on any file that already happens to share a
    /// basename with a file under the destination. Rely only on the speed
    /// heuristic (verification reads local disk far faster than a network
    /// download) and the explicit verified-file flag.
    var isCheckingIntegrity: Bool {
        if isVerifyingExistingFiles { return true }
        if let speed = overall?.speedText, speed.contains("GB/s") || speed.contains("GiB/s") {
            return true
        }
        return false
    }
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
        if cleaned.range(of: #"\]\s+0\s*B\s*/\s*0\s*B\s*\("#, options: .regularExpression) != nil { return nil }

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

        if let path = parseVerifiedFileName(cleaned) {
            tracker.noteVerifiedFile(displayName(for: path))
            return .progress(tracker.state)
        }

        return nil
    }

    /// Parses nxdl's "already verified" line, e.g.
    /// `Data/Base/Base.wz already present and verified (skipping download).`,
    /// returning the source-relative path so callers can derive a display name.
    static func parseVerifiedFileName(_ cleaned: String) -> String? {
        let marker = " already present and verified"
        guard let range = cleaned.range(of: marker) else { return nil }
        let path = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
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
        guard (parseByteCount(totalText) ?? 0) > 0 else { return nil }
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
            tracker.setStatusMessage(formatted)
            return .message(formatted)
        }
        return nil
    }
}

final class NxdlProgressTracker {
    private(set) var state = NxdlDownloadProgressState()

    /// Per-file bars seen since the last aggregate bar. indicatif renders the
    /// aggregate bar first in every frame, so the aggregate line marks a frame
    /// boundary and the file names collected after it belong to one frame.
    private var frameFileNames: [String] = []

    func setOverall(_ overall: NxdlProgressBarInfo) {
        state.overall = overall
        if state.phase == .preparing { state.phase = .downloading }
        if !frameFileNames.isEmpty {
            state.currentFileNames = frameFileNames
            frameFileNames = []
        }
    }

    func upsert(_ file: NxdlFileProgressInfo) {
        // Real per-file download progress means we're no longer just
        // reporting verified/skipped files.
        state.isVerifyingExistingFiles = false
        if state.phase == .checking { state.phase = .downloading }
        guard !frameFileNames.contains(file.displayName) else { return }
        frameFileNames.append(file.displayName)
        // Publish while the frame is still growing; a shorter list waits for the
        // frame to end so the UI does not flicker down to one name and back.
        if frameFileNames.count >= state.currentFileNames.count {
            state.currentFileNames = frameFileNames
        }
    }

    func setStatusMessage(_ message: String) {
        state.statusMessage = message
        state.notePhase(message)
    }

    func setDestinationURL(_ url: URL?) {
        state.destinationURL = url
    }

    /// Publishes a file name parsed from an "already present and verified" line
    /// so the UI can show which file is being integrity-checked.
    func noteVerifiedFile(_ displayName: String) {
        state.isVerifyingExistingFiles = true
        if state.currentFileNames == [displayName] { return }
        state.currentFileNames = [displayName]
    }

    func messageUpdate(_ message: String) -> NxdlDownloadUpdate {
        state.statusMessage = message
        state.notePhase(message)
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
    case incompleteUpdate(String)

    var errorDescription: String? {
        switch self {
        case let .binaryDownloadFailed(message):
            return "無法下載客戶端工具：\(message)"
        case let .binaryNotExecutable(path):
            return "客戶端工具無法執行：\(path)"
        case let .binaryChecksumMismatch(expected, actual):
            return "客戶端工具校驗失敗（預期 \(expected)，實際 \(actual)）"
        case let .processFailed(code, output):
            if output.isEmpty {
                return "客戶端工具失敗（結束代碼 \(code)）"
            }
            return "客戶端工具失敗（結束代碼 \(code)）：\(output)"
        case let .pathNormalizeFailed(message):
            return "無法還原下載檔案路徑：\(message)"
        case let .incompleteUpdate(message): return message
        case .cancelled:
            return "下載已取消"
        }
    }
}

/// SHA-256 helpers for the pinned `nxdl_darwin` binary (CommonCrypto → macOS 10.12+).
enum NxdlBinaryIntegrity {
    /// `shasum -a 256` of HikariCalyx/nxdl `v0.1.2-prerelease9` / `nxdl_darwin`.
    static let expectedSHA256Hex = "e200004877ce629a1f3103da2bbb1c3235c15dafcfe7996ac0907e09f481e34e"

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
            let count: Int = autoreleasepool {
                let chunk = handle.readData(ofLength: 1024 * 1024)
                chunk.withUnsafeBytes { rawBuffer in
                    _ = CC_SHA256_Update(&context, rawBuffer.baseAddress, CC_LONG(chunk.count))
                }
                return chunk.count
            }
            if count == 0 { break }
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
        guard !basename.hasPrefix("\\"), !basename.contains(":"),
              !basename.split(separator: "\\").contains("..") else { return nil }
        let parts = basename
            .split(separator: "\\", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard parts.count >= 2 else { return nil }
        return parts
    }
}

final class NxdlDownloader {
    static let releaseTag = "v0.1.2-prerelease9"
    static let binaryRemoteURL = URL(
        string: "https://github.com/HikariCalyx/nxdl/releases/download/v0.1.2-prerelease9/nxdl_darwin"
    )!
    /// Must match `NxdlBinaryIntegrity.expectedSHA256Hex` for this releaseTag.
    static let binarySHA256Hex = NxdlBinaryIntegrity.expectedSHA256Hex
    static let gameAlias = "tms_cw"
    static let classicExecutableName = "Maplestory_Classic.exe"
    static let applicationSupportFolderName = "local.ogom.beanfunotp"

    private let supportRoot: URL?
    // Internal pin used by reproducible historical-route tests. The app UI
    // always leaves this nil and follows the current official target.
    private let classicManifestTarget: String?
    private let fileManager: FileManager
    private let session: URLSession
    private let log: (String) -> Void
    private let processLock = NSLock()
    private var activeProcess: Process?
    private var binaryTask: URLSessionDownloadTask?
    private var epoch: UInt64 = 0
    private var completionSummary = ""
    var completionNote: String {
        processLock.lock(); defer { processLock.unlock() }; return completionSummary
    }
    private var currentEpoch: UInt64 {
        processLock.lock(); defer { processLock.unlock() }; return epoch
    }
    private func launch(_ process: Process, epoch expected: UInt64) throws {
        processLock.lock(); defer { processLock.unlock() }
        guard epoch == expected else { throw NxdlDownloaderError.cancelled }
        if #available(macOS 10.13, *) { try process.run() } else { process.launch() }
        activeProcess = process
    }
    private func clearProcess(_ process: Process) {
        processLock.lock(); defer { processLock.unlock() }
        if activeProcess === process { activeProcess = nil }
    }

    init(
        fileManager: FileManager = .default,
        supportRoot: URL? = nil,
        session: URLSession = .shared,
        classicManifestTarget: String? = nil,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.supportRoot = supportRoot
        self.session = session
        self.classicManifestTarget = classicManifestTarget
        self.log = log
    }

    func supportDirectory(for config: GameClientToolConfig) -> URL {
        let base = supportRoot ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent(Self.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent(config.cacheFolderName, isDirectory: true)
    }

    func binaryURL(for config: GameClientToolConfig) -> URL {
        supportDirectory(for: config).appendingPathComponent(config.binaryFileName)
    }

    /// nxdl classic cache shortcut (existing callers / tests).
    var supportDirectory: URL {
        supportDirectory(for: .nxdlClassic)
    }

    /// nxdl classic binary shortcut (existing callers / tests).
    var binaryURL: URL {
        binaryURL(for: .nxdlClassic)
    }

    func cancel() {
        processLock.lock()
        epoch &+= 1
        binaryTask?.cancel()
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        processLock.unlock()
    }

    func downloadClassicClient(
        to destination: URL,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        downloadClient(
            config: .nxdlClassic,
            to: destination,
            onUpdate: onUpdate,
            completion: completion
        )
    }

    func downloadMapleStoryClient(
        to destination: URL,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        downloadClient(
            config: .cmsdlMapleStory,
            to: destination,
            onUpdate: onUpdate,
            completion: completion
        )
    }

    func downloadClient(
        config: GameClientToolConfig,
        to destination: URL,
        operation: ClientUpdatePlan.Operation = .download,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let epoch = currentEpoch
        ensureBinary(config: config, onUpdate: onUpdate) { [weak self] result in
            guard let self else { return }
            guard self.currentEpoch == epoch else { completion(.failure(NxdlDownloaderError.cancelled)); return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(binary):
                if (config == .nxdlClassic || config == .cmsdlMapleStory)
                    && (operation == .patch || self.fileManager.fileExists(atPath: destination.path)) {
                    self.runTransactionalUpdate(config: config, binary: binary, destination: destination,
                        operation: operation, epoch: epoch, onUpdate: onUpdate, completion: completion)
                } else {
                    self.runDownload(config: config, binary: binary, destination: destination,
                        operation: operation, epoch: epoch, onUpdate: onUpdate, completion: completion)
                }
            }
        }
    }

    /// Ensures the tool binary, then runs `--check --json` over a pipe (no PTY)
    /// and returns parsed `total_size`.
    func probeTotalSize(
        config: GameClientToolConfig,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<UInt64, Error>) -> Void
    ) {
        ensureBinary(config: config, onUpdate: onUpdate) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(binary):
                self.runCheck(config: config, binary: binary, onUpdate: onUpdate, completion: completion)
            }
        }
    }

    /// Ensures the tool binary, then runs `--check -v` over a pipe
    /// and returns parsed `ManifestInfo`.
    func probeManifestInfo(
        config: GameClientToolConfig,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<ManifestInfo, Error>) -> Void
    ) {
        ensureBinary(config: config, onUpdate: onUpdate) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(binary):
                self.runVerboseCheck(config: config, binary: binary, onUpdate: onUpdate, completion: completion)
            }
        }
    }

    @available(macOS 10.15, *)
    func downloadClassicClient(
        to destination: URL,
        onUpdate: @escaping @Sendable (NxdlDownloadUpdate) -> Void
    ) async throws {
        try await downloadClient(config: .nxdlClassic, to: destination, onUpdate: onUpdate)
    }

    @available(macOS 10.15, *)
    func downloadMapleStoryClient(
        to destination: URL,
        onUpdate: @escaping @Sendable (NxdlDownloadUpdate) -> Void
    ) async throws {
        try await downloadClient(config: .cmsdlMapleStory, to: destination, onUpdate: onUpdate)
    }

    @available(macOS 10.15, *)
    func downloadClient(
        config: GameClientToolConfig,
        to destination: URL,
        operation: ClientUpdatePlan.Operation = .download,
        onUpdate: @escaping @Sendable (NxdlDownloadUpdate) -> Void
    ) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                downloadClient(config: config, to: destination, operation: operation, onUpdate: onUpdate) { result in
                    continuation.resume(with: result)
                }
            }
        }, onCancel: { self.cancel() })
    }

    @available(macOS 10.15, *)
    func probeTotalSize(
        config: GameClientToolConfig,
        onUpdate: @escaping @Sendable (NxdlDownloadUpdate) -> Void
    ) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt64, Error>) in
            probeTotalSize(config: config, onUpdate: onUpdate) { result in
                continuation.resume(with: result)
            }
        }
    }

    @available(macOS 10.15, *)
    func probeManifestInfo(
        config: GameClientToolConfig,
        onUpdate: @escaping @Sendable (NxdlDownloadUpdate) -> Void
    ) async throws -> ManifestInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ManifestInfo, Error>) in
            probeManifestInfo(config: config, onUpdate: onUpdate) { result in
                continuation.resume(with: result)
            }
        }
    }

    func inspectClient(
        config: GameClientToolConfig, destination: URL,
        completion: @escaping (Result<ClientUpdatePlan, Error>) -> Void
    ) {
        let epoch = currentEpoch
        ensureBinary(config: config, onUpdate: { _ in }) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(binary):
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try ClientUpdateTransaction.reclaimAbandoned(destination: destination)
                        let process = Process(), pipe = Pipe()
                        process.launchPath = binary.path
                        process.currentDirectoryPath = self.supportDirectory(for: config).path
                        process.arguments = config == .cmsdlMapleStory
                            ? [config.gameAlias, "--upgrade-path-check", "latest", destination.path, "-v"] : config.checkArguments
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = pipe; process.standardError = pipe
                        try self.launch(process, epoch: epoch)
                        defer { self.clearProcess(process) }
                        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
                        defer { timeout.cancel() }
                        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        process.waitUntilExit()
                        guard self.currentEpoch == epoch else { throw NxdlDownloaderError.cancelled }
                        guard process.terminationReason != .uncaughtSignal else {
                            throw NxdlDownloaderError.processFailed(-1, "更新查詢逾時，請重試。")
                        }
                        if config == .cmsdlMapleStory {
                            completion(.success(try ClientUpdateInspection.cmsdl(exitCode: process.terminationStatus, output: output)))
                        } else {
                            guard process.terminationStatus == 0, let json = Self.extractJSONObjectText(from: output) else {
                                throw NxdlDownloaderError.processFailed(process.terminationStatus, output)
                            }
                            completion(.success(try ClientUpdateInspection.classic(json: json, directory: destination)))
                        }
                    } catch { completion(.failure(error)) }
                }
            }
        }
    }

    @available(macOS 10.15, *)
    func inspectClient(config: GameClientToolConfig, destination: URL) async throws -> ClientUpdatePlan {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                inspectClient(config: config, destination: destination) { continuation.resume(with: $0) }
            }
        }, onCancel: { self.cancel() })
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
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            var existingAncestor = destinationParent
            while !fileManager.fileExists(atPath: existingAncestor.path) && existingAncestor.path != "/" {
                existingAncestor.deleteLastPathComponent()
            }
            let resolvedAncestor = existingAncestor.resolvingSymlinksInPath().standardizedFileURL.path
            guard (resolvedAncestor + "/" == resolvedRoot || resolvedAncestor.hasPrefix(resolvedRoot)),
                  (try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw NxdlDownloaderError.pathNormalizeFailed("路徑含符號連結，請手動檢查。")
            }
            try fileManager.createDirectory(
                at: destinationParent,
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                throw NxdlDownloaderError.pathNormalizeFailed("目標已存在，未覆寫任何檔案：\(destinationURL.lastPathComponent)")
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
        findPrimaryExecutable(config: .nxdlClassic, in: root)
    }

    func findPrimaryExecutable(config: GameClientToolConfig, in root: URL) -> String? {
        findExecutable(named: config.primaryExecutableName, in: root)
    }

    func findExecutable(named name: String, in root: URL) -> String? {
        let direct = root.appendingPathComponent(name).path
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
            if fileURL.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
                return fileURL.path
            }
            if fileURL.pathComponents.count - root.pathComponents.count > 4 {
                enumerator.skipDescendants()
            }
        }
        return nil
    }

    private func ensureBinary(
        config: GameClientToolConfig,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0)) else {
            completion(.failure(NxdlDownloaderError.binaryDownloadFailed("新版下載工具需要 macOS 11 以上；登入功能仍可使用。")))
            return
        }
        let expectedEpoch = currentEpoch
        let originalCompletion = completion
        let completion: (Result<URL, Error>) -> Void = { result in
            guard self.currentEpoch == expectedEpoch else { originalCompletion(.failure(NxdlDownloaderError.cancelled)); return }
            originalCompletion(result)
        }
        let url = binaryURL(for: config)
        let supportDir = supportDirectory(for: config)
        if fileManager.isExecutableFile(atPath: url.path) {
            do {
                try NxdlBinaryIntegrity.verifyFile(at: url.path, expectedSHA256Hex: config.sha256Hex)
                // Always clear quarantine before reuse: GateKeeper may still block a
                // cached binary that retained or regained com.apple.quarantine.
                try prepareBinaryForExecution(at: url.path)
                completion(.success(url))
                return
            } catch let error as NxdlDownloaderError {
                if case .binaryChecksumMismatch = error {
                    log("快取的 \(config.binaryFileName) 校驗失敗，將重新下載：\(error.localizedDescription)")
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

        onUpdate(.message("正在下載 \(config.binaryFileName)（\(config.releaseTag)）…"))
        do {
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }

        let task = session.downloadTask(with: config.binaryRemoteURL) { [weak self] tempURL, response, error in
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
                try NxdlBinaryIntegrity.verifyFile(at: tempURL.path, expectedSHA256Hex: config.sha256Hex)

                if self.fileManager.fileExists(atPath: url.path) {
                    try self.fileManager.removeItem(at: url)
                }
                try self.fileManager.moveItem(at: tempURL, to: url)
                try self.prepareBinaryForExecution(at: url.path)

                guard self.fileManager.isExecutableFile(atPath: url.path) else {
                    completion(.failure(NxdlDownloaderError.binaryNotExecutable(url.path)))
                    return
                }

                self.log("\(config.binaryFileName) 已就緒：\(url.path)")
                completion(.success(url))
            } catch {
                try? self.fileManager.removeItem(at: url)
                completion(.failure(error))
            }
        }
        processLock.lock(); binaryTask = task; processLock.unlock()
        task.resume()
    }

    private func runCheck(
        config: GameClientToolConfig,
        binary: URL,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<UInt64, Error>) -> Void
    ) {
        do {
            try prepareBinaryForExecution(at: binary.path)
        } catch {
            completion(.failure(error))
            return
        }

        onUpdate(.message("正在查詢客戶端大小…"))

        let stdoutPipe = Pipe()
        let stderrPipe = stdoutPipe
        let process = Process()
        process.launchPath = binary.path
        process.currentDirectoryPath = supportDirectory(for: config).path
        process.arguments = config.checkArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let expectedEpoch = currentEpoch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.clearProcess(process) }
            do { try self.launch(process, epoch: expectedEpoch) }
            catch { completion(.failure(error)); return }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
            defer { timeout.cancel() }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = Data()
            process.waitUntilExit()

            if process.terminationReason == .uncaughtSignal {
                completion(.failure(NxdlDownloaderError.cancelled))
                return
            }

            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self)
            let stderrText = String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)

            if process.terminationStatus != 0 {
                let cleaned = NxdlProgressParser.stripANSI(stderrText.isEmpty ? stdoutText : stderrText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = cleaned.isEmpty ? "無法取得客戶端大小" : "無法取得客戶端大小：\(cleaned)"
                completion(.failure(NxdlDownloaderError.processFailed(process.terminationStatus, detail)))
                return
            }

            guard let jsonText = Self.extractJSONObjectText(from: stdoutText)
                ?? Self.extractJSONObjectText(from: stderrText)
            else {
                completion(.failure(NxdlDownloaderError.processFailed(
                    process.terminationStatus,
                    "無法取得客戶端大小（找不到 JSON）"
                )))
                return
            }

            do {
                let total = try ClientCheckJSONParser.totalSizeBytes(fromJSONText: jsonText)
                completion(.success(total))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func runVerboseCheck(
        config: GameClientToolConfig,
        binary: URL,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<ManifestInfo, Error>) -> Void
    ) {
        do {
            try prepareBinaryForExecution(at: binary.path)
        } catch {
            completion(.failure(error))
            return
        }

        onUpdate(.message("正在查詢客戶端檔案清單…"))

        let stdoutPipe = Pipe()
        let stderrPipe = stdoutPipe
        let process = Process()
        process.launchPath = binary.path
        process.currentDirectoryPath = supportDirectory(for: config).path
        process.arguments = config.verboseCheckArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let expectedEpoch = currentEpoch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.clearProcess(process) }
            do { try self.launch(process, epoch: expectedEpoch) }
            catch { completion(.failure(error)); return }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
            defer { timeout.cancel() }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = Data()
            process.waitUntilExit()

            if process.terminationReason == .uncaughtSignal {
                completion(.failure(NxdlDownloaderError.cancelled))
                return
            }

            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self)
            let stderrText = String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)

            if process.terminationStatus != 0 {
                let cleaned = NxdlProgressParser.stripANSI(stderrText.isEmpty ? stdoutText : stderrText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = cleaned.isEmpty ? "無法取得客戶端檔案清單" : "無法取得客戶端檔案清單：\(cleaned)"
                completion(.failure(NxdlDownloaderError.processFailed(process.terminationStatus, detail)))
                return
            }

            let fullOutput = stdoutText + "\n" + stderrText
            let totalBytes = NxdlManifestParser.extractTotalBytes(from: fullOutput) ?? 0
            let filePaths = NxdlManifestParser.parseFilePaths(from: fullOutput, config: config)

            completion(.success(ManifestInfo(totalBytes: totalBytes, filePaths: filePaths)))
        }
    }

    /// Prefer a whole JSON object line; fall back to first `{`…last `}` span.
    private static func extractJSONObjectText(from raw: String) -> String? {
        ClientCheckJSONParser.extractJSONObjectText(from: raw)
    }


    private func runTransactionalUpdate(
        config: GameClientToolConfig, binary: URL, destination: URL, operation: ClientUpdatePlan.Operation, epoch: UInt64,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                onUpdate(.message("正在建立安全更新副本；完成驗證後才會切換遊戲資料夾。"))
                let check = { if self.currentEpoch != epoch { throw NxdlDownloaderError.cancelled } }
                let transaction = try ClientUpdateTransaction(destination: destination, checkCancelled: check)
                var handedOff = false
                defer { if !handedOff { transaction.discard() } }
                var executableOnly = false
                var retainExecutable = false
                if config == .cmsdlMapleStory {
                    let manifest = try self.fetchUpdateJSON(URL(string: "https://maplestory-download.beanfun.com/maplestory/productInfo.json")!, checkCancelled: check)
                    let currentBase = try TMSExecutablePolicy.hasCurrentBase(in: transaction.working, manifest: manifest)
                    executableOnly = operation == .patch && currentBase
                    retainExecutable = try TMSExecutablePolicy.shouldRetainExecutable(in: transaction.working, manifest: manifest)
                    // cmsdl reuses ExePatch.dat by length alone, even if a
                    // killed segmented download merely preallocated the file.
                    let hotfix = transaction.working.appendingPathComponent("ExePatch.dat")
                    if self.fileManager.fileExists(atPath: hotfix.path) { try self.fileManager.removeItem(at: hotfix) }
                }
                func prepareFullRepair() throws {
                    if config == .cmsdlMapleStory {
                        // Preserve a same-generation executable changed by the
                        // game. Clear placeholders and obsolete-generation EXEs.
                        let names = retainExecutable ? ["ExePatch.dat", "ExePatch.dat.cmsdl"]
                            : ["MapleStory.exe", "MapleStory.exe.cmsdl", "ExePatch.dat", "ExePatch.dat.cmsdl"]
                        for name in names {
                            let file = transaction.working.appendingPathComponent(name)
                            if self.fileManager.fileExists(atPath: file.path) { try self.fileManager.removeItem(at: file) }
                        }
                    } else if let entries = self.fileManager.enumerator(at: transaction.working, includingPropertiesForKeys: [.isRegularFileKey]) {
                        // NGM's resume bitmap does not authenticate the bytes
                        // already written. Restart those objects from the CDN.
                        for case let file as URL in entries where file.pathExtension == "ngmdl" {
                            try check()
                            try self.fileManager.removeItem(at: file)
                        }
                    }
                }
                if operation == .download || executableOnly { try prepareFullRepair() }
                if executableOnly && retainExecutable {
                    onUpdate(.message("主版本一致，保留既有主程式，避免覆蓋遊戲端的小更新。"))
                }
                func finish(_ result: Result<Void, Error>) {
                    do {
                        try result.get()
                        try check()
                        if config == .nxdlClassic {
                            try self.synchronizeClassic(transaction: transaction, checkCancelled: check, onUpdate: onUpdate)
                        }
                        var verification = NxdlDownloadProgressState()
                        verification.phase = .finishing
                        verification.statusMessage = "正在驗證更新後的遊戲檔案…"
                        onUpdate(.progress(verification))
                        try self.verifyUpdatedClient(config: config, directory: transaction.working, checkCancelled: check)
                        if config == .nxdlClassic {
                            let patchdata = transaction.working.appendingPathComponent("patchdata")
                            if self.fileManager.fileExists(atPath: patchdata.path) { try self.fileManager.removeItem(at: patchdata) }
                        }
                        try transaction.commit(checkCancelled: check)
                        if config == .nxdlClassic {
                            self.processLock.lock()
                            self.completionSummary = "經典版檔案校驗完成，已安全切換至目標版本。"
                            self.processLock.unlock()
                        }
                        completion(.success(()))
                    } catch { transaction.discard(); completion(.failure(error)) }
                }
                handedOff = true
                self.runDownload(config: config, binary: binary, destination: transaction.working,
                    operation: executableOnly ? .download : operation, executableOnly: executableOnly,
                    epoch: epoch, onUpdate: onUpdate) { result in
                    switch result {
                    case .success: finish(result)
                    case let .failure(error):
                        if self.currentEpoch != epoch { transaction.discard(); completion(.failure(NxdlDownloaderError.cancelled)); return }
                        guard operation == .patch else { finish(result); return }
                        if config == .nxdlClassic, let failure = error as? NxdlDownloaderError,
                           case let .processFailed(_, detail) = failure, detail.contains("unknown patch opcode") {
                            do {
                                onUpdate(.message("工具遇到未支援的差分指令，正在以相容解碼完成已校驗的補丁…"))
                                try self.completeClassicCompatibility(transaction: transaction, checkCancelled: check)
                                finish(.success(()))
                            } catch { finish(.failure(error)) }
                            return
                        }
                        // Missing routes and damaged old input can be recovered
                        // by the tools' authenticated full-file download. Keep
                        // it inside the private copy as well.
                        onUpdate(.message("差分更新未完成，改用完整檔案修復；原安裝仍保留。\(error.localizedDescription)"))
                        do {
                            try prepareFullRepair()
                            self.runDownload(config: config, binary: binary, destination: transaction.working,
                                operation: .download, epoch: epoch, onUpdate: onUpdate, completion: finish)
                        } catch { transaction.discard(); completion(.failure(error)) }
                    }
                }
            } catch { completion(.failure(error)) }
        }
    }

    /// Validate authoritative file digests, not just the patcher's exit status
    /// or final version marker. This also catches incomplete NGM patch routes
    /// which omit newly added files.
    func verifyUpdatedClient(config: GameClientToolConfig, directory: URL,
                                     checkCancelled: () throws -> Void) throws {
        let manifestURL: URL
        if config == .nxdlClassic {
            let hash: String
            if let pinned = classicManifestTarget { hash = pinned }
            else {
                let info = try fetchUpdateJSON(URL(string: "https://ngmapi.nexon.com/game-info/2982@2141")!, checkCancelled: checkCancelled)
                guard let latest = info["manifest_name"] as? String else { throw ClientCheckError.invalidJSON }
                hash = latest
            }
            guard hash.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
                  ClientUpdateInspection.classicMarker(in: directory)?.lowercased() == hash.lowercased() else {
                throw NxdlDownloaderError.incompleteUpdate("更新尚未到達伺服器目標版本；原安裝仍保留。")
            }
            manifestURL = URL(string: "https://tw-ngm.maplestoryclassic.games.gamania.com/\(hash)")!
        } else {
            manifestURL = URL(string: "https://maplestory-download.beanfun.com/maplestory/productInfo.json")!
        }
        let manifest = try fetchUpdateJSON(manifestURL, checkCancelled: checkCancelled)
        var files: [(String, String, Bool)] = []
        var ngmChunkSize = 0
        if config == .nxdlClassic {
            guard let entries = manifest["files"] as? [String: [String: Any]], !entries.isEmpty,
                  let size = manifest["chunk_size"] as? Int, size > 0, size <= 16 * 1024 * 1024 else {
                throw ClientCheckError.invalidJSON
            }
            ngmChunkSize = size
            for (encoded, entry) in entries {
                guard let raw = Data(base64Encoded: encoded), let path = String(data: raw, encoding: .utf8),
                      let objects = entry["objects"] as? [String: String] else { throw ClientCheckError.invalidJSON }
                if objects.isEmpty || objects.values.contains("__DIR__") { continue }
                let ordered = objects.compactMap { key, value -> (Int, String)? in
                    guard let index = Int(key), index >= 0,
                          value.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { return nil }
                    return (index, value)
                }.sorted { $0.0 < $1.0 }
                guard ordered.count == objects.count,
                      ordered.enumerated().allSatisfy({ $0.offset == $0.element.0 }) else { throw ClientCheckError.invalidJSON }
                // The NGM file-level `hash` is not the uncompressed file hash.
                // Authenticate each uncompressed object against its SHA-1.
                files.append((path, ordered.map { $0.1 }.joined(), true))
            }
        } else {
            guard let entries = manifest["files"] as? [[String: Any]], !entries.isEmpty else { throw ClientCheckError.invalidJSON }
            for entry in entries {
                guard let path = entry["path"] as? String, let hash = entry["sha256"] as? String else { throw ClientCheckError.invalidJSON }
                // The standalone executable hotfix intentionally differs from
                // the full-client digest; runDownload checks its own outcome.
                if path.lowercased() == "maplestory.exe" { continue }
                // Official major patches remove this obsolete installer helper.
                // Its absence is expected; runtime/data files remain mandatory.
                if path.lowercased() == "shortcuts.ini",
                   !fileManager.fileExists(atPath: directory.appendingPathComponent(path).path) { continue }
                files.append((path, hash, false))
            }
        }
        for (path, expected, sha1) in files {
            try checkCancelled()
            let components = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else {
                throw ClientCheckError.invalidJSON
            }
            let file = components.reduce(directory) { $0.appendingPathComponent($1) }
            guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                  try Self.updateDigest(file, sha1: sha1, chunkSize: ngmChunkSize, checkCancelled: checkCancelled).lowercased() == expected.lowercased() else {
                throw NxdlDownloaderError.incompleteUpdate("更新後檔案未通過完整性檢查：\(path)。原安裝仍保留，可改用完整下載修復。")
            }
        }
    }

    private func completeClassicCompatibility(transaction: ClientUpdateTransaction,
                                               checkCancelled: () throws -> Void) throws {
        guard let source = ClientUpdateInspection.classicMarker(in: transaction.destination) else { throw ClientCheckError.invalidJSON }
        let target: String
        if let pinned = classicManifestTarget { target = pinned }
        else {
            let info = try fetchUpdateJSON(URL(string: "https://ngmapi.nexon.com/game-info/2982@2141")!, checkCancelled: checkCancelled)
            guard let hash = info["manifest_name"] as? String else { throw ClientCheckError.invalidJSON }
            target = hash
        }
        guard [source, target].allSatisfy({ $0.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil }) else { throw ClientCheckError.invalidJSON }
        let base = "https://tw-ngm.maplestoryclassic.games.gamania.com/"
        let patchManifest = try fetchUpdateJSON(URL(string: base + target + "-" + source)!, checkCancelled: checkCancelled)
        let full = try fetchUpdateJSON(URL(string: base + target)!, checkCancelled: checkCancelled)
        guard let entries = patchManifest["files"] as? [String: [String: Any]],
              let targetFiles = full["files"] as? [String: [String: Any]],
              let chunkSize = patchManifest["chunk_size"] as? Int, chunkSize > 0, chunkSize <= 16 * 1024 * 1024 else { throw ClientCheckError.invalidJSON }
        var applied = 0
        for (encoded, entry) in entries {
            try checkCancelled()
            guard let data = Data(base64Encoded: encoded), let path = String(data: data, encoding: .utf8) else { throw ClientCheckError.invalidJSON }
            let components = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else { throw ClientCheckError.invalidJSON }
            let relative = components.joined(separator: "/")
            let patch = transaction.working.appendingPathComponent("patchdata/patches/" + relative + ".nxdlpatch")
            guard fileManager.fileExists(atPath: patch.path) else { continue } // nxdl removed successful streams.
            guard let objects = entry["objects"] as? [String: String],
                  let patchSize = entry["uncompressed_size"] as? Int, patchSize >= 0,
                  let targetSize = targetFiles[encoded]?["uncompressed_size"] as? Int, targetSize >= 0 else { throw ClientCheckError.invalidJSON }
            let ordered = objects.compactMap { key, hash -> (Int, String)? in
                guard let index = Int(key), index >= 0,
                      hash.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { return nil }
                return (index, hash)
            }.sorted { $0.0 < $1.0 }
            guard ordered.count == objects.count, !ordered.isEmpty,
                  ordered.enumerated().allSatisfy({ $0.offset == $0.element.0 }),
                  (try patch.resourceValues(forKeys: [.fileSizeKey])).fileSize == patchSize,
                  try Self.updateDigest(patch, sha1: true, chunkSize: chunkSize, checkCancelled: checkCancelled).lowercased() == ordered.map({ $0.1 }).joined().lowercased() else {
                throw NxdlDownloaderError.incompleteUpdate("相容補丁未通過官方物件雜湊校驗。")
            }
            let original = transaction.destination.appendingPathComponent(relative)
            let output = transaction.working.appendingPathComponent(relative)
            let temporary = transaction.workspace.appendingPathComponent("compatible-\(UUID().uuidString)")
            guard [original, patch, output].allSatisfy({ $0.resolvingSymlinksInPath().path == $0.standardizedFileURL.path }) else { throw ClientCheckError.invalidJSON }
            try NGMDeltaCompatibility.apply(source: original, patch: patch, output: temporary,
                expectedSize: UInt64(targetSize), checkCancelled: checkCancelled)
            try fileManager.removeItem(at: output)
            try fileManager.moveItem(at: temporary, to: output)
            try fileManager.removeItem(at: patch)
            applied += 1
        }
        guard applied > 0 else { throw NxdlDownloaderError.incompleteUpdate("沒有可安全續接的差分指令。") }
        try target.write(to: transaction.working.appendingPathComponent("2982.manifest.hash"), atomically: true, encoding: .utf8)
    }

    private func synchronizeClassic(transaction: ClientUpdateTransaction, checkCancelled: () throws -> Void,
                                    onUpdate: (NxdlDownloadUpdate) -> Void) throws {
        let hash: String
        if let pinned = classicManifestTarget { hash = pinned }
        else {
            let info = try fetchUpdateJSON(URL(string: "https://ngmapi.nexon.com/game-info/2982@2141")!, checkCancelled: checkCancelled)
            guard let remote = info["manifest_name"] as? String else { throw ClientCheckError.invalidJSON }
            hash = remote
        }
        guard hash.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw ClientCheckError.invalidJSON }
        let manifest = try fetchUpdateJSON(URL(string: "https://tw-ngm.maplestoryclassic.games.gamania.com/\(hash)")!, checkCancelled: checkCancelled)
        var progress = NxdlDownloadProgressState()
        progress.phase = .checking
        progress.statusMessage = "正在比對官方完整清單與差分結果…"
        onUpdate(.progress(progress))
        let result = try NGMClientSynchronization.synchronize(directory: transaction.working, scratch: transaction.workspace,
            manifest: manifest, fetch: { try self.fetchUpdateData($0, checkCancelled: checkCancelled) },
            checkCancelled: checkCancelled, report: {
                progress.phase = .downloading; progress.statusMessage = $0
                onUpdate(.progress(progress))
            })
        onUpdate(.message("官方清單同步完成：補齊 \(result.files) 個檔案、下載 \(result.objects) 個已校驗物件。"))
        try hash.write(to: transaction.working.appendingPathComponent("2982.manifest.hash"), atomically: true, encoding: .utf8)
    }

    private func fetchUpdateJSON(_ url: URL, checkCancelled: () throws -> Void) throws -> [String: Any] {
        let data = try fetchUpdateData(url, fresh: true, checkCancelled: checkCancelled)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientCheckError.invalidJSON }
        return object
    }

    private func fetchUpdateData(_ url: URL, fresh: Bool = false, checkCancelled: () throws -> Void) throws -> Data {
        let result = UpdateJSONResult()
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let task = session.dataTask(with: request) { data, response, error in
            result.data = data; result.status = (response as? HTTPURLResponse)?.statusCode; result.error = error
            semaphore.signal()
        }
        task.resume()
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(60)
        while semaphore.wait(timeout: .now() + 0.2) != .success {
            try checkCancelled()
            if Date() >= deadline { throw URLError(.timedOut) }
        }
        try checkCancelled()
        if let error = result.error { throw error }
        guard result.status == 200, let data = result.data, data.count <= 32 * 1024 * 1024 else { throw ClientCheckError.invalidJSON }
        return data
    }

    private final class UpdateJSONResult: @unchecked Sendable {
        var data: Data?; var status: Int?; var error: Error?
    }

    private static func updateDigest(_ url: URL, sha1: Bool, chunkSize: Int, checkCancelled: () throws -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        if sha1 {
            var hashes = ""
            while true {
                try checkCancelled()
                let hash: String? = autoreleasepool {
                    let data = handle.readData(ofLength: chunkSize)
                    if data.isEmpty { return nil }
                    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
                    data.withUnsafeBytes { raw in _ = CC_SHA1(raw.baseAddress, CC_LONG(data.count), &digest) }
                    return digest.map { String(format: "%02x", $0) }.joined()
                }
                guard let hash else { return hashes }
                hashes += hash
            }
        }
        var one = CC_SHA1_CTX(), two = CC_SHA256_CTX()
        if sha1 { CC_SHA1_Init(&one) } else { CC_SHA256_Init(&two) }
        while true {
            try checkCancelled()
            let count: Int = autoreleasepool {
                let data = handle.readData(ofLength: 1024 * 1024)
                data.withUnsafeBytes { raw in
                    if sha1 { _ = CC_SHA1_Update(&one, raw.baseAddress, CC_LONG(data.count)) }
                    else { _ = CC_SHA256_Update(&two, raw.baseAddress, CC_LONG(data.count)) }
                }
                return data.count
            }
            if count == 0 { break }
        }
        var digest = [UInt8](repeating: 0, count: Int(sha1 ? CC_SHA1_DIGEST_LENGTH : CC_SHA256_DIGEST_LENGTH))
        if sha1 { CC_SHA1_Final(&digest, &one) } else { CC_SHA256_Final(&digest, &two) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func runDownload(
        config: GameClientToolConfig,
        binary: URL,
        destination: URL,
        operation: ClientUpdatePlan.Operation,
        executableOnly: Bool = false,
        epoch: UInt64,
        onUpdate: @escaping (NxdlDownloadUpdate) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try self.prepareBinaryForExecution(at: binary.path)
                let pty = try Self.openPseudoTerminal()
                defer { pty.master.closeFile() }
                let process = Process()
                process.launchPath = binary.path
                process.currentDirectoryPath = self.supportDirectory(for: config).path
                if executableOnly {
                    process.arguments = [config.gameAlias, "--download", destination.path, "--filter=MapleStory.exe", "--no-gui"]
                } else if operation == .patch {
                    if let target = self.classicManifestTarget,
                       target.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) == nil { throw ClientCheckError.invalidJSON }
                    process.arguments = config == .cmsdlMapleStory
                        ? [config.gameAlias, "--patch", "latest", destination.path, "--no-gui"]
                        : [config.gameAlias, "--patch"] + (self.classicManifestTarget.map { [$0] } ?? []) + [destination.path]
                } else { process.arguments = config.downloadArguments(destinationPath: destination.path) }
                var environment = ProcessInfo.processInfo.environment
                environment["TERM"] = "xterm-256color"
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pty.slave
                process.standardError = pty.slave
                do { try self.launch(process, epoch: epoch) }
                catch { pty.slave.closeFile(); throw error }
                pty.slave.closeFile()
                defer { self.clearProcess(process) }
                onUpdate(.message(operation == .patch ? "正在套用更新…" : Self.downloadStatusMessage(for: config)))
                let parser = NxdlOutputStreamParser()
                var carry = Data(), lines: [String] = []
                var buffer = [UInt8](repeating: 0, count: 32768)
                var warning: String?
                var unsupportedPatchOpcode: String?
                var minorInstalled = false
                var executableRetained = false
                var noMinorPublished = false
                func emit(_ updates: [NxdlDownloadUpdate]) {
                    for update in updates {
                        onUpdate(update)
                        let message: String
                        switch update {
                        case let .message(text): message = text
                        case let .progress(state): message = state.statusMessage
                        }
                        if !message.isEmpty {
                            lines.append(message)
                            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
                            let lower = message.lowercased()
                            if lower.contains("unknown patch opcode") { unsupportedPatchOpcode = message }
                            if lower.contains("maplestory.exe updated.") || lower.contains("replaced with the downloaded hotfix") { minorInstalled = true }
                            if lower.contains("maplestory.exe: kept as is") || lower.contains("keeping the existing file") { executableRetained = true }
                            if lower.contains("no minor patch available") || lower.contains("no minor patch.") { noMinorPublished = true }
                            if lower.contains("warning:") && (lower.contains("patch") || lower.contains("maplestory.exe")) {
                                warning = "主程式小更新尚未確認完成，請稍後再試；已保留既有遊戲檔案。"
                            }
                        }
                    }
                }
                while true {
                    let count = Darwin.read(pty.master.fileDescriptor, &buffer, buffer.count)
                    if count > 0 {
                        carry.append(contentsOf: buffer.prefix(count))
                        emit(parser.ingest(Self.drainDecodableUTF8(from: &carry)))
                    } else if count < 0 && errno == EINTR { continue }
                    else { break }
                }
                if !carry.isEmpty { emit(parser.ingest(String(decoding: carry, as: UTF8.self))) }
                emit(parser.finish())
                process.waitUntilExit()
                guard self.currentEpoch == epoch, process.terminationReason != .uncaughtSignal else {
                    throw NxdlDownloaderError.cancelled
                }
                guard process.terminationStatus == 0 else {
                    throw NxdlDownloaderError.processFailed(process.terminationStatus,
                        unsupportedPatchOpcode ?? NxdlFailureMessage.preferred(from: lines, lastProgressLine: ""))
                }
                if let warning { throw NxdlDownloaderError.incompleteUpdate(warning) }
                self.processLock.lock()
                self.completionSummary = config == .cmsdlMapleStory
                    ? (executableRetained ? "已保留現有主程式，避免覆蓋遊戲端的小更新；遊戲檔案驗證完成。"
                       : minorInstalled ? "主程式小更新已套用；本次作業完成。"
                       : noMinorPublished ? "本次未發現可用的主程式小更新；遊戲檔案作業完成。"
                       : "遊戲檔案作業完成；主程式小更新尚未確認，必要時請再次檢查。")
                    : "本次經典版作業完成；可登入遊戲。"
                self.processLock.unlock()
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    private static func downloadStatusMessage(for config: GameClientToolConfig) -> String {
        if config == .nxdlClassic {
            return "正在下載新楓之谷：經典版客戶端…"
        }
        if config == .cmsdlMapleStory {
            return "正在下載新楓之谷客戶端…"
        }
        return "正在下載遊戲客戶端…"
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
                "無法解除 quarantine：\(path)"
            )
        }
        log("已解除 quarantine：\(path)")
    }
}

enum NxdlManifestParser {
    static func extractTotalBytes(from text: String) -> UInt64? {
        let cleaned = NxdlProgressParser.stripANSI(text)
        guard let regex = try? NSRegularExpression(pattern: #"\(([\d,]+)\s*bytes\)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = cleaned as NSString
        let matches = regex.matches(in: cleaned, options: [], range: NSRange(location: 0, length: nsText.length))
        guard let lastMatch = matches.last, lastMatch.numberOfRanges > 1 else {
            return nil
        }
        let digitsStr = nsText.substring(with: lastMatch.range(at: 1)).replacingOccurrences(of: ",", with: "")
        return UInt64(digitsStr)
    }

    static func parseFilePaths(from text: String, config: GameClientToolConfig) -> [String] {
        let cleaned = NxdlProgressParser.stripANSI(text)
        let lines = cleaned.components(separatedBy: .newlines)
        var filePaths: [String] = []

        if config == .cmsdlMapleStory {
            var inFilesSection = false
            for line in lines {
                if line.contains("file(s):") {
                    inFilesSection = true
                    continue
                }
                if inFilesSection {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("  ") && !trimmed.isEmpty {
                        filePaths.append(trimmed)
                    } else if !line.hasPrefix(" ") && !trimmed.isEmpty {
                        inFilesSection = false
                    }
                }
            }
        } else {
            var inTable = false
            for line in lines {
                if line.hasPrefix("PATH") && line.contains("SIZE") {
                    inTable = true
                    continue
                }
                if inTable && line.hasPrefix("----") {
                    continue
                }
                if inTable {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    let lineStr = line as NSString
                    if let regex = try? NSRegularExpression(pattern: #"^\s*(\S.*?)\s{2,}"#, options: []),
                       let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: lineStr.length)),
                       match.numberOfRanges > 1 {
                        let path = lineStr.substring(with: match.range(at: 1))
                        if path != "PATH" {
                            filePaths.append(path)
                        }
                    }
                }
            }
        }
        return filePaths
    }
}
