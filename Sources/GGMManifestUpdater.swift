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

    func refreshIfNeeded(current: GGMManifest, completion: @escaping (GGMManifest) -> Void) {
        let finish: (GGMManifest) -> Void = { value in
            DispatchQueue.main.async { completion(value) }
        }

        var request = URLRequest(url: manifestURL)
        if let metadata = try? store.loadCachedMetadata() {
            if let etag = metadata.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = metadata.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                finish(current)
                return
            }
            if let error {
                self.log("GGM manifest 更新失敗：\(error.localizedDescription)")
                finish(current)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(current)
                return
            }
            if http.statusCode == 304 {
                self.log("GGM manifest 未更新（304）")
                finish(current)
                return
            }
            guard http.statusCode == 200, let data else {
                self.log("GGM manifest 更新略過：HTTP \(http.statusCode)")
                finish(current)
                return
            }

            do {
                let remote = try GGMManifest.fromJSONData(data)
                guard remote.isValid else {
                    self.log("GGM manifest 更新略過：遠端 JSON 無效")
                    finish(current)
                    return
                }
                guard remote.isNewer(than: current) else {
                    self.log("GGM manifest 未更新（遠端不比本機新）")
                    finish(current)
                    return
                }

                let metadata = GGMManifestCacheMetadata(
                    etag: Self.headerValue(http, "ETag"),
                    lastModified: Self.headerValue(http, "Last-Modified"),
                    fetchedAt: ISO8601DateFormatter().string(from: Date())
                )
                try self.store.saveCachedManifest(remote, metadata: metadata)
                self.log("GGM manifest 已更新為 \(remote.updatedAt)")
                finish(remote)
            } catch {
                self.log("GGM manifest 更新失敗：\(error.localizedDescription)")
                finish(current)
            }
        }
        task.resume()
    }

    private static func headerValue(_ response: HTTPURLResponse, _ name: String) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String,
                  key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return value as? String
        }
        return nil
    }
}
