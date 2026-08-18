import Foundation

struct GGMManifest: Codable, Equatable {
    struct MapleStoryConfig: Codable, Equatable {
        let ggmClientVersion: String
        let ggmWebStartDllSha256: String
    }

    let schemaVersion: Int
    let updatedAt: String
    let mapleStory: MapleStoryConfig

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case mapleStory = "maplestory"
    }

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

    static func fromJSONData(_ data: Data) throws -> GGMManifest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BeanfunError.parse("GGM manifest 不是 JSON object")
        }
        guard let schemaVersion = intValue(object["schemaVersion"]) else {
            throw BeanfunError.parse("GGM manifest 缺少 schemaVersion")
        }
        guard let updatedAt = object["updatedAt"] as? String else {
            throw BeanfunError.parse("GGM manifest 缺少 updatedAt")
        }
        guard let maple = object["maplestory"] as? [String: Any],
              let cv = maple["ggmClientVersion"] as? String,
              let hash = maple["ggmWebStartDllSha256"] as? String else {
            throw BeanfunError.parse("GGM manifest 缺少 maplestory 欄位")
        }
        return GGMManifest(
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            mapleStory: .init(ggmClientVersion: cv, ggmWebStartDllSha256: hash)
        )
    }

    func jsonData() throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "updatedAt": updatedAt,
            "maplestory": [
                "ggmClientVersion": mapleStory.ggmClientVersion,
                "ggmWebStartDllSha256": mapleStory.ggmWebStartDllSha256,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static let timestampFormatter = ISO8601DateFormatter()
}
