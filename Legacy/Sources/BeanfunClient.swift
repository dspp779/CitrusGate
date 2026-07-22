import AppKit
import Foundation

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
            finish(completion, .failure(BeanfunError.parse("Cookie 中缺少 bfWebToken，無法授權 game_zone")))
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
            finish(completion, .failure(BeanfunError.parse("帳號清單為空；登入可能已失效或尚未建立\(game.name)帳號")))
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
                    self.finish(completion, .failure(BeanfunError.parse("step2 回應無法解析")))
                    return
                }
                self.log("  LongPolling key=\(start.longPollingKey)")
                self.log("  account_id=\(start.accountID)")
                self.log("  sn=\(start.sn)")
                self.log("  name=\(start.displayName)")
                self.log("  create_time=\(start.createTime)")
                self.secret("  dynamic_session_guard=\(start.guardName)=\(start.guardValue)")
                guard start.accountID == account.id, start.sn == account.sn else {
                    self.finish(completion, .failure(BeanfunError.parse("step2 回傳帳號與所選帳號不同")))
                    return
                }
                self.fetchOTPStep2(start: start, step2URL: step2URL, account: account, game: game, gen: gen, completion: completion)
            }
        }
    }

    private func fetchOTPStep2(
        start: GameStartData,
        step2URL: URL,
        account: GameAccount,
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        log("[OTP 2/6] 取得 SecretCode")
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
                self.secret("  SecretCode=\(secretCode)")
                self.secret("  ppppp=\(Self.ppppp)")
                self.fetchOTPStep3(
                    start: start,
                    step2URL: step2URL,
                    secretCode: secretCode,
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
                    self.finish(completion, .failure(BeanfunError.rejected("record_service_start：\(recordText.prefix(300))")))
                    return
                }
                self.log("  record_service_start：Success")
                self.fetchOTPStep4(
                    start: start,
                    step2URL: step2URL,
                    secretCode: secretCode,
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
        account: GameAccount,
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        log("[OTP 4/6] 背景啟動 LongPolling")
        if let pollURL = try? url(
            "https://\(Self.host)/generic_handlers/get_result.ashx",
            query: [
                "meth": "GetResultByLongPolling",
                "key": start.longPollingKey,
                "_": String(Int(Date().timeIntervalSince1970 * 1000)),
            ]
        ) {
            request(pollURL, referer: step2URL) { [weak self] result in
                guard let self = self, self.generation == gen else { return }
                switch result {
                case let .success(response):
                    self.log("  LongPolling 背景回應：\((try? self.text(response.data))?.prefix(240) ?? "")")
                case let .failure(error):
                    self.log("  LongPolling 背景結束：\(error.localizedDescription)")
                }
            }
        }
        log("  LongPolling 已開始；主流程繼續")
        fetchOTPStep5(start: start, step2URL: step2URL, secretCode: secretCode, account: account, game: game, gen: gen, completion: completion)
    }

    private func fetchOTPStep5(
        start: GameStartData,
        step2URL: URL,
        secretCode: String,
        account: GameAccount,
        game: GameDefinition,
        gen: UInt64,
        completion: @escaping (Result<OTPResult, Error>) -> Void
    ) {
        log("[OTP 5/6] 取得 WebStart OTP envelope")
        guard let webToken = cookieValue(named: "bfWebToken") else {
            finish(completion, .failure(BeanfunError.parse("Cookie 中缺少 bfWebToken")))
            return
        }
        guard let otpURL = try? url(
            "https://\(Self.host)/beanfun_block/generic_handlers/get_webstart_otp.ashx",
            query: [
                "SN": start.longPollingKey,
                "WebToken": webToken,
                "SecretCode": secretCode,
                "ppppp": Self.ppppp,
                "ServiceCode": game.serviceCode,
                "ServiceRegion": game.serviceRegion,
                "ServiceAccount": start.accountID,
                "CreateTime": start.createTime,
                "d": String(Int(Date().timeIntervalSince1970 * 1000)),
            ]
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
                self.fetchOTPFinish(otpResponse: otpResponse, completion: completion)
            }
        }
    }

    private func fetchOTPFinish(
        otpResponse: HTTPResult,
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
            finish(completion, .failure(BeanfunError.rejected(String(parts[1].prefix(300)))))
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
            log("  OTP 解密成功：\(otp.count) 字元")
            secret("  OTP=\(otp)")
            finish(completion, .success(OTPResult(value: otp, retrievedAt: Date())))
        } catch {
            finish(completion, .failure(error))
        }
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
