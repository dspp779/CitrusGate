import Foundation

struct GGMManifestCacheMetadata: Equatable {
    let etag: String?
    let lastModified: String?
    let fetchedAt: String

    static func fromJSONData(_ data: Data) throws -> GGMManifestCacheMetadata {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BeanfunError.parse("GGM manifest metadata 不是 JSON object")
        }
        guard let fetchedAt = object["fetchedAt"] as? String else {
            throw BeanfunError.parse("GGM manifest metadata 缺少 fetchedAt")
        }
        return GGMManifestCacheMetadata(
            etag: object["etag"] as? String,
            lastModified: object["lastModified"] as? String,
            fetchedAt: fetchedAt
        )
    }

    func jsonData() throws -> Data {
        var object: [String: Any] = ["fetchedAt": fetchedAt]
        if let etag {
            object["etag"] = etag
        }
        if let lastModified {
            object["lastModified"] = lastModified
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    }
}

final class GGMManifestStore {
    static let modernCacheFolderName = "Beanfun OTP"
    static let legacyCacheFolderName = "Beanfun OTP Legacy"

    private let fileManager: FileManager
    private let bundle: Bundle
    private let cacheFolderName: String
    private let appSupportRoot: URL

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        cacheFolderName: String = GGMManifestStore.modernCacheFolderName,
        appSupportRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.cacheFolderName = cacheFolderName
        self.appSupportRoot = appSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    func loadFallbackManifest() throws -> GGMManifest {
        guard let url = bundle.url(forResource: GGMManifest.bundledResourceName, withExtension: "json") else {
            return GGMManifest.fallback()
        }
        let data = try Data(contentsOf: url)
        let manifest = try GGMManifest.fromJSONData(data)
        return manifest.isValid ? manifest : GGMManifest.fallback()
    }

    func loadCachedManifest() throws -> GGMManifest? {
        let url = try cacheDirectory().appendingPathComponent("ggm-manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let manifest = try GGMManifest.fromJSONData(data)
        return manifest.isValid ? manifest : nil
    }

    func loadCachedMetadata() throws -> GGMManifestCacheMetadata? {
        let url = try cacheDirectory().appendingPathComponent("ggm-manifest.metadata.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try GGMManifestCacheMetadata.fromJSONData(data)
    }

    func saveCachedManifest(_ manifest: GGMManifest, metadata: GGMManifestCacheMetadata) throws {
        let dir = try cacheDirectory()
        try manifest.jsonData().write(to: dir.appendingPathComponent("ggm-manifest.json"))
        try metadata.jsonData().write(to: dir.appendingPathComponent("ggm-manifest.metadata.json"))
    }

    func cacheDirectory() throws -> URL {
        let dir = appSupportRoot.appendingPathComponent(cacheFolderName, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
