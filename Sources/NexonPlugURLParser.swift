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
        let rawPassarg = (value("passarg") ?? "").replacingOccurrences(of: "+", with: " ")
        let tokens = rawPassarg
            .split { $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
        return Parsed(gameCode: gameCode, obdTag: obdTag, passargTokens: tokens)
    }

    static func classicOpenArguments(executablePath: String, passargTokens: [String]) -> [String] {
        if passargTokens.isEmpty {
            return ["-n", executablePath]
        }
        return ["-n", executablePath, "--args"] + passargTokens
    }
}
