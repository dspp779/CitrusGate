import AppKit
import Combine
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    private static let legacyMapleStoryPathKey = "MapleStoryExecutablePath"
    private static let executablePathPrefix = "ExecutablePath."
    private static let advancedLaunchCommandStyleKey = "AdvancedLaunchCommandStyle"
    private static let officialNexonPlugAppPath =
        "/Library/Application Support/Nexon/Plug/NexonPlug.app"
    private static let nexonPlugScheme = "NexonPlug"
    private static let beanfunOTPBundleID = "local.ogom.beanfunotp"

    @Published private(set) var mode: AppMode = .defaultMode
    @Published var screen: AppScreen = .games
    @Published private(set) var selectedGameID: String?
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
    @Published private(set) var launchedAccountID: String?
    @Published var executablePath: String {
        didSet {
            guard let selectedGame else { return }
            defaults.set(executablePath, forKey: executablePathKey(for: selectedGame))
        }
    }
    @Published var advancedLaunchCommandStyle: AdvancedLaunchCommandStyle {
        didSet {
            defaults.set(advancedLaunchCommandStyle.rawValue, forKey: Self.advancedLaunchCommandStyleKey)
        }
    }

    private let defaults: UserDefaults
    private var pendingClassicPassargTokens: [String]?
    // AppDelegate.application(_:open:) and .onOpenURL can both deliver the
    // same cold-start URL; dedupe by absoluteString within a short window
    // instead of handling (and launching) it twice.
    private var lastHandledURLString: String?
    private var lastHandledURLDate: Date?
    private static let duplicateURLWindow: TimeInterval = 2
    private var loginTask: Task<Void, Never>?
    private var otpTask: Task<Void, Never>?
    private var otpCountdownTask: Task<Void, Never>?
    private lazy var client = BeanfunClient { [weak self] message in
        self?.appendLog(message)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedGameID = nil
        executablePath = ""
        if defaults.string(forKey: Self.executablePathPrefix + GameDefinition.mapleStory.id) == nil,
           let legacyPath = defaults.string(forKey: Self.legacyMapleStoryPathKey),
           !legacyPath.isEmpty {
            defaults.set(legacyPath, forKey: Self.executablePathPrefix + GameDefinition.mapleStory.id)
        }
        if let raw = defaults.string(forKey: Self.advancedLaunchCommandStyleKey),
           let style = AdvancedLaunchCommandStyle(rawValue: raw) {
            advancedLaunchCommandStyle = style
        } else {
            advancedLaunchCommandStyle = .open
        }
    }

    var games: [GameDefinition] { GameDefinition.all }

    var selectedGame: GameDefinition? {
        guard let selectedGameID else { return nil }
        return games.first { $0.id == selectedGameID }
    }

    var selectedAccount: GameAccount? {
        guard let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }
    }

    var canCopyLaunchCommand: Bool { fullLaunchCommand != nil }

    var fullLaunchCommand: String? {
        guard let game = selectedGame else { return nil }
        let path = normalizedExecutablePath
        guard !path.isEmpty,
              let account = selectedAccount,
              let otp else { return nil }
        return LaunchCommandBuilder.fullCommand(
            style: advancedLaunchCommandStyle,
            game: game,
            executablePath: path,
            accountID: account.id,
            otp: otp.value
        )
    }

    func handleInitialAppearance() {
        // General mode intentionally starts at game selection. Requesting an
        // executable before that would make it unclear which game is being set.
    }

    func setMode(_ newMode: AppMode) {
        guard mode != newMode else { return }
        mode = newMode
        statusMessage = "已切換至\(newMode.title)"
        if newMode == .standard {
            setAutoRefresh(false)
            if screen == .otp { screen = .accounts }
            if selectedGame != nil, normalizedExecutablePath.isEmpty {
                Task { [weak self] in
                    await Task.yield()
                    guard let self else { return }
                    self.chooseExecutable()
                }
            }
        } else if otp != nil, screen == .accounts {
            screen = .otp
        }
    }

    func selectGame(_ game: GameDefinition, autoPickExecutable: Bool = true) {
        loginTask?.cancel()
        otpTask?.cancel()
        otpCountdownTask?.cancel()
        selectedGameID = game.id
        executablePath = defaults.string(forKey: executablePathKey(for: game)) ?? ""
        resetGameSession()
        if game.authFlow == .webNexonPlug {
            screen = .classic
            statusMessage = "已選擇\(game.name)。請選擇主程式並開啟登入網頁。"
            // When a Classic NexonPlug URL is already driving this selection,
            // handleClassicNexonPlug() owns the picker; scheduling this delayed
            // picker too would show two pickers in a row.
            if autoPickExecutable, mode == .standard, normalizedExecutablePath.isEmpty,
               pendingClassicPassargTokens == nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard let self, self.selectedGameID == game.id else { return }
                    self.chooseExecutable()
                }
            }
        } else {
            screen = .welcome
            statusMessage = "已選擇\(game.name)"
            if autoPickExecutable, mode == .standard, normalizedExecutablePath.isEmpty {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard let self, self.selectedGameID == game.id else { return }
                    self.chooseExecutable()
                }
            }
        }
    }

    func showGamePicker() {
        loginTask?.cancel()
        otpTask?.cancel()
        otpCountdownTask?.cancel()
        resetGameSession()
        screen = .games
        statusMessage = "請選擇遊戲"
    }

    func startLogin() {
        guard let game = selectedGame else {
            errorMessage = "請先選擇遊戲"
            screen = .games
            return
        }
        guard game.usesBeanfunQR else {
            errorMessage = "楓之谷：經典版請使用網頁登入"
            screen = .classic
            return
        }
        loginTask?.cancel()
        otpTask?.cancel()
        otpCountdownTask?.cancel()
        errorMessage = nil
        accounts = []
        selectedAccountID = nil
        otp = nil
        launchedAccountID = nil
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
                        let loadedAccounts = try await client.fetchAccounts(for: game)
                        accounts = loadedAccounts
                        selectedAccountID = loadedAccounts.first?.id
                        screen = .accounts
                        isBusy = false
                        if mode == .standard, loadedAccounts.count == 1 {
                            statusMessage = "登入成功，正在以 \(loadedAccounts[0].displayName) 開啟遊戲…"
                            launchSelectedAccount()
                        } else {
                            statusMessage = "登入成功，請選擇\(game.name)帳號"
                        }
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
        retrieveOTP(launchWhenReady: false)
    }

    func launchSelectedAccount() {
        launchedAccountID = nil
        retrieveOTP(launchWhenReady: true)
    }

    func selectAccount(_ account: GameAccount) {
        selectedAccountID = account.id
        launchedAccountID = nil
        otp = nil
    }

    private func retrieveOTP(launchWhenReady: Bool) {
        guard let game = selectedGame else {
            errorMessage = "請先選擇遊戲"
            return
        }
        guard let account = selectedAccount else {
            errorMessage = "請先選擇\(game.name)帳號"
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
                let result = try await client.fetchOTP(for: account, game: game)
                try Task.checkCancellation()
                otp = result
                isBusy = false
                if launchWhenReady {
                    statusMessage = "OTP 已取得，正在以 \(account.displayName) 開啟遊戲…"
                    launchGame()
                } else {
                    screen = .otp
                    statusMessage = "OTP 已更新"
                    scheduleAutoRefreshIfNeeded()
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

    func copyAccountID() {
        guard let value = selectedAccount?.id else { return }
        copy(value)
        statusMessage = "遊戲帳號已複製"
    }

    func copyCommandLine() {
        copyLaunchCommand()
    }

    func copyLaunchCommand() {
        guard let value = fullLaunchCommand else { return }
        copy(value)
        statusMessage = "啟動指令已複製"
    }

    func copyDebugLog() {
        copy(logText)
        statusMessage = "Debug log 已複製"
    }

    func chooseExecutable() {
        guard let game = selectedGame else {
            errorMessage = "請先選擇遊戲"
            screen = .games
            return
        }
        let panel = NSOpenPanel()
        panel.title = "選擇 \(game.executableName)"
        panel.message = "選擇要由 Cyder 開啟的\(game.name)主程式"
        panel.prompt = "選擇"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        executablePath = url.path
        statusMessage = "已記住\(game.name)主程式位置"
    }

    func launchGame() {
        guard let game = selectedGame else {
            errorMessage = "請先選擇遊戲"
            return
        }
        let path = normalizedExecutablePath
        guard !path.isEmpty else {
            errorMessage = "請先選擇 \(game.executableName)"
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            errorMessage = "找不到\(game.name)主程式：\(path)"
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

        launchedAccountID = nil

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = game.openArguments(
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
                    self.launchedAccountID = account.id
                    if game.supportsAutomaticLogin {
                        self.statusMessage = "已透過 Cyder 啟動\(game.name)"
                    } else {
                        self.copy(otp.value)
                        self.statusMessage = "已啟動\(game.name)，OTP 已複製"
                    }
                    self.appendLog("執行 open -n：game=\(game.serviceKey)，executable=\(path)，account=\(account.id)")
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
        statusMessage = "正在以 open -n 透過 Cyder 啟動\(game.name)…"
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
        statusMessage = "請選擇\(selectedGame?.name ?? "遊戲")帳號"
    }

    func openClassicLoginPage() {
        guard let game = selectedGame, game.authFlow == .webNexonPlug,
              let url = game.loginURL else {
            errorMessage = "無法開啟登入網頁"
            return
        }
        NSWorkspace.shared.open(url)
        statusMessage = "已開啟\(game.name)登入網頁"
    }

    func claimNexonPlugHandler() {
        let status = LSSetDefaultHandlerForURLScheme(
            Self.nexonPlugScheme as NSString,
            Self.beanfunOTPBundleID as NSString
        )
        if status == noErr {
            statusMessage = "已將 NexonPlug 設為由 Beanfun OTP 處理"
        } else {
            errorMessage = "設定 NexonPlug 處理程式失敗（代碼 \(status)）"
        }
    }

    func handleOpenedURL(_ url: URL) {
        let urlString = url.absoluteString
        let now = Date()
        if urlString == lastHandledURLString,
           let lastDate = lastHandledURLDate,
           now.timeIntervalSince(lastDate) < Self.duplicateURLWindow {
            appendLog("忽略重複遞送的 NexonPlug URL：\(urlString)")
            return
        }
        lastHandledURLString = urlString
        lastHandledURLDate = now
        guard let parsed = NexonPlugURLParser.parse(url) else {
            appendLog("忽略非 NexonPlug URL：\(urlString)")
            return
        }
        if NexonPlugURLParser.isMapleStoryClassic(gameCode: parsed.gameCode) {
            handleClassicNexonPlug(parsed)
        } else {
            forwardNexonPlug(url)
        }
    }

    private func handleClassicNexonPlug(_ parsed: NexonPlugURLParser.Parsed) {
        guard !parsed.passargTokens.isEmpty else {
            // selectGame() → resetGameSession() clears errorMessage, so it must
            // run first; setting errorMessage afterwards keeps it visible.
            // autoPickExecutable: false avoids popping the file picker 180ms
            // later for a URL we're about to reject as invalid.
            selectGame(GameDefinition.mapleStoryClassic, autoPickExecutable: false)
            errorMessage = "NexonPlug 連結缺少 passarg，無法啟動經典版"
            return
        }
        pendingClassicPassargTokens = parsed.passargTokens
        if selectedGameID != GameDefinition.mapleStoryClassic.id {
            selectGame(GameDefinition.mapleStoryClassic)
        } else {
            screen = .classic
            executablePath = defaults.string(
                forKey: executablePathKey(for: GameDefinition.mapleStoryClassic)
            ) ?? ""
        }
        if !isValidExecutablePath(normalizedExecutablePath) {
            chooseExecutable()
        }
        guard isValidExecutablePath(normalizedExecutablePath), let tokens = pendingClassicPassargTokens else {
            pendingClassicPassargTokens = nil
            statusMessage = "已取消"
            return
        }
        pendingClassicPassargTokens = nil
        launchClassic(passargTokens: tokens)
    }

    private func launchClassic(passargTokens: [String]) {
        let path = normalizedExecutablePath
        guard isValidExecutablePath(path) else {
            errorMessage = "請先選擇 Maplestory_Classic.exe"
            return
        }
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = NexonPlugURLParser.classicOpenArguments(
            executablePath: path,
            passargTokens: passargTokens
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
                    self.statusMessage = "已透過 Cyder 啟動楓之谷：經典版"
                    self.appendLog("執行 open -n：classic executable=\(path) args=\(passargTokens.joined(separator: " "))")
                } else {
                    let message = errorText.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "open 結束代碼 \(process.terminationStatus)"
                    self.present(BeanfunError.rejected(message))
                }
            }
        }
        isBusy = true
        statusMessage = "正在以 open -n 透過 Cyder 啟動楓之谷：經典版…"
        do {
            try process.run()
        } catch {
            isBusy = false
            present(error)
        }
    }

    private func forwardNexonPlug(_ url: URL) {
        let plugPath = Self.officialNexonPlugAppPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: plugPath, isDirectory: &isDir) else {
            errorMessage = "找不到 NexonPlug.app，無法轉發其他遊戲的 NexonPlug 連結"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", plugPath, url.absoluteString]
        do {
            try process.run()
            statusMessage = "已將 NexonPlug 連結轉發給官方 NexonPlug"
            appendLog("forward NexonPlug → \(plugPath): \(url.absoluteString)")
        } catch {
            present(error)
        }
    }

    private var normalizedExecutablePath: String {
        executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A path is only usable if it's non-empty and actually exists on disk;
    /// a stale/removed path must be treated the same as no path at all.
    private func isValidExecutablePath(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    private func executablePathKey(for game: GameDefinition) -> String {
        Self.executablePathPrefix + game.id
    }

    private func resetGameSession() {
        errorMessage = nil
        accounts = []
        selectedAccountID = nil
        otp = nil
        launchedAccountID = nil
        qrImage = nil
        qrSecondsRemaining = 60
        isBusy = false
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
