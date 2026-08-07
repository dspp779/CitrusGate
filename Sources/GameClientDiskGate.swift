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

struct ManifestInfo: Equatable {
    let totalBytes: UInt64
    let filePaths: [String]
}

enum IncrementalSizeCalculator {
    /// Compares manifest relative file paths with local files in `destination`.
    /// Returns the estimated remaining bytes needed to be downloaded.
    /// If all manifest files exist and their total size >= `totalManifestBytes`, returns 0.
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

    static func evaluate(totalBytes: UInt64, freeBytes: UInt64) -> DiskSpaceEvaluation {
        let comfortable = UInt64(Double(totalBytes) * 1.05)
        let minimum = totalBytes + gibibyte
        let verdict: DiskSpaceVerdict
        if minimum > comfortable {
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
