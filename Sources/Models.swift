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

enum GameAuthFlow: String, Hashable {
    case beanfunQR
    case webNexonPlug
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
    let authFlow: GameAuthFlow

    var serviceKey: String { "\(serviceCode)_\(serviceRegion)" }

    var supportsAutomaticLogin: Bool { launchStyle != .manual }

    var loginURL: URL? {
        switch authFlow {
        case .beanfunQR:
            return nil
        case .webNexonPlug:
            return URL(string: "https://maplestoryclassic.beanfun.com/Main")
        }
    }

    var usesBeanfunQR: Bool { authFlow == .beanfunQR }

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

    func openArguments(
        executablePath: String,
        accountID: String,
        otp: String,
        launcher: OpenLauncher = .defaultApplication
    ) -> [String] {
        OpenLaunchArguments.build(
            executablePath: executablePath,
            gameArguments: gameArguments(accountID: accountID, otp: otp),
            launcher: launcher
        )
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
        accountFlow: .gameZone,
        authFlow: .beanfunQR
    )

    static let mapleStoryClassic = GameDefinition(
        id: "maplestory-classic",
        name: "新楓之谷：經典版",
        serviceCode: "2982",
        serviceRegion: "CL",
        imageName: "maplestory-classic.jpg",
        executableName: "Maplestory_Classic.exe",
        launchStyle: .manual,
        accountFlow: .gameZone,
        authFlow: .webNexonPlug
    )

    static let all: [GameDefinition] = [
        mapleStory,
        mapleStoryClassic,
        GameDefinition(
            id: "mabinogi",
            name: "新瑪奇",
            serviceCode: "600309",
            serviceRegion: "A2",
            imageName: "mabinogi.jpg",
            executableName: "mabinogi.exe",
            launchStyle: .mabinogi,
            accountFlow: .gameZone,
            authFlow: .beanfunQR
        ),
        GameDefinition(
            id: "elsword",
            name: "艾爾之光",
            serviceCode: "300148",
            serviceRegion: "AF",
            imageName: "elsword.jpg",
            executableName: "elsword.exe",
            launchStyle: .elsword,
            accountFlow: .gameZone,
            authFlow: .beanfunQR
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
        GameDefinition.mapleStory.gameArguments(accountID: accountID, otp: otp)
    }

    static func openArguments(
        executablePath: String,
        accountID: String,
        otp: String
    ) -> [String] {
        GameDefinition.mapleStory.openArguments(
            executablePath: executablePath,
            accountID: accountID,
            otp: otp
        )
    }

    static func commandLine(accountID: String, otp: String) -> String {
        GameDefinition.mapleStory.commandLine(accountID: accountID, otp: otp)
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

enum OpenLauncher: Equatable {
    case defaultApplication
    case cyder
    case cyderMapleStoryOEM

    static let cyderBundleIdentifier = "local.cyder.app"
    static let cyderMapleStoryOEMBundleIdentifier = "local.cyder.maplestory-oem25"

    static func cyder(for game: GameDefinition) -> OpenLauncher {
        game.id == GameDefinition.mapleStory.id ? .cyderMapleStoryOEM : .cyder
    }

    var openApplicationArguments: [String] {
        switch self {
        case .defaultApplication:
            return []
        case .cyder:
            return ["-b", Self.cyderBundleIdentifier]
        case .cyderMapleStoryOEM:
            return ["-b", Self.cyderMapleStoryOEMBundleIdentifier]
        }
    }
}

enum OpenLaunchArguments {
    static func build(
        executablePath: String,
        gameArguments: [String],
        launcher: OpenLauncher = .defaultApplication
    ) -> [String] {
        var result = ["-n"]
        result += launcher.openApplicationArguments
        result.append(executablePath)
        if !gameArguments.isEmpty {
            result += ["--args"] + gameArguments
        }
        return result
    }
}

enum LaunchCommandBuilder {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func openCommand(
        executablePath: String,
        game: GameDefinition,
        accountID: String,
        otp: String,
        launcher: OpenLauncher = .defaultApplication
    ) -> String {
        let quotedPath = shellQuote(executablePath)
        let args = game.gameArguments(accountID: accountID, otp: otp)
        let applicationFlag: String
        switch launcher {
        case .defaultApplication:
            applicationFlag = ""
        case .cyder:
            applicationFlag = "-b \(shellQuote(OpenLauncher.cyderBundleIdentifier)) "
        case .cyderMapleStoryOEM:
            applicationFlag = "-b \(shellQuote(OpenLauncher.cyderMapleStoryOEMBundleIdentifier)) "
        }
        if args.isEmpty {
            return "open -n \(applicationFlag)\(quotedPath)"
        }
        return "open -n \(applicationFlag)\(quotedPath) --args \(args.joined(separator: " "))"
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
        let envExports = """
        export CX_ROOT=\(shellQuote(MapleStoryWineLauncher.cxRoot))
        export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
        export LANG=zh_TW.UTF-8
        export LC_ALL=zh_TW.UTF-8
        export LC_CTYPE=zh_TW.UTF-8
        """
        return """
        \(envExports)

        wine --bottle \(MapleStoryWineLauncher.bottle) --wait-children --enable-alt-loader macdrv --workdir \(shellQuote(workdir)) \(shellQuote(executablePath)) \(args)
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
    case games
    case welcome
    case qr
    case accounts
    case otp
    case classic
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
