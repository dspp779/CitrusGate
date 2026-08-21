import AppKit
import Foundation

enum BeanfunWebStartOTP {
    static func makeURL(
        host: String,
        sn: String,
        webToken: String,
        secretCode: String,
        ppppp: String,
        serviceCode: String,
        serviceRegion: String,
        serviceAccount: String,
        createTime: String,
        d: String
    ) throws -> URL {
        let createTimeEncoded = createTime.replacingOccurrences(of: " ", with: "%20")
        let query = [
            "SN=\(sn)",
            "WebToken=\(webToken)",
            "SecretCode=\(secretCode)",
            "ppppp=\(ppppp)",
            "ServiceCode=\(serviceCode)",
            "ServiceRegion=\(serviceRegion)",
            "ServiceAccount=\(serviceAccount)",
            "CreateTime=\(createTimeEncoded)",
            "d=\(d)",
        ]
        let value = "https://\(host)/beanfun_block/generic_handlers/get_webstart_otp.ashx?\(query.joined(separator: "&"))"
        guard let url = URL(string: value) else { throw BeanfunError.invalidURL(value) }
        return url
    }

    static func cacheBuster(at date: Date = Date()) -> String {
        let millis = Int(date.timeIntervalSince1970 * 1000)
        return String(Int32(truncatingIfNeeded: millis))
    }

    static func ppppp(from page: String, fallback: String) -> String {
        let pattern = #"ppppp=([0-9A-Fa-f]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
              let range = Range(match.range(at: 1), in: page) else {
            return fallback
        }
        return String(page[range])
    }

    static func pageHints(from html: String) -> [String] {
        var hints: [String] = []
        hints.append("HTML \(html.count) chars")
        if let regex = try? NSRegularExpression(pattern: #"src=["']([^"']+)["']"#, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: html) else { continue }
                let src = String(html[valueRange])
                if src.lowercased().contains(".js") { hints.append("script \(src)") }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9_./-]+\.ashx[^"'<\s]*"#) {
            let range = NSRange(html.startIndex..., in: html)
            for match in regex.matches(in: html, range: range) {
                guard let valueRange = Range(match.range, in: html) else { continue }
                hints.append("ashx \(html[valueRange])")
            }
        }
        let markers = [
            "get_webstart_otp",
            "ppppp=",
            "GGM.LaunchGame",
            "GGM.SmartLaunch",
            "gamaniagames://",
            "StartGame",
        ]
        for marker in markers {
            if html.range(of: marker, options: .caseInsensitive) == nil {
                hints.append("沒有 \(marker)")
            } else {
                hints.append("含 \(marker)")
            }
        }
        for needle in ["GGM.LaunchGame", "GGM.SmartLaunch", "StartGame("] {
            if let snippet = snippet(around: needle, in: html, radius: 220) {
                hints.append("片段 \(redactSecrets(snippet))")
            }
        }
        if let launch = launchObject(from: html) {
            hints.append(
                "m_objData region=\(launch.region) sn=\(launch.sn) data=\(launch.data.count) chars"
            )
        }
        let accountFields = propertyNames(prefix: "MyAccountData", in: html)
        if !accountFields.isEmpty {
            hints.append("MyAccountData 欄位：\(accountFields.joined(separator: ", "))")
        }
        let launchFields = uniqueNames(
            propertyNames(prefix: "m_objData", in: html) + objectLiteralKeys(named: "m_objData", in: html)
        )
        if !launchFields.isEmpty {
            hints.append("m_objData 欄位：\(launchFields.joined(separator: ", "))")
        }
        for needle in ["m_objData =", "var m_objData", "function StartGame", "supportService", "var MyAccountData"] {
            if let snippet = snippet(around: needle, in: html, radius: 480) {
                hints.append("片段 \(redactSecrets(snippet))")
            }
        }
        return hints
    }

    static func snippet(around needle: String, in html: String, radius: Int) -> String? {
        guard let range = html.range(of: needle, options: .caseInsensitive) else { return nil }
        let start = html.index(range.lowerBound, offsetBy: -radius, limitedBy: html.startIndex) ?? html.startIndex
        let end = html.index(range.upperBound, offsetBy: radius, limitedBy: html.endIndex) ?? html.endIndex
        return String(html[start..<end])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func redactSecrets(_ text: String) -> String {
        var value = summarizeDataField(in: text)
        value = value.replacingOccurrences(
            of: #"(WebToken|SecretCode|webToken|secretCode)\s*[:=]\s*['"][^'"]+['"]"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
        return value
    }

    static func summarizeDataField(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #""data"\s*:\s*"([^"]+)""#) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return text
        }
        let payload = String(text[valueRange])
        guard payload.count >= 24 else { return text }
        return text.replacingCharacters(in: valueRange, with: "[\(payload.count) chars]")
    }

    struct LaunchObject {
        let region: String
        let sn: String
        let data: String
        /// `m_objData.secretCode`, when the page embeds one. This is the SecretCode already
        /// paired server-side with this specific game-start session (as opposed to any value
        /// fetched separately from another host), and must be preferred for the legacy
        /// `get_webstart_otp.ashx` request used by non-MapleStory games.
        let secretCode: String?
        /// `m_objData.webToken`, when present. Kept for the same reason as `secretCode`.
        let webToken: String?
    }

    static func launchObject(from html: String) -> LaunchObject? {
        guard let keyword = html.range(of: "m_objData") else { return nil }
        guard let braceStart = html[keyword.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var braceEnd: String.Index?
        var index = braceStart
        while index < html.endIndex {
            let character = html[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = html.index(after: index)
                    break
                }
            }
            index = html.index(after: index)
        }
        guard let braceEnd else { return nil }
        let json = String(html[braceStart..<braceEnd])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let region = object["region"] as? String,
              let sn = object["sn"] as? String,
              let payload = object["data"] as? String,
              !payload.isEmpty else {
            return nil
        }
        return LaunchObject(
            region: region,
            sn: sn,
            data: payload,
            secretCode: object["secretCode"] as? String,
            webToken: object["webToken"] as? String
        )
    }

    static func propertyNames(prefix: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: prefix)
        guard let regex = try? NSRegularExpression(pattern: #"\#(escaped)\.([A-Za-z_][A-Za-z0-9_]*)"#) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        var names: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: html) else { continue }
            let name = String(html[valueRange])
            if seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    static func objectLiteralKeys(named name: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: #"\#(escaped)\s*=\s*\{([^}]*)\}"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let innerRange = Range(match.range(at: 1), in: html) else {
            return []
        }
        let inner = String(html[innerRange])
        guard let keyRegex = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*:"#) else {
            return []
        }
        var names: [String] = []
        var seen = Set<String>()
        let range = NSRange(inner.startIndex..., in: inner)
        for match in keyRegex.matches(in: inner, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: inner) else { continue }
            let name = String(inner[valueRange])
            if seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

final class BeanfunClient {
    static let host = "tw.beanfun.com"
    static let loginHost = "tw.newlogin.beanfun.com"
    static let modernLoginHost = "login.beanfun.com"
    static let ppppp = "1F552AEAFF976018F942B13690C990F60ED01510DDF89165F1658CCE7BC21DBA"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138 Safari/537.36"

    var includeSecrets = false

    private var session: URLSession
    private var cookieStorage: HTTPCookieStorage
    private let logHandler: (String) -> Void
    private var activeQRSession: BeanfunQRSession?
    private var generation: UInt64 = 0

    init(log: @escaping (String) -> Void) {
        logHandler = log
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        cookieStorage = configuration.httpCookieStorage ?? .shared
        session = URLSession(configuration: configuration)
    }

    func reset() {
        generation &+= 1
        session.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        cookieStorage = configuration.httpCookieStorage ?? .shared
        session = URLSession(configuration: configuration)
        activeQRSession = nil
    }

    // MARK: - QR login

    func createQRSession(completion: @escaping (Result<BeanfunQRSession, Error>) -> Void) {
        reset()
        let gen = generation
        log("[登入 1/7] 建立 tw.beanfun.com ASP.NET session")
        guard let homeURL = try? makeURL("https://\(Self.host)/") else {
            finish(completion, .failure(BeanfunError.invalidURL("https://\(Self.host)/")))
            return
        }
        request(homeURL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case .success:
                self.createQRSessionStep2(homeURL: homeURL, gen: gen, completion: completion)
            }
        }
    }

    private func createQRSessionStep2(
        homeURL: URL,
        gen: UInt64,
        completion: @escaping (Result<BeanfunQRSession, Error>) -> Void
    ) {
        log("[登入 2/7] 取得 Beanfun SessionKey（pSKey）")
        let timestamp = Self.loginTimestamp()
        guard let gatewayURL = try? url(
            "https://\(Self.host)/beanfun_block/bflogin/default.aspx",
            query: [
                "service": "999999_T0",
                "dt": timestamp,
                "url": homeURL.absoluteString,
            ]
        ) else {
            finish(completion, .failure(BeanfunError.invalidURL("beanfun_block/bflogin/default.aspx")))
            return
        }
        request(gatewayURL, referer: homeURL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(gateway):
                guard let finalURL = gateway.response.url,
                      let components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
                      let sessionKey = components.queryItems?.first(where: {
                          $0.name.caseInsensitiveCompare("skey") == .orderedSame
                              || $0.name.caseInsensitiveCompare("pSKey") == .orderedSame
                      })?.value,
                      !sessionKey.isEmpty else {
                    self.finish(
                        completion,
                        .failure(BeanfunError.parse("登入 redirect 中找不到 SessionKey：\(gateway.response.url?.absoluteString ?? "")"))
                    )
                    return
                }
                self.log("  SessionKey=\(sessionKey)")
                self.createQRSessionStep3(sessionKey: sessionKey, finalURL: finalURL, gen: gen, completion: completion)
            }
        }
    }

    private func createQRSessionStep3(
        sessionKey: String,
        finalURL: URL,
        gen: UInt64,
        completion: @escaping (Result<BeanfunQRSession, Error>) -> Void
    ) {
        log("[登入 3/7] 取得 CSRF token 與 QR code")
        guard let loginURL = try? url(
            "https://\(Self.modernLoginHost)/Login/Index",
            query: ["pSKey": sessionKey]
        ) else {
            finish(completion, .failure(BeanfunError.invalidURL("Login/Index")))
            return
        }
        request(loginURL, referer: finalURL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(loginPage):
                guard let loginHTML = try? self.text(loginPage.data),
                      let verificationToken = try? self.capture(
                          #"name="__RequestVerificationToken"[^>]*value="([^"]+)""#,
                          in: loginHTML,
                          label: "RequestVerificationToken",
                          options: [.caseInsensitive]
                      ) else {
                    self.finish(completion, .failure(BeanfunError.parse("找不到 RequestVerificationToken")))
                    return
                }
                self.createQRSessionStep4(
                    sessionKey: sessionKey,
                    verificationToken: verificationToken,
                    loginURL: loginURL,
                    gen: gen,
                    completion: completion
                )
            }
        }
    }

    private func createQRSessionStep4(
        sessionKey: String,
        verificationToken: String,
        loginURL: URL,
        gen: UInt64,
        completion: @escaping (Result<BeanfunQRSession, Error>) -> Void
    ) {
        let apiHeaders = modernLoginHeaders(token: verificationToken)
        guard let initURL = try? makeURL("https://\(Self.modernLoginHost)/Login/InitLogin") else {
            finish(completion, .failure(BeanfunError.invalidURL("Login/InitLogin")))
            return
        }
        request(initURL, referer: loginURL, headers: apiHeaders) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(initResponse):
                guard let initJSON = try? self.jsonObject(initResponse.data) else {
                    self.finish(completion, .failure(BeanfunError.parse("InitLogin JSON 無法解析")))
                    return
                }
                guard (initJSON["ResultCode"] as? NSNumber)?.intValue == 1,
                      let resultData = initJSON["ResultData"] as? [String: Any],
                      let encodedImage = resultData["QRImage"] as? String,
                      let imageData = Data(base64Encoded: encodedImage),
                      let image = NSImage(data: imageData) else {
                    self.finish(
                        completion,
                        .failure(BeanfunError.rejected(initJSON["ResultMessage"] as? String ?? "InitLogin 沒有回傳 QRImage"))
                    )
                    return
                }
                let deepLink = resultData["DeepLink"] as? String ?? ""
                self.secret("  RequestVerificationToken=\(verificationToken)")
                self.secret("  DeepLink=\(deepLink)")
                self.log("  QRImage=\(imageData.count) bytes")

                let qrSession = BeanfunQRSession(
                    sessionKey: sessionKey,
                    verificationToken: verificationToken,
                    loginURL: loginURL,
                    image: image,
                    deepLink: deepLink,
                    createdAt: Date()
                )
                self.activeQRSession = qrSession
                self.finish(completion, .success(qrSession))
            }
        }
    }

    func pollQRLogin(completion: @escaping (Result<QRLoginStatus, Error>) -> Void) {
        let gen = generation
        guard let qr = activeQRSession else {
            finish(completion, .failure(BeanfunError.parse("尚未建立 QR session")))
            return
        }
        guard let pollURL = try? makeURL("https://\(Self.modernLoginHost)/QRLogin/CheckLoginStatus") else {
            finish(completion, .failure(BeanfunError.invalidURL("QRLogin/CheckLoginStatus")))
            return
        }
        request(
            pollURL,
            method: "POST",
            json: [:],
            referer: qr.loginURL,
            headers: modernLoginHeaders(token: qr.verificationToken)
        ) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(response):
                guard let object = try? self.jsonObject(response.data) else {
                    self.finish(completion, .failure(BeanfunError.parse("CheckLoginStatus JSON 無法解析")))
                    return
                }
                let code = (object["ResultCode"] as? NSNumber)?.intValue ?? -1
                let message = object["ResultMessage"] as? String ?? "Unknown"
                self.log("  QR polling：ResultCode=\(code)，ResultMessage=\(message)")
                if code == 1 || message == "Success" {
                    self.finish(completion, .success(.confirmed))
                    return
                }
                if message == "Token Expired" {
                    self.finish(completion, .success(.expired))
                    return
                }
                self.finish(completion, .success(.waiting(message)))
            }
        }
    }

    func completeQRLogin(completion: @escaping (Result<Void, Error>) -> Void) {
        let gen = generation
        guard let qr = activeQRSession else {
            finish(completion, .failure(BeanfunError.parse("尚未建立 QR session")))
            return
        }
        let headers = modernLoginHeaders(token: qr.verificationToken)
        log("[登入 5/7] 完成 QRLogin 並取得 AuthKey")
        guard let qrLoginURL = try? makeURL("https://\(Self.modernLoginHost)/QRLogin/QRLogin") else {
            finish(completion, .failure(BeanfunError.invalidURL("QRLogin/QRLogin")))
            return
        }
        request(qrLoginURL, referer: qr.loginURL, headers: headers) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(qrResponse):
                guard let qrJSON = try? self.jsonObject(qrResponse.data) else {
                    self.finish(completion, .failure(BeanfunError.parse("QRLogin JSON 無法解析")))
                    return
                }
                guard (qrJSON["ResultCode"] as? NSNumber)?.intValue == 1 else {
                    self.finish(completion, .failure(BeanfunError.rejected(qrJSON["ResultMessage"] as? String ?? "QRLogin failed")))
                    return
                }
                self.completeQRLoginStep2(qr: qr, headers: headers, gen: gen, completion: completion)
            }
        }
    }

    private func completeQRLoginStep2(
        qr: BeanfunQRSession,
        headers: [String: String],
        gen: UInt64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let sendLoginURL = try? makeURL("https://\(Self.modernLoginHost)/Login/SendLogin") else {
            finish(completion, .failure(BeanfunError.invalidURL("Login/SendLogin")))
            return
        }
        request(sendLoginURL, referer: qr.loginURL, headers: headers) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(sendLogin):
                guard let sendLoginHTML = try? self.text(sendLogin.data),
                      let authKey = try? self.capture(
                          #"name="AuthKey"[^>]*value="([^"]+)""#,
                          in: sendLoginHTML,
                          label: "AuthKey",
                          options: [.caseInsensitive]
                      ) else {
                    self.finish(completion, .failure(BeanfunError.parse("找不到 AuthKey")))
                    return
                }
                self.secret("  AuthKey=\(authKey)")
                self.completeQRLoginStep3(qr: qr, sendLoginURL: sendLoginURL, authKey: authKey, gen: gen, completion: completion)
            }
        }
    }

    private func completeQRLoginStep3(
        qr: BeanfunQRSession,
        sendLoginURL: URL,
        authKey: String,
        gen: UInt64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        log("[登入 6/7] 交換 tw.beanfun.com WebToken")
        guard let returnURL = try? makeURL("https://\(Self.host)/beanfun_block/bflogin/return.aspx") else {
            finish(completion, .failure(BeanfunError.invalidURL("beanfun_block/bflogin/return.aspx")))
            return
        }
        request(
            returnURL,
            method: "POST",
            form: ["SessionKey": qr.sessionKey, "AuthKey": authKey],
            referer: sendLoginURL
        ) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case .success:
                self.completeQRLoginStep4(returnURL: returnURL, gen: gen, completion: completion)
            }
        }
    }

    private func completeQRLoginStep4(
        returnURL: URL,
        gen: UInt64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let homeURL = try? makeURL("https://\(Self.host)/") else {
            finish(completion, .failure(BeanfunError.invalidURL("https://\(Self.host)/")))
            return
        }
        request(homeURL, referer: returnURL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case .success:
                self.log("[登入 7/7] 檢查 Beanfun Cookie")
                self.dumpCookies()
                let required = ["ASP.NET_SessionId", "bfWebToken", "bfUID", "bfTD"]
                let missing = required.filter { self.cookieValue(named: $0) == nil }
                guard missing.isEmpty else {
                    self.finish(completion, .failure(BeanfunError.parse("登入完成但缺少 Cookie：\(missing.joined(separator: ", "))")))
                    return
                }
                self.secret("  Cookie: \(self.cookieHeader(for: homeURL))")
                self.finish(completion, .success(()))
            }
        }
    }

    // MARK: - Accounts

    func fetchAccounts(for game: GameDefinition, completion: @escaping (Result<[GameAccount], Error>) -> Void) {
        let gen = generation
        log("[帳號] 取得\(game.name)帳號清單（\(game.serviceKey)）")
        guard let webToken = cookieValue(named: "bfWebToken") else {
            finish(completion, .failure(BeanfunError.expired(BeanfunError.defaultExpiredMessage)))
            return
        }
        guard let homeURL = try? makeURL("https://\(Self.host)/") else {
            finish(completion, .failure(BeanfunError.invalidURL("https://\(Self.host)/")))
            return
        }
        let authURL: URL
        do {
            switch game.accountFlow {
            case .gameZone:
                authURL = try url(
                    "https://\(Self.host)/beanfun_block/auth.aspx",
                    query: [
                        "channel": "game_zone",
                        "page_and_query": "game_start.aspx?service_code_and_region=\(game.serviceKey)",
                        "web_token": webToken,
                    ]
                )
            case .accountsManagement:
                authURL = try url(
                    "https://\(Self.host)/TW/auth.aspx",
                    query: [
                        "channel": "accounts_management",
                        "page_and_query": "01.aspx?ServiceCode=\(game.serviceCode)&ServiceRegion=\(game.serviceRegion)",
                        "web_token": webToken,
                    ]
                )
            }
        } catch {
            finish(completion, .failure(error))
            return
        }
        log("  先以 bfWebToken 授權 \(game.accountFlow.rawValue)")
        request(authURL, referer: homeURL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(authResponse):
                guard let html = try? self.text(authResponse.data) else {
                    self.finish(completion, .failure(BeanfunError.parse("HTTP response 不是 UTF-8")))
                    return
                }
                let accounts = self.parseAccounts(from: html)
                self.fetchAccountsFallback(
                    accounts: accounts,
                    game: game,
                    webToken: webToken,
                    homeURL: homeURL,
                    gen: gen,
                    completion: completion
                )
            }
        }
    }

    // CSO's public launcher routes through accounts_management. Some
    // accounts still expose the standard game_zone account list, so use it
    // as a compatibility fallback without replacing the official route.
    private func fetchAccountsFallback(
        accounts: [GameAccount],
        game: GameDefinition,
        webToken: String,
        homeURL: URL,
        gen: UInt64,
        completion: @escaping (Result<[GameAccount], Error>) -> Void
    ) {
        guard accounts.isEmpty, game.accountFlow == .accountsManagement else {
            fetchAccountsListFallback(accounts: accounts, game: game, gen: gen, completion: completion)
            return
        }
        guard let fallbackURL = try? url(
            "https://\(Self.host)/beanfun_block/auth.aspx",
            query: [
                "channel": "game_zone",
                "page_and_query": "game_start.aspx?service_code_and_region=\(game.serviceKey)",
                "web_token": webToken,
            ]
        ) else {
            finish(completion, .failure(BeanfunError.invalidURL("beanfun_block/auth.aspx")))
            return
        }
        log("  accounts_management 未直接列出帳號，嘗試 game_zone 相容流程")
        request(fallbackURL, referer: homeURL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(fallback):
                guard let html = try? self.text(fallback.data) else {
                    self.finish(completion, .failure(BeanfunError.parse("HTTP response 不是 UTF-8")))
                    return
                }
                let updated = self.parseAccounts(from: html)
                self.fetchAccountsListFallback(accounts: updated, game: game, gen: gen, completion: completion)
            }
        }
    }

    private func fetchAccountsListFallback(
        accounts: [GameAccount],
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<[GameAccount], Error>) -> Void
    ) {
        guard accounts.isEmpty else {
            finishFetchAccounts(accounts: accounts, game: game, completion: completion)
            return
        }
        guard let listURL = try? url(
            "https://\(Self.host)/beanfun_block/game_zone/game_server_account_list.aspx",
            query: [
                "sc": game.serviceCode,
                "sr": game.serviceRegion,
                "dt": Self.method2Timestamp(),
            ]
        ) else {
            finish(completion, .failure(BeanfunError.invalidURL("game_server_account_list.aspx")))
            return
        }
        request(listURL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(response):
                guard let html = try? self.text(response.data) else {
                    self.finish(completion, .failure(BeanfunError.parse("HTTP response 不是 UTF-8")))
                    return
                }
                let finalAccounts = self.parseAccounts(from: html)
                self.finishFetchAccounts(accounts: finalAccounts, game: game, completion: completion)
            }
        }
    }

    private func finishFetchAccounts(
        accounts: [GameAccount],
        game: GameDefinition,
        completion: @escaping (Result<[GameAccount], Error>) -> Void
    ) {
        guard !accounts.isEmpty else {
            finish(completion, .failure(BeanfunError.expired("帳號清單為空或登入已失效，請重新取得 QR Code 並掃描登入")))
            return
        }
        for account in accounts {
            log("  id=\(account.id)，sn=\(account.sn)，name=\(account.displayName)")
        }
        finish(completion, .success(accounts.sorted { $0.sn < $1.sn }))
    }

    private func parseAccounts(from html: String) -> [GameAccount] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<div\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match -> GameAccount? in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            guard let id = Self.attribute("id", in: tag),
                  let sn = Self.attribute("sn", in: tag),
                  sn.allSatisfy(\.isNumber),
                  let name = Self.attribute("name", in: tag),
                  !id.isEmpty, !name.isEmpty else { return nil }
            return GameAccount(id: id, sn: sn, displayName: Self.decodeHTML(name))
        }
    }

    // MARK: - OTP

    func fetchOTP(for account: GameAccount, game: GameDefinition, completion: @escaping (Result<OTPResult, Error>) -> Void) {
        let gen = generation
        log("[OTP 1/6] 初始化\(game.name)啟動：id=\(account.id)，sn=\(account.sn)，name=\(account.displayName)")
        guard let step2URL = try? url(
            "https://\(Self.host)/beanfun_block/game_zone/game_start_step2.aspx",
            query: [
                "service_code": game.serviceCode,
                "service_region": game.serviceRegion,
                "sotp": account.sn,
                "dt": Self.method2Timestamp(),
            ]
        ) else {
            finish(completion, .failure(BeanfunError.invalidURL("game_start_step2.aspx")))
            return
        }
        request(step2URL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(step2Response):
                guard let page = try? self.text(step2Response.data),
                      let start = try? self.parseStartData(page) else {
                    self.finish(completion, .failure(BeanfunError.expired(BeanfunError.defaultExpiredMessage)))
                    return
                }
                let ppppp = BeanfunWebStartOTP.ppppp(from: page, fallback: Self.ppppp)
                self.log("  LongPolling key=\(start.longPollingKey)")
                self.log("  account_id=\(start.accountID)")
                self.log("  sn=\(start.sn)")
                self.log("  name=\(start.displayName)")
                self.log("  create_time=\(start.createTime)")
                self.secret("  dynamic_session_guard=\(start.guardName)=\(start.guardValue)")
                if start.ggmData.isEmpty {
                    self.log("  頁面沒有 m_objData.data")
                } else {
                    self.log("  m_objData.data \(start.ggmData.count) chars")
                }
                if ppppp != Self.ppppp {
                    self.log("  step2 內嵌 ppppp 與內建常數不同，改用頁面值")
                }
                for hint in BeanfunWebStartOTP.pageHints(from: page) {
                    self.log("  step2：\(hint)")
                }
                guard start.accountID == account.id, start.sn == account.sn else {
                    self.finish(completion, .failure(BeanfunError.parse("step2 回傳帳號與所選帳號不同")))
                    return
                }
                self.fetchOTPStep2(start: start, step2URL: step2URL, ppppp: ppppp, account: account, game: game, gen: gen, completion: completion)
            }
        }
    }

    private func fetchOTPStep2(
        start: GameStartData,
        step2URL: URL,
        ppppp: String,
        account: GameAccount,
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        log("[OTP 2/6] 取得 SecretCode")
        if !start.secretCode.isEmpty {
            // Prefer the SecretCode already embedded in game_start_step2.aspx's m_objData —
            // it's the value actually paired server-side with this game-start session.
            // Fetching a fresh one from a different host (tw.newlogin.beanfun.com) here
            // returns a SecretCode tied to a *different* session, which the server later
            // rejects with "Secret codes do not match!".
            log("  SecretCode 取自 step2 m_objData（避免另外呼叫 get_cookies.ashx 造成不同 session 的 SecretCode 對不上）")
            secret("  SecretCode=\(start.secretCode)")
            secret("  ppppp=\(ppppp)")
            fetchOTPStep3(
                start: start,
                step2URL: step2URL,
                secretCode: start.secretCode,
                ppppp: ppppp,
                account: account,
                game: game,
                gen: gen,
                completion: completion
            )
            return
        }
        guard let secretURL = try? makeURL("https://\(Self.loginHost)/generic_handlers/get_cookies.ashx") else {
            finish(completion, .failure(BeanfunError.invalidURL("get_cookies.ashx")))
            return
        }
        request(secretURL, referer: step2URL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(secretResponse):
                guard let page = try? self.text(secretResponse.data),
                      let secretCode = try? self.capture(
                          #"m_strSecretCode\s*=\s*'([^']+)'"#,
                          in: page,
                          label: "SecretCode"
                      ) else {
                    self.finish(completion, .failure(BeanfunError.parse("找不到 SecretCode")))
                    return
                }
                self.log("  step2 未內嵌 secretCode，改用 get_cookies.ashx 取得")
                self.secret("  SecretCode=\(secretCode)")
                self.secret("  ppppp=\(ppppp)")
                self.fetchOTPStep3(
                    start: start,
                    step2URL: step2URL,
                    secretCode: secretCode,
                    ppppp: ppppp,
                    account: account,
                    game: game,
                    gen: gen,
                    completion: completion
                )
            }
        }
    }

    private func fetchOTPStep3(
        start: GameStartData,
        step2URL: URL,
        secretCode: String,
        ppppp: String,
        account: GameAccount,
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        log("[OTP 3/6] 登記遊戲啟動")
        guard let recordURL = try? makeURL("https://\(Self.host)/beanfun_block/generic_handlers/record_service_start.ashx") else {
            finish(completion, .failure(BeanfunError.invalidURL("record_service_start.ashx")))
            return
        }
        request(
            recordURL,
            method: "POST",
            form: [
                "service_code": game.serviceCode,
                "service_region": game.serviceRegion,
                "service_account_id": start.accountID,
                "sotp": start.sn,
                "service_account_display_name": start.displayName,
                "service_account_create_time": start.createTime,
                start.guardName: start.guardValue,
            ],
            referer: step2URL,
            sensitiveFormKeys: [start.guardName]
        ) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(recordResponse):
                guard let recordText = try? self.text(recordResponse.data) else {
                    self.finish(completion, .failure(BeanfunError.parse("HTTP response 不是 UTF-8")))
                    return
                }
                guard recordText.range(
                    of: #"['"]?intResult['"]?\s*:\s*1"#,
                    options: .regularExpression
                ) != nil else {
                    let lower = recordText.lowercased()
                    if lower.contains("登入") || lower.contains("逾時") || lower.contains("session") || lower.contains("expired") {
                        self.finish(completion, .failure(BeanfunError.expired(BeanfunError.defaultExpiredMessage)))
                        return
                    }
                    self.finish(completion, .failure(BeanfunError.rejected("record_service_start：\(recordText.prefix(300))")))
                    return
                }
                self.log("  record_service_start：Success")
                self.fetchOTPStep4(
                    start: start,
                    step2URL: step2URL,
                    secretCode: secretCode,
                    ppppp: ppppp,
                    account: account,
                    game: game,
                    gen: gen,
                    completion: completion
                )
            }
        }
    }

    private func fetchOTPStep4(
        start: GameStartData,
        step2URL: URL,
        secretCode: String,
        ppppp: String,
        account: GameAccount,
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        log("[OTP 4/6] 背景啟動 LongPolling")
        let pollURL: URL
        do {
            pollURL = try url(
                "https://\(Self.host)/generic_handlers/get_result.ashx",
                query: [
                    "meth": "GetResultByLongPolling",
                    "key": start.longPollingKey,
                    "_": Self.loginTimestamp(),
                ]
            )
        } catch {
            finish(completion, .failure(error))
            return
        }
        request(pollURL, referer: step2URL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .success(response):
                self.log("  LongPolling 背景回應：\((try? self.text(response.data))?.prefix(240) ?? "")")
            case let .failure(error):
                self.log("  LongPolling 背景結束：\(error.localizedDescription)")
            }
        }
        log("  LongPolling 已開始；主流程繼續")
        fetchOTPStep5(
            start: start,
            step2URL: step2URL,
            secretCode: secretCode,
            ppppp: ppppp,
            account: account,
            game: game,
            gen: gen,
            completion: completion
        )
    }

    private func fetchOTPStep5(
        start: GameStartData,
        step2URL: URL,
        secretCode: String,
        ppppp: String,
        account: GameAccount,
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        log("[OTP 5/6] 取得 WebStart OTP envelope")
        guard let webToken = cookieValue(named: "bfWebToken") else {
            finish(completion, .failure(BeanfunError.expired(BeanfunError.defaultExpiredMessage)))
            return
        }
        guard let otpURL = try? BeanfunWebStartOTP.makeURL(
            host: Self.host,
            sn: start.longPollingKey,
            webToken: webToken,
            secretCode: secretCode,
            ppppp: ppppp,
            serviceCode: game.serviceCode,
            serviceRegion: game.serviceRegion,
            serviceAccount: start.accountID,
            createTime: start.createTime,
            d: BeanfunWebStartOTP.cacheBuster()
        ) else {
            finish(completion, .failure(BeanfunError.invalidURL("get_webstart_otp.ashx")))
            return
        }
        request(otpURL, referer: step2URL) { [weak self] result in
            guard let self = self, self.generation == gen else { return }
            switch result {
            case let .failure(error):
                self.finish(completion, .failure(error))
            case let .success(otpResponse):
                self.fetchOTPFinish(otpResponse: otpResponse, account: account, game: game, completion: completion)
            }
        }
    }

    private func fetchOTPFinish(
        otpResponse: HTTPResult,
        account: GameAccount,
        game: GameDefinition,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        guard let rawText = try? text(otpResponse.data) else {
            finish(completion, .failure(BeanfunError.parse("HTTP response 不是 UTF-8")))
            return
        }
        let envelope = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = envelope.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            finish(completion, .failure(BeanfunError.parse("OTP 回應格式不正確：\(envelope.prefix(200))")))
            return
        }
        guard parts[0] == "1" else {
            let reason = String(parts[1].prefix(300))
            let lower = reason.lowercased()
            if lower.contains("登入") || lower.contains("逾時") || lower.contains("session") || lower.contains("expired") {
                finish(completion, .failure(BeanfunError.expired(BeanfunError.defaultExpiredMessage)))
                return
            }
            finish(completion, .failure(BeanfunError.rejected(reason)))
            return
        }
        let payload = String(parts[1])
        guard payload.count >= 24 else {
            finish(completion, .failure(BeanfunError.parse("OTP 加密資料太短")))
            return
        }
        let keyText = String(payload.prefix(8))
        let encryptedText = String(payload.dropFirst(8))
        guard let key = keyText.data(using: .ascii),
              let encrypted = Data(hexString: encryptedText) else {
            finish(completion, .failure(BeanfunError.parse("OTP envelope 的 DES key 或密文無效")))
            return
        }
        secret("  DES key=\(keyText)，密文=\(encryptedText)")

        log("[OTP 6/6] DES-ECB 解密")
        do {
            let plaintext = try DESCipher.decryptECB(ciphertext: encrypted, asciiKey: key)
            guard let otp = String(data: plaintext, encoding: .utf8), !otp.isEmpty else {
                finish(completion, .failure(BeanfunError.parse("OTP 解密結果不是 UTF-8")))
                return
            }
            let commandLine = game.commandLine(accountID: account.id, otp: otp)
            log("  OTP 解密成功：\(otp.count) 字元")
            secret("  OTP=\(otp)")
            finish(completion, .success(OTPResult(value: otp, retrievedAt: Date(), commandLine: commandLine)))
        } catch {
            finish(completion, .failure(error))
        }
    }

    private func parseStartData(_ page: String) throws -> GameStartData {
        do {
            let key = try capture(
                #"GetResultByLongPolling(?:&amp;|&)key=([0-9a-fA-F-]{36})"#,
                in: page,
                label: "LongPolling key"
            )
            let accountID = try capture(#"ServiceAccountID:\s*"([^"]+)""#, in: page, label: "account ID")
            let sn = try capture(#"ServiceAccountSN:\s*"([^"]+)""#, in: page, label: "account SN")
            let displayName = Self.decodeHTML(try capture(
                #"ServiceAccountDisplayName:\s*"([^"]+)""#,
                in: page,
                label: "account name"
            ))
            let createTime = try capture(
                #"ServiceAccountCreateTime:\s*"([^"]+)""#,
                in: page,
                label: "account create time"
            )
            let guardName = try capture(
                #"MyAccountData\.ServiceAccountCreateTime\s*\+\s*"&([^="]+)=([^"]+)"\s*;"#,
                in: page,
                label: "dynamic session guard",
                group: 1
            )
            let encodedGuard = try capture(
                #"MyAccountData\.ServiceAccountCreateTime\s*\+\s*"&([^="]+)=([^"]+)"\s*;"#,
                in: page,
                label: "dynamic session guard value",
                group: 2
            )
            let guardValue = encodedGuard.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                ?? encodedGuard
            let launch = BeanfunWebStartOTP.launchObject(from: page)
            let ggmData = launch?.data ?? ""
            return GameStartData(
                longPollingKey: key,
                accountID: accountID,
                sn: sn,
                displayName: displayName,
                createTime: createTime,
                guardName: guardName,
                guardValue: guardValue,
                ggmData: ggmData,
                secretCode: launch?.secretCode ?? ""
            )
        } catch {
            let lower = page.lowercased()
            if lower.contains("login") || lower.contains("登入") || lower.contains("auth") {
                throw BeanfunError.expired(BeanfunError.defaultExpiredMessage)
            }
            throw error
        }
    }


    // MARK: - HTTP core

    private struct HTTPResult {
        let data: Data
        let response: HTTPURLResponse
    }

    private func request(
        _ url: URL,
        method: String = "GET",
        form: [String: String]? = nil,
        json: [String: Any]? = nil,
        referer: URL? = nil,
        headers: [String: String] = [:],
        sensitiveFormKeys: Set<String> = [],
        completion: @escaping (Result<HTTPResult, Error>) -> Void
    ) {
        if form != nil && json != nil {
            DispatchQueue.main.async {
                completion(.failure(BeanfunError.parse("HTTP request 不能同時使用 form 與 JSON")))
            }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let form {
            request.httpBody = Self.formData(form)
            request.setValue(
                "application/x-www-form-urlencoded; charset=UTF-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        } else if let json {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(BeanfunError.parse("JSON body 編碼失敗：\(error.localizedDescription)")))
                }
                return
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        log("  → \(method) \(includeSecrets ? url.absoluteString : Self.redactedURL(url))")
        if let form {
            let rendered = form.sorted { $0.key < $1.key }.map { name, value in
                if !includeSecrets && sensitiveFormKeys.contains(name) {
                    return "<dynamic-session-guard>=<redacted>"
                }
                return "\(name)=\(value)"
            }.joined(separator: "&")
            log("    參數：\(rendered)")
        }
        if let referer {
            log("    Referer：\(referer.absoluteString)")
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(BeanfunError.network(error.localizedDescription)))
                }
                return
            }
            guard let data = data, let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(BeanfunError.network("沒有 HTTP response")))
                }
                return
            }
            self.log("  ← HTTP \(http.statusCode)，收到 \(data.count) bytes")
            if let finalURL = http.url, finalURL != url {
                self.log("    最終 URL：\(finalURL.absoluteString)")
            }
            guard (200..<400).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    completion(.failure(BeanfunError.http(http.statusCode, url.absoluteString, body)))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(HTTPResult(data: data, response: http)))
            }
        }
        task.resume()
    }

    private func finish<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
        DispatchQueue.main.async { completion(result) }
    }

    private func modernLoginHeaders(token: String) -> [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://\(Self.modernLoginHost)",
            "RequestVerificationToken": token,
        ]
    }

    private func cookieValue(named name: String) -> String? {
        cookieStorage.cookies?.last(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private func cookieHeader(for url: URL) -> String {
        HTTPCookie.requestHeaderFields(with: cookieStorage.cookies(for: url) ?? []).first {
            $0.key.caseInsensitiveCompare("Cookie") == .orderedSame
        }?.value ?? ""
    }

    private func dumpCookies() {
        let cookies = (cookieStorage.cookies ?? []).sorted {
            ($0.domain, $0.name) < ($1.domain, $1.name)
        }
        for cookie in cookies {
            let value = includeSecrets ? cookie.value : "<redacted>"
            log("  domain=\(cookie.domain)，path=\(cookie.path)，\(cookie.name)=\(value)")
        }
    }

    private func log(_ message: String) {
        logHandler(message)
    }

    private func secret(_ message: String) {
        if includeSecrets {
            logHandler(message)
        }
    }

    private func makeURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw BeanfunError.invalidURL(value) }
        return url
    }

    private func url(_ base: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: base) else {
            throw BeanfunError.invalidURL(base)
        }
        components.queryItems = query.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let url = components.url else { throw BeanfunError.invalidURL(base) }
        return url
    }

    private func text(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw BeanfunError.parse("HTTP response 不是 UTF-8")
        }
        return value
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BeanfunError.parse("JSON root 不是 object")
            }
            return object
        } catch let error as BeanfunError {
            throw error
        } catch {
            throw BeanfunError.parse("JSON 無法解析：\(error.localizedDescription)")
        }
    }

    private func capture(
        _ pattern: String,
        in text: String,
        label: String,
        options: NSRegularExpression.Options = [],
        group: Int = 1
    ) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: fullRange),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else {
            throw BeanfunError.parse("找不到 \(label)")
        }
        return String(text[range])
    }

    private static func formData(_ values: [String: String]) -> Data {
        let rendered = values.sorted { $0.key < $1.key }.map { name, value in
            "\(formEncode(name))=\(formEncode(value))"
        }.joined(separator: "&")
        return Data(rendered.utf8)
    }

    private static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }

    private static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return url.absoluteString }
        let sensitive = Set(["webtoken", "secretcode", "ppppp"])
        components.queryItems = items.map {
            sensitive.contains($0.name.lowercased())
                ? URLQueryItem(name: $0.name, value: "<redacted>")
                : $0
        }
        return components.string ?? url.absoluteString
    }

    private static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(escaped)\\s*=\\s*(['\\\"])(.*?)\\1",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let valueRange = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[valueRange])
    }

    private static func loginTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss.SSS"
        return formatter.string(from: Date())
    }

    private static func method2Timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }
}
