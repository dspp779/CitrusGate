import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showDebug = false
    @State private var hoveredGameID: String?

    var body: some View {
        Group {
            if model.mode == .standard {
                if model.screen == .qr {
                    standardContent
                } else {
                    standardContent
                        .padding(20)
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(spacing: 14) {
                            advancedContent
                            statusBar
                            debugSection
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(width: model.mode == .standard ? 400 : 720)
        .background(
            FixedWindowConfigurator(
                mode: model.mode,
                screen: model.screen,
                extendContentUnderTitlebar: model.mode == .standard
            )
        )
        .onAppear { model.handleInitialAppearance() }
        .alert(
            "Beanfun OTP",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("關閉", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { model.showClassicDownloadProgress },
            set: { _ in }
        )) {
            ClassicDownloadProgressView(model: model)
                .interactiveDismissDisabled(model.isDownloadingGameClient)
        }
    }

    private var windowSize: CGSize {
        model.mode == .standard
            ? CGSize(width: 400, height: 440)
            : CGSize(width: 720, height: 640)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Beanfun OTP")
                    .font(.title2.bold())
                Text("\(model.selectedGame?.name ?? "選擇遊戲") · \(model.mode.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.screen != .welcome, model.screen != .games, model.screen != .classic {
                Button("重新登入") { model.startLogin() }
                    .disabled(model.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var standardContent: some View {
        switch model.screen {
        case .games:
            gamePickerView
        case .welcome:
            standardWelcomeView
        case .qr:
            standardQRView
        case .accounts, .otp:
            standardAccountView
        case .classic:
            classicView
        }
    }

    private var gamePickerView: some View {
        VStack(spacing: 12) {
            Text("選擇遊戲")
                .font(.title2.bold())
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: 3
                    ),
                    spacing: 10
                ) {
                    ForEach(model.games) { game in
                        Button {
                            model.selectGame(game)
                        } label: {
                            VStack(spacing: 6) {
                                GameArtwork(game: game)
                                    .frame(height: 60)
                                Text(game.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
                            .background(
                                hoveredGameID == game.id
                                    ? Color.secondary.opacity(0.10)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            hoveredGameID = isHovered ? game.id : nil
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 440, minHeight: 320)
    }

    private var standardWelcomeView: some View {
        VStack(spacing: 14) {
            if let game = model.selectedGame {
                GameArtwork(game: game)
                    .frame(width: 132, height: 88)
                Text(game.name)
                    .font(.title2.bold())
            }
            if model.isDownloadingGameClient {
                ProgressView(model.classicDownloadStatus.isEmpty
                             ? "正在準備下載…"
                             : model.classicDownloadStatus)
            } else if model.isBusy {
                ProgressView("正在產生登入 QR Code…")
            } else {
                Button {
                    model.startLogin()
                } label: {
                    Label("取得 QR Code", systemImage: "qrcode")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            ClientUpdateActionsSection(model: model)
            ExecutablePickerSection(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var standardQRView: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.white
                if let image = model.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 8) {
                Text("請使用 Gama Play App 掃描並確認登入")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text("剩餘約 \(model.qrSecondsRemaining) 秒")
                        .monospacedDigit()
                }
                .foregroundStyle(model.qrSecondsRemaining <= 10 ? .red : .secondary)
                Button("重新產生 QR Code") { model.startLogin() }
                    .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var advancedContent: some View {
        switch model.screen {
        case .games:
            gamePickerView
        case .welcome:
            welcomeView
        case .qr:
            qrView
        case .accounts:
            advancedAccountView
        case .otp:
            otpView
        case .classic:
            classicView
        }
    }

    private var classicView: some View {
        VStack(spacing: 14) {
            if let game = model.selectedGame {
                GameArtwork(game: game)
                    .frame(width: 132, height: 88)
                Text(game.name)
                    .font(.title2.bold())
            }
            Text("此遊戲使用網頁登入。登入後網站會開啟 NexonPlug://，由 Beanfun OTP 啟動遊戲。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("將 NexonPlug 設為由 Beanfun OTP 處理") {
                model.claimNexonPlugHandler()
            }
            .buttonStyle(.link)
            ClientUpdateActionsSection(model: model)
            Button {
                model.openClassicLoginPage()
            } label: {
                Label("開啟登入網頁", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy)
            if model.mode == .standard {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ExecutablePickerSection(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeView: some View {
        GroupBox {
            VStack(spacing: 16) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.orange)
                VStack(spacing: 6) {
                    Text("使用 Gama Play 掃碼登入")
                        .font(.title3.bold())
                    Text("登入成功後會自動列出\(model.selectedGame?.name ?? "遊戲")帳號，不需要事先知道 SN。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if model.isDownloadingGameClient {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.classicDownloadStatus.isEmpty
                             ? "正在準備下載…"
                             : model.classicDownloadStatus)
                    }
                    .foregroundStyle(.secondary)
                } else if model.mode == .standard, model.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在產生登入 QR Code…")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.startLogin()
                    } label: {
                        Label("產生登入 QR Code", systemImage: "qrcode")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }
                ClientUpdateActionsSection(model: model)
                ExecutablePickerSection(model: model)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .padding()
        }
    }

    private var qrView: some View {
        GroupBox("掃描登入 QR Code") {
            VStack(spacing: 12) {
                if let image = model.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(8)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                Text("請使用 Gama Play App 掃描並確認登入")
                    .font(.headline)
                HStack {
                    Image(systemName: "timer")
                    Text("QR 剩餘時間：約 \(model.qrSecondsRemaining) 秒")
                        .monospacedDigit()
                }
                .foregroundStyle(model.qrSecondsRemaining <= 10 ? .red : .secondary)
                Button("重新產生 QR Code") { model.startLogin() }
                    .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private var standardAccountView: some View {
        GroupBox(model.accounts.count == 1
                 ? "開啟\(model.selectedGame?.name ?? "遊戲")"
                 : "選擇\(model.selectedGame?.name ?? "遊戲")帳號") {
            VStack(spacing: 12) {
                if model.accounts.count > 1 {
                    Text("請選擇要使用的帳號")
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.accounts) { account in
                                Button {
                                    model.selectAccount(account)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: model.selectedAccountID == account.id
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.selectedAccountID == account.id
                                                             ? .orange : .secondary)
                                        Text(account.displayName)
                                            .font(.headline)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(10)
                                    .background(
                                        model.selectedAccountID == account.id
                                            ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.05)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                } else if let account = model.selectedAccount {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(account.displayName)
                        .font(.title2.bold())
                }

                if model.isBusy && model.launchUIPhase == .idle {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.statusMessage)
                    }
                    .foregroundStyle(.secondary)
                } else if let account = model.selectedAccount {
                    VStack(spacing: 10) {
                        if model.selectedGame?.id == GameDefinition.mapleStory.id {
                            VStack(spacing: 10) {
                                HStack(spacing: 10) {
                                    Button {
                                        model.launchSelectedAccountViaOpen()
                                    } label: {
                                        Label("開啟", systemImage: "play.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.areLaunchButtonsDisabled)

                                    Button {
                                        model.launchSelectedAccountViaCyder()
                                    } label: {
                                        Label("以 Cyder 開啟", systemImage: "shippingbox")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.areLaunchButtonsDisabled)
                                }

                                Button {
                                    model.launchSelectedAccountViaWine()
                                } label: {
                                    Label("以 MapleStory Launcher 開啟", systemImage: "wineglass")
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.areLaunchButtonsDisabled)
                            }
                        } else {
                            HStack(spacing: 10) {
                                Button {
                                    model.launchSelectedAccountViaOpen()
                                } label: {
                                    Label("開啟", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.areLaunchButtonsDisabled)

                                Button {
                                    model.launchSelectedAccountViaCyder()
                                } label: {
                                    Label("以 Cyder 開啟", systemImage: "shippingbox")
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.areLaunchButtonsDisabled)
                            }
                        }

                        if !model.launchStatusText.isEmpty {
                            HStack(spacing: 8) {
                                if model.launchUIPhase == .launching {
                                    ProgressView().controlSize(.small)
                                }
                                Text(model.launchStatusText)
                                    .foregroundStyle(model.launchUIPhase == .launched ? .green : .secondary)
                            }
                            .font(.headline)
                        }
                        if model.selectedGame?.supportsAutomaticLogin == false,
                           model.launchedAccountID == account.id {
                            HStack {
                                Button("複製帳號") { model.copyAccountID() }
                                Button("複製 OTP") { model.copyOTP() }
                            }
                        }
                    }
                }

                ExecutablePickerSection(model: model)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding()
        }
    }

    private var advancedAccountView: some View {
        GroupBox("選擇\(model.selectedGame?.name ?? "遊戲")帳號") {
            VStack(alignment: .leading, spacing: 12) {
                Text("已從 Beanfun 帳號清單取得 \(model.accounts.count) 個帳號")
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(model.accounts) { account in
                        Button {
                            model.selectAccount(account)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.selectedAccountID == account.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedAccountID == account.id
                                                     ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.displayName)
                                        .font(.headline)
                                    Text("SN \(account.sn)  ·  \(account.id)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(12)
                            .background(
                                model.selectedAccountID == account.id
                                    ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.05)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    ExecutablePickerSection(model: model)
                    Spacer()
                    Button {
                        model.retrieveOTP()
                    } label: {
                        Label("取得 OTP", systemImage: "key.fill")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.selectedAccount == nil || model.isBusy)
                }
            }
            .padding()
        }
    }

    private var otpView: some View {
        VStack(spacing: 12) {
            GroupBox {
                VStack(spacing: 12) {
                    if let account = model.selectedAccount {
                        Text(account.displayName)
                            .font(.title3.bold())
                        Text("SN \(account.sn)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(model.otp?.value ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let retrievedAt = model.otp?.retrievedAt {
                        Text("更新時間：\(retrievedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button { model.copyAccountID() } label: {
                            Label("複製帳號", systemImage: "person.text.rectangle")
                        }
                        Button { model.copyOTP() } label: {
                            Label("複製 OTP", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { model.retrieveOTP() } label: {
                            Label("立即更新", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            GroupBox("自動更新") {
                HStack(spacing: 16) {
                    Toggle(
                        "定期重新取得 OTP",
                        isOn: Binding(
                            get: { model.autoRefresh },
                            set: { model.setAutoRefresh($0) }
                        )
                    )
                    Spacer()
                    Picker(
                        "間隔",
                        selection: Binding(
                            get: { model.autoRefreshInterval },
                            set: { model.updateRefreshInterval($0) }
                        )
                    ) {
                        Text("30 秒").tag(30)
                        Text("60 秒").tag(60)
                        Text("90 秒").tag(90)
                    }
                    .frame(width: 150)
                    .disabled(!model.autoRefresh)
                    if model.autoRefresh {
                        Text("\(model.otpSecondsRemaining) 秒")
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                .padding(10)
            }

            GroupBox("遊戲啟動指令") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.selectedGame?.id == GameDefinition.mapleStory.id {
                        Picker("指令形式", selection: $model.advancedLaunchCommandStyle) {
                            ForEach(AdvancedLaunchCommandStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if let command = model.fullLaunchCommand {
                        Text(command)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("請先選擇主程式並取得 OTP，以產生完整啟動指令。")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button { model.copyLaunchCommand() } label: {
                            Label("複製啟動指令", systemImage: "terminal")
                        }
                        .disabled(!model.canCopyLaunchCommand)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            if let game = model.selectedGame {
                                Button("選擇「\(game.name)」主程式…") { model.chooseExecutable() }
                                    .buttonStyle(.link)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Button("選擇其他帳號") { model.chooseAnotherAccount() }
                                    .buttonStyle(.link)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Button("選擇其他遊戲") { model.showGamePicker() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
            }

            GroupBox("開啟遊戲") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用 macOS 的 open -n 依預設 App 或指定 Cyder 開啟 .exe。檔案位置會自動記住。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(
                            "\(model.selectedGame?.executableName ?? ".exe") 位置",
                            text: $model.executablePath
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("選擇…") { model.chooseExecutable() }
                    }
                    HStack {
                        Text(model.selectedGame?.supportsAutomaticLogin == true
                             ? "「開啟」使用預設 App；「以 Cyder 開啟」指定 Cyder.app（新楓之谷為 Cyder MapleStory OEM）。"
                             : "使用 open -n 啟動；OTP 會放入剪貼簿供登入使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { model.launchGame() } label: {
                            Label("啟動\(model.selectedGame?.name ?? "遊戲")", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.executablePath.isEmpty || model.isBusy)
                    }
                }
                .padding(10)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.errorMessage == nil ? "info.circle" : "exclamationmark.triangle")
            }
            Text(model.statusMessage)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var debugSection: some View {
        DisclosureGroup("Debug Log", isExpanded: $showDebug) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "顯示 Cookie、Token、SecretCode 與 OTP 完整內容",
                    isOn: $model.includeSecrets
                )
                .foregroundStyle(.red)
                Text("這些內容等同登入憑證，請勿貼到公開網站。設定會套用到下一個請求。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(model.logText.isEmpty ? "尚無紀錄" : model.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(Color.black.opacity(0.88))
                .foregroundStyle(.green.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("複製 Debug Log") { model.copyDebugLog() }
                }
            }
            .padding(.top, 8)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ClientUpdateActionsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let game = model.selectedGame,
           game.id == GameDefinition.mapleStory.id || game.id == GameDefinition.mapleStoryClassic.id {
            if !model.hasValidExecutable {
                downloadButton(for: game)
            } else {
                updateStatusControls(for: game)
            }
        }
    }

    @ViewBuilder
    private func downloadButton(for game: GameDefinition) -> some View {
        if game.id == GameDefinition.mapleStoryClassic.id {
            Button {
                model.downloadClassicClient()
            } label: {
                Label("下載經典版", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.isDownloadingGameClient || model.isBusy)
        } else if game.id == GameDefinition.mapleStory.id {
            Button {
                model.downloadMapleStoryClient()
            } label: {
                Label("下載新楓之谷", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.isDownloadingGameClient || model.isBusy)
        }
    }

    @ViewBuilder
    private func updateStatusControls(for game: GameDefinition) -> some View {
        let status = model.classicUpdateStatus
        VStack(spacing: 8) {
            if status == .checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在檢查更新…")
                }
                .foregroundStyle(.secondary)
            }

            if let caption = ClientUpdateUI.statusCaption(status) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if ClientUpdateUI.showsCheckButton(status) {
                Button {
                    model.checkClientUpdate()
                } label: {
                    Label("檢查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }

            if ClientUpdateUI.showsPrimaryUpdateButton(status) {
                Button {
                    if game.id == GameDefinition.mapleStoryClassic.id {
                        model.updateClassicClient()
                    } else {
                        model.updateMapleStoryClient()
                    }
                } label: {
                    Label("更新", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }

            if case .maintenanceOrError = status {
                Button("再試一次") {
                    model.checkClientUpdate()
                }
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }

            if ClientUpdateUI.showsForceUpdateButton(status) {
                Button {
                    model.forceUpdateClient()
                } label: {
                    Text(ClientUpdateUI.forceUpdateButtonTitle(gameID: game.id))
                }
                .buttonStyle(.bordered)
                .disabled(model.isDownloadingGameClient || model.isBusy)
            }
        }
    }
}

private struct ExecutablePickerSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            if let game = model.selectedGame {
                if model.hasValidExecutable {
                    Text("主程式：\(model.executablePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                } else if !model.executablePath.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("找不到主程式：\(model.executablePath)")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                    Button("重新選擇「\(game.name)」主程式…") {
                        model.chooseExecutable()
                    }
                    .buttonStyle(.link)
                } else {
                    Text("（未選擇「\(game.name)」主程式）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Button("選擇「\(game.name)」主程式…") {
                        model.chooseExecutable()
                    }
                }
            }

            Spacer().frame(height: 4)

            Button("‹ 選擇其他遊戲") {
                model.showGamePicker()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private struct GameArtwork: View {
    let game: GameDefinition

    var body: some View {
        Group {
            if let url = Bundle.main.url(
                forResource: game.imageName,
                withExtension: nil,
                subdirectory: "GameImages"
            ), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.cyan.opacity(0.9), .purple.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .clipped()
        .accessibilityLabel(game.name)
    }
}

private struct FixedWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        var hasAdjustedInitialFrame = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    let mode: AppMode
    let screen: AppScreen
    var extendContentUnderTitlebar: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView, coordinator: context.coordinator)
    }

    private func configure(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if extendContentUnderTitlebar {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            } else {
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
            }
            window.backgroundColor = NSColor.windowBackgroundColor

            let targetWidth: CGFloat = mode == .standard ? 400 : 720
            let targetHeight: CGFloat
            if mode == .standard {
                if let contentView = window.contentView {
                    contentView.layoutSubtreeIfNeeded()
                    let fitH = contentView.fittingSize.height
                    let minH: CGFloat
                    switch screen {
                    case .games, .welcome: minH = 360
                    case .qr: minH = 440
                    case .accounts, .otp: minH = 420
                    case .classic: minH = 380
                    }
                    targetHeight = max(fitH, minH)
                } else {
                    targetHeight = 360
                }
            } else {
                targetHeight = 640
            }

            let currentContentRect = window.contentRect(forFrameRect: window.frame)
            let shouldAnimate = coordinator.hasAdjustedInitialFrame
            if abs(currentContentRect.height - targetHeight) > 1 || abs(currentContentRect.width - targetWidth) > 1 {
                let newFrame = window.frameRect(forContentRect: NSRect(
                    x: window.frame.origin.x,
                    y: window.frame.origin.y + (currentContentRect.height - targetHeight),
                    width: targetWidth,
                    height: targetHeight
                ))
                window.setFrame(newFrame, display: true, animate: shouldAnimate)
                coordinator.hasAdjustedInitialFrame = true
            }
        }
    }
}
