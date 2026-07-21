import AppKit
import Foundation

struct GameAccount: Identifiable, Hashable {
    let id: String
    let sn: String
    let displayName: String
}

struct BeanfunQRSession {
    let sessionKey: String
    let verificationToken: String
    let loginURL: URL
    let image: NSImage
    let deepLink: String
    let createdAt: Date
}

enum QRLoginStatus: Equatable {
    case waiting(String)
    case confirmed
    case expired
}

struct OTPResult: Equatable {
    let value: String
    let retrievedAt: Date
    let commandLine: String
}

enum GameLaunchStyle: String, Hashable {
    case mapleStory
    case mabinogi
    case elsword
    case manual
}

enum BeanfunAccountFlow: String, Hashable {
    case gameZone
    case accountsManagement
}

struct GameDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let serviceCode: String
    let serviceRegion: String
    let imageName: String
    let executableName: String
    let launchStyle: GameLaunchStyle
    let accountFlow: BeanfunAccountFlow

    var serviceKey: String { "\(serviceCode)_\(serviceRegion)" }

    var supportsAutomaticLogin: Bool { launchStyle != .manual }

    func gameArguments(accountID: String, otp: String) -> [String] {
        switch launchStyle {
        case .mapleStory:
            return ["tw.login.maplestory.beanfun.com", "8484", "BeanFun", accountID, otp]
        case .mabinogi:
            return ["/N:\(accountID)", "/V:\(otp)", "/T:gamania"]
        case .elsword:
            return [accountID, otp, "TW"]
        case .manual:
            return []
        }
    }

    func openArguments(executablePath: String, accountID: String, otp: String) -> [String] {
        let arguments = gameArguments(accountID: accountID, otp: otp)
        return arguments.isEmpty
            ? ["-n", executablePath]
            : ["-n", executablePath, "--args"] + arguments
    }

    func commandLine(accountID: String, otp: String) -> String {
        gameArguments(accountID: accountID, otp: otp).joined(separator: " ")
    }

    static let mapleStory = GameDefinition(
        id: "maplestory",
        name: "新楓之谷",
        serviceCode: "610074",
        serviceRegion: "T9",
        imageName: "maplestory.jpg",
        executableName: "MapleStory.exe",
        launchStyle: .mapleStory,
        accountFlow: .gameZone
    )

    static let all: [GameDefinition] = [
        mapleStory,
        GameDefinition(
            id: "lineage-international",
            name: "天堂國際服",
            serviceCode: "611639",
            serviceRegion: "T0",
            imageName: "lineage-international.jpg",
            executableName: "Lineage.exe",
            launchStyle: .manual,
            accountFlow: .gameZone
        ),
        GameDefinition(
            id: "lineage",
            name: "天堂",
            serviceCode: "600035",
            serviceRegion: "T7",
            imageName: "lineage.jpg",
            executableName: "Lineage.exe",
            launchStyle: .manual,
            accountFlow: .gameZone
        ),
        GameDefinition(
            id: "lineage-health",
            name: "天堂健康服",
            serviceCode: "600037",
            serviceRegion: "T7",
            imageName: "lineage.jpg",
            executableName: "Lineage.exe",
            launchStyle: .manual,
            accountFlow: .gameZone
        ),
        GameDefinition(
            id: "lineage-free",
            name: "天堂免費服",
            serviceCode: "600041",
            serviceRegion: "BE",
            imageName: "lineage.jpg",
            executableName: "Lineage.exe",
            launchStyle: .manual,
            accountFlow: .gameZone
        ),
        GameDefinition(
            id: "mabinogi",
            name: "新瑪奇",
            serviceCode: "600309",
            serviceRegion: "A2",
            imageName: "mabinogi.jpg",
            executableName: "mabinogi.exe",
            launchStyle: .mabinogi,
            accountFlow: .gameZone
        ),
        GameDefinition(
            id: "elsword",
            name: "艾爾之光",
            serviceCode: "300148",
            serviceRegion: "AF",
            imageName: "elsword.jpg",
            executableName: "elsword.exe",
            launchStyle: .elsword,
            accountFlow: .gameZone
        ),
        GameDefinition(
            id: "dragon-nest",
            name: "新龍之谷",
            serviceCode: "611653",
            serviceRegion: "VA",
            imageName: "dragon-nest.jpg",
            executableName: "DragonNest.exe",
            launchStyle: .manual,
            accountFlow: .gameZone
        ),
        GameDefinition(
            id: "cso",
            name: "絕對武力 Online",
            serviceCode: "610153",
            serviceRegion: "TN",
            imageName: "cso.jpg",
            executableName: "cstrike-online.exe",
            launchStyle: .manual,
            accountFlow: .accountsManagement
        ),
    ]
}

enum AppMode: String, CaseIterable, Identifiable {
    case standard
    case advanced

    static let defaultMode: AppMode = .standard

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: return "一般模式"
        case .advanced: return "進階模式"
        }
    }
}

enum MapleStoryLaunch {
    static let host = "tw.login.maplestory.beanfun.com"
    static let port = "8484"
    static let provider = "BeanFun"

    static func gameArguments(accountID: String, otp: String) -> [String] {
        [host, port, provider, accountID, otp]
    }

    static func openArguments(
        executablePath: String,
        accountID: String,
        otp: String
    ) -> [String] {
        ["-n", executablePath, "--args"] + gameArguments(accountID: accountID, otp: otp)
    }

    static func commandLine(accountID: String, otp: String) -> String {
        gameArguments(accountID: accountID, otp: otp).joined(separator: " ")
    }
}

enum AdvancedLaunchCommandStyle: String, CaseIterable, Identifiable {
    case open
    case nexonWine

    var id: Self { self }

    var title: String {
        switch self {
        case .open: return "open"
        case .nexonWine: return "Nexon Launcher Wine"
        }
    }
}

enum LaunchCommandBuilder {
    static let mapleStoryWineCXRoot =
        "/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
    static let mapleStoryWineBottle = "maplestory"

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func openCommand(
        executablePath: String,
        game: GameDefinition,
        accountID: String,
        otp: String
    ) -> String {
        let quotedPath = shellQuote(executablePath)
        let args = game.gameArguments(accountID: accountID, otp: otp)
        if args.isEmpty {
            return "open -n \(quotedPath)"
        }
        return "open -n \(quotedPath) --args \(args.joined(separator: " "))"
    }

    static func nexonWineCommand(
        executablePath: String,
        accountID: String,
        otp: String
    ) -> String {
        let workdir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        let args = GameDefinition.mapleStory
            .gameArguments(accountID: accountID, otp: otp)
            .joined(separator: " ")
        return """
        export CX_ROOT=\(shellQuote(mapleStoryWineCXRoot))
        export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
        export LANG=zh_TW.UTF-8
        export LC_ALL=zh_TW.UTF-8
        export LC_CTYPE=zh_TW.UTF-8

        wine --bottle \(mapleStoryWineBottle) --workdir \(shellQuote(workdir)) \(shellQuote(executablePath)) \(args)
        """
    }

    static func fullCommand(
        style: AdvancedLaunchCommandStyle,
        game: GameDefinition,
        executablePath: String,
        accountID: String,
        otp: String
    ) -> String {
        if style == .nexonWine, game.id == GameDefinition.mapleStory.id {
            return nexonWineCommand(
                executablePath: executablePath,
                accountID: accountID,
                otp: otp
            )
        }
        return openCommand(
            executablePath: executablePath,
            game: game,
            accountID: accountID,
            otp: otp
        )
    }
}

struct GameStartData {
    let longPollingKey: String
    let accountID: String
    let sn: String
    let displayName: String
    let createTime: String
    let guardName: String
    let guardValue: String
}

enum AppScreen: Equatable {
    case welcome
    case qr
    case accounts
    case otp
}

enum BeanfunError: LocalizedError {
    case invalidURL(String)
    case http(Int, String, String)
    case network(String)
    case parse(String)
    case rejected(String)
    case expired(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "URL 無效：\(value)"
        case let .http(status, url, body):
            return "HTTP \(status)：\(url)\n\(body.prefix(300))"
        case let .network(message):
            return "連線失敗：\(message)"
        case let .parse(message):
            return "解析失敗：\(message)"
        case let .rejected(message):
            return "Beanfun 拒絕請求：\(message)"
        case let .expired(message):
            return message
        case .cancelled:
            return "操作已取消"
        }
    }
}
