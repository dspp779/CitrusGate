import Foundation

struct GGMManifestCacheMetadata: Codable, Equatable {
    let etag: String?
    let lastModified: String?
    let fetchedAt: String
}

final class GGMManifestStore {
    private let fileManager: FileManager
    private let bundle: Bundle
    private let appSupportRoot: URL

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        appSupportRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.appSupportRoot = appSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    func loadFallbackManifest() throws -> GGMManifest {
        guard let url = bundle.url(forResource: GGMManifest.bundledResourceName, withExtension: "json") else {
            return GGMManifest.fallback()
        }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(GGMManifest.self, from: data)
        return manifest.isValid ? manifest : GGMManifest.fallback()
    }

    func loadCachedManifest() throws -> GGMManifest? {
        let url = try cacheDirectory().appendingPathComponent("ggm-manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(GGMManifest.self, from: data)
        return manifest.isValid ? manifest : nil
    }

    func loadCachedMetadata() throws -> GGMManifestCacheMetadata? {
        let url = try cacheDirectory().appendingPathComponent("ggm-manifest.metadata.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GGMManifestCacheMetadata.self, from: data)
    }

    func saveCachedManifest(_ manifest: GGMManifest, metadata: GGMManifestCacheMetadata) throws {
        let dir = try cacheDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("ggm-manifest.json"))
        try encoder.encode(metadata).write(to: dir.appendingPathComponent("ggm-manifest.metadata.json"))
    }

    func cacheDirectory() throws -> URL {
        let dir = appSupportRoot.appendingPathComponent("Beanfun OTP", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
