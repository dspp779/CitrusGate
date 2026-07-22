import AppKit

final class AppController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Screen {
        case games, qr, accounts, otp
    }

    private static let lastGameIDKey = "LegacyLastGameID"

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
    private var otpValue: String = ""

    private var pollTimer: Timer?
    private var countdownTimer: Timer?
    private var qrSecondsRemaining: Int = 60
    private var loginCompletionInFlight = false

    // Outlets created in code.
    private let statusLabel = NSTextField(wrappingLabelWithString: "選擇遊戲")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let imageView = NSImageView()
    private let qrStatusLabel = NSTextField(labelWithString: "")
    private let accountCaptionLabel = NSTextField(labelWithString: "帳號")
    private let accountField = NSTextField(labelWithString: "")
    private let otpCaptionLabel = NSTextField(labelWithString: "OTP")
    private let otpField = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "下一步", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "複製帳號", target: nil, action: nil)
    private let backButton = NSButton(title: "選擇其他遊戲", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
        restoreLastGame()
        updateVisibility()
    }

    deinit {
        stopTimers()
    }

    // MARK: - UI construction

    private func buildUI() {
        statusLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 13)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 360
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
        scrollView.heightAnchor.constraint(equalToConstant: 260).isActive = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 220).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        qrStatusLabel.alignment = .center
        qrStatusLabel.font = NSFont.systemFont(ofSize: 12)
        qrStatusLabel.textColor = NSColor.disabledControlTextColor

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
        if let base = NSFont.userFixedPitchFont(ofSize: 36) {
            otpField.font = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        otpField.isEditable = false
        otpField.isSelectable = true
        otpField.isBezeled = false
        otpField.drawsBackground = false

        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondary)

        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(handleBack)

        let buttonRow = NSStackView(views: [primaryButton, secondaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let otpBlock = NSStackView(views: [
            accountCaptionLabel, accountField, otpCaptionLabel, otpField,
        ])
        otpBlock.orientation = .vertical
        otpBlock.alignment = .leading
        otpBlock.spacing = 4
        otpBlock.setCustomSpacing(12, after: accountField)

        let root = NSStackView(views: [
            statusLabel, scrollView, imageView, qrStatusLabel, otpBlock, buttonRow, backButton,
        ])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            otpBlock.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            otpBlock.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
    }

    // MARK: - Visibility / state

    private func updateVisibility() {
        scrollView.isHidden = !(screen == .games || screen == .accounts)
        imageView.isHidden = screen != .qr
        qrStatusLabel.isHidden = screen != .qr
        otpBlockVisibility(screen == .otp)
        if screen == .games || screen == .accounts {
            tableView.reloadData()
        }
        updateButtons()
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
            primaryButton.title = "下一步"
            primaryButton.isEnabled = tableView.selectedRow >= 0
            secondaryButton.isHidden = true
            backButton.isHidden = true
        case .qr:
            primaryButton.title = "重新產生"
            primaryButton.isEnabled = true
            secondaryButton.isHidden = true
            backButton.isHidden = false
        case .accounts:
            primaryButton.title = "取得 OTP"
            primaryButton.isEnabled = selectedAccountIndex >= 0
            secondaryButton.isHidden = true
            backButton.isHidden = false
        case .otp:
            primaryButton.title = "複製 OTP"
            primaryButton.isEnabled = true
            secondaryButton.title = "複製帳號"
            secondaryButton.isHidden = false
            backButton.isHidden = false
        }
    }

    private func restoreLastGame() {
        guard let lastID = UserDefaults.standard.string(forKey: Self.lastGameIDKey),
              let index = games.firstIndex(where: { $0.id == lastID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
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
        otpValue = ""
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
            updateButtons()
        case .accounts:
            selectedAccountIndex = tableView.selectedRow
            updateButtons()
        default:
            break
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
            copyToPasteboard(otpValue)
        }
    }

    @objc private func handleSecondary() {
        guard screen == .otp, let account = selectedAccount else { return }
        copyToPasteboard(account.id)
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
        UserDefaults.standard.set(game.id, forKey: Self.lastGameIDKey)
        startLogin()
    }

    // MARK: - Login flow

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
                self.qrStatusLabel.stringValue = "請使用 Beanfun App 掃描 QR Code（60 秒內）"
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
        qrStatusLabel.stringValue = "請使用 Beanfun App 掃描 QR Code（\(qrSecondsRemaining) 秒內）"
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
                    self.fetchOTP(for: accounts[0])
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

    private func fetchOTP(for account: GameAccount) {
        guard let game = selectedGame else { return }
        statusLabel.stringValue = "取得\(account.displayName)的 OTP…"
        primaryButton.isEnabled = false
        client.fetchOTP(for: account, game: game) { [weak self] result in
            guard let self = self else { return }
            self.primaryButton.isEnabled = true
            switch result {
            case let .success(otp):
                self.selectedAccount = account
                self.otpValue = otp.value
                self.accountField.stringValue = "\(account.displayName)（\(account.id)）"
                self.otpField.stringValue = otp.value
                self.statusLabel.stringValue = "\(account.displayName) 登入資訊"
                self.screen = .otp
            case let .failure(error):
                self.showError(error)
            }
        }
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Beanfun OTP Legacy"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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
