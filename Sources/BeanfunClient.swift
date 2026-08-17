import AppKit
import Foundation

/// Builds `get_webstart_otp.ashx` the way Beanfun's WPF client does.
/// `URLComponents.queryItems` sorts keys and is not byte-identical to the
/// official `?SN=&WebToken=&SecretCode=&ppppp=...&CreateTime=` template;
/// Beanfun rejects that with `Query String Error`.
///
/// GGM `Region`/`Cmd`/`Data` queries are a 20-byte parse failure (`0;Query
/// String Error`). Official MapleStory launch now opens `gamaniagames://`
/// instead of this handler.
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

    /// `ggm.js` format: `gamaniagames://Region=…&&&&SN=…&&&&Cmd=…&&&&Data=…`
    /// Do not percent-encode `;` in Region; GGM parses the raw string.
    static func schemeURI(region: String, sn: String, command: String, data: String) -> String {
        "gamaniagames://Region=\(region)&&&&SN=\(sn)&&&&Cmd=\(command)&&&&Data=\(data)"
    }

    static var defaultWebStartPath: String {
        NSHomeDirectory()
            + "/Library/Application Support/Cyder/bottles/shared/drive_c/Program Files"
            + "/gamania Games/gamania Games Manager/GGMWebStart.exe"
    }

    static let webStartPathFinderHelp = """
    在 Cyder 安裝 gamania Games Manager 後，預設位置是：
    ~/Library/Application Support/Cyder/bottles/shared/drive_c/Program Files/gamania Games/gamania Games Manager/GGMWebStart.exe

    也可在 Finder 按 ⌘F 搜尋「GGMWebStart.exe」，或按「選擇…」從 Cyder bottle 的 drive_c → Program Files → gamania Games → gamania Games Manager 選取。請選這個檔，不要選 MapleStory.exe。
    """

    static func resolvedWebStartPath(stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultWebStartPath : trimmed
    }

    static func missingWebStartPathDescription(path: String) -> String {
        "找不到 GGMWebStart.exe：\(path)\n\n\(webStartPathFinderHelp)"
    }

    static func openArguments(uri: String, webStartPath: String) -> [String] {
        OpenLaunchArguments.build(
            executablePath: webStartPath,
            gameArguments: [uri],
            launcher: .cyder
        )
    }

    /// Open `gamaniagames://…` via the system-registered URL scheme handler.
    static func openSchemeArguments(uri: String) -> [String] {
        ["-n", uri]
    }

    static func cyderOpenCommand(
        uri: String,
        webStartPath: String = defaultWebStartPath
    ) -> String {
        "open -n -b \(LaunchCommandBuilder.shellQuote(OpenLauncher.cyderBundleIdentifier)) "
            + "\(LaunchCommandBuilder.shellQuote(webStartPath)) "
            + "--args \(LaunchCommandBuilder.shellQuote(uri))"
    }

    static func schemeOpenCommand(uri: String) -> String {
        "open -n \(LaunchCommandBuilder.shellQuote(uri))"
    }

    static func supportServiceCodes(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"supportService\s*=\s*\[([^\]]+)\]"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let innerRange = Range(match.range(at: 1), in: html) else {
            return []
        }
        return String(html[innerRange])
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            .filter { !$0.isEmpty }
    }

    static func ggmCommand(serviceCode: String, html: String) -> String {
        supportServiceCodes(from: html).contains(serviceCode) ? "06006" : "06004"
    }

    static let otpV2URL =
        "https://tw.beanfun.com/beanfun_block/generic_handlers/get_webstart_otp_v2.ashx"

    /// Matches GGM 1.5.0.2 captures; used for `CV` on otp_v2 POST.
    static let ggmClientVersion = "1.5.0.2"

    /// SHA-256 of GGM 1.5.0.2 `GGMWebStart.dll`. Baked in so native OTP does not
    /// require Games Manager to be installed.
    static let ggmWebStartDLLHash =
        "dfd568a69d87abcd8f4a93d1a4481ebb57712d1d28ab0b6fc018fcf140101e06"

    static func otpV2RequestBody(
        sn: String,
        launchTicket: String,
        hash: String = ggmWebStartDLLHash,
        cv: String = ggmClientVersion,
        arch: String = "x64"
    ) -> Data {
        let ordered: [(String, String)] = [
            ("SN", sn),
            ("LaunchTicket", launchTicket),
            ("CV", cv),
            ("Hash", hash),
            ("arch", arch),
        ]
        let inner = ordered.map { key, value in
            "\"\(key)\":\"\(value)\""
        }.joined(separator: ",")
        return Data("{\(inner)}".utf8)
    }

    /// WPF `Environment.TickCount`: signed 32-bit millis. Beanfun parses `d`
    /// as Int32; 13-digit unix millis overflows and returns Query String Error.
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
        return LaunchObject(region: region, sn: sn, data: payload)
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

/// Offline `Command.DecryptParam` for `gamaniagames://…&&&&Data=…` (Cmd 06004/06006).
enum GGMDataParam {
    static let substitutionTables = [
        "18EA0FD239BBD938",
        "bac987d65e432f10",
        "3bc4d5e6f2a79108",
        "cdbeaf9012456378",
        "4e6fb81a3c5d7092",
        "bdef1246789ac530",
        "5f82cb4093e71d6a",
        "df1468ace0357b92",
    ]

    static func decryptParam(_ data: String) throws -> [String: String] {
        guard let first = data.first, first.isHexDigit,
              let offset = Int(String(first), radix: 16), (0...15).contains(offset) else {
            throw BeanfunError.parse("Data 偏移量無效")
        }
        guard data.count > 1 else {
            throw BeanfunError.parse("Data 太短")
        }
        // Table 0 in the protocol doc is not a hex permutation. Live 06006
        // payloads decode with tables[1 + offset % 4] (tables 1–4).
        let tableIndex = 1 + (offset % 4)
        let table = substitutionTables[tableIndex]
        var hexDigits: [Character] = []
        hexDigits.reserveCapacity(data.count - 1)
        for character in data.dropFirst() {
            guard let index = table.firstIndex(of: character) else {
                throw BeanfunError.parse("Data 字元 \(character) 不在代換表 \(tableIndex) 中")
            }
            let nibble = table.distance(from: table.startIndex, to: index)
            hexDigits.append(nibbleHexCharacter(nibble))
        }
        let hexPayload = String(hexDigits)
        let keyStart = offset + 1
        guard keyStart + 8 <= hexPayload.count else {
            throw BeanfunError.parse("Data 還原後長度不足以提取 DES key")
        }
        let desKey = String(hexPayload.dropFirst(keyStart).prefix(8))
        let cipherHex = String(hexPayload.prefix(keyStart) + hexPayload.dropFirst(keyStart + 8))
        guard let encrypted = Data(hexString: cipherHex) else {
            throw BeanfunError.parse("Data 還原後的 DES 密文不是合法 hex")
        }
        let plaintext = try DESCipher.decryptECB(
            ciphertext: encrypted,
            asciiKey: Data(desKey.utf8)
        )
        guard var text = String(data: plaintext, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) else {
            throw BeanfunError.parse("Data 解密結果不是 UTF-8")
        }
        while text.last == "\0" {
            text.removeLast()
        }
        var params: [String: String] = [:]
        let pieces = text.split { $0 == ";" || $0 == "&" || $0 == "\n" }
        for pair in pieces {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            if !key.isEmpty {
                params[key] = value
            }
        }
        guard !params.isEmpty else {
            throw BeanfunError.parse("Data 解密後沒有鍵值對")
        }
        return params
    }

    static func launchTicket(from data: String) throws -> String {
        let params = try decryptParam(data)
        guard let launchTicket = params["LaunchTicket"],
              launchTicket.count == 64,
              launchTicket.allSatisfy(\.isHexDigit) else {
            throw BeanfunError.parse("Data 解密後缺少 64 字元 LaunchTicket")
        }
        return launchTicket
    }

    static func decryptOTPEnvelope(_ envelope: String) throws -> String {
        guard envelope.count >= 40 else {
            throw BeanfunError.parse("OTP envelope 太短")
        }
        let keyText = String(envelope.prefix(8))
        let encryptedText = String(envelope.dropFirst(8))
        guard let key = keyText.data(using: .ascii),
              let encrypted = Data(hexString: encryptedText) else {
            throw BeanfunError.parse("OTP envelope 的 DES key 或密文無效")
        }
        let plaintext = try DESCipher.decryptECB(ciphertext: encrypted, asciiKey: key)
        guard let otp = String(data: plaintext, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
              !otp.isEmpty else {
            throw BeanfunError.parse("OTP 解密結果不是 UTF-8")
        }
        return otp
    }

    private static func nibbleHexCharacter(_ value: Int) -> Character {
        precondition((0...15).contains(value))
        return Character(String(value, radix: 16))
    }
}

@MainActor
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
    private let ggmLaunchHandler: (GGMLaunchTicket) -> Void
    private var activeQRSession: BeanfunQRSession?

    init(
        log: @escaping (String) -> Void,
        ggmLaunch: @escaping (GGMLaunchTicket) -> Void = { _ in }
    ) {
        logHandler = log
        ggmLaunchHandler = ggmLaunch
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

    func fetchAccounts(for game: GameDefinition) async throws -> [GameAccount] {
        log("[帳號] 取得\(game.name)帳號清單（\(game.serviceKey)）")
        guard let webToken = cookieValue(named: "bfWebToken") else {
            throw BeanfunError.expired(BeanfunError.defaultExpiredMessage)
        }
        let homeURL = try makeURL("https://\(Self.host)/")
        let authURL: URL
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
        log("  先以 bfWebToken 授權 \(game.accountFlow.rawValue)")
        let authResponse = try await request(authURL, referer: homeURL)
        var accounts = parseAccounts(from: try text(authResponse.data))

        // CSO's public launcher routes through accounts_management. Some
        // accounts still expose the standard game_zone account list, so use it
        // as a compatibility fallback without replacing the official route.
        if accounts.isEmpty, game.accountFlow == .accountsManagement {
            let fallbackURL = try url(
                "https://\(Self.host)/beanfun_block/auth.aspx",
                query: [
                    "channel": "game_zone",
                    "page_and_query": "game_start.aspx?service_code_and_region=\(game.serviceKey)",
                    "web_token": webToken,
                ]
            )
            log("  accounts_management 未直接列出帳號，嘗試 game_zone 相容流程")
            let fallback = try await request(fallbackURL, referer: homeURL)
            accounts = parseAccounts(from: try text(fallback.data))
        }

        if accounts.isEmpty {
            let listURL = try url(
                "https://\(Self.host)/beanfun_block/game_zone/game_server_account_list.aspx",
                query: [
                    "sc": game.serviceCode,
                    "sr": game.serviceRegion,
                    "dt": Self.method2Timestamp(),
                ]
            )
            let response = try await request(listURL)
            accounts = parseAccounts(from: try text(response.data))
        }
        guard !accounts.isEmpty else {
            throw BeanfunError.expired("帳號清單為空或登入已失效，請重新取得 QR Code 並掃描登入")
        }
        for account in accounts {
            log("  id=\(account.id)，sn=\(account.sn)，name=\(account.displayName)")
        }
        return accounts.sorted { $0.sn < $1.sn }
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

    func fetchOTP(for account: GameAccount, game: GameDefinition) async throws -> OTPResult {
        log("[OTP 1/6] 初始化\(game.name)啟動：id=\(account.id)，sn=\(account.sn)，name=\(account.displayName)")
        let step2URL = try url(
            "https://\(Self.host)/beanfun_block/game_zone/game_start_step2.aspx",
            query: [
                "service_code": game.serviceCode,
                "service_region": game.serviceRegion,
                "sotp": account.sn,
                "dt": Self.method2Timestamp(),
            ]
        )
        let step2Response = try await request(step2URL)
        let step2HTML = try text(step2Response.data)
        let start = try parseStartData(step2HTML)
        let ppppp = BeanfunWebStartOTP.ppppp(from: step2HTML, fallback: Self.ppppp)
        log("  LongPolling key=\(start.longPollingKey)")
        log("  account_id=\(start.accountID)")
        log("  sn=\(start.sn)")
        log("  name=\(start.displayName)")
        log("  create_time=\(start.createTime)")
        secret("  dynamic_session_guard=\(start.guardName)=\(start.guardValue)")
        if let launch = BeanfunWebStartOTP.launchObject(from: step2HTML) {
            let ticket = GGMLaunchTicket(
                region: launch.region,
                sn: launch.sn,
                command: BeanfunWebStartOTP.ggmCommand(serviceCode: game.serviceCode, html: step2HTML),
                data: launch.data
            )
            ggmLaunchHandler(ticket)
            log("  GGM URI 已可在進階模式複製：Region=\(ticket.region) SN=\(ticket.sn) Cmd=\(ticket.command) Data=\(ticket.data.count) chars")
            if let launchTicket = try? GGMDataParam.launchTicket(from: launch.data) {
                log("  Data 離線解密：LaunchTicket=\(launchTicket.count) chars")
            }
        } else if start.ggmData.isEmpty {
            log("  頁面沒有 m_objData.data")
        } else {
            log("  m_objData.data \(start.ggmData.count) chars")
        }
        if ppppp != Self.ppppp {
            log("  step2 內嵌 ppppp 與內建常數不同，改用頁面值")
        }
        for hint in BeanfunWebStartOTP.pageHints(from: step2HTML) {
            log("  step2：\(hint)")
        }
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
        secret("  ppppp=\(ppppp)")

        log("[OTP 3/6] 登記遊戲啟動")
        let recordURL = try makeURL("https://\(Self.host)/beanfun_block/generic_handlers/record_service_start.ashx")
        let recordResponse = try await request(
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
        )
        let recordText = try text(recordResponse.data)
        guard recordText.range(
            of: #"['"]?intResult['"]?\s*:\s*1"#,
            options: .regularExpression
        ) != nil else {
            let lower = recordText.lowercased()
            if lower.contains("登入") || lower.contains("逾時") || lower.contains("session") || lower.contains("expired") {
                throw BeanfunError.expired(BeanfunError.defaultExpiredMessage)
            }
            throw BeanfunError.rejected("record_service_start：\(recordText.prefix(300))")
        }
        log("  record_service_start：Success")

        log("[OTP 4/6] 背景啟動 LongPolling")
        let pollURL = try url(
            "https://\(Self.host)/generic_handlers/get_result.ashx",
            query: [
                "meth": "GetResultByLongPolling",
                "key": start.longPollingKey,
                "_": Self.loginTimestamp(),
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

        if game.id == GameDefinition.mapleStory.id {
            guard let launch = BeanfunWebStartOTP.launchObject(from: step2HTML) else {
                throw BeanfunError.parse("step2 沒有 m_objData，無法以 otp_v2 取得 OTP")
            }
            return try await fetchOTPV2(
                launchData: launch.data,
                schemeSN: launch.sn,
                account: account,
                game: game
            )
        }

        log("[OTP 5/6] 取得 WebStart OTP envelope")
        guard let webToken = cookieValue(named: "bfWebToken") else {
            throw BeanfunError.expired(BeanfunError.defaultExpiredMessage)
        }
        let otpURL = try BeanfunWebStartOTP.makeURL(
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
        )
        let otpResponse = try await request(otpURL, referer: step2URL)
        let envelope = try text(otpResponse.data).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = envelope.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw BeanfunError.parse("OTP 回應格式不正確：\(envelope.prefix(200))")
        }
        guard parts[0] == "1" else {
            let reason = String(parts[1].prefix(300))
            let lower = reason.lowercased()
            if lower.contains("登入") || lower.contains("逾時") || lower.contains("session") || lower.contains("expired") {
                throw BeanfunError.expired(BeanfunError.defaultExpiredMessage)
            }
            throw BeanfunError.rejected(reason)
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
        // Games expect Beanfun's ServiceAccountID, not the editable display name.
        let commandLine = game.commandLine(accountID: account.id, otp: otp)
        log("  OTP 解密成功：\(otp.count) 字元")
        secret("  OTP=\(otp)")
        return OTPResult(value: otp, retrievedAt: Date(), commandLine: commandLine)
    }

    private func fetchOTPV2(
        launchData: String,
        schemeSN: String,
        account: GameAccount,
        game: GameDefinition
    ) async throws -> OTPResult {
        log("[OTP 5/6] 離線解密 Data 並 POST get_webstart_otp_v2.ashx")
        let launchTicket = try GGMDataParam.launchTicket(from: launchData)
        secret("  LaunchTicket=\(launchTicket)")
        secret("  otp_v2 SN=\(schemeSN)")
        log("  GGMWebStart.dll SHA-256=\(BeanfunWebStartOTP.ggmWebStartDLLHash.prefix(8))…（內建）")
        guard let url = URL(string: BeanfunWebStartOTP.otpV2URL) else {
            throw BeanfunError.invalidURL(BeanfunWebStartOTP.otpV2URL)
        }
        let body = BeanfunWebStartOTP.otpV2RequestBody(
            sn: schemeSN,
            launchTicket: launchTicket
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = body
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        log("  → POST \(BeanfunWebStartOTP.otpV2URL)（無 Cookie，body \(body.count) bytes）")

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw BeanfunError.network("沒有 HTTP response")
        }
        log("  ← HTTP \(http.statusCode)，收到 \(data.count) bytes")
        guard (200..<400).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw BeanfunError.http(http.statusCode, url.absoluteString, bodyText)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BeanfunError.parse("otp_v2 回應不是 JSON")
        }
        let resultCode = (object["result"] as? NSNumber)?.intValue ?? object["result"] as? Int
        let message = object["message"] as? String
        guard resultCode == 1, let envelope = object["data"] as? String else {
            let reason = message ?? String(data: data, encoding: .utf8) ?? "未知錯誤"
            throw BeanfunError.rejected(reason)
        }
        log("  otp_v2 成功：data=\(envelope.count) chars")

        log("[OTP 6/6] DES-ECB 解密")
        let otp = try GGMDataParam.decryptOTPEnvelope(envelope)
        let commandLine = game.commandLine(accountID: account.id, otp: otp)
        log("  OTP 解密成功：\(otp.count) 字元")
        secret("  OTP=\(otp)")
        return OTPResult(value: otp, retrievedAt: Date(), commandLine: commandLine)
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
            let ggmData = BeanfunWebStartOTP.launchObject(from: page)?.data ?? ""
            return GameStartData(
                longPollingKey: key,
                accountID: accountID,
                sn: sn,
                displayName: displayName,
                createTime: createTime,
                guardName: guardName,
                guardValue: guardValue,
                ggmData: ggmData
            )
        } catch {
            let lower = page.lowercased()
            if lower.contains("login") || lower.contains("登入") || lower.contains("auth") {
                throw BeanfunError.expired(BeanfunError.defaultExpiredMessage)
            }
            throw error
        }
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
