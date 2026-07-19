import AppKit
import Foundation

@MainActor
final class BeanfunClient {
    static let serviceCode = "610074"
    static let serviceRegion = "T9"
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

    func createQRSession() async throws -> BeanfunQRSession {
        reset()
        log("[登入 1/7] 建立 tw.beanfun.com ASP.NET session")
        let homeURL = try makeURL("https://\(Self.host)/")
        _ = try await request(homeURL)

        log("[登入 2/7] 取得 Beanfun SessionKey（pSKey）")
        let timestamp = Self.loginTimestamp()
        let gatewayURL = try url(
            "https://\(Self.host)/beanfun_block/bflogin/default.aspx",
            query: [
                "service": "999999_T0",
                "dt": timestamp,
                "url": homeURL.absoluteString,
            ]
        )
        let gateway = try await request(gatewayURL, referer: homeURL)
        guard let finalURL = gateway.response.url,
              let components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
              let sessionKey = components.queryItems?.first(where: {
                  $0.name.caseInsensitiveCompare("skey") == .orderedSame
                      || $0.name.caseInsensitiveCompare("pSKey") == .orderedSame
              })?.value,
              !sessionKey.isEmpty else {
            throw BeanfunError.parse("登入 redirect 中找不到 SessionKey：\(gateway.response.url?.absoluteString ?? "")")
        }
        log("  SessionKey=\(sessionKey)")

        log("[登入 3/7] 取得 CSRF token 與 QR code")
        let loginURL = try url(
            "https://\(Self.modernLoginHost)/Login/Index",
            query: ["pSKey": sessionKey]
        )
        let loginPage = try await request(loginURL, referer: finalURL)
        let loginHTML = try text(loginPage.data)
        let verificationToken = try capture(
            #"name="__RequestVerificationToken"[^>]*value="([^"]+)""#,
            in: loginHTML,
            label: "RequestVerificationToken",
            options: [.caseInsensitive]
        )
        let apiHeaders = modernLoginHeaders(token: verificationToken)
        let initURL = try makeURL("https://\(Self.modernLoginHost)/Login/InitLogin")
        let initResponse = try await request(
            initURL,
            referer: loginURL,
            headers: apiHeaders
        )
        let initJSON = try jsonObject(initResponse.data)
        guard (initJSON["ResultCode"] as? NSNumber)?.intValue == 1,
              let resultData = initJSON["ResultData"] as? [String: Any],
              let encodedImage = resultData["QRImage"] as? String,
              let imageData = Data(base64Encoded: encodedImage),
              let image = NSImage(data: imageData) else {
            throw BeanfunError.rejected(
                initJSON["ResultMessage"] as? String ?? "InitLogin 沒有回傳 QRImage"
            )
        }
        let deepLink = resultData["DeepLink"] as? String ?? ""
        secret("  RequestVerificationToken=\(verificationToken)")
        secret("  DeepLink=\(deepLink)")
        log("  QRImage=\(imageData.count) bytes")

        let qrSession = BeanfunQRSession(
            sessionKey: sessionKey,
            verificationToken: verificationToken,
            loginURL: loginURL,
            image: image,
            deepLink: deepLink,
            createdAt: Date()
        )
        activeQRSession = qrSession
        return qrSession
    }

    func pollQRLogin() async throws -> QRLoginStatus {
        guard let qr = activeQRSession else {
            throw BeanfunError.parse("尚未建立 QR session")
        }
        let pollURL = try makeURL("https://\(Self.modernLoginHost)/QRLogin/CheckLoginStatus")
        let response = try await request(
            pollURL,
            method: "POST",
            json: [:],
            referer: qr.loginURL,
            headers: modernLoginHeaders(token: qr.verificationToken)
        )
        let object = try jsonObject(response.data)
        let code = (object["ResultCode"] as? NSNumber)?.intValue ?? -1
        let message = object["ResultMessage"] as? String ?? "Unknown"
        log("  QR polling：ResultCode=\(code)，ResultMessage=\(message)")
        if code == 1 || message == "Success" {
            return .confirmed
        }
        if message == "Token Expired" {
            return .expired
        }
        return .waiting(message)
    }

    func completeQRLogin() async throws {
        guard let qr = activeQRSession else {
            throw BeanfunError.parse("尚未建立 QR session")
        }
        let headers = modernLoginHeaders(token: qr.verificationToken)
        log("[登入 5/7] 完成 QRLogin 並取得 AuthKey")
        let qrLoginURL = try makeURL("https://\(Self.modernLoginHost)/QRLogin/QRLogin")
        let qrResponse = try await request(
            qrLoginURL,
            referer: qr.loginURL,
            headers: headers
        )
        let qrJSON = try jsonObject(qrResponse.data)
        guard (qrJSON["ResultCode"] as? NSNumber)?.intValue == 1 else {
            throw BeanfunError.rejected(qrJSON["ResultMessage"] as? String ?? "QRLogin failed")
        }

        let sendLoginURL = try makeURL("https://\(Self.modernLoginHost)/Login/SendLogin")
        let sendLogin = try await request(
            sendLoginURL,
            referer: qr.loginURL,
            headers: headers
        )
        let authKey = try capture(
            #"name="AuthKey"[^>]*value="([^"]+)""#,
            in: try text(sendLogin.data),
            label: "AuthKey",
            options: [.caseInsensitive]
        )
        secret("  AuthKey=\(authKey)")

        log("[登入 6/7] 交換 tw.beanfun.com WebToken")
        let returnURL = try makeURL("https://\(Self.host)/beanfun_block/bflogin/return.aspx")
        _ = try await request(
            returnURL,
            method: "POST",
            form: ["SessionKey": qr.sessionKey, "AuthKey": authKey],
            referer: sendLoginURL
        )
        let homeURL = try makeURL("https://\(Self.host)/")
        _ = try await request(homeURL, referer: returnURL)

        log("[登入 7/7] 檢查 Beanfun Cookie")
        dumpCookies()
        let required = ["ASP.NET_SessionId", "bfWebToken", "bfUID", "bfTD"]
        let missing = required.filter { cookieValue(named: $0) == nil }
        guard missing.isEmpty else {
            throw BeanfunError.parse("登入完成但缺少 Cookie：\(missing.joined(separator: ", "))")
        }
        secret("  Cookie: \(cookieHeader(for: homeURL))")
    }

    func fetchAccounts() async throws -> [GameAccount] {
        log("[帳號] 取得楓之谷帳號清單")
        guard let webToken = cookieValue(named: "bfWebToken") else {
            throw BeanfunError.parse("Cookie 中缺少 bfWebToken，無法授權 game_zone")
        }
        let homeURL = try makeURL("https://\(Self.host)/")
        let authURL = try url(
            "https://\(Self.host)/beanfun_block/auth.aspx",
            query: [
                "channel": "game_zone",
                "page_and_query": "game_start.aspx?service_code_and_region=\(Self.serviceCode)_\(Self.serviceRegion)",
                "web_token": webToken,
            ]
        )
        log("  先以 bfWebToken 授權 game_zone")
        _ = try await request(authURL, referer: homeURL)

        let listURL = try url(
            "https://\(Self.host)/beanfun_block/game_zone/game_server_account_list.aspx",
            query: [
                "sc": Self.serviceCode,
                "sr": Self.serviceRegion,
                "dt": Self.method2Timestamp(),
            ]
        )
        let response = try await request(listURL)
        let html = try text(response.data)
        let regex = try NSRegularExpression(pattern: #"<div\b[^>]*>"#, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        let accounts = regex.matches(in: html, range: range).compactMap { match -> GameAccount? in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            guard let id = Self.attribute("id", in: tag),
                  let sn = Self.attribute("sn", in: tag),
                  sn.allSatisfy(\.isNumber),
                  let name = Self.attribute("name", in: tag),
                  !id.isEmpty, !name.isEmpty else { return nil }
            return GameAccount(
                id: id,
                sn: sn,
                displayName: Self.decodeHTML(name)
            )
        }
        guard !accounts.isEmpty else {
            throw BeanfunError.parse("帳號清單為空；登入可能已失效或尚未建立楓之谷帳號")
        }
        for account in accounts {
            log("  id=\(account.id)，sn=\(account.sn)，name=\(account.displayName)")
        }
        return accounts.sorted { $0.sn < $1.sn }
    }

    func fetchOTP(for account: GameAccount) async throws -> OTPResult {
        log("[OTP 1/6] 初始化遊戲啟動：id=\(account.id)，sn=\(account.sn)，name=\(account.displayName)")
        let step2URL = try url(
            "https://\(Self.host)/beanfun_block/game_zone/game_start_step2.aspx",
            query: [
                "service_code": Self.serviceCode,
                "service_region": Self.serviceRegion,
                "sotp": account.sn,
                "dt": Self.method2Timestamp(),
            ]
        )
        let step2Response = try await request(step2URL)
        let start = try parseStartData(try text(step2Response.data))
        log("  LongPolling key=\(start.longPollingKey)")
        log("  account_id=\(start.accountID)")
        log("  sn=\(start.sn)")
        log("  name=\(start.displayName)")
        log("  create_time=\(start.createTime)")
        secret("  dynamic_session_guard=\(start.guardName)=\(start.guardValue)")
        guard start.accountID == account.id, start.sn == account.sn else {
            throw BeanfunError.parse("step2 回傳帳號與所選帳號不同")
        }

        log("[OTP 2/6] 取得 SecretCode")
        let secretURL = try makeURL("https://\(Self.loginHost)/generic_handlers/get_cookies.ashx")
        let secretResponse = try await request(secretURL, referer: step2URL)
        let secretCode = try capture(
            #"m_strSecretCode\s*=\s*'([^']+)'"#,
            in: try text(secretResponse.data),
            label: "SecretCode"
        )
        secret("  SecretCode=\(secretCode)")
        secret("  ppppp=\(Self.ppppp)")

        log("[OTP 3/6] 登記遊戲啟動")
        let recordURL = try makeURL("https://\(Self.host)/beanfun_block/generic_handlers/record_service_start.ashx")
        let recordResponse = try await request(
            recordURL,
            method: "POST",
            form: [
                "service_code": Self.serviceCode,
                "service_region": Self.serviceRegion,
                "service_account_id": start.accountID,
                "sotp": start.sn,
                "service_account_display_name": start.displayName,
                "service_account_create_time": start.createTime,
                start.guardName: start.guardValue,
            ],
            referer: step2URL,
            sensitiveFormKeys: [start.guardName]
        )
        let recordText = try text(recordResponse.data)
        guard recordText.range(
            of: #"['"]?intResult['"]?\s*:\s*1"#,
            options: .regularExpression
        ) != nil else {
            throw BeanfunError.rejected("record_service_start：\(recordText.prefix(300))")
        }
        log("  record_service_start：Success")

        log("[OTP 4/6] 背景啟動 LongPolling")
        let pollURL = try url(
            "https://\(Self.host)/generic_handlers/get_result.ashx",
            query: [
                "meth": "GetResultByLongPolling",
                "key": start.longPollingKey,
                "_": String(Int(Date().timeIntervalSince1970 * 1000)),
            ]
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.request(pollURL, referer: step2URL)
                self.log("  LongPolling 背景回應：\((try? self.text(response.data))?.prefix(240) ?? "")")
            } catch {
                self.log("  LongPolling 背景結束：\(error.localizedDescription)")
            }
        }
        await Task.yield()
        log("  LongPolling 已開始；主流程繼續")

        log("[OTP 5/6] 取得 WebStart OTP envelope")
        guard let webToken = cookieValue(named: "bfWebToken") else {
            throw BeanfunError.parse("Cookie 中缺少 bfWebToken")
        }
        let otpURL = try url(
            "https://\(Self.host)/beanfun_block/generic_handlers/get_webstart_otp.ashx",
            query: [
                "SN": start.longPollingKey,
                "WebToken": webToken,
                "SecretCode": secretCode,
                "ppppp": Self.ppppp,
                "ServiceCode": Self.serviceCode,
                "ServiceRegion": Self.serviceRegion,
                "ServiceAccount": start.accountID,
                "CreateTime": start.createTime,
                "d": String(Int(Date().timeIntervalSince1970 * 1000)),
            ]
        )
        let otpResponse = try await request(otpURL, referer: step2URL)
        let envelope = try text(otpResponse.data).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = envelope.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw BeanfunError.parse("OTP 回應格式不正確：\(envelope.prefix(200))")
        }
        guard parts[0] == "1" else {
            throw BeanfunError.rejected(String(parts[1].prefix(300)))
        }
        let payload = String(parts[1])
        guard payload.count >= 24 else {
            throw BeanfunError.parse("OTP 加密資料太短")
        }
        let keyText = String(payload.prefix(8))
        let encryptedText = String(payload.dropFirst(8))
        guard let key = keyText.data(using: .ascii),
              let encrypted = Data(hexString: encryptedText) else {
            throw BeanfunError.parse("OTP envelope 的 DES key 或密文無效")
        }
        secret("  DES key=\(keyText)，密文=\(encryptedText)")

        log("[OTP 6/6] DES-ECB 解密")
        let plaintext = try DESCipher.decryptECB(ciphertext: encrypted, asciiKey: key)
        guard let otp = String(data: plaintext, encoding: .utf8), !otp.isEmpty else {
            throw BeanfunError.parse("OTP 解密結果不是 UTF-8")
        }
        // MapleStory expects Beanfun's ServiceAccountID (the T9... value),
        // not the user-editable service-account display name.
        let commandLine = MapleStoryLaunch.commandLine(accountID: account.id, otp: otp)
        log("  OTP 解密成功：\(otp.count) 字元")
        secret("  OTP=\(otp)")
        return OTPResult(value: otp, retrievedAt: Date(), commandLine: commandLine)
    }

    private func parseStartData(_ page: String) throws -> GameStartData {
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
        return GameStartData(
            longPollingKey: key,
            accountID: accountID,
            sn: sn,
            displayName: displayName,
            createTime: createTime,
            guardName: guardName,
            guardValue: guardValue
        )
    }

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
        sensitiveFormKeys: Set<String> = []
    ) async throws -> HTTPResult {
        if form != nil && json != nil {
            throw BeanfunError.parse("HTTP request 不能同時使用 form 與 JSON")
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
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
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

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw BeanfunError.network("沒有 HTTP response")
            }
            log("  ← HTTP \(http.statusCode)，收到 \(data.count) bytes")
            if let finalURL = http.url, finalURL != url {
                log("    最終 URL：\(finalURL.absoluteString)")
            }
            guard (200..<400).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw BeanfunError.http(http.statusCode, url.absoluteString, body)
            }
            return HTTPResult(data: data, response: http)
        } catch is CancellationError {
            throw BeanfunError.cancelled
        } catch let error as BeanfunError {
            throw error
        } catch {
            throw BeanfunError.network(error.localizedDescription)
        }
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
