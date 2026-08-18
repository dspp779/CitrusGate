import Foundation

struct GGMManifest: Codable, Equatable {
    struct MapleStoryConfig: Codable, Equatable {
        let ggmClientVersion: String
        let ggmWebStartDllSha256: String
    }

    let schemaVersion: Int
    let updatedAt: String
    let mapleStory: MapleStoryConfig

    static let bundledResourceName = "ggm-manifest"

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
            && Self.timestampFormatter.date(from: updatedAt) != nil
            && !mapleStory.ggmClientVersion.isEmpty
            && mapleStory.ggmWebStartDllSha256.count == 64
            && mapleStory.ggmWebStartDllSha256.allSatisfy(\.isHexDigit)
    }

    func isNewer(than other: GGMManifest) -> Bool {
        guard let lhs = Self.timestampFormatter.date(from: updatedAt),
              let rhs = Self.timestampFormatter.date(from: other.updatedAt) else {
            return false
        }
        return lhs > rhs
    }

    private static let timestampFormatter = ISO8601DateFormatter()
}
