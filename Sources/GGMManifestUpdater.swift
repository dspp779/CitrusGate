import Foundation

final class GGMManifestUpdater {
    private let manifestURL: URL
    private let session: URLSession
    private let store: GGMManifestStore
    private let log: (String) -> Void

    init(
        manifestURL: URL,
        session: URLSession = .shared,
        store: GGMManifestStore,
        log: @escaping (String) -> Void
    ) {
        self.manifestURL = manifestURL
        self.session = session
        self.store = store
        self.log = log
    }

    func refreshIfNeeded(current: GGMManifest) async -> GGMManifest {
        do {
            var request = URLRequest(url: manifestURL)
            if let metadata = try store.loadCachedMetadata() {
                if let etag = metadata.etag {
                    request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                }
                if let lastModified = metadata.lastModified {
                    request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
                }
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return current
            }
            if http.statusCode == 304 {
                log("GGM manifest 未更新（304）")
                return current
            }
            guard http.statusCode == 200 else {
                log("GGM manifest 更新略過：HTTP \(http.statusCode)")
                return current
            }

            let remote = try JSONDecoder().decode(GGMManifest.self, from: data)
            guard remote.isValid else {
                log("GGM manifest 更新略過：遠端 JSON 無效")
                return current
            }
            guard remote.isNewer(than: current) else {
                log("GGM manifest 未更新（遠端不比本機新）")
                return current
            }

            let metadata = GGMManifestCacheMetadata(
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                fetchedAt: ISO8601DateFormatter().string(from: Date())
            )
            try store.saveCachedManifest(remote, metadata: metadata)
            log("GGM manifest 已更新為 \(remote.updatedAt)")
            return remote
        } catch {
            log("GGM manifest 更新失敗：\(error.localizedDescription)")
            return current
        }
    }
}
