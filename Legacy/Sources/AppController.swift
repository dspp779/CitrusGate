import AppKit
import UniformTypeIdentifiers

final class AppController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Screen {
        case games, qr, accounts, otp, classic
    }

    private static let lastGameIDKey = "LegacyLastGameID"
    private static let legacyMapleStoryPathKey = "MapleStoryExecutablePath"
    private static let executablePathPrefix = "ExecutablePath."
    private static let officialNexonPlugAppPath = "/Library/Application Support/Nexon/Plug/NexonPlug.app"
    private static let nexonPlugScheme = "NexonPlug"
    private static let beanfunOTPBundleID = "local.ogom.beanfunotp.legacy"

    private let client = BeanfunClient { message in
        NSLog("%@", message)
    }

    private var screen: Screen = .games {
        didSet { updateVisibility() }
    }

    private var games: [GameDefinition] = GameDefinition.all
    private var selectedGame: GameDefinition?
    private var accounts: [GameAccount] = []
    private var selectedAccountIndex: Int = -1
    private var selectedAccount: GameAccount?
    private var otpResult: OTPResult?

    private var pollTimer: Timer?
    private var countdownTimer: Timer?
    private var qrSecondsRemaining: Int = 60
    private var loginCompletionInFlight = false
    private var quitAfterSuccessfulClassicLaunch = false
    private var pendingClassicPassargTokens: [String]?
    private var isDownloadingGameClient = false {
        didSet { updateGameClientDownloadUI() }
    }
    private var classicDownloadStatus = ""
    private var classicDownloadProgressWindow: ClassicDownloadProgressWindowController?
    private lazy var nxdlDownloader = NxdlDownloader { message in
        NSLog("%@", message)
    }

    private var executablePath: String = "" {
        didSet {
            updateExePathLabel()
        }
    }

    // UI Controls
    private let statusLabel = NSTextField(wrappingLabelWithString: "選擇遊戲")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let imageView = NSImageView()
    private let qrStatusLabel = NSTextField(labelWithString: "")

    // Executable path & settings UI
    private let exePathLabel = NSTextField(wrappingLabelWithString: "")
    private let chooseExeButton = NSButton(title: "選擇主程式…", target: nil, action: nil)
    private var exeContainer: NSStackView!
    private var rootStackView: NSStackView!

    // Classic Mode UI
    private let openClassicWebButton = NSButton(title: "開啟官方登入網頁", target: nil, action: nil)
    private let claimNexonPlugButton = NSButton(title: "將 NexonPlug 設為由 Beanfun OTP 處理", target: nil, action: nil)
    private let downloadClassicButton = NSButton(title: "下載經典版", target: nil, action: nil)
    private let downloadMapleStoryButton = NSButton(title: "下載新楓之谷", target: nil, action: nil)
    private let classicNoticeLabel = NSTextField(wrappingLabelWithString: "網頁登入後會透過 NexonPlug:// 傳送參數啟動經典版。")
    private var classicContainer: NSStackView!

    // OTP Block UI
    private let accountCaptionLabel = NSTextField(labelWithString: "帳號")
    private let accountField = NSTextField(labelWithString: "")
    private let otpCaptionLabel = NSTextField(labelWithString: "OTP")
    private let otpField = NSTextField(labelWithString: "")

    // Action Buttons
    private let primaryButton = NSButton(title: "下一步", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "複製帳號", target: nil, action: nil)
    private let wineLaunchButton = NSButton(title: "以 Launcher 開啟", target: nil, action: nil)
    private let copyCmdButton = NSButton(title: "複製指令", target: nil, action: nil)
    private let backButton = NSButton(title: "選擇其他遊戲", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 360))
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
        restoreLastGame()
        updateVisibility()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowSize(animate: false)
    }

    deinit {
        stopTimers()
        nxdlDownloader.cancel()
    }

    // MARK: - UI construction

    private func buildUI() {
        setupMainMenu()
        statusLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 13)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 380
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleTableDoubleClick)
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 26

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 180).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        qrStatusLabel.alignment = .center
        qrStatusLabel.font = NSFont.systemFont(ofSize: 12)
        qrStatusLabel.textColor = NSColor.disabledControlTextColor

        // Executable Path Section
        exePathLabel.alignment = .center
        exePathLabel.font = NSFont.systemFont(ofSize: 11)
        exePathLabel.textColor = NSColor.secondaryLabelColor
        exePathLabel.maximumNumberOfLines = 2
        exePathLabel.lineBreakMode = .byTruncatingMiddle

        chooseExeButton.bezelStyle = .rounded
        chooseExeButton.target = self
        chooseExeButton.action = #selector(handleChooseExecutable)

        downloadMapleStoryButton.bezelStyle = .rounded
        downloadMapleStoryButton.target = self
        downloadMapleStoryButton.action = #selector(handleDownloadMapleStory)

        exeContainer = NSStackView(views: [exePathLabel, chooseExeButton, downloadMapleStoryButton])
        exeContainer.orientation = .vertical
        exeContainer.alignment = .centerX
        exeContainer.spacing = 6
        exeContainer.translatesAutoresizingMaskIntoConstraints = false

        // Classic Mode Section
        openClassicWebButton.bezelStyle = .rounded
        openClassicWebButton.target = self
        openClassicWebButton.action = #selector(handleOpenClassicWeb)

        claimNexonPlugButton.bezelStyle = .rounded
        claimNexonPlugButton.target = self
        claimNexonPlugButton.action = #selector(handleClaimNexonPlug)

        downloadClassicButton.bezelStyle = .rounded
        downloadClassicButton.target = self
        downloadClassicButton.action = #selector(handleDownloadClassic)

        classicNoticeLabel.alignment = .center
        classicNoticeLabel.font = NSFont.systemFont(ofSize: 11)
        classicNoticeLabel.textColor = NSColor.secondaryLabelColor

        classicContainer = NSStackView(views: [
            classicNoticeLabel,
            openClassicWebButton,
            claimNexonPlugButton,
            downloadClassicButton,
        ])
        classicContainer.orientation = .vertical
        classicContainer.alignment = .centerX
        classicContainer.spacing = 8
        classicContainer.translatesAutoresizingMaskIntoConstraints = false

        // OTP Section
        for caption in [accountCaptionLabel, otpCaptionLabel] {
            caption.alignment = .left
            caption.font = NSFont.boldSystemFont(ofSize: 12)
            caption.textColor = NSColor.disabledControlTextColor
        }

        accountField.alignment = .center
        accountField.font = NSFont.systemFont(ofSize: 15)
        accountField.isEditable = false
        accountField.isSelectable = true
        accountField.isBezeled = false
        accountField.drawsBackground = false

        otpField.alignment = .center
        if let base = NSFont.userFixedPitchFont(ofSize: 32) {
            otpField.font = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        otpField.isEditable = false
        otpField.isSelectable = true
        otpField.isBezeled = false
        otpField.drawsBackground = false

        let otpBlock = NSStackView(views: [
            accountCaptionLabel, accountField, otpCaptionLabel, otpField,
        ])
        otpBlock.orientation = .vertical
        otpBlock.alignment = .leading
        otpBlock.spacing = 4
        otpBlock.setCustomSpacing(12, after: accountField)
        otpBlock.translatesAutoresizingMaskIntoConstraints = false

        // Action Buttons
        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondary)

        wineLaunchButton.bezelStyle = .rounded
        wineLaunchButton.target = self
        wineLaunchButton.action = #selector(handleWineLaunch)

        copyCmdButton.bezelStyle = .rounded
        copyCmdButton.target = self
        copyCmdButton.action = #selector(handleCopyCmd)

        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(handleBack)
        setSubtleButtonTitle(backButton, title: "‹ 選擇其他遊戲")

        let buttonRow = NSStackView(views: [primaryButton, secondaryButton, wineLaunchButton, copyCmdButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.distribution = .fillEqually
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        rootStackView = NSStackView(views: [
            statusLabel, scrollView, imageView, qrStatusLabel, classicContainer, otpBlock, exeContainer, buttonRow, backButton,
        ])
        rootStackView.orientation = .vertical
        rootStackView.alignment = .centerX
        rootStackView.spacing = 10
        rootStackView.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        rootStackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStackView)
        NSLayoutConstraint.activate([
            rootStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            rootStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            rootStackView.topAnchor.constraint(equalTo: view.topAnchor),
            rootStackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootStackView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootStackView.trailingAnchor),
            otpBlock.leadingAnchor.constraint(equalTo: rootStackView.leadingAnchor),
            otpBlock.trailingAnchor.constraint(equalTo: rootStackView.trailingAnchor),
            exeContainer.leadingAnchor.constraint(equalTo: rootStackView.leadingAnchor),
            exeContainer.trailingAnchor.constraint(equalTo: rootStackView.trailingAnchor),
            classicContainer.leadingAnchor.constraint(equalTo: rootStackView.leadingAnchor),
            classicContainer.trailingAnchor.constraint(equalTo: rootStackView.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: rootStackView.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: rootStackView.trailingAnchor),
        ])
    }

    // MARK: - Visibility & State

    private func updateVisibility() {
        scrollView.isHidden = !(screen == .games || screen == .accounts)
        imageView.isHidden = screen != .qr
        qrStatusLabel.isHidden = screen != .qr
        classicContainer.isHidden = screen != .classic
        otpBlockVisibility(screen == .otp)
        exeContainer.isHidden = !(screen == .qr || screen == .accounts || screen == .otp || screen == .classic)
        let hasExe = !executablePath.isEmpty && FileManager.default.fileExists(atPath: executablePath)
        chooseExeButton.isHidden = hasExe || screen == .classic
        downloadMapleStoryButton.isHidden = hasExe || selectedGame?.id != GameDefinition.mapleStory.id || screen == .classic
        downloadClassicButton.isHidden = hasExe || selectedGame?.id != GameDefinition.mapleStoryClassic.id

        if screen == .games || screen == .accounts {
            tableView.reloadData()
        }
        updateButtons()
        updateWindowSize(animate: view.window != nil)
    }

    private func updateWindowSize(animate: Bool = true) {
        view.layoutSubtreeIfNeeded()
        let minH: CGFloat = (screen == .accounts || screen == .otp) ? 420 : ((screen == .qr) ? 440 : 340)
        let targetHeight = max(rootStackView.fittingSize.height, minH)
        guard targetHeight > 0 else { return }

        preferredContentSize = NSSize(width: 440, height: targetHeight)

        if let window = view.window {
            let currentContentRect = window.contentRect(forFrameRect: window.frame)
            if abs(currentContentRect.height - targetHeight) > 1 {
                let newFrame = window.frameRect(forContentRect: NSRect(
                    x: window.frame.origin.x,
                    y: window.frame.origin.y + (currentContentRect.height - targetHeight),
                    width: 440,
                    height: targetHeight
                ))
                window.setFrame(newFrame, display: true, animate: animate)
            }
        }
    }

    private func otpBlockVisibility(_ visible: Bool) {
        accountCaptionLabel.isHidden = !visible
        accountField.isHidden = !visible
        otpCaptionLabel.isHidden = !visible
        otpField.isHidden = !visible
    }

    private func updateButtons() {
        switch screen {
        case .games:
            primaryButton.isHidden = false
            primaryButton.title = "下一步"
            primaryButton.isEnabled = tableView.selectedRow >= 0
            secondaryButton.isHidden = true
            wineLaunchButton.isHidden = true
            copyCmdButton.isHidden = true
            backButton.isHidden = true
        case .qr:
            primaryButton.isHidden = false
            primaryButton.title = "重新產生"
            primaryButton.isEnabled = true
            secondaryButton.isHidden = true
            wineLaunchButton.isHidden = true
            copyCmdButton.isHidden = true
            backButton.isHidden = false
        case .accounts:
            primaryButton.isHidden = false
            primaryButton.title = "取得 OTP"
            primaryButton.isEnabled = selectedAccountIndex >= 0
            secondaryButton.isHidden = true
            wineLaunchButton.isHidden = true
            copyCmdButton.isHidden = true
            backButton.isHidden = false
        case .otp:
            primaryButton.isHidden = false
            if selectedGame?.id == GameDefinition.mapleStory.id {
                primaryButton.title = "開啟"
                primaryButton.isEnabled = isValidExecutablePath(executablePath)
                secondaryButton.title = "以 Cyder 開啟"
                secondaryButton.isHidden = false
                secondaryButton.isEnabled = isValidExecutablePath(executablePath)
                wineLaunchButton.isHidden = false
                wineLaunchButton.isEnabled = isValidExecutablePath(executablePath)
            } else if isValidExecutablePath(executablePath) {
                primaryButton.title = "開啟"
                primaryButton.isEnabled = true
                secondaryButton.title = "以 Cyder 開啟"
                secondaryButton.isHidden = false
                secondaryButton.isEnabled = true
                wineLaunchButton.isHidden = true
            } else {
                primaryButton.title = "複製 OTP"
                primaryButton.isEnabled = true
                secondaryButton.title = "複製帳號"
                secondaryButton.isHidden = false
                wineLaunchButton.isHidden = true
            }
            copyCmdButton.isHidden = false
            backButton.isHidden = false
        case .classic:
            let hasExe = !executablePath.isEmpty && FileManager.default.fileExists(atPath: executablePath)
            if hasExe {
                primaryButton.isHidden = true
            } else {
                primaryButton.title = "選擇主程式…"
                primaryButton.isHidden = false
                primaryButton.isEnabled = !isDownloadingGameClient
            }
            secondaryButton.isHidden = true
            wineLaunchButton.isHidden = true
            copyCmdButton.isHidden = true
            backButton.isHidden = false
        }
    }

    private func updateGameClientDownloadUI() {
        let downloading = isDownloadingGameClient
        let hasExe = !executablePath.isEmpty && FileManager.default.fileExists(atPath: executablePath)
        downloadClassicButton.isHidden = hasExe || selectedGame?.id != GameDefinition.mapleStoryClassic.id
        downloadMapleStoryButton.isHidden = hasExe || selectedGame?.id != GameDefinition.mapleStory.id || screen == .classic
        chooseExeButton.isHidden = hasExe || screen == .classic
        downloadClassicButton.isEnabled = !downloading
        downloadMapleStoryButton.isEnabled = !downloading
        openClassicWebButton.isEnabled = !downloading
        claimNexonPlugButton.isEnabled = !downloading
    }

    private func restoreLastGame() {
        guard let lastID = UserDefaults.standard.string(forKey: Self.lastGameIDKey),
              let index = games.firstIndex(where: { $0.id == lastID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        loadExecutablePath(for: games[index])
    }

    private func loadExecutablePath(for game: GameDefinition) {
        let key = Self.executablePathPrefix + game.id
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            executablePath = stored
        } else if game.id == GameDefinition.mapleStory.id,
                  let legacy = UserDefaults.standard.string(forKey: Self.legacyMapleStoryPathKey),
                  !legacy.isEmpty {
            executablePath = legacy
            UserDefaults.standard.set(legacy, forKey: key)
        } else {
            executablePath = ""
        }
    }

    private func saveExecutablePath(_ path: String, for game: GameDefinition) {
        let key = Self.executablePathPrefix + game.id
        UserDefaults.standard.set(path, forKey: key)
        if selectedGame?.id == game.id {
            executablePath = path
        }
    }

    private func updateExePathLabel() {
        guard let game = selectedGame else {
            exePathLabel.stringValue = ""
            return
        }
        if executablePath.isEmpty {
            exePathLabel.stringValue = "（未指定 \(game.executableName) 主程式）"
        } else if !FileManager.default.fileExists(atPath: executablePath) {
            exePathLabel.stringValue = "⚠️ 找不到主程式：\(executablePath)"
        } else {
            exePathLabel.stringValue = "主程式：\(executablePath)"
        }
        updateButtons()
    }

    private func clearTableSelection() {
        tableView.deselectAll(nil)
        selectedAccountIndex = -1
    }

    private func resetToGames() {
        stopTimers()
        loginCompletionInFlight = false
        accounts = []
        selectedAccount = nil
        clearTableSelection()
        otpResult = nil
        accountField.stringValue = ""
        otpField.stringValue = ""
        imageView.image = nil
        qrStatusLabel.stringValue = ""
        statusLabel.stringValue = "選擇遊戲"
        screen = .games
    }

    // MARK: - Actions

    @objc private func handleTableDoubleClick() {
        guard screen == .games else { return }
        selectGame(at: tableView.clickedRow)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        switch screen {
        case .games:
            if games.indices.contains(tableView.selectedRow) {
                loadExecutablePath(for: games[tableView.selectedRow])
            }
            updateButtons()
        case .accounts:
            selectedAccountIndex = tableView.selectedRow
            updateButtons()
        default:
            break
        }
    }

    @objc private func handleChooseExecutable() {
        chooseExecutable()
    }

    @objc private func handleOpenClassicWeb() {
        guard let url = GameDefinition.mapleStoryClassic.loginURL else { return }
        NSWorkspace.shared.open(url)
        statusLabel.stringValue = "已開啟新楓之谷：經典版登入網頁"
    }

    @objc private func handleDownloadClassic() {
        guard selectedGame?.id == GameDefinition.mapleStoryClassic.id else { return }
        guard !isDownloadingGameClient else { return }

        let destination: URL
        if !executablePath.isEmpty, FileManager.default.fileExists(atPath: executablePath) {
            destination = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        } else {
            let panel = NSOpenPanel()
            panel.title = "選擇下載資料夾"
            panel.message = "新楓之谷：經典版將下載到此資料夾。檔案很大，請預留足夠的磁碟空間。"
            panel.prompt = "下載到此處"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false

            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        beginGameClientDownload(
            targetGame: GameDefinition.mapleStoryClassic,
            config: .nxdlClassic,
            destination: destination,
            progressTitle: "下載新楓之谷：經典版",
            statusWhileDownloading: "正在下載新楓之谷：經典版…",
            missingExecutableHint: "下載完成，請手動選擇 Maplestory_Classic.exe",
            logLabel: "經典版"
        )
    }

    @objc private func handleDownloadMapleStory() {
        guard selectedGame?.id == GameDefinition.mapleStory.id else { return }
        guard !isDownloadingGameClient else { return }

        let destination: URL
        if !executablePath.isEmpty, FileManager.default.fileExists(atPath: executablePath) {
            destination = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        } else {
            let panel = NSOpenPanel()
            panel.title = "選擇下載資料夾"
            panel.message = "新楓之谷將下載到此資料夾。檔案很大，請預留足夠的磁碟空間。"
            panel.prompt = "下載到此處"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false

            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        beginGameClientDownload(
            targetGame: GameDefinition.mapleStory,
            config: .cmsdlMapleStory,
            destination: destination,
            progressTitle: "下載新楓之谷",
            statusWhileDownloading: "正在下載新楓之谷…",
            missingExecutableHint: "下載完成，請手動選擇 MapleStory.exe",
            logLabel: "新楓之谷"
        )
    }

    private func downloadClassicNewLocation() {
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

        beginGameClientDownload(
            targetGame: GameDefinition.mapleStoryClassic,
            config: .nxdlClassic,
            destination: destination,
            progressTitle: "下載新楓之谷：經典版",
            statusWhileDownloading: "正在下載新楓之谷：經典版…",
            missingExecutableHint: "下載完成，請手動選擇 Maplestory_Classic.exe",
            logLabel: "經典版"
        )
    }

    private func downloadMapleStoryNewLocation() {
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

        beginGameClientDownload(
            targetGame: GameDefinition.mapleStory,
            config: .cmsdlMapleStory,
            destination: destination,
            progressTitle: "下載新楓之谷",
            statusWhileDownloading: "正在下載新楓之谷…",
            missingExecutableHint: "下載完成，請手動選擇 MapleStory.exe",
            logLabel: "新楓之谷"
        )
    }

    private func setupMainMenu() {
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        NSApp.mainMenu = mainMenu

        let exeMenuItem = NSMenuItem(title: "主程式", action: nil, keyEquivalent: "")
        let exeSubMenu = NSMenu(title: "主程式")

        let chooseItem = NSMenuItem(title: "選擇主程式", action: #selector(handleChooseExecutable), keyEquivalent: "")
        chooseItem.target = self
        exeSubMenu.addItem(chooseItem)

        let downloadItem = NSMenuItem(title: "下載主程式", action: #selector(handleDownloadMenuAction), keyEquivalent: "")
        downloadItem.target = self
        exeSubMenu.addItem(downloadItem)

        let updateItem = NSMenuItem(title: "更新主程式", action: #selector(handleUpdateMenuAction), keyEquivalent: "")
        updateItem.target = self
        exeSubMenu.addItem(updateItem)

        exeMenuItem.submenu = exeSubMenu
        mainMenu.addItem(exeMenuItem)
    }

    @objc private func handleDownloadMenuAction() {
        if selectedGame?.id == GameDefinition.mapleStoryClassic.id {
            downloadClassicNewLocation()
        } else {
            downloadMapleStoryNewLocation()
        }
    }

    @objc private func handleUpdateMenuAction() {
        if selectedGame?.id == GameDefinition.mapleStoryClassic.id {
            handleDownloadClassic()
        } else {
            handleDownloadMapleStory()
        }
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

    private func beginGameClientDownload(
        targetGame: GameDefinition,
        config: GameClientToolConfig,
        destination: URL,
        progressTitle: String,
        statusWhileDownloading: String,
        missingExecutableHint: String,
        logLabel: String
    ) {
        isDownloadingGameClient = true
        classicDownloadStatus = "正在檢查下載大小…"
        statusLabel.stringValue = "正在檢查下載大小…"
        updateButtons()

        nxdlDownloader.probeTotalSize(config: config, onUpdate: { [weak self] update in
            DispatchQueue.main.async {
                if case let .message(message) = update {
                    self?.statusLabel.stringValue = message
                    self?.classicDownloadStatus = message
                }
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    if let nxdlError = error as? NxdlDownloaderError, case .cancelled = nxdlError {
                        self.statusLabel.stringValue = "下載已取消"
                    } else {
                        self.showError(error)
                        self.statusLabel.stringValue = "下載失敗"
                    }
                    self.finishGameClientDownload()
                case let .success(total):
                    do {
                        let free = try VolumeFreeSpace.freeBytes(forDirectory: destination)
                        let evaluation = DiskSpaceGate.evaluate(totalBytes: total, freeBytes: free)
                        guard self.presentDiskGate(evaluation: evaluation) else {
                            self.statusLabel.stringValue = "已取消下載"
                            self.finishGameClientDownload()
                            return
                        }
                        self.startGameClientDownload(
                            targetGame: targetGame,
                            config: config,
                            to: destination,
                            progressTitle: progressTitle,
                            statusWhileDownloading: statusWhileDownloading,
                            missingExecutableHint: missingExecutableHint,
                            logLabel: logLabel
                        )
                    } catch {
                        self.showError(error)
                        self.statusLabel.stringValue = "下載失敗"
                        self.finishGameClientDownload()
                    }
                }
            }
        })
    }

    private func startGameClientDownload(
        targetGame: GameDefinition,
        config: GameClientToolConfig,
        to destination: URL,
        progressTitle: String,
        statusWhileDownloading: String,
        missingExecutableHint: String,
        logLabel: String
    ) {
        classicDownloadStatus = "準備下載…"
        statusLabel.stringValue = statusWhileDownloading

        let progressWindow = ClassicDownloadProgressWindowController(title: progressTitle) { [weak self] in
            self?.handleCancelGameClientDownload()
        }
        classicDownloadProgressWindow = progressWindow
        progressWindow.apply(update: .message("準備下載…"))
        progressWindow.show(relativeTo: view.window)

        nxdlDownloader.downloadClient(config: config, to: destination, onUpdate: { [weak self] update in
            DispatchQueue.main.async {
                self?.classicDownloadProgressWindow?.apply(update: update)
                if case let .message(message) = update {
                    self?.classicDownloadStatus = message
                } else if case let .progress(progress) = update, !progress.statusMessage.isEmpty {
                    self?.classicDownloadStatus = progress.statusMessage
                }
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    if let exePath = self.nxdlDownloader.findPrimaryExecutable(config: config, in: destination) {
                        self.saveExecutablePath(exePath, for: targetGame)
                        self.statusLabel.stringValue = "下載完成，已設定主程式路徑"
                        NSLog("%@下載完成：%@，主程式=%@", logLabel, destination.path, exePath)
                    } else {
                        self.statusLabel.stringValue = missingExecutableHint
                        NSLog("%@下載完成：%@（未自動找到主程式）", logLabel, destination.path)
                    }
                case let .failure(error as NxdlDownloaderError):
                    if case .cancelled = error {
                        self.statusLabel.stringValue = "下載已取消"
                    } else {
                        self.showError(error)
                        self.statusLabel.stringValue = "下載失敗"
                    }
                case let .failure(error):
                    self.showError(error)
                    self.statusLabel.stringValue = "下載失敗"
                }
                self.finishGameClientDownload()
            }
        })
    }

    @objc private func handleCancelGameClientDownload() {
        nxdlDownloader.cancel()
    }

    private func finishGameClientDownload() {
        isDownloadingGameClient = false
        classicDownloadStatus = ""
        classicDownloadProgressWindow?.closeProgressWindow()
        classicDownloadProgressWindow = nil
        updateGameClientDownloadUI()
        updateButtons()
    }

    @objc private func handleClaimNexonPlug() {
        let status = LSSetDefaultHandlerForURLScheme(
            Self.nexonPlugScheme as NSString,
            Self.beanfunOTPBundleID as NSString
        )
        if status == noErr {
            statusLabel.stringValue = "已將 NexonPlug 設為由 Beanfun OTP 處理"
        } else {
            showError(BeanfunError.rejected("設定 NexonPlug 處理程式失敗（代碼 \(status)）"))
        }
    }

    @objc private func handlePrimary() {
        switch screen {
        case .games:
            selectGame(at: tableView.selectedRow)
        case .qr:
            stopTimers()
            startLogin()
        case .accounts:
            guard accounts.indices.contains(selectedAccountIndex) else { return }
            fetchOTP(for: accounts[selectedAccountIndex])
        case .otp:
            if isValidExecutablePath(executablePath) {
                launchViaOpen()
            } else {
                guard let otp = otpResult else { return }
                copyToPasteboard(otp.value)
                statusLabel.stringValue = "OTP 已複製"
            }
        case .classic:
            chooseExecutable()
        }
    }

    @objc private func handleSecondary() {
        guard screen == .otp else { return }
        if isValidExecutablePath(executablePath), let game = selectedGame {
            launchViaOpen(launcher: .cyder(for: game))
        } else if let otp = otpResult {
            copyToPasteboard(otp.value)
            statusLabel.stringValue = "OTP 已複製"
        } else if let account = selectedAccount {
            copyToPasteboard(account.id)
            statusLabel.stringValue = "帳號已複製"
        }
    }

    @objc private func handleWineLaunch() {
        guard screen == .otp else { return }
        launchViaMapleStoryLauncherWine()
    }

    @objc private func handleCopyCmd() {
        guard screen == .otp, let game = selectedGame, let account = selectedAccount, let otp = otpResult else { return }
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            showError(BeanfunError.rejected("請先指定 \(game.executableName) 主程式位置"))
            return
        }
        let cmd: String
        if game.id == GameDefinition.mapleStory.id {
            cmd = LaunchCommandBuilder.nexonWineCommand(
                executablePath: path,
                accountID: account.id,
                otp: otp.value
            )
        } else {
            cmd = LaunchCommandBuilder.openCommand(
                executablePath: path,
                game: game,
                accountID: account.id,
                otp: otp.value
            )
        }
        copyToPasteboard(cmd)
        statusLabel.stringValue = "啟動指令已複製"
    }

    @objc private func handleBack() {
        client.reset()
        selectedGame = nil
        resetToGames()
    }

    private func selectGame(at row: Int) {
        guard games.indices.contains(row) else { return }
        let game = games[row]
        selectedGame = game
        loadExecutablePath(for: game)
        UserDefaults.standard.set(game.id, forKey: Self.lastGameIDKey)

        if game.authFlow == .webNexonPlug {
            screen = .classic
            statusLabel.stringValue = "已選擇 \(game.name)"
        } else {
            startLogin()
        }
    }

    private func chooseExecutable() {
        guard let game = selectedGame else { return }
        let panel = NSOpenPanel()
        panel.title = "選擇 \(game.executableName)"
        panel.message = "選擇要開啟的 \(game.name) 主程式 (.exe)"
        panel.prompt = "選擇"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        } else {
            panel.allowedFileTypes = ["exe"]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveExecutablePath(url.path, for: game)
        statusLabel.stringValue = "已設定 \(game.name) 主程式位置"

        if let tokens = pendingClassicPassargTokens {
            pendingClassicPassargTokens = nil
            launchClassic(passargTokens: tokens)
        }
    }

    // MARK: - Login Flow

    private func startLogin() {
        guard let game = selectedGame else { return }
        stopTimers()
        loginCompletionInFlight = false
        imageView.image = nil
        qrStatusLabel.stringValue = ""
        statusLabel.stringValue = "正在建立 \(game.name) 的 QR 登入…"
        screen = .qr
        primaryButton.isEnabled = false
        client.createQRSession { [weak self] result in
            guard let self = self else { return }
            self.primaryButton.isEnabled = true
            switch result {
            case let .success(session):
                self.imageView.image = session.image
                self.qrSecondsRemaining = 60
                self.qrStatusLabel.stringValue = "請使用 Gama Play 掃描 QR Code（60 秒內）"
                self.statusLabel.stringValue = "掃描 QR Code 登入 \(game.name)"
                self.beginPolling()
            case let .failure(error):
                self.showError(error)
            }
        }
    }

    private func beginPolling() {
        stopTimers()
        pollTimer = Timer.scheduledTimer(
            timeInterval: 2, target: self, selector: #selector(pollTick), userInfo: nil, repeats: true
        )
        countdownTimer = Timer.scheduledTimer(
            timeInterval: 1, target: self, selector: #selector(countdownTick), userInfo: nil, repeats: true
        )
    }

    private func stopTimers() {
        pollTimer?.invalidate()
        pollTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    @objc private func countdownTick() {
        guard screen == .qr else { return }
        qrSecondsRemaining -= 1
        if qrSecondsRemaining <= 0 {
            stopTimers()
            qrStatusLabel.stringValue = "QR Code 已逾時，請按「重新產生」"
            return
        }
        qrStatusLabel.stringValue = "請使用 Gama Play 掃描 QR Code（\(qrSecondsRemaining) 秒內）"
    }

    @objc private func pollTick() {
        client.pollQRLogin { [weak self] result in
            guard let self = self, self.screen == .qr else { return }
            switch result {
            case let .success(status):
                switch status {
                case .confirmed:
                    guard !self.loginCompletionInFlight else { return }
                    self.loginCompletionInFlight = true
                    self.stopTimers()
                    self.completeLogin()
                case .expired:
                    self.stopTimers()
                    self.qrStatusLabel.stringValue = "QR Code 已過期，請按「重新產生」"
                case .waiting:
                    break
                }
            case let .failure(error):
                self.stopTimers()
                self.showError(error)
            }
        }
    }

    private func completeLogin() {
        guard let game = selectedGame else { return }
        statusLabel.stringValue = "登入驗證中…"
        client.completeQRLogin { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.fetchAccounts(for: game)
            case let .failure(error):
                self.showError(error)
                self.resetToGames()
                self.selectedGame = game
            }
        }
    }

    private func fetchAccounts(for game: GameDefinition) {
        statusLabel.stringValue = "取得\(game.name)帳號清單…"
        client.fetchAccounts(for: game) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(accounts):
                self.accounts = accounts
                if accounts.count == 1 {
                    self.selectedAccountIndex = 0
                    self.fetchOTP(for: accounts[0], autoLaunch: true)
                } else {
                    self.clearTableSelection()
                    self.statusLabel.stringValue = "選擇\(game.name)帳號"
                    self.screen = .accounts
                }
            case let .failure(error):
                self.showError(error)
                self.resetToGames()
                self.selectedGame = game
            }
        }
    }

    private func fetchOTP(for account: GameAccount, autoLaunch: Bool = false) {
        guard let game = selectedGame else { return }
        statusLabel.stringValue = "取得\(account.displayName)的 OTP…"
        primaryButton.isEnabled = false
        client.fetchOTP(for: account, game: game) { [weak self] result in
            guard let self = self else { return }
            self.primaryButton.isEnabled = true
            switch result {
            case let .success(otp):
                self.selectedAccount = account
                self.otpResult = otp
                self.accountField.stringValue = "\(account.displayName)（\(account.id)）"
                self.otpField.stringValue = otp.value
                self.statusLabel.stringValue = "\(account.displayName) 登入資訊"
                self.screen = .otp

                if autoLaunch, self.isValidExecutablePath(self.executablePath) {
                    self.launchViaOpen()
                }
            case let .failure(error):
                self.showError(error)
            }
        }
    }

    // MARK: - Game Launching Logic

    private func runProcess(
        launchPath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        standardError: Pipe? = nil,
        terminationHandler: ((Process) -> Void)? = nil
    ) throws {
        let process = Process()
        if let environment = environment {
            process.environment = environment
        }
        if let standardError = standardError {
            process.standardError = standardError
        }
        process.terminationHandler = terminationHandler
        if #available(macOS 10.13, *) {
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            try process.run()
        } else {
            process.launchPath = launchPath
            process.arguments = arguments
            process.launch()
        }
    }

    private func launchViaOpen(launcher: OpenLauncher = .defaultApplication) {
        guard let game = selectedGame, let account = selectedAccount, let otp = otpResult else { return }
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidExecutablePath(path) else {
            chooseExecutable()
            return
        }

        let standardError = Pipe()
        let args = game.openArguments(
            executablePath: path,
            accountID: account.id,
            otp: otp.value,
            launcher: launcher
        )

        do {
            try clearQuarantineIfNeeded(at: path)
        } catch {
            showError(error)
            return
        }

        switch launcher {
        case .defaultApplication:
            statusLabel.stringValue = "正在開啟\(game.name)…"
        case .cyder, .cyderMapleStoryOEM:
            statusLabel.stringValue = "正在以 Cyder 開啟\(game.name)…"
        }
        do {
            try runProcess(
                launchPath: "/usr/bin/open",
                arguments: args,
                standardError: standardError,
                terminationHandler: { [weak self] process in
                    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if process.terminationStatus == 0 {
                            let launchVerb = launcher == .defaultApplication ? "開啟" : "透過 Cyder 開啟"
                            self.statusLabel.stringValue = "已\(launchVerb)\(game.name)"
                        } else {
                            let msg = errorText.flatMap { $0.isEmpty ? nil : $0 } ?? "open 結束代碼 \(process.terminationStatus)"
                            self.showError(BeanfunError.rejected(msg))
                        }
                    }
                }
            )
        } catch {
            showError(error)
        }
    }

    private func launchViaCyder() {
        guard let game = selectedGame else { return }
        launchViaOpen(launcher: .cyder(for: game))
    }

    private func launchViaMapleStoryLauncherWine() {
        guard let game = selectedGame, game.id == GameDefinition.mapleStory.id,
              let account = selectedAccount, let otp = otpResult else { return }
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidExecutablePath(path) else {
            chooseExecutable()
            return
        }

        let wineURL = MapleStoryWineLauncher.wineExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: wineURL.path) else {
            showError(BeanfunError.rejected("找不到 MapleStory Launcher 的 Wine。請先安裝並開啟過 MapleStory Launcher。"))
            return
        }

        let args = MapleStoryWineLauncher.arguments(executablePath: path, accountID: account.id, otp: otp.value)
        let env = MapleStoryWineLauncher.processEnvironment()

        statusLabel.stringValue = "正在以 MapleStory Launcher 啟動新楓之谷…"
        do {
            try clearQuarantineIfNeeded(at: path)
            try runProcess(
                launchPath: wineURL.path,
                arguments: args,
                environment: env
            )
            statusLabel.stringValue = "已透過 MapleStory Launcher 啟動新楓之谷"
        } catch {
            showError(error)
        }
    }

    // MARK: - NexonPlug Scheme Handling

    func handleOpenedURL(_ url: URL, fromColdStart: Bool = false) {
        if fromColdStart {
            quitAfterSuccessfulClassicLaunch = true
        }
        guard let parsed = NexonPlugURLParser.parse(url) else { return }

        if NexonPlugURLParser.isMapleStoryClassic(gameCode: parsed.gameCode) {
            handleClassicNexonPlug(parsed)
        } else {
            forwardNexonPlug(url)
        }
    }

    private func handleClassicNexonPlug(_ parsed: NexonPlugURLParser.Parsed) {
        guard !parsed.passargTokens.isEmpty else {
            showError(BeanfunError.parse("NexonPlug 連結缺少 passarg，無法啟動經典版"))
            return
        }
        let classic = GameDefinition.mapleStoryClassic
        selectedGame = classic
        loadExecutablePath(for: classic)
        screen = .classic
        pendingClassicPassargTokens = parsed.passargTokens

        if !isValidExecutablePath(executablePath) {
            chooseExecutable()
        } else {
            pendingClassicPassargTokens = nil
            launchClassic(passargTokens: parsed.passargTokens)
        }
    }

    private func launchClassic(passargTokens: [String]) {
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidExecutablePath(path) else {
            showError(BeanfunError.rejected("請先選擇 Maplestory_Classic.exe"))
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
                statusLabel.stringValue = "已取消"
                return
            }
            launcher = .defaultApplication
        }

        let standardError = Pipe()
        let args = NexonPlugURLParser.classicOpenArguments(
            executablePath: path,
            passargTokens: passargTokens,
            launcher: launcher
        )

        statusLabel.stringValue = "正在開啟新楓之谷：經典版…"
        do {
            try clearQuarantineIfNeeded(at: path)
            try runProcess(
                launchPath: "/usr/bin/open",
                arguments: args,
                standardError: standardError,
                terminationHandler: { [weak self] process in
                    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if process.terminationStatus == 0 {
                            self.statusLabel.stringValue = "已開啟新楓之谷：經典版"
                            if self.quitAfterSuccessfulClassicLaunch {
                                NSApp.terminate(nil)
                            }
                        } else {
                            let msg = errorText.flatMap { $0.isEmpty ? nil : $0 } ?? "open 結束代碼 \(process.terminationStatus)"
                            self.showError(BeanfunError.rejected(msg))
                        }
                    }
                }
            )
        } catch {
            showError(error)
        }
    }

    private func forwardNexonPlug(_ url: URL) {
        let plugPath = Self.officialNexonPlugAppPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: plugPath, isDirectory: &isDir) else {
            showError(BeanfunError.rejected("找不到 NexonPlug.app，無法轉發其他遊戲的 NexonPlug 連結"))
            return
        }
        do {
            try runProcess(
                launchPath: "/usr/bin/open",
                arguments: ["-a", plugPath, url.absoluteString]
            )
            statusLabel.stringValue = "已將 NexonPlug 連結轉發給官方 NexonPlug"
        } catch {
            showError(error)
        }
    }

    // MARK: - Helpers

    private func clearQuarantineIfNeeded(at path: String) throws {
        let names = try extendedAttributeNames(at: path)
        guard names.contains("com.apple.quarantine") else { return }

        do {
            try removeExtendedAttribute("com.apple.quarantine", at: path)
        } catch {
            let detail = (error as NSError).localizedDescription
            throw BeanfunError.rejected(
                "無法解除檔案的 macOS quarantine，請檢查檔案權限後再試一次：\(path)\n\(detail)"
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

    // MARK: - Helpers

    private func isValidExecutablePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && FileManager.default.fileExists(atPath: trimmed)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func setSubtleButtonTitle(_ button: NSButton, title: String) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12)
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    private func showError(_ error: Error) {
        if let beanfunError = error as? BeanfunError, beanfunError.isSessionExpired {
            handleSessionExpired(message: beanfunError.localizedDescription)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Beanfun OTP Legacy"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func handleSessionExpired(message: String = BeanfunError.defaultExpiredMessage) {
        client.reset()
        stopTimers()
        loginCompletionInFlight = false
        accounts = []
        selectedAccount = nil
        clearTableSelection()
        otpResult = nil
        accountField.stringValue = ""
        otpField.stringValue = ""
        imageView.image = nil
        qrStatusLabel.stringValue = ""

        let msg = message.isEmpty ? BeanfunError.defaultExpiredMessage : message
        statusLabel.stringValue = "登入階段已過期"

        let alert = NSAlert()
        alert.messageText = "登入階段已過期"
        alert.informativeText = msg
        alert.alertStyle = .warning
        if selectedGame != nil && selectedGame?.usesBeanfunQR == true {
            alert.addButton(withTitle: "重新產生 QR Code 並登入")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                startLogin()
            } else {
                resetToGames()
            }
        } else {
            alert.addButton(withTitle: "確定")
            alert.runModal()
            resetToGames()
        }
    }


    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch screen {
        case .games: return games.count
        case .accounts: return accounts.count
        default: return 0
        }
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        switch screen {
        case .games:
            guard games.indices.contains(row) else { return nil }
            return games[row].name
        case .accounts:
            guard accounts.indices.contains(row) else { return nil }
            let account = accounts[row]
            return "\(account.displayName)（\(account.sn)）"
        default:
            return nil
        }
    }
}
