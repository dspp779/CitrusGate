import Foundation

enum NexonPlugURLParser {
    struct Parsed: Equatable {
        let gameCode: String
        let obdTag: String?
        let passargTokens: [String]
    }

    static func isMapleStoryClassic(gameCode: String) -> Bool {
        gameCode == "2982"
    }

    static func parse(_ url: URL) -> Parsed? {
        guard let scheme = url.scheme?.lowercased(), scheme == "nexonplug" else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let game = value("game"), !game.isEmpty else { return nil }
        let parts = game.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let gameCode = String(parts[0])
        guard !gameCode.isEmpty else { return nil }
        let obdTag = parts.count > 1 ? String(parts[1]) : nil
        let tokens = passargTokens(from: url)
        return Parsed(gameCode: gameCode, obdTag: obdTag, passargTokens: tokens)
    }

    static func classicOpenArguments(
        executablePath: String,
        passargTokens: [String],
        enableMetalHUD: Bool = false
    ) -> [String] {
        var result = ["-n"]
        if enableMetalHUD {
            result += ["--env", "MTL_HUD_ENABLED=1"]
        }
        result.append(executablePath)
        if !passargTokens.isEmpty {
            result += ["--args"] + passargTokens
        }
        return result
    }

    private static func passargTokens(from url: URL) -> [String] {
        guard let query = url.query else { return [] }
        let raw = rawQueryValue(named: "passarg", in: query) ?? ""
        let normalized = raw.replacingOccurrences(of: "+", with: " ")
        let decoded = normalized.removingPercentEncoding ?? normalized
        return decoded
            .split(whereSeparator: isASCIIWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func rawQueryValue(named name: String, in query: String) -> String? {
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let keyPart = parts.first else { continue }
            if String(keyPart) == name {
                return parts.count > 1 ? String(parts[1]) : ""
            }
        }
        return nil
    }

    private static func isASCIIWhitespace(_ char: Character) -> Bool {
        guard char.unicodeScalars.count == 1, let scalar = char.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }
}
