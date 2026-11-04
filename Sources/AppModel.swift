import AppKit
import Combine
#if UI_PREVIEW
import CoreImage
#endif
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
    private static let ggmManifestURLString =
        "https://raw.githubusercontent.com/dspp779/CitrusGate/main/metadata/ggm-manifest.json"

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
    @Published var ggmTicketState: GGMLaunchTicketState = .none

    var ggmLaunchTicket: GGMLaunchTicket? { ggmTicketState.ticket }

    var isGGMLaunchTicketUsable: Bool { ggmTicketState.isUsable }
    @Published var otpSecondsRemaining = 0
    @Published var autoRefresh = false
    @Published var autoRefreshInterval = 60
    @Published var includeSecrets = false
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
    @Published private(set) var isCancellingClientDownload = false
    @Published private(set) var classicDownloadProgress = NxdlDownloadProgressState()
    @Published private(set) var gameClientDownloadTitle = ""
    @Published var showClassicDownloadProgress = false
    @Published private(set) var classicUpdateStatus: ClassicUpdateStatus = .none
    @Published private(set) var isNexonPlugHandler = false

    @Published private(set) var clientUpdateDetail = ""
    @Published private(set) var readinessItems: [LaunchReadinessItem] = []
    private var updateCheckID = UUID()
    private var downloadID = UUID()

    private let defaults: UserDefaults
    private let ggmManifestStore = GGMManifestStore()
    private var ggmManifestUpdater: GGMManifestUpdater?
    private var activeGGMManifest = GGMManifest.fallback()
    private var didStartManifestRefresh = false
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
            Task { @MainActor in self?.appendLog(message) }
        },
        ggmLaunch: { [weak self] ticket in
            self?.ggmTicketState = .consumed(ticket)
        },
        manifest: { [weak self] in
            self?.activeGGMManifest ?? GGMManifest.fallback()
        }
    )
    private lazy var nxdlDownloader = NxdlDownloader { [weak self] message in
        Task { @MainActor in self?.appendLog(message) }
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
        do {
            let fallback = try ggmManifestStore.loadFallbackManifest()
            activeGGMManifest = fallback
            if let cached = try ggmManifestStore.loadCachedManifest(),
               cached.isNewer(than: fallback) {
                activeGGMManifest = cached
            }
        } catch {
            activeGGMManifest = GGMManifest.fallback()
        }
        if let url = URL(string: Self.ggmManifestURLString) {
            ggmManifestUpdater = GGMManifestUpdater(
                manifestURL: url,
                store: ggmManifestStore,
                log: { [weak self] message in self?.appendLog(message) }
            )
        }
    }

    #if UI_PREVIEW
    func configurePreview(_ state: String) {
        didStartManifestRefresh = true
        if state == "games" { return }
        selectGame(state == "classic" ? .mapleStoryClassic : .mapleStory, autoPickExecutable: false)
        statusMessage = "準備登入"
        if state == "qr" || state == "expired" {
            screen = .qr
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data("https://example.invalid/preview".utf8), forKey: "inputMessage")
            let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
            qrImage = NSImage(cgImage: CIContext().createCGImage(image, from: image.extent)!, size: NSSize(width: 264, height: 264))
            qrSecondsRemaining = state == "expired" ? 0 : 42
            statusMessage = state == "expired" ? "QR Code 已到期，請重新產生。" : "等待手機確認登入"
        } else if state == "accounts" {
            screen = .accounts
            accounts = [GameAccount(id: "preview-a", sn: "fixture-a", displayName: "我的冒險帳號"),
                        GameAccount(id: "preview-b", sn: "fixture-b", displayName: "很長的帳號名稱，用來檢查文字換行與按鈕是否完整顯示")]
            selectedAccountID = accounts.first?.id
            statusMessage = "登入完成，請選擇帳號。"
        } else if state == "update" || state == "minor" {
            gameClientDownloadTitle = "更新新楓之谷"
            classicDownloadProgress.phase = state == "minor" ? .minorPatch : .downloading
            classicDownloadProgress.overall = NxdlProgressBarInfo(downloadedText: "74.50 MiB", totalText: "176.88 MiB", speedText: "12.30 MiB/s", etaText: "ETA 8s", elapsedText: "00:00:06", fraction: 0.42)
            classicDownloadProgress.currentFileNames = [state == "minor" ? "ExePatch.dat" : "非常長的遊戲資源檔案名稱_Character_00001.wz"]
        } else if state == "verifying" || state == "cancelling" {
            gameClientDownloadTitle = "更新新楓之谷"
            classicDownloadProgress.phase = .finishing
            isCancellingClientDownload = state == "cancelling"
        } else if state == "advanced" {
            mode = .advanced
        } else if state == "update-error" {
            classicUpdateStatus = .maintenanceOrError("更新尚未完成")
            clientUpdateDetail = "無法連線至更新伺服器，請稍後再試。已保留既有遊戲檔案。"
        } else if state == "readiness" {
            readinessItems = [LaunchReadinessItem(title: "遊戲主程式", detail: "請選擇 MapleStory.exe。", isReady: false),
                              LaunchReadinessItem(title: "啟動環境", detail: "請安裝 Cyder，或設定 .exe 的預設開啟程式。", isReady: false)]
        }
    }
    #endif

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
        guard !didStartManifestRefresh else { return }
        didStartManifestRefresh = true
        ggmManifestUpdater?.refreshIfNeeded(current: activeGGMManifest) { [weak self] updated in
            self?.activeGGMManifest = updated
        }
    }

    func setMode(_ newMode: AppMode) {
        guard mode != newMode, !isBusy else { return }
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
        clientUpdateDetail = ""
        refreshLaunchReadiness()
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
        ggmTicketState = .none
        launchedAccountID = nil
        qrImage = nil
        logText = ""
        isBusy = true
        statusMessage = "正在建立 Beanfun 登入階段…"
        client.includeSecrets = false

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
        ggmTicketState = .none
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
        ggmTicketState = .none
        client.includeSecrets = false
        isBusy = true
        statusMessage = "正在取得 \(account.displayName) 的 OTP…"
        otpTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.fetchOTP(for: account, game: game)
                try Task.checkCancellation()
                otp = result
                isBusy = false
                if game.id == GameDefinition.mapleStory.id {
                    ggmTicketState.consume()
                    appendLog("  原生 otp_v2 已兌現 LaunchTicket，此 Data 已標記無效")
                }
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
                    case .ggmWebStart, .ggmSchemeViaCyder:
                        break
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
        guard isGGMLaunchTicketUsable, let value = ggmLaunchTicket?.uri else {
            statusMessage = "此 Data 已失效，請重新用橘子遊戲管理器開啟以取得新 URI"
            return
        }
        copy(value)
        statusMessage = "GGM URI 已複製"
    }

    func copyGGMCyderCommand() {
        guard isGGMLaunchTicketUsable, let ticket = ggmLaunchTicket else {
            statusMessage = "此 Data 已失效，請重新用橘子遊戲管理器開啟以取得新 URI"
            return
        }
        copy(ticket.cyderOpenCommand(webStartPath: resolvedGGMWebStartPath))
        statusMessage = "GGM Cyder 指令已複製"
    }

    func copyGGMSchemeCommand() {
        guard isGGMLaunchTicketUsable, let ticket = ggmLaunchTicket else {
            statusMessage = "此 Data 已失效，請重新用橘子遊戲管理器開啟以取得新 URI"
            return
        }
        copy(ticket.schemeOpenCommand())
        statusMessage = "gamaniagames open 指令已複製"
    }

    func copyDebugLog() {
        copy(DiagnosticRedactor.redact(logText))
        statusMessage = "Debug log 已複製"
    }

    func chooseExecutable() {
        guard !isDownloadingGameClient else { return }
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
        classicUpdateCheckTask?.cancel()
        updateCheckID = UUID()
        classicUpdateStatus = .none
        clientUpdateDetail = ""
        executablePath = url.path
        refreshLaunchReadiness()
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
        guard preflight(launcher: .defaultApplication) else { return }
        pendingLaunchKind = .defaultOpen
        launchSelectedAccount()
    }

    private func preflight(launcher: OpenLauncher) -> Bool {
        guard let game = selectedGame else { return false }
        if let issue = LaunchPreflight.fileProblem(path: normalizedExecutablePath, expectedName: game.executableName) {
            errorMessage = issue; return false
        }
        guard LaunchPreflight.application(for: launcher, executable: normalizedExecutablePath) != nil else {
            errorMessage = "找不到此遊戲的啟動環境，請先完成啟動前檢查。"; return false
        }
        return true
    }

    func launchSelectedAccountViaCyder() {
        // This route uses native OTP and the official Cyder bundle below;
        // the OEM launcher remains a separate advanced-mode option.
        guard selectedGame != nil, preflight(launcher: .cyder) else { return }
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
        prepareGGMThenLaunch()
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
        prepareGGMThenLaunch()
    }

    private func prepareGGMThenLaunch() {
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
        ggmTicketState = .none
        otp = nil
        client.includeSecrets = false
        isBusy = true
        statusMessage = "正在準備 \(account.displayName) 的 gamaniagames://…"
        otpTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ticket = try await client.prepareGGMLaunchTicket(for: account, game: game)
                try Task.checkCancellation()
                ggmTicketState = .usable(ticket)
                isBusy = false
                statusMessage = "URI 已準備，正在啟動…"
                switch pendingLaunchKind {
                case .ggmWebStart:
                    launchViaGGM()
                case .ggmSchemeViaCyder:
                    launchViaGamaniagamesScheme()
                default:
                    break
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

    func launchViaOpen(launcher: OpenLauncher = .defaultApplication) {
        guard let game = selectedGame else {
            errorMessage = "請先選擇遊戲"
            return
        }
        guard let (path, account, otp) = validatedLaunchTarget(for: game) else { return }

        guard LaunchPreflight.application(for: launcher, executable: path) != nil else {
            errorMessage = launcher == .defaultApplication
                ? "找不到可開啟 .exe 的程式。請安裝 Cyder，或在 Finder 設定預設開啟程式。"
                : "找不到此遊戲需要的 Cyder 版本，請先完成安裝。"
            return
        }

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
        guard isGGMLaunchTicketUsable, let ticket = ggmLaunchTicket else {
            errorMessage = "Games Manager 啟動參數已失效，請重新開啟"
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
            ggmTicketState.consume()
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
        guard isGGMLaunchTicketUsable, let ticket = ggmLaunchTicket else {
            errorMessage = "gamaniagames 啟動參數已失效，請重新開啟"
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
            ggmTicketState.consume()
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
        if let problem = LaunchPreflight.fileProblem(path: path, expectedName: game.executableName) {
            errorMessage = problem; return nil
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
        let id = UUID(); updateCheckID = id
        classicUpdateStatus = .checking
        clientUpdateDetail = "正在比較本機版本與伺服器更新路線…"
        let config: GameClientToolConfig = isClassic ? .nxdlClassic : .cmsdlMapleStory
        let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
        classicUpdateCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await self.nxdlDownloader.inspectClient(config: config, destination: destination)
                guard !Task.isCancelled, self.updateCheckID == id else { return }
                self.clientUpdateDetail = plan.detail
                self.classicUpdateStatus = plan.isCurrent ? .upToDate : .updateAvailable
            } catch {
                guard !Task.isCancelled, self.updateCheckID == id else { return }
                self.classicUpdateStatus = .maintenanceOrError("無法確認更新，請重試。")
                self.clientUpdateDetail = DiagnosticRedactor.redact(error.localizedDescription)
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
        guard isDownloadingGameClient, !isCancellingClientDownload else { return }
        isCancellingClientDownload = true
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

    private func startGameClientDownload(
        targetGame: GameDefinition, config: GameClientToolConfig, destination: URL,
        progressTitle: String, statusWhileDownloading: String,
        missingExecutableHint: String, logLabel: String, isDeepUpdate: Bool = false
    ) {
        classicUpdateCheckTask?.cancel()
        updateCheckID = UUID()
        let id = UUID(); downloadID = id
        classicUpdateStatus = .none
        classicDownloadTask = Task { [weak self] in
            guard let self else { return }
            self.gameClientDownloadTitle = progressTitle
            self.isDownloadingGameClient = true
            self.isCancellingClientDownload = false
            self.isBusy = true
            self.showClassicDownloadProgress = true
            self.classicDownloadProgress = NxdlDownloadProgressState(statusMessage: "正在確認更新路線…")
            self.classicDownloadStatus = "正在確認更新路線…"
            defer {
                if self.downloadID == id {
                    self.isDownloadingGameClient = false
                    self.isCancellingClientDownload = false
                    self.isBusy = false
                    self.showClassicDownloadProgress = false
                }
            }
            let update: @Sendable (NxdlDownloadUpdate) -> Void = { [weak self] value in
                Task { @MainActor in
                    guard let self, self.downloadID == id, self.isDownloadingGameClient else { return }
                    switch value {
                    case let .message(message):
                        self.classicDownloadStatus = message
                        self.classicDownloadProgress.notePhase(message)
                    case var .progress(progress):
                        progress.notePhase(progress.statusMessage)
                        self.classicDownloadProgress = progress
                        if !progress.statusMessage.isEmpty { self.classicDownloadStatus = progress.statusMessage }
                    }
                }
            }
            do {
                let problem = LaunchPreflight.destinationProblem(destination)
                if let problem { throw BeanfunError.rejected(problem) }
                let installed = self.nxdlDownloader.findPrimaryExecutable(config: config, in: destination) != nil
                let plan = !isDeepUpdate && installed
                    ? try await self.nxdlDownloader.inspectClient(config: config, destination: destination)
                    : ClientUpdatePlan.fullDownload("下載並驗證客戶端檔案。")
                try Task.checkCancellation()
                self.clientUpdateDetail = plan.detail
                // Reserve a private replacement tree, application scratch files,
                // and patch downloads even on volumes without file cloning.
                // --purge-wz-files never guaranteed a 5 GiB upper bound.
                let total = try await self.nxdlDownloader.probeTotalSize(config: config, onUpdate: update)
                try Task.checkCancellation()
                try ClientUpdateTransaction.reclaimAbandoned(destination: destination)
                let reserve = plan.operation == .patch
                    ? DiskSpaceGate.updateReserve(total: total, patch: plan.downloadBytes ?? total)
                    : FileManager.default.fileExists(atPath: destination.path) ? DiskSpaceGate.updateReserve(total: total, patch: 0) : total
                let free = try VolumeFreeSpace.freeBytes(forDirectory: destination)
                guard self.presentDiskGate(evaluation: DiskSpaceGate.evaluate(totalBytes: reserve, freeBytes: free)) else {
                    self.statusMessage = "已取消，既有遊戲檔案已保留。"; return
                }
                try Task.checkCancellation()
                self.statusMessage = statusWhileDownloading
                try await self.nxdlDownloader.downloadClient(config: config, to: destination,
                    operation: plan.operation, onUpdate: update)
                // Success means the directory exchange already committed. A late
                // cancellation must not misreport that installed update as cancelled.
                guard let exePath = self.nxdlDownloader.findPrimaryExecutable(config: config, in: destination) else {
                    throw BeanfunError.rejected(missingExecutableHint)
                }
                self.saveExecutablePath(exePath, for: targetGame)
                self.classicUpdateStatus = .completed
                self.clientUpdateDetail = self.nxdlDownloader.completionNote
                self.statusMessage = self.nxdlDownloader.completionNote
                self.appendLog("\(logLabel)更新完成，已設定主程式路徑。")
                self.refreshLaunchReadiness()
            } catch is CancellationError {
                self.statusMessage = "已取消，既有遊戲檔案已保留；重試可能重新下載。"
            } catch let error as NxdlDownloaderError {
                if case .cancelled = error { self.statusMessage = "已取消，既有遊戲檔案已保留；重試可能重新下載。" }
                else {
                    self.classicUpdateStatus = .maintenanceOrError("更新尚未完成")
                    self.clientUpdateDetail = DiagnosticRedactor.redact(error.localizedDescription)
                    self.present(error)
                }
            } catch {
                self.classicUpdateStatus = .maintenanceOrError("更新尚未完成")
                self.clientUpdateDetail = DiagnosticRedactor.redact(error.localizedDescription)
                self.present(error)
            }
        }
    }

    func repairLegacyDownloadPaths() {
        guard !isBusy, hasValidExecutable else { return }
        let destination = URL(fileURLWithPath: normalizedExecutablePath).deletingLastPathComponent()
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let count = try await Task.detached {
                    try NxdlDownloader().normalizeWindowsPathFilenames(in: destination)
                }.value
                self.statusMessage = count == 0 ? "未發現需要修復的舊版路徑。" : "已修復 \(count) 個舊版檔案路徑。"
            } catch { self.present(error) }
        }
    }

    func refreshLaunchReadiness() {
        guard let game = selectedGame else { readinessItems = []; return }
        let issue = LaunchPreflight.fileProblem(path: normalizedExecutablePath, expectedName: game.executableName)
        let defaultApp = hasValidExecutable ? LaunchPreflight.application(for: .defaultApplication, executable: normalizedExecutablePath) : nil
        let cyder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OpenLauncher.cyderBundleIdentifier)
        readinessItems = [
            LaunchReadinessItem(title: "遊戲主程式", detail: issue ?? "檔案可讀取", isReady: issue == nil),
            LaunchReadinessItem(title: "系統預設開啟程式", detail: defaultApp != nil ? "已設定 .exe 的開啟程式" : "尚未設定預設程式，可改用 Cyder 啟動。", isReady: defaultApp != nil),
            LaunchReadinessItem(title: "Cyder", detail: cyder != nil ? "已找到此遊戲的 Cyder 版本" : "未找到此遊戲的 Cyder 版本，請依安裝說明設定。", isReady: cyder != nil)
        ]
        if game.id == GameDefinition.mapleStory.id {
            let oemReady = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OpenLauncher.cyderMapleStoryOEMBundleIdentifier) != nil
            readinessItems.append(LaunchReadinessItem(title: "Cyder 新楓之谷分支（選用）", detail: oemReady ? "可供進階模式使用" : "未安裝不影響 Cyder 正式版的啟動方式。", isReady: oemReady))
            let wineReady = FileManager.default.isExecutableFile(atPath: MapleStoryWineLauncher.wineExecutableURL().path)
            readinessItems.append(LaunchReadinessItem(title: "MapleStory Launcher Wine", detail: wineReady ? "已找到 Wine 啟動環境" : "如需使用 Wine，請先安裝 MapleStory Launcher。", isReady: wineReady))
        }
        if game.id == GameDefinition.mapleStoryClassic.id {
            refreshNexonPlugHandlerStatus()
            readinessItems.append(LaunchReadinessItem(title: "網頁登入連結", detail: isNexonPlugHandler ? "已交由 Beanfun OTP 處理" : "請設定由 Beanfun OTP 接收登入連結。", isReady: isNexonPlugHandler))
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Beanfun-OTP-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let report = "Beanfun OTP \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nnxdl \(NxdlDownloader.releaseTag) / cmsdl \(GameClientToolConfig.cmsdlMapleStory.releaseTag)\n\n" + DiagnosticRedactor.redact(logText)
        do { try report.write(to: url, atomically: true, encoding: .utf8); statusMessage = "診斷紀錄已匯出，登入連結與憑證已遮蔽。" }
        catch { present(error) }
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
        guard !isDownloadingGameClient else {
            statusMessage = "更新期間暫不啟動遊戲；完成後請重新由官網登入。"
            return
        }
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
        if let issue = LaunchPreflight.fileProblem(path: path, expectedName: GameDefinition.mapleStoryClassic.executableName) {
            errorMessage = issue; return
        }
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
        ggmTicketState = .none
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
        let line = "[\(formatter.string(from: Date()))] \(DiagnosticRedactor.redact(message))"
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
