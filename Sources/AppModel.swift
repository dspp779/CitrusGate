import AppKit
import Combine
import CoreServices
import Foundation
import UniformTypeIdentifiers

enum LaunchUIPhase: Equatable {
    case idle
    case launching
    case launched
}

@MainActor
final class AppModel: ObservableObject {
    private enum PendingLaunchKind {
        case defaultOpen
        case cyderApp
        case nativeOTPCyder
        case mapleStoryWine
        case ggmWebStart
        case ggmSchemeViaCyder
    }

    private static let legacyMapleStoryPathKey = "MapleStoryExecutablePath"
    private static let executablePathPrefix = "ExecutablePath."
    private static let advancedLaunchCommandStyleKey = "AdvancedLaunchCommandStyle"
    private static let ggmWebStartPathKey = "GGMWebStartPath"
    private static let officialNexonPlugAppPath =
        "/Library/Application Support/Nexon/Plug/NexonPlug.app"
    private static let nexonPlugScheme = "NexonPlug"
    private static let beanfunOTPBundleID = "local.ogom.beanfunotp"

    enum QuarantineStatus: Equatable {
        case notQuarantined
        case quarantined
    }

    nonisolated static func quarantineStatus(
        forExtendedAttributes names: [String]
    ) -> QuarantineStatus {
        names.contains("com.apple.quarantine") ? .quarantined : .notQuarantined
    }

    nonisolated static func quarantineRemovalErrorDescription(
        path: String,
        underlying: String
    ) -> String {
        "無法解除檔案的 macOS quarantine，請檢查檔案權限後再試一次：\(path)\n\(underlying)"
    }

    @Published private(set) var mode: AppMode = .defaultMode
    @Published var screen: AppScreen = .games
    @Published private(set) var selectedGameID: String?
    @Published var qrImage: NSImage?
    @Published var qrSecondsRemaining = 60
    @Published var accounts: [GameAccount] = []
    @Published var selectedAccountID: String?
    @Published var otp: OTPResult?
    @Published var ggmLaunchTicket: GGMLaunchTicket?
    @Published var otpSecondsRemaining = 0
    @Published var autoRefresh = false
    @Published var autoRefreshInterval = 60
    @Published var includeSecrets = true
    @Published var isBusy = false
    @Published var statusMessage = "準備登入"
    @Published var errorMessage: String?
    @Published var logText = ""
    @Published private(set) var launchedAccountID: String?
    @Published private(set) var launchUIPhase: LaunchUIPhase = .idle
    @Published private(set) var launchStatusText = ""
    @Published var executablePath: String {
        didSet {
            guard let selectedGame else { return }
            defaults.set(executablePath, forKey: executablePathKey(for: selectedGame))
        }
    }
    @Published var ggmWebStartPath: String {
        didSet {
            defaults.set(ggmWebStartPath, forKey: Self.ggmWebStartPathKey)
        }
    }
    @Published var advancedLaunchCommandStyle: AdvancedLaunchCommandStyle {
        didSet {
            defaults.set(advancedLaunchCommandStyle.rawValue, forKey: Self.advancedLaunchCommandStyleKey)
        }
    }
    @Published private(set) var isDownloadingGameClient = false
    @Published private(set) var classicDownloadStatus = ""
    @Published private(set) var classicDownloadProgress = NxdlDownloadProgressState()
    @Published private(set) var gameClientDownloadTitle = ""
    @Published var showClassicDownloadProgress = false
    @Published private(set) var classicUpdateStatus: ClassicUpdateStatus = .none
    @Published private(set) var isNexonPlugHandler = false

    private let defaults: UserDefaults
    private var pendingClassicPassargTokens: [String]?
    // AppDelegate.application(_:open:) and .onOpenURL can both deliver the
    // same cold-start URL; dedupe by absoluteString within a short window
    // instead of handling (and launching) it twice.
    private var lastHandledURLString: String?
    private var lastHandledURLDate: Date?
    private static let duplicateURLWindow: TimeInterval = 2
    /// Set when a NexonPlug URL arrives during cold-start; cleared only by process exit.
    private(set) var quitAfterSuccessfulClassicLaunch = false
    private var loginTask: Task<Void, Never>?
    private var otpTask: Task<Void, Never>?
    private var otpCountdownTask: Task<Void, Never>?
    private var launchCooldownTask: Task<Void, Never>?
    private var classicDownloadTask: Task<Void, Never>?
    private var classicUpdateCheckTask: Task<Void, Never>?
    private static let launchCooldownNanoseconds: UInt64 = 10_000_000_000
    private var pendingLaunchKind: PendingLaunchKind = .defaultOpen
    private lazy var client = BeanfunClient(
        log: { [weak self] message in
            self?.appendLog(message)
        },
        ggmLaunch: { [weak self] ticket in
            self?.ggmLaunchTicket = ticket
        }
    )
    private lazy var nxdlDownloader = NxdlDownloader { [weak self] message in
        self?.appendLog(message)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedGameID = nil
        executablePath = ""
        let storedGGMPath = defaults.string(forKey: Self.ggmWebStartPathKey) ?? ""
        ggmWebStartPath = BeanfunWebStartOTP.resolvedWebStartPath(stored: storedGGMPath)
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

    var areLaunchButtonsDisabled: Bool {
        launchUIPhase != .idle || isBusy
    }

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
        classicUpdateCheckTask?.cancel()
        classicUpdateStatus = .none
        selectedGameID = game.id
        executablePath = defaults.string(forKey: executablePathKey(for: game)) ?? ""
        resetGameSession()
        if game.authFlow == .webNexonPlug {
            screen = .classic
            refreshNexonPlugHandlerStatus()
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
            errorMessage = "新楓之谷：經典版請使用網頁登入"
            screen = .classic
            refreshNexonPlugHandlerStatus()
            return
        }
        loginTask?.cancel()
        otpTask?.cancel()
        otpCountdownTask?.cancel()
        errorMessage = nil
        accounts = []
        selectedAccountID = nil
        otp = nil
        ggmLaunchTicket = nil
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
                            pendingLaunchKind = .defaultOpen
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
        ggmLaunchTicket = nil
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
        ggmLaunchTicket = nil
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
                    switch pendingLaunchKind {
                    case .defaultOpen:
                        launchViaOpen()
                    case .cyderApp:
                        launchViaOpen(launcher: .cyder)
                    case .nativeOTPCyder:
                        launchViaOpen(launcher: .cyder)
                    case .mapleStoryWine:
                        launchViaMapleStoryLauncherWine()
                    case .ggmWebStart:
                        launchViaGGM()
                    case .ggmSchemeViaCyder:
                        launchViaGamaniagamesScheme()
                    }
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
                if launchWhenReady, ggmLaunchTicket != nil {
                    switch pendingLaunchKind {
                    case .ggmWebStart:
                        appendLog("OTP 失敗，改以 Games Manager 啟動：\(error.localizedDescription)")
                        isBusy = false
                        launchViaGGM()
                        return
                    case .ggmSchemeViaCyder:
                        appendLog("OTP 失敗，改以 gamaniagames scheme 啟動：\(error.localizedDescription)")
                        isBusy = false
                        launchViaGamaniagamesScheme()
                        return
                    default:
                        break
                    }
                }
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

    func copyGGMURI() {
        guard let value = ggmLaunchTicket?.uri else { return }
        copy(value)
        statusMessage = "GGM URI 已複製"
    }

    func copyGGMCyderCommand() {
        guard let ticket = ggmLaunchTicket else { return }
        copy(ticket.cyderOpenCommand(webStartPath: resolvedGGMWebStartPath))
        statusMessage = "GGM Cyder 指令已複製"
    }

    func copyGGMSchemeCommand() {
        guard let ticket = ggmLaunchTicket else { return }
        copy(ticket.schemeOpenCommand())
        statusMessage = "gamaniagames open 指令已複製"
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
        panel.message = "選擇\(game.name)主程式"
        panel.prompt = "選擇"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        executablePath = url.path
        classicUpdateCheckTask?.cancel()
        classicUpdateStatus = .none
        statusMessage = "已記住\(game.name)主程式位置"
    }

    func chooseGGMWebStart() {
        let panel = NSOpenPanel()
        panel.title = "選擇 GGMWebStart.exe"
        panel.message = "從 Cyder bottle 的 drive_c／Program Files／gamania Games／gamania Games Manager 選擇 GGMWebStart.exe"
        panel.prompt = "選擇"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.directoryURL = ggmWebStartPanelDirectory()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent.lowercased()
        guard name == "ggmwebstart.exe" else {
            errorMessage = "請選擇 GGMWebStart.exe，不要選 MapleStory.exe"
            return
        }
        ggmWebStartPath = url.path
        statusMessage = "已記住 GGMWebStart.exe 位置"
    }

    private func ggmWebStartPanelDirectory() -> URL? {
        let resolved = URL(fileURLWithPath: resolvedGGMWebStartPath)
        let managerFolder = resolved.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: managerFolder.path) {
            return managerFolder
        }
        let bottles = NSHomeDirectory() + "/Library/Application Support/Cyder/bottles"
        if FileManager.default.fileExists(atPath: bottles) {
            return URL(fileURLWithPath: bottles)
        }
        return nil
    }

    /// Deprecated alias kept for the advanced-mode launch button.
    func launchGame() {
        launchViaOpen()
    }

    func launchSelectedAccountViaOpen() {
        pendingLaunchKind = .defaultOpen
        launchSelectedAccount()
    }

    func launchSelectedAccountViaCyder() {
        if selectedGame?.id == GameDefinition.mapleStory.id,
           !CyderInstallation.isOfficialCyderInstalled() {
            errorMessage = "請先安裝 Cyder 正式版。"
            return
        }
        pendingLaunchKind = .cyderApp
        launchSelectedAccount()
    }

    /// Native otp_v2 (offline DecryptParam + POST v2) then Cyder opens MapleStory.exe.
    func launchSelectedAccountViaNativeOTPCyder() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else {
            errorMessage = "原生 OTP 啟動僅支援新楓之谷"
            return
        }
        guard CyderInstallation.isOfficialCyderInstalled() else {
            errorMessage = "請先安裝 Cyder 正式版。"
            return
        }
        pendingLaunchKind = .nativeOTPCyder
        launchSelectedAccount()
    }

    /// Fetch launch ticket then `open gamaniagames://…` (system scheme handler).
    func launchSelectedAccountViaGGMScheme() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else {
            errorMessage = "gamaniagames 啟動僅支援新楓之谷"
            return
        }
        pendingLaunchKind = .ggmSchemeViaCyder
        launchSelectedAccount()
    }

    func launchSelectedAccountViaWine() {
        pendingLaunchKind = .mapleStoryWine
        launchSelectedAccount()
    }

    func launchSelectedAccountViaGGM() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else {
            errorMessage = "Games Manager 啟動僅支援新楓之谷"
            return
        }
        guard CyderInstallation.isOfficialCyderInstalled() else {
            errorMessage = "請先安裝 Cyder 正式版，才能啟動 gamania Games Manager。"
            return
        }
        guard validatedGGMWebStartPath() != nil else {
            chooseGGMWebStart()
            return
        }
        pendingLaunchKind = .ggmWebStart
        launchSelectedAccount()
    }

    func launchViaOpen(launcher: OpenLauncher = .defaultApplication) {
        guard let game = selectedGame else {
            errorMessage = "請先選擇遊戲"
            return
        }
        guard let (path, account, otp) = validatedLaunchTarget(for: game) else { return }

        do {
            try clearQuarantineIfNeeded(at: path)
        } catch {
            present(error)
            return
        }

        launchedAccountID = nil
        beginLaunchUI()

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = game.openArguments(
            executablePath: path,
            accountID: account.id,
            otp: otp.value,
            launcher: launcher
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
                    let launchVerb = launcher == .defaultApplication ? "開啟" : "透過 Cyder 開啟"
                    if game.supportsAutomaticLogin {
                        self.statusMessage = "已\(launchVerb)\(game.name)"
                    } else {
                        self.copy(otp.value)
                        self.statusMessage = "已啟動\(game.name)，OTP 已複製"
                    }
                    self.appendLog("執行 open -n：launcher=\(launcher)，game=\(game.serviceKey)，executable=\(path)，account=\(account.id)")
                    self.markLaunchSucceeded()
                } else {
                    let message = errorText.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "open 結束代碼 \(process.terminationStatus)"
                    self.markLaunchFailed()
                    self.present(BeanfunError.rejected(
                        message
                    ))
                }
            }
        }

        isBusy = true
        switch launcher {
        case .defaultApplication:
            statusMessage = "正在開啟\(game.name)…"
        case .cyder, .cyderMapleStoryOEM:
            statusMessage = "正在以 Cyder 開啟\(game.name)…"
        }
        do {
            try process.run()
        } catch {
            isBusy = false
            markLaunchFailed()
            present(error)
        }
    }

    func launchViaCyder() {
        guard let game = selectedGame else {
            errorMessage = "請先選擇遊戲"
            return
        }
        launchViaOpen(launcher: .cyder(for: game))
    }

    func launchViaGGM() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else {
            errorMessage = "Games Manager 啟動僅支援新楓之谷"
            return
        }
        guard let ticket = ggmLaunchTicket else {
            errorMessage = "尚未取得 Games Manager 啟動參數，請再試一次"
            return
        }
        guard CyderInstallation.isOfficialCyderInstalled() else {
            errorMessage = "請先安裝 Cyder 正式版，才能啟動 gamania Games Manager。"
            return
        }
        guard let path = validatedGGMWebStartPath() else { return }

        do {
            try clearQuarantineIfNeeded(at: path)
        } catch {
            present(error)
            return
        }

        launchedAccountID = nil
        beginLaunchUI()

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = BeanfunWebStartOTP.openArguments(uri: ticket.uri, webStartPath: path)
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if process.terminationStatus == 0 {
                    self.statusMessage = "已透過 Games Manager 啟動新楓之谷"
                    self.appendLog("執行 open -n：GGMWebStart=\(path) SN=\(ticket.sn) Cmd=\(ticket.command)")
                    self.markLaunchSucceeded()
                } else {
                    let message = errorText.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "open 結束代碼 \(process.terminationStatus)"
                    self.markLaunchFailed()
                    self.present(BeanfunError.rejected(message))
                }
            }
        }

        isBusy = true
        statusMessage = "正在以 Games Manager 啟動新楓之谷…"
        do {
            try process.run()
        } catch {
            isBusy = false
            markLaunchFailed()
            present(error)
        }
    }

    func launchViaGamaniagamesScheme() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else {
            errorMessage = "gamaniagames 啟動僅支援新楓之谷"
            return
        }
        guard let ticket = ggmLaunchTicket else {
            errorMessage = "尚未取得 gamaniagames 啟動參數，請再試一次"
            return
        }

        launchedAccountID = nil
        beginLaunchUI()

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = BeanfunWebStartOTP.openSchemeArguments(uri: ticket.uri)
        process.standardError = standardError
        process.terminationHandler = { [weak self] process in
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if process.terminationStatus == 0 {
                    self.statusMessage = "已開啟 gamaniagames://"
                    self.appendLog("執行 open -n：gamaniagames SN=\(ticket.sn) Cmd=\(ticket.command)")
                    self.markLaunchSucceeded()
                } else {
                    let message = errorText.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "open 結束代碼 \(process.terminationStatus)"
                    self.markLaunchFailed()
                    self.present(BeanfunError.rejected(message))
                }
            }
        }

        isBusy = true
        statusMessage = "正在開啟 gamaniagames://…"
        do {
            try process.run()
        } catch {
            isBusy = false
            markLaunchFailed()
            present(error)
        }
    }

    func launchViaMapleStoryLauncherWine() {
        guard let game = selectedGame, game.id == GameDefinition.mapleStory.id else {
            errorMessage = "MapleStory Launcher 啟動僅支援新楓之谷"
            return
        }
        guard let (path, account, otp) = validatedLaunchTarget(for: game) else { return }
        let wineURL = MapleStoryWineLauncher.wineExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: wineURL.path) else {
            errorMessage = "找不到 MapleStory Launcher 的 Wine。請先安裝並開啟過 MapleStory Launcher。"
            return
        }

        beginLaunchUI()
        launchedAccountID = nil
        isBusy = true
        statusMessage = "正在以 MapleStory Launcher Wine 啟動\(game.name)…"

        let process = Process()
        process.executableURL = wineURL
        process.arguments = MapleStoryWineLauncher.arguments(
            executablePath: path,
            accountID: account.id,
            otp: otp.value
        )
        process.environment = MapleStoryWineLauncher.processEnvironment()

        do {
            try process.run()
            // Do not wait for wine exit; the launcher stays running independently.
            isBusy = false
            launchedAccountID = account.id
            statusMessage = "已透過 MapleStory Launcher 啟動\(game.name)"
            appendLog("執行 wine：executable=\(path) account=\(account.id)")
            markLaunchSucceeded()
        } catch {
            isBusy = false
            markLaunchFailed()
            present(error)
        }
    }

    /// Validates the current executable path, account, and OTP for launching
    /// `game`, setting `errorMessage` and returning `nil` on the first failed
    /// check. Shared by `launchViaCyder()` and `launchViaMapleStoryLauncherWine()`.
    private func validatedLaunchTarget(
        for game: GameDefinition
    ) -> (path: String, account: GameAccount, otp: OTPResult)? {
        let path = normalizedExecutablePath
        guard !path.isEmpty else {
            errorMessage = "請先選擇 \(game.executableName)"
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            errorMessage = "找不到\(game.name)主程式：\(path)"
            return nil
        }
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "exe" else {
            errorMessage = "請選擇副檔名為 .exe 的檔案"
            return nil
        }
        guard let account = selectedAccount, let otp else {
            errorMessage = "請先選擇帳號並取得 OTP"
            return nil
        }
        return (path, account, otp)
    }

    private func validatedGGMWebStartPath() -> String? {
        let path = resolvedGGMWebStartPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            errorMessage = BeanfunWebStartOTP.missingWebStartPathDescription(path: path)
            return nil
        }
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "exe" else {
            errorMessage = "請選擇副檔名為 .exe 的檔案"
            return nil
        }
        guard URL(fileURLWithPath: path).lastPathComponent.lowercased() == "ggmwebstart.exe" else {
            errorMessage = "請選擇 GGMWebStart.exe，不要選 MapleStory.exe"
            return nil
        }
        return path
    }

    private func beginLaunchUI() {
        launchCooldownTask?.cancel()
        launchUIPhase = .launching
        launchStatusText = "啟動中…"
    }

    private func markLaunchSucceeded() {
        launchUIPhase = .launched
        launchStatusText = "已啟動"
        launchCooldownTask?.cancel()
        launchCooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.launchCooldownNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.launchUIPhase = .idle
            self.launchStatusText = ""
        }
    }

    private func markLaunchFailed() {
        launchCooldownTask?.cancel()
        launchUIPhase = .idle
        launchStatusText = ""
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
            refreshNexonPlugHandlerStatus()
            statusMessage = "已將 NexonPlug 設為由 Beanfun OTP 處理"
        } else {
            errorMessage = "設定 NexonPlug 處理程式失敗（代碼 \(status)）"
        }
    }

    func refreshNexonPlugHandlerStatus() {
        let current = LSCopyDefaultHandlerForURLScheme(Self.nexonPlugScheme as CFString)?
            .takeRetainedValue() as String?
        isNexonPlugHandler = NexonPlugHandlerStatus.isBound(
            currentHandlerBundleID: current,
            selfBundleID: Self.beanfunOTPBundleID
        )
    }

    func downloadClassicClient() {
        guard selectedGame?.id == GameDefinition.mapleStoryClassic.id else { return }
        guard !isDownloadingGameClient else { return }

        let panel = NSOpenPanel()
        panel.title = "選擇下載資料夾"
        panel.message = "新楓之谷：經典版將下載到此資料夾。檔案很大，請預留足夠的磁碟空間。"
        panel.prompt = "下載到此處"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        startGameClientDownload(
            targetGame: GameDefinition.mapleStoryClassic,
            config: .nxdlClassic,
            destination: destination,
            progressTitle: "下載新楓之谷：經典版",
            statusWhileDownloading: "正在下載新楓之谷：經典版…",
            missingExecutableHint: "下載完成，請手動選擇 Maplestory_Classic.exe",
            logLabel: "經典版"
        )
    }

    func updateClassicClient() {
        guard selectedGame?.id == GameDefinition.mapleStoryClassic.id else { return }
        guard !isDownloadingGameClient else { return }
        let path = normalizedExecutablePath
        guard !path.isEmpty, isValidExecutablePath(path) else {
            downloadClassicClient()
            return
        }
        let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
        startGameClientDownload(
            targetGame: GameDefinition.mapleStoryClassic,
            config: .nxdlClassic,
            destination: destination,
            progressTitle: "更新新楓之谷：經典版",
            statusWhileDownloading: "正在更新新楓之谷：經典版…",
            missingExecutableHint: "更新完成，請手動選擇 Maplestory_Classic.exe",
            logLabel: "經典版"
        )
    }

    func checkClientUpdate() {
        guard let game = selectedGame else {
            classicUpdateStatus = .none
            return
        }
        let isClassic = game.id == GameDefinition.mapleStoryClassic.id
        let isMaple = game.id == GameDefinition.mapleStory.id
        guard isClassic || isMaple else {
            classicUpdateStatus = .none
            return
        }
        let path = normalizedExecutablePath
        guard !path.isEmpty, isValidExecutablePath(path) else {
            classicUpdateStatus = .none
            return
        }
        guard !isDownloadingGameClient else { return }

        classicUpdateCheckTask?.cancel()
        classicUpdateStatus = .checking

        let config: GameClientToolConfig = isClassic ? .nxdlClassic : .cmsdlMapleStory
        let destination = URL(fileURLWithPath: path).deletingLastPathComponent()

        classicUpdateCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let manifestInfo = try await self.nxdlDownloader.probeManifestInfo(config: config) { _ in }
                guard !Task.isCancelled else {
                    self.classicUpdateStatus = .none
                    return
                }
                let totalManifestBytes = manifestInfo.totalBytes > 0
                    ? manifestInfo.totalBytes
                    : (try await self.nxdlDownloader.probeTotalSize(config: config) { _ in })
                guard !Task.isCancelled else {
                    self.classicUpdateStatus = .none
                    return
                }
                // Walks every manifest file on disk; can be slow for large
                // installs, so run it off the main actor to avoid freezing the UI.
                let filePaths = manifestInfo.filePaths
                let bytesNeeded = await Task.detached(priority: .userInitiated) {
                    IncrementalSizeCalculator.calculateRequiredDownloadBytes(
                        manifestFiles: filePaths,
                        totalManifestBytes: totalManifestBytes,
                        destination: destination
                    )
                }.value
                guard !Task.isCancelled else {
                    self.classicUpdateStatus = .none
                    return
                }
                self.classicUpdateStatus = bytesNeeded == 0 ? .upToDate : .updateAvailable
            } catch {
                guard !Task.isCancelled else {
                    self.classicUpdateStatus = .none
                    return
                }
                let errorMsg = error.localizedDescription
                let message: String
                if errorMsg.contains("failed to parse game-info response")
                    || errorMsg.contains("failed to lookup address information")
                    || errorMsg.contains("Dns Failed")
                    || errorMsg.contains("HTTP request failed")
                    || errorMsg.contains("ConnectFailed")
                    || errorMsg.contains("timed out") {
                    message = "無法檢查更新（可能是伺服器維修中）"
                } else {
                    message = "無法檢查更新：\(errorMsg)"
                }
                self.classicUpdateStatus = .maintenanceOrError(message)
            }
        }
    }

    func forceUpdateClient() {
        guard let game = selectedGame else { return }
        if game.id == GameDefinition.mapleStoryClassic.id {
            guard !isDownloadingGameClient else { return }
            let path = normalizedExecutablePath
            guard !path.isEmpty, isValidExecutablePath(path) else {
                downloadClassicClient()
                return
            }
            let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
            startGameClientDownload(
                targetGame: GameDefinition.mapleStoryClassic,
                config: .nxdlClassic,
                destination: destination,
                progressTitle: "完整下載新楓之谷：經典版",
                statusWhileDownloading: "正在完整下載新楓之谷：經典版…",
                missingExecutableHint: "下載完成，請手動選擇 Maplestory_Classic.exe",
                logLabel: "經典版",
                isDeepUpdate: true
            )
        } else if game.id == GameDefinition.mapleStory.id {
            guard !isDownloadingGameClient else { return }
            let path = normalizedExecutablePath
            guard !path.isEmpty, isValidExecutablePath(path) else {
                downloadMapleStoryClient()
                return
            }
            let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
            startGameClientDownload(
                targetGame: GameDefinition.mapleStory,
                config: .cmsdlMapleStory,
                destination: destination,
                progressTitle: "更新新楓之谷",
                statusWhileDownloading: "正在更新新楓之谷…",
                missingExecutableHint: "更新完成，請手動選擇 MapleStory.exe",
                logLabel: "新楓之谷",
                isDeepUpdate: true
            )
        }
    }

    func downloadMapleStoryClient() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else { return }
        guard !isDownloadingGameClient else { return }

        let panel = NSOpenPanel()
        panel.title = "選擇下載資料夾"
        panel.message = "新楓之谷將下載到此資料夾。檔案很大，請預留足夠的磁碟空間。"
        panel.prompt = "下載到此處"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        startGameClientDownload(
            targetGame: GameDefinition.mapleStory,
            config: .cmsdlMapleStory,
            destination: destination,
            progressTitle: "下載新楓之谷",
            statusWhileDownloading: "正在下載新楓之谷…",
            missingExecutableHint: "下載完成，請手動選擇 MapleStory.exe",
            logLabel: "新楓之谷"
        )
    }

    func updateMapleStoryClient() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else { return }
        guard !isDownloadingGameClient else { return }
        let path = normalizedExecutablePath
        guard !path.isEmpty, isValidExecutablePath(path) else {
            downloadMapleStoryClient()
            return
        }
        let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
        startGameClientDownload(
            targetGame: GameDefinition.mapleStory,
            config: .cmsdlMapleStory,
            destination: destination,
            progressTitle: "更新新楓之谷",
            statusWhileDownloading: "正在更新新楓之谷…",
            missingExecutableHint: "更新完成，請手動選擇 MapleStory.exe",
            logLabel: "新楓之谷"
        )
    }

    func cancelClassicDownload() {
        nxdlDownloader.cancel()
        classicDownloadTask?.cancel()
    }

    private func presentDiskGate(evaluation: DiskSpaceEvaluation) -> Bool {
        let needed = ByteCountFormat.string(bytes: evaluation.totalBytes)
        let free = ByteCountFormat.string(bytes: evaluation.freeBytes)
        let minimum = ByteCountFormat.string(bytes: evaluation.minimumBytes)
        switch evaluation.verdict {
        case .ok:
            return true
        case .blocked:
            let alert = NSAlert()
            alert.messageText = "磁碟空間不足"
            alert.informativeText =
                "下載約需 \(needed)，目的地磁碟剩餘 \(free)。\n至少需要 \(minimum) 才能下載。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "確定")
            alert.runModal()
            return false
        case .warn:
            let alert = NSAlert()
            alert.messageText = "磁碟空間偏低"
            alert.informativeText =
                "下載約需 \(needed)，目的地磁碟剩餘 \(free)。\n建議至少保留約 \(ByteCountFormat.string(bytes: evaluation.comfortableBytes))（總量的 105%）。仍要繼續嗎？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "仍要下載")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func presentUpToDateAlert(forceButtonTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "經快速檢查，本機檔案完整且檔案大小一致。\n目前不需要下載額外檔案。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "確定")
        alert.addButton(withTitle: forceButtonTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func startGameClientDownload(
        targetGame: GameDefinition,
        config: GameClientToolConfig,
        destination: URL,
        progressTitle: String,
        statusWhileDownloading: String,
        missingExecutableHint: String,
        logLabel: String,
        isDeepUpdate: Bool = false
    ) {
        classicUpdateCheckTask?.cancel()
        classicUpdateStatus = .none
        classicDownloadTask?.cancel()
        classicDownloadTask = Task { [weak self] in
            guard let self else { return }
            self.gameClientDownloadTitle = progressTitle
            self.isDownloadingGameClient = true
            self.isBusy = true
            if isDeepUpdate {
                self.statusMessage = targetGame.id == GameDefinition.mapleStoryClassic.id
                    ? "正在準備完整下載…"
                    : "正在準備更新…"
            } else {
                self.statusMessage = "正在檢查下載大小…"
            }
            self.classicDownloadStatus = self.statusMessage
            self.classicDownloadProgress = NxdlDownloadProgressState(statusMessage: self.statusMessage)
            // Progress sheet opens only after the disk gate passes.

            do {
                let manifestInfo = try await self.nxdlDownloader.probeManifestInfo(config: config) { update in
                    Task { @MainActor in
                        if case let .message(message) = update {
                            self.statusMessage = message
                            self.classicDownloadStatus = message
                        }
                    }
                }
                let total = manifestInfo.totalBytes > 0
                    ? manifestInfo.totalBytes
                    : (try await self.nxdlDownloader.probeTotalSize(config: config) { _ in })
                let free = try VolumeFreeSpace.freeBytes(forDirectory: destination)

                var bytesToCheck = total
                if !isDeepUpdate {
                    // Walks every manifest file on disk; run off the main actor
                    // to avoid freezing the UI for large installs.
                    let filePaths = manifestInfo.filePaths
                    bytesToCheck = await Task.detached(priority: .userInitiated) {
                        IncrementalSizeCalculator.calculateRequiredDownloadBytes(
                            manifestFiles: filePaths,
                            totalManifestBytes: total,
                            destination: destination
                        )
                    }.value
                }

                if !isDeepUpdate && bytesToCheck == 0 {
                    self.statusMessage = "本機檔案完整且大小一致，已是最新版本"
                    self.isDownloadingGameClient = false
                    self.isBusy = false
                    self.classicDownloadStatus = ""
                    self.classicDownloadProgress = NxdlDownloadProgressState()
                    self.gameClientDownloadTitle = ""
                    self.classicUpdateStatus = .upToDate
                    let forceTitle = ClientUpdateUI.forceUpdateButtonTitle(gameID: targetGame.id)
                    if self.presentUpToDateAlert(forceButtonTitle: forceTitle) {
                        self.startGameClientDownload(
                            targetGame: targetGame,
                            config: config,
                            destination: destination,
                            progressTitle: progressTitle,
                            statusWhileDownloading: statusWhileDownloading,
                            missingExecutableHint: missingExecutableHint,
                            logLabel: logLabel,
                            isDeepUpdate: true
                        )
                    }
                    return
                }

                // Deep update re-downloads everything, so the gate must cover the
                // full size — except cmsdlMapleStory, which purges WZ files as it
                // goes and never holds more than ~5 GiB on disk at once.
                let diskGateTotal: UInt64
                if isDeepUpdate {
                    diskGateTotal = config == .cmsdlMapleStory ? min(total, 5 * DiskSpaceGate.gibibyte) : total
                } else {
                    diskGateTotal = bytesToCheck
                }
                let evaluation = DiskSpaceGate.evaluate(totalBytes: diskGateTotal, freeBytes: free)
                guard self.presentDiskGate(evaluation: evaluation) else {
                    self.statusMessage = "已取消下載"
                    self.isDownloadingGameClient = false
                    self.isBusy = false
                    self.classicDownloadStatus = ""
                    self.classicDownloadProgress = NxdlDownloadProgressState()
                    self.gameClientDownloadTitle = ""
                    return
                }

                self.classicDownloadStatus = "準備下載…"
                self.classicDownloadProgress = NxdlDownloadProgressState(statusMessage: "準備下載…")
                self.showClassicDownloadProgress = true
                self.statusMessage = statusWhileDownloading

                try await self.nxdlDownloader.downloadClient(config: config, to: destination) { update in
                    Task { @MainActor in
                        switch update {
                        case let .message(message):
                            self.classicDownloadStatus = message
                        case let .progress(progress):
                            self.classicDownloadProgress = progress
                            if !progress.statusMessage.isEmpty {
                                self.classicDownloadStatus = progress.statusMessage
                            }
                        }
                    }
                }

                self.classicUpdateStatus = .upToDate

                if let exePath = self.nxdlDownloader.findPrimaryExecutable(config: config, in: destination) {
                    self.saveExecutablePath(exePath, for: targetGame)
                    self.statusMessage = "下載完成，已設定主程式路徑"
                    self.appendLog("\(logLabel)下載完成：\(destination.path)，主程式=\(exePath)")
                } else {
                    self.statusMessage = missingExecutableHint
                    self.appendLog("\(logLabel)下載完成：\(destination.path)（未自動找到主程式）")
                }
            } catch is CancellationError {
                self.statusMessage = "下載已取消"
            } catch let error as NxdlDownloaderError {
                if case .cancelled = error {
                    self.statusMessage = "下載已取消"
                } else {
                    self.present(error)
                }
            } catch {
                self.present(error)
            }

            self.isDownloadingGameClient = false
            self.isBusy = false
            self.classicDownloadStatus = ""
            self.classicDownloadProgress = NxdlDownloadProgressState()
            self.gameClientDownloadTitle = ""
            self.showClassicDownloadProgress = false
        }
    }

    func handleOpenedURL(_ url: URL, fromColdStart: Bool = false) {
        if fromColdStart {
            quitAfterSuccessfulClassicLaunch = true
        }
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
            refreshNexonPlugHandlerStatus()
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

        let launcher: OpenLauncher
        if CyderInstallation.isOfficialCyderInstalled() {
            launcher = .cyder
        } else {
            let alert = NSAlert()
            alert.messageText = "未偵測到 Cyder"
            alert.informativeText = "經典版需透過 Cyder 才能可靠傳遞執行參數。請安裝 Cyder 正式版後再試。若仍要以系統預設的「打開方式」開啟，參數可能無法正確傳遞，遊戲可能無法登入。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "仍要開啟")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                statusMessage = "已取消"
                return
            }
            launcher = .defaultApplication
        }

        do {
            try clearQuarantineIfNeeded(at: path)
        } catch {
            present(error)
            return
        }
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = NexonPlugURLParser.classicOpenArguments(
            executablePath: path,
            passargTokens: passargTokens,
            launcher: launcher
        )
        process.standardError = standardError
        let launcherLabel = launcher == .cyder ? "cyder" : "default"
        process.terminationHandler = { [weak self] process in
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if process.terminationStatus == 0 {
                    self.statusMessage = "已開啟新楓之谷：經典版"
                    self.appendLog("執行 open -n：classic executable=\(path) launcher=\(launcherLabel) args=\(passargTokens.joined(separator: " "))")
                    if self.quitAfterSuccessfulClassicLaunch {
                        NSApp.terminate(nil)
                    }
                } else {
                    let message = errorText.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "open 結束代碼 \(process.terminationStatus)"
                    self.present(BeanfunError.rejected(message))
                }
            }
        }
        isBusy = true
        statusMessage = "正在開啟新楓之谷：經典版…"
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

    var hasValidExecutable: Bool {
        isValidExecutablePath(normalizedExecutablePath)
    }

    var hasValidGGMWebStart: Bool {
        isValidExecutablePath(resolvedGGMWebStartPath)
    }

    var resolvedGGMWebStartPath: String {
        BeanfunWebStartOTP.resolvedWebStartPath(stored: ggmWebStartPath)
    }

    private var normalizedExecutablePath: String {
        executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A path is only usable if it's non-empty and actually exists on disk;
    /// a stale/removed path must be treated the same as no path at all.
    private func isValidExecutablePath(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    /// Clears `com.apple.quarantine` only when present, immediately before an
    /// `open`-based launch. Uses Darwin xattr APIs because Foundation's
    /// `URL.fileExtendedAttributesKey` / `removeExtendedAttribute(forName:)`
    /// are unavailable on this toolchain.
    private func clearQuarantineIfNeeded(at path: String) throws {
        let names = try extendedAttributeNames(at: path)
        guard Self.quarantineStatus(forExtendedAttributes: names) == .quarantined else {
            return
        }

        do {
            try removeExtendedAttribute("com.apple.quarantine", at: path)
            appendLog("已解除 quarantine：\(path)")
        } catch {
            let detail = (error as NSError).localizedDescription
            throw BeanfunError.rejected(
                Self.quarantineRemovalErrorDescription(path: path, underlying: detail)
            )
        }
    }

    private func extendedAttributeNames(at path: String) throws -> [String] {
        let length = listxattr(path, nil, 0, 0)
        guard length >= 0 else {
            throw posixError(errno, path: path)
        }
        guard length > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: length)
        let result = listxattr(path, &buffer, buffer.count, 0)
        guard result >= 0 else {
            throw posixError(errno, path: path)
        }

        return Data(bytes: buffer, count: result)
            .split(separator: 0)
            .compactMap { String(data: Data($0), encoding: .utf8) }
            .filter { !$0.isEmpty }
    }

    private func removeExtendedAttribute(_ name: String, at path: String) throws {
        if removexattr(path, name, 0) != 0 {
            throw posixError(errno, path: path)
        }
    }

    private func posixError(_ code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
                NSFilePathErrorKey: path,
            ]
        )
    }

    private func executablePathKey(for game: GameDefinition) -> String {
        Self.executablePathPrefix + game.id
    }

    private func saveExecutablePath(_ path: String, for game: GameDefinition) {
        defaults.set(path, forKey: executablePathKey(for: game))
        if selectedGame?.id == game.id {
            executablePath = path
        }
    }

    private func resetGameSession() {
        errorMessage = nil
        accounts = []
        selectedAccountID = nil
        otp = nil
        ggmLaunchTicket = nil
        launchedAccountID = nil
        qrImage = nil
        qrSecondsRemaining = 60
        isBusy = false
        resetLaunchUI()
    }

    private func resetLaunchUI() {
        launchCooldownTask?.cancel()
        launchCooldownTask = nil
        launchUIPhase = .idle
        launchStatusText = ""
        pendingLaunchKind = .defaultOpen
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
        if let beanfunError = error as? BeanfunError {
            if beanfunError.isSessionExpired {
                handleSessionExpired(message: beanfunError.localizedDescription)
                return
            }
            statusMessage = "操作失敗"
            errorMessage = beanfunError.localizedDescription
        } else {
            statusMessage = "操作失敗"
            errorMessage = error.localizedDescription
        }
        appendLog("錯誤：\(errorMessage ?? error.localizedDescription)")
    }

    func handleSessionExpired(message: String = BeanfunError.defaultExpiredMessage) {
        client.reset()
        resetGameSession()
        statusMessage = "登入階段已過期"
        errorMessage = message.isEmpty ? BeanfunError.defaultExpiredMessage : message
        screen = .welcome
        appendLog("Session 已過期：\(errorMessage ?? "")")
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
