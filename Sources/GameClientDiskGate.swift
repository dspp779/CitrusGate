import Foundation

enum ClientCheckError: LocalizedError {
    case invalidJSON
    case missingTotalSize
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "無法解析客戶端大小資訊（JSON 無效）"
        case .missingTotalSize: return "無法解析客戶端大小資訊（缺少 total_size）"
        case .invalidSize: return "客戶端大小資訊不是有效的非負整數"
        }
    }
}

enum ClientCheckJSONParser {
    /// stdout/stderr share a pipe so neither can fill while the other is read.
    /// Accept only a real JSON object, even when a warning follows the JSON line.
    static func extractJSONObjectText(from raw: String) -> String? {
        let cleaned = NxdlProgressParser.stripANSI(raw)
        var candidates = [cleaned.trimmingCharacters(in: .whitespacesAndNewlines)]
        candidates += cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end {
            candidates.append(String(cleaned[start...end]))
        }
        for text in candidates where text.hasPrefix("{") {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["total_size"] != nil else { continue }
            return text
        }
        return nil
    }

    static func totalSizeBytes(fromJSONText text: String) throws -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClientCheckError.invalidJSON
        }
        guard let number = obj["total_size"] as? NSNumber else { throw ClientCheckError.missingTotalSize }
        guard CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = UInt64(number.stringValue), value <= UInt64(Int64.max) - DiskSpaceGate.gibibyte else {
            throw ClientCheckError.invalidSize
        }
        return value
    }
}

struct ManifestInfo: Equatable {
    let totalBytes: UInt64
    let filePaths: [String]
}

enum IncrementalSizeCalculator {
    /// Compares manifest relative file paths with local files in `destination`.
    /// Returns the estimated remaining bytes needed to be downloaded.
    /// This is an estimate only; zero must never be treated as a version/integrity verdict.
    static func calculateRequiredDownloadBytes(
        manifestFiles: [String],
        totalManifestBytes: UInt64,
        destination: URL
    ) -> UInt64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            return totalManifestBytes
        }

        if manifestFiles.isEmpty {
            return totalManifestBytes
        }

        var existingCount = 0
        var existingBytes: UInt64 = 0

        for relPath in manifestFiles {
            let normPath = relPath.replacingOccurrences(of: "\\", with: "/")
            let itemURL = destination.appendingPathComponent(normPath)
            if fm.fileExists(atPath: itemURL.path) {
                existingCount += 1
                if let attrs = try? fm.attributesOfItem(atPath: itemURL.path),
                   let size = attrs[.size] as? NSNumber {
                    existingBytes += size.uint64Value
                }
            }
        }

        if existingCount == manifestFiles.count && (existingBytes + 1_000_000 >= totalManifestBytes) {
            return 0
        }

        if existingBytes >= totalManifestBytes {
            return 0
        }

        return totalManifestBytes - existingBytes
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

    static func reserve(total: UInt64, patch: UInt64) -> UInt64 {
        let sum = total.addingReportingOverflow(patch)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    static func updateReserve(total: UInt64, patch: UInt64) -> UInt64 {
        // A non-cloning volume needs a private client copy AND patch scratch
        // space before the atomic exchange. APFS will generally use less.
        reserve(total: reserve(total: total, patch: total), patch: patch)
    }

    static func evaluate(totalBytes: UInt64, freeBytes: UInt64) -> DiskSpaceEvaluation {
        let comfortableDouble = Double(totalBytes) * 1.05
        let comfortable = comfortableDouble >= Double(UInt64.max) ? UInt64.max : UInt64(comfortableDouble)
        let sum = totalBytes.addingReportingOverflow(gibibyte)
        let minimum = sum.overflow ? UInt64.max : sum.partialValue
        let verdict: DiskSpaceVerdict
        if sum.overflow {
            verdict = .blocked
        } else if minimum > comfortable {
            verdict = freeBytes >= minimum ? .ok : .blocked
        } else if freeBytes >= comfortable {
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

enum VolumeFreeSpaceError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case let .unavailable(path):
            return "無法讀取磁碟剩餘空間：\(path)"
        }
    }
}

enum VolumeFreeSpace {
    /// Returns free bytes on the volume containing `url`, or throws if unavailable.
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
}

enum ByteCountFormat {
    static func string(bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
