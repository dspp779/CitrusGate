import Foundation

/// Runs the same offline fixtures against each complete client implementation.
/// Only parses pages and builds URLs; never creates a client or sends a request.
@main
enum WebTokenTests {
    private struct Fixture {
        let page: String
        let cookie: String?
        let embedded: String?
        let diagnostic: String
        let selected: String?
        var serviceCode = "600309"
        var serviceRegion = "A2"
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw Failure(message: "Expected fixture directory and implementation name")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let matched = "embedded webToken present; embedded == cookie: true"
        let different = "embedded webToken present; embedded == cookie: false"
        let missing = "embedded webToken missing; embedded == cookie: unavailable"
        let unavailable = "embedded webToken present; embedded == cookie: unavailable"
        let mabinogiToken = "FIXTURE_MABINOGI_WEB_TOKEN"
        let elswordToken = "FIXTURE_ELSWORD_WEB_TOKEN"
        let cookieToken = "FIXTURE_COOKIE_WEB_TOKEN"
        let fixtures: [Fixture] = [
            Fixture(page: "mabinogi", cookie: mabinogiToken, embedded: mabinogiToken, diagnostic: matched, selected: mabinogiToken),
            Fixture(page: "elsword", cookie: cookieToken, embedded: elswordToken, diagnostic: different,
                    selected: cookieToken,
                    serviceCode: "300148", serviceRegion: "AF"),
            Fixture(page: "mabinogi", cookie: "fixture_mabinogi_web_token", embedded: mabinogiToken,
                    diagnostic: different, selected: "fixture_mabinogi_web_token"),
            Fixture(page: "missing", cookie: cookieToken, embedded: nil, diagnostic: missing, selected: cookieToken),
            Fixture(page: "empty", cookie: cookieToken, embedded: "", diagnostic: missing, selected: cookieToken),
            Fixture(page: "null", cookie: cookieToken, embedded: nil, diagnostic: missing, selected: cookieToken),
            Fixture(page: "non-string", cookie: cookieToken, embedded: nil, diagnostic: missing, selected: cookieToken),
            Fixture(page: "no-launch", cookie: cookieToken, embedded: nil, diagnostic: missing, selected: cookieToken),
            Fixture(page: "mabinogi", cookie: nil, embedded: mabinogiToken, diagnostic: unavailable, selected: mabinogiToken),
            Fixture(page: "mabinogi", cookie: "", embedded: mabinogiToken, diagnostic: unavailable, selected: mabinogiToken),
            Fixture(page: "missing", cookie: nil, embedded: nil, diagnostic: missing, selected: nil),
            Fixture(page: "empty", cookie: "", embedded: "", diagnostic: missing, selected: nil),
            Fixture(page: "missing", cookie: "", embedded: nil, diagnostic: missing, selected: nil),
            Fixture(page: "empty", cookie: nil, embedded: "", diagnostic: missing, selected: nil),
        ]

        for fixture in fixtures {
            let html = try String(contentsOf: directory.appendingPathComponent(fixture.page + ".html"), encoding: .utf8)
            let launch = BeanfunWebStartOTP.launchObject(from: html)
            try expect(launch?.webToken == fixture.embedded, "\(fixture.page): embedded webToken parse failed")
            if fixture.page == "no-launch" {
                try expect(launch == nil, "page without m_objData should have no launch object")
            } else {
                try expect(launch != nil, "\(fixture.page): missing optional webToken must not discard launch object")
                try expect(launch?.secretCode == "FIXTURE_SECRET_CODE", "\(fixture.page): secretCode parse failed")
            }

            let diagnostic = BeanfunWebStartOTP.webTokenDiagnostic(embedded: launch?.webToken, cookie: fixture.cookie)
            try expect(diagnostic == fixture.diagnostic, "\(fixture.page): diagnostic status mismatch")
            let selected = BeanfunWebStartOTP.selectWebToken(embedded: launch?.webToken, cookie: fixture.cookie)
            try expect(selected == fixture.selected, "\(fixture.page): WebToken selection mismatch")
            for value in [fixture.embedded, fixture.cookie, launch?.secretCode].compactMap({ $0 }).filter({ !$0.isEmpty }) {
                try expect(!diagnostic.contains(value), "\(fixture.page): diagnostic leaked a fixture secret")
            }
            let hints = BeanfunWebStartOTP.pageHints(from: html).joined(separator: "\n")
            for value in [fixture.embedded, launch?.secretCode].compactMap({ $0 }).filter({ !$0.isEmpty }) {
                try expect(!hints.contains(value), "\(fixture.page): page hints leaked a fixture secret")
            }

            // Exercise the production selector and URL builder together, including conflicts,
            // cookie fallback and an embedded value without a cookie. Never contact the endpoint.
            if let selected = selected {
                let url = try BeanfunWebStartOTP.makeURL(
                    host: "tw.beanfun.com", sn: "fixture-polling-key", webToken: selected,
                    secretCode: launch?.secretCode ?? "FIXTURE_SECRET_CODE_FALLBACK",
                    ppppp: "FIXTURE_PPPPP", serviceCode: fixture.serviceCode,
                    serviceRegion: fixture.serviceRegion, serviceAccount: "FIXTURE_ACCOUNT",
                    createTime: "2026-10-06 12:00:00", d: "1"
                )
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                try expect(query.first(where: { $0.name == "WebToken" })?.value == fixture.selected,
                           "\(fixture.page): selected WebToken must reach the OTP URL unchanged")
            }
        }

        // Values containing log syntax must still produce only the fixed status vocabulary.
        let injected = "FIXTURE_TOKEN\nembedded == cookie: true"
        try expect(BeanfunWebStartOTP.webTokenDiagnostic(embedded: injected, cookie: "other") == different,
                   "diagnostic must not interpolate token content")
        try expect(BeanfunWebStartOTP.webTokenDiagnostic(embedded: injected, cookie: injected) == matched,
                   "equal tokens must not be rendered in the diagnostic")
        for token in ["FIXTURE+TOKEN", " FIXTURE_TOKEN ", "fixture_Mixed_CASE", injected] {
            try expect(BeanfunWebStartOTP.selectWebToken(embedded: token, cookie: nil) == token,
                       "embedded token must not be trimmed or normalized")
            try expect(BeanfunWebStartOTP.selectWebToken(embedded: nil, cookie: token) == token,
                       "cookie fallback must not be trimmed or normalized")
        }
        let assignment = "m_objData.webToken = 'FIXTURE_ASSIGNMENT_TOKEN'; m_objData.secretCode = 'FIXTURE_ASSIGNMENT_SECRET';"
        let redacted = BeanfunWebStartOTP.redactSecrets(assignment)
        try expect(!redacted.contains("FIXTURE_ASSIGNMENT_TOKEN") && !redacted.contains("FIXTURE_ASSIGNMENT_SECRET"),
                   "assignment-style redaction must remain supported")
        print("WebTokenTests (\(CommandLine.arguments[2])): \(fixtures.count) fixture cases and secret-safety checks passed")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error {
        let message: String
    }
}
