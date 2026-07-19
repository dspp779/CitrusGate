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

enum MapleStoryLaunch {
    static let host = "tw.login.maplestory.beanfun.com"
    static let port = "8484"
    static let provider = "BeanFun"

    static func gameArguments(accountID: String, otp: String) -> [String] {
        [host, port, provider, accountID, otp]
    }

    static func cyderArguments(
        executablePath: String,
        accountID: String,
        otp: String
    ) -> [String] {
        ["--launch-exe", executablePath, "--"] + gameArguments(accountID: accountID, otp: otp)
    }

    static func commandLine(accountID: String, otp: String) -> String {
        gameArguments(accountID: accountID, otp: otp).joined(separator: " ")
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
