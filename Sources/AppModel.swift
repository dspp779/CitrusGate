import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    private static let executablePathKey = "MapleStoryExecutablePath"

    @Published var screen: AppScreen = .welcome
    @Published var qrImage: NSImage?
    @Published var qrSecondsRemaining = 60
    @Published var accounts: [GameAccount] = []
    @Published var selectedAccountID: String?
    @Published var otp: OTPResult?
    @Published var otpSecondsRemaining = 0
    @Published var autoRefresh = false
    @Published var autoRefreshInterval = 60
    @Published var includeSecrets = true
    @Published var isBusy = false
    @Published var statusMessage = "準備登入"
    @Published var errorMessage: String?
    @Published var logText = ""
    @Published var maplestoryExecutablePath: String {
        didSet {
            defaults.set(maplestoryExecutablePath, forKey: Self.executablePathKey)
        }
    }

    private let defaults: UserDefaults
    private var loginTask: Task<Void, Never>?
    private var otpTask: Task<Void, Never>?
    private var otpCountdownTask: Task<Void, Never>?
    private lazy var client = BeanfunClient { [weak self] message in
        self?.appendLog(message)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maplestoryExecutablePath = defaults.string(forKey: Self.executablePathKey) ?? ""
    }

    var selectedAccount: GameAccount? {
        guard let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }
    }

    func startLogin() {
        loginTask?.cancel()
        otpTask?.cancel()
        otpCountdownTask?.cancel()
        errorMessage = nil
        accounts = []
        selectedAccountID = nil
        otp = nil
        qrImage = nil
        logText = ""
        isBusy = true
        statusMessage = "正在建立 Beanfun 登入階段…"
        client.includeSecrets = includeSecrets

        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let qr = try await client.createQRSession()
                try Task.checkCancellation()
                qrImage = qr.image
                screen = .qr
                isBusy = false
                statusMessage = "請使用 Gama Play 掃描 QR code"
                qrSecondsRemaining = 60

                while !Task.isCancelled {
                    qrSecondsRemaining = max(
                        0,
                        60 - Int(Date().timeIntervalSince(qr.createdAt))
                    )
                    if qrSecondsRemaining == 0 {
                        throw BeanfunError.expired("QR code 已過期，請重新產生")
                    }
                    let result = try await client.pollQRLogin()
                    switch result {
                    case .confirmed:
                        statusMessage = "掃碼成功，正在交換登入 Cookie…"
                        isBusy = true
                        try await client.completeQRLogin()
                        let loadedAccounts = try await client.fetchAccounts()
                        accounts = loadedAccounts
                        selectedAccountID = loadedAccounts.first?.id
                        screen = .accounts
                        statusMessage = "登入成功，請選擇楓之谷帳號"
                        isBusy = false
                        return
                    case .expired:
                        throw BeanfunError.expired("QR code 已過期，請重新產生")
                    case .waiting:
                        break
                    }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch is CancellationError {
                isBusy = false
            } catch BeanfunError.cancelled {
                isBusy = false
            } catch {
                present(error)
            }
        }
    }

    func retrieveOTP() {
        guard let account = selectedAccount else {
            errorMessage = "請先選擇楓之谷帳號"
            return
        }
        otpTask?.cancel()
        otpCountdownTask?.cancel()
        client.includeSecrets = includeSecrets
        isBusy = true
        statusMessage = "正在取得 \(account.displayName) 的 OTP…"
        otpTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.fetchOTP(for: account)
                try Task.checkCancellation()
                otp = result
                screen = .otp
                isBusy = false
                statusMessage = "OTP 已更新"
                scheduleAutoRefreshIfNeeded()
            } catch is CancellationError {
                isBusy = false
            } catch BeanfunError.cancelled {
                isBusy = false
            } catch {
                present(error)
            }
        }
    }

    func setAutoRefresh(_ enabled: Bool) {
        autoRefresh = enabled
        if enabled {
            scheduleAutoRefreshIfNeeded()
        } else {
            otpCountdownTask?.cancel()
            otpSecondsRemaining = 0
        }
    }

    func updateRefreshInterval(_ seconds: Int) {
        autoRefreshInterval = seconds
        if autoRefresh {
            scheduleAutoRefreshIfNeeded()
        }
    }

    func copyOTP() {
        guard let value = otp?.value else { return }
        copy(value)
        statusMessage = "OTP 已複製"
    }

    func copyCommandLine() {
        guard let value = otp?.commandLine else { return }
        copy(value)
        statusMessage = "啟動參數已複製"
    }

    func copyDebugLog() {
        copy(logText)
        statusMessage = "Debug log 已複製"
    }

    func chooseMapleStoryExecutable() {
        let panel = NSOpenPanel()
        panel.title = "選擇 MapleStory.exe"
        panel.message = "選擇要由 Cyder 開啟的 MapleStory.exe"
        panel.prompt = "選擇"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        maplestoryExecutablePath = url.path
        statusMessage = "已記住 MapleStory.exe 位置"
    }

    func launchMapleStory() {
        let path = maplestoryExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            errorMessage = "請先選擇 MapleStory.exe"
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            errorMessage = "找不到 MapleStory.exe：\(path)"
            return
        }
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "exe" else {
            errorMessage = "請選擇副檔名為 .exe 的檔案"
            return
        }
        guard let account = selectedAccount, let otp else {
            errorMessage = "請先選擇帳號並取得 OTP"
            return
        }

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = MapleStoryLaunch.openArguments(
            executablePath: path,
            accountID: account.id,
            otp: otp.value
        )
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if process.terminationStatus == 0 {
                    self.statusMessage = "已透過 Cyder 啟動 MapleStory.exe"
                    self.appendLog("執行 open -n：executable=\(path)，account=\(account.id)")
                } else {
                    let message = errorText.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "open 結束代碼 \(process.terminationStatus)"
                    self.present(BeanfunError.rejected(
                        message
                    ))
                }
            }
        }

        isBusy = true
        statusMessage = "正在以 open -n 透過 Cyder 啟動楓之谷…"
        do {
            try process.run()
        } catch {
            isBusy = false
            present(error)
        }
    }

    func chooseAnotherAccount() {
        otpCountdownTask?.cancel()
        otpSecondsRemaining = 0
        screen = .accounts
        statusMessage = "請選擇楓之谷帳號"
    }

    func clearError() {
        errorMessage = nil
    }

    private func scheduleAutoRefreshIfNeeded() {
        otpCountdownTask?.cancel()
        guard autoRefresh, otp != nil else {
            otpSecondsRemaining = 0
            return
        }
        otpSecondsRemaining = autoRefreshInterval
        otpCountdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, otpSecondsRemaining > 0 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                otpSecondsRemaining -= 1
            }
            guard !Task.isCancelled, autoRefresh else { return }
            otpCountdownTask = nil
            retrieveOTP()
        }
    }

    private func present(_ error: Error) {
        isBusy = false
        statusMessage = "操作失敗"
        if let beanfunError = error as? BeanfunError {
            errorMessage = beanfunError.localizedDescription
        } else {
            errorMessage = error.localizedDescription
        }
        appendLog("錯誤：\(errorMessage ?? error.localizedDescription)")
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        if logText.isEmpty {
            logText = line
        } else {
            logText += "\n" + line
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
