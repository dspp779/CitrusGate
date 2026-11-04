import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showDebug = false
    @State private var hoveredGameID: String?
    @State private var showReadiness = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.mode == .standard {
                VStack(spacing: 0) {
                    compactHeader
                    Divider().opacity(0.55)
                    ScrollView {
                        standardContent
                            .padding(24)
                            .frame(maxWidth: .infinity, minHeight: 520, alignment: .top)
                    }
                    Divider().opacity(0.55)
                    HStack(spacing: 8) {
                        Image(systemName: model.isBusy ? "hourglass" : "lock.shield")
                            .accessibilityHidden(true)
                        Text(model.screen == .games ? "Beanfun OTP · 非官方 macOS 登入工具" : model.statusMessage)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(CitrusTheme.secondary)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                }
                .frame(height: 660)

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
        .frame(width: model.mode == .standard ? 480 : 760)
        .background(
            FixedWindowConfigurator(
                mode: model.mode,
                screen: model.screen,
                extendContentUnderTitlebar: model.mode == .standard
            )
        )
        .tint(CitrusTheme.accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.screen)
        .onAppear { model.handleInitialAppearance() }
        .sheet(isPresented: $showReadiness) {
            VStack(spacing: 0) {
                LaunchReadinessView(model: model)
                Button("完成") { showReadiness = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 20)
            }
        }
        .alert(
            "Beanfun OTP",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            if model.selectedGame != nil {
                Button("檢查設定") {
                    model.clearError()
                    model.refreshLaunchReadiness()
                    DispatchQueue.main.async { showReadiness = true }
                }
            }
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

    private var compactHeader: some View {
        HStack(spacing: 12) {
            if model.screen != .games {
                Button { model.showGamePicker() } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 28)
                }
                .buttonStyle(.borderless)
                .help("選擇其他遊戲")
                .accessibilityLabel("返回遊戲選擇")
                .disabled(model.isBusy)
            } else {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(CitrusTheme.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("CITRUSGATE").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2)
                Text(model.selectedGame?.name ?? "Beanfun OTP")
                    .font(.system(size: 11)).foregroundStyle(CitrusTheme.secondary)
            }
            Spacer()
            Menu {
                Button("進階模式") { model.setMode(.advanced) }
                if model.selectedGame != nil {
                    Button("啟動前檢查…") { model.refreshLaunchReadiness(); showReadiness = true }
                    if model.screen == .accounts || model.screen == .otp {
                        Button("重新登入") { model.startLogin() }
                    }
                    if model.selectedGame?.id == GameDefinition.mapleStory.id || model.selectedGame?.id == GameDefinition.mapleStoryClassic.id {
                        Button("修復舊版下載路徑…") { model.repairLegacyDownloadPaths() }
                            .disabled(!model.hasValidExecutable)
                    }
                }
                Divider()
                Button("匯出診斷紀錄…") { model.exportDiagnostics() }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("更多選項")
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(height: 82)
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
                    .foregroundStyle(CitrusTheme.secondary)
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
        VStack(alignment: .leading, spacing: 24) {
            CitrusSectionHeading(eyebrow: "YOUR NEXT ADVENTURE", title: "準備好，進入遊戲。", subtitle: "選擇遊戲，完成登入，就能出發。")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 16) {
                ForEach(model.games) { game in
                    Button { model.selectGame(game, autoPickExecutable: false) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            GameArtwork(game: game).frame(height: 112).clipped()
                            VStack(alignment: .leading, spacing: 5) {
                                Text(game.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).frame(minHeight: 20, alignment: .top)
                                HStack(spacing: 5) {
                                    Text(game.authFlow == .webNexonPlug ? "網頁登入" : "Gama Play 掃碼")
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                                }
                                .font(.system(size: 11)).foregroundStyle(CitrusTheme.secondary)
                            }
                            .padding(13)
                        }
                        .background(CitrusTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(hoveredGameID == game.id ? CitrusTheme.accent : CitrusTheme.hairline, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredGameID = $0 ? game.id : nil }
                    .accessibilityLabel("\(game.name)，\(game.authFlow == .webNexonPlug ? "網頁登入" : "Gama Play 掃碼登入")")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var hasUpdateFailure: Bool {
        if case .maintenanceOrError = model.classicUpdateStatus { return true }
        return false
    }

    private var standardWelcomeView: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let game = model.selectedGame {
                if !hasUpdateFailure {
                    GameArtwork(game: game).frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                CitrusSectionHeading(eyebrow: "ONE SCAN AWAY", title: "\(game.name)", subtitle: "使用 Gama Play 掃碼，確認後選擇遊戲帳號。")
            }
            if hasUpdateFailure { ClientUpdateActionsSection(model: model) }
            Button { model.startLogin() } label: {
                Label(model.isBusy ? "正在準備登入…" : "產生登入 QR Code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(CitrusPrimaryButton())
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy)
            if !hasUpdateFailure { ClientUpdateActionsSection(model: model) }
            Button("啟動前檢查") { model.refreshLaunchReadiness(); showReadiness = true }
                .buttonStyle(.link)
            Divider()
            ExecutablePickerSection(model: model)
        }
    }

    private var standardQRView: some View {
        VStack(spacing: 18) {
            CitrusSectionHeading(eyebrow: "SCAN & CONFIRM", title: "掃碼，確認登入。", subtitle: "開啟 Gama Play 掃描下方 QR Code，並在手機上確認。")
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.white)
                if let image = model.qrImage {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(18)
                } else { ProgressView("正在產生 QR Code…").foregroundStyle(.black) }
            }
            .frame(width: 264, height: 264)
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(CitrusTheme.hairline))
            .accessibilityLabel("請用手機 Gama Play 掃描登入 QR Code")
            Label(model.qrSecondsRemaining > 0 ? "等待手機確認 · 剩餘 \(model.qrSecondsRemaining) 秒" : "QR Code 已到期，請重新產生", systemImage: model.qrSecondsRemaining > 0 ? "iphone" : "clock.badge.exclamationmark")
                .font(.callout.monospacedDigit())
                .foregroundStyle(model.qrSecondsRemaining <= 10 ? Color.red : CitrusTheme.secondary)
            Button("重新產生 QR Code") { model.startLogin() }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
        }
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
        VStack(alignment: .leading, spacing: 22) {
            if let game = model.selectedGame {
                GameArtwork(game: game).frame(height: 132).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                CitrusSectionHeading(eyebrow: "A CLASSIC RETURNS", title: "\(game.name)", subtitle: "在官網完成登入後，回到這裡啟動遊戲。")
            }
            if !model.isNexonPlugHandler {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "link.badge.plus").foregroundStyle(CitrusTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("先連結網頁登入").font(.headline)
                        Text("讓官網將登入結果交給 Beanfun OTP。").font(.caption).foregroundStyle(CitrusTheme.secondary)
                        Button("設定登入連結") { model.claimNexonPlugHandler() }.buttonStyle(.link)
                    }
                }
            }
            Button { model.openClassicLoginPage() } label: { Label("開啟官網登入", systemImage: "arrow.up.right.square") }
                .buttonStyle(CitrusPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
            ClientUpdateActionsSection(model: model)
            Button("啟動前檢查") { model.refreshLaunchReadiness(); showReadiness = true }.buttonStyle(.link)
            Divider()
            ExecutablePickerSection(model: model)
        }
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
                        .foregroundStyle(CitrusTheme.secondary)
                        .multilineTextAlignment(.center)
                }
                if model.isDownloadingGameClient {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.classicDownloadStatus.isEmpty
                             ? "正在準備下載…"
                             : model.classicDownloadStatus)
                    }
                    .foregroundStyle(CitrusTheme.secondary)
                } else if model.mode == .standard, model.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在產生登入 QR Code…")
                    }
                    .foregroundStyle(CitrusTheme.secondary)
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
        VStack(alignment: .leading, spacing: 22) {
            CitrusSectionHeading(eyebrow: "YOU’RE SIGNED IN", title: model.accounts.count > 1 ? "選擇你的帳號。" : "準備進入遊戲。", subtitle: model.selectedGame?.name ?? "登入已完成")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.accounts) { account in
                        Button { model.selectAccount(account) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 28)).foregroundStyle(CitrusTheme.accent).accessibilityHidden(true)
                                Text(account.displayName).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: model.selectedAccountID == account.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedAccountID == account.id ? CitrusTheme.accent : CitrusTheme.secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(14)
                            .background(model.selectedAccountID == account.id ? CitrusTheme.accent.opacity(0.09) : CitrusTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(model.selectedAccountID == account.id ? CitrusTheme.accent.opacity(0.5) : CitrusTheme.hairline))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(account.displayName)，\(model.selectedAccountID == account.id ? "已選取" : "未選取")")
                        .disabled(model.isBusy)
                    }
                }
            }
            .frame(height: min(CGFloat(model.accounts.count) * 72, 216))
            if model.selectedAccount != nil {
                Button { model.launchSelectedAccountViaOpen() } label: {
                    Label(model.launchUIPhase == .launching ? "正在啟動…" : "啟動遊戲", systemImage: "play.fill")
                }
                .buttonStyle(CitrusPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(model.areLaunchButtonsDisabled)
                HStack {
                    Button("以 Cyder 開啟") { model.launchSelectedAccountViaCyder() }.disabled(model.areLaunchButtonsDisabled)
                    if model.selectedGame?.id == GameDefinition.mapleStory.id {
                        Button("橘子遊戲管理器") { model.launchSelectedAccountViaGGMScheme() }.disabled(model.areLaunchButtonsDisabled)
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            if !model.launchStatusText.isEmpty {
                Label(model.launchStatusText, systemImage: model.launchUIPhase == .launched ? "checkmark.circle.fill" : "hourglass")
                    .font(.callout).foregroundStyle(model.launchUIPhase == .launched ? Color.green : CitrusTheme.secondary)
            }
            if model.selectedGame?.supportsAutomaticLogin == false, model.launchedAccountID != nil {
                HStack {
                    Button("複製帳號") { model.copyAccountID() }
                    Button("複製 OTP") { model.copyOTP() }
                }
            }
            Divider()
            ExecutablePickerSection(model: model)
        }
    }

    private var advancedAccountView: some View {
        GroupBox("選擇\(model.selectedGame?.name ?? "遊戲")帳號") {
            VStack(alignment: .leading, spacing: 12) {
                Text("已從 Beanfun 帳號清單取得 \(model.accounts.count) 個帳號")
                    .foregroundStyle(CitrusTheme.secondary)
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
                                        .foregroundStyle(CitrusTheme.secondary)
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
                GGMLaunchSection(model: model)
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
                            .foregroundStyle(CitrusTheme.secondary)
                    }
                    Text(model.otp?.value ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let retrievedAt = model.otp?.retrievedAt {
                        Text("更新時間：\(retrievedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(CitrusTheme.secondary)
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
                            .foregroundStyle(CitrusTheme.secondary)
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
                                    .foregroundStyle(CitrusTheme.secondary)
                            }
                            HStack(spacing: 6) {
                                Button("選擇其他帳號") { model.chooseAnotherAccount() }
                                    .buttonStyle(.link)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(CitrusTheme.secondary)
                                Button("選擇其他遊戲") { model.showGamePicker() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(CitrusTheme.secondary)
                            }
                        }
                    }
                }
                .padding(10)
            }

            GGMLaunchSection(model: model)

            GroupBox("開啟遊戲") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用 macOS 的 open -n 依預設 App 或指定 Cyder 開啟 .exe。檔案位置會自動記住。")
                        .font(.caption)
                        .foregroundStyle(CitrusTheme.secondary)
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
                            .foregroundStyle(CitrusTheme.secondary)
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
                Text("診斷紀錄會遮蔽登入連結、Cookie、Token 與 OTP。")
                    .font(.caption).foregroundStyle(CitrusTheme.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(model.logText.isEmpty ? "尚無紀錄" : model.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 240)
                .background(Color.black.opacity(0.88))
                .foregroundStyle(.green.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("匯出診斷…") { model.exportDiagnostics() }
                    Button("複製診斷紀錄") { model.copyDebugLog() }
                }
            }
            .padding(.top, 8)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct GGMLaunchSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.selectedGame?.id == GameDefinition.mapleStory.id {
            GroupBox("gamania Games Manager") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("以 Cyder 開啟 GGMWebStart.exe。Games Manager 會自行向 Beanfun 取 OTP 並啟動新楓之谷；票券一次性，請取得後立刻啟動。")
                        .font(.caption)
                        .foregroundStyle(CitrusTheme.secondary)
                    HStack(spacing: 8) {
                        TextField("GGMWebStart.exe 位置", text: $model.ggmWebStartPath)
                            .textFieldStyle(.roundedBorder)
                        Button("選擇…") { model.chooseGGMWebStart() }
                    }
                    if model.hasValidGGMWebStart {
                        Text("目前：\(model.resolvedGGMWebStartPath)")
                            .font(.caption)
                            .foregroundStyle(CitrusTheme.secondary)
                            .lineLimit(2)
                    } else {
                        Text("找不到這個檔。請依下方說明選取 GGMWebStart.exe。")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    DisclosureGroup("如何找到 GGMWebStart.exe") {
                        Text(BeanfunWebStartOTP.webStartPathFinderHelp)
                            .font(.caption)
                            .foregroundStyle(CitrusTheme.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    if let ticket = model.ggmLaunchTicket {
                        if model.isGGMLaunchTicketUsable {
                            Text("Region=\(ticket.region)  SN=\(ticket.sn)  Cmd=\(ticket.command)  Data=\(ticket.data.count) chars")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        } else {
                            Text("Data 已失效（已兌現或已交給 GGM）。下次請重新用橘子遊戲管理器開啟以取得新票。")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                        }
                        ScrollView {
                            Text(ticket.uri)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .opacity(model.isGGMLaunchTicketUsable ? 1 : 0.45)
                        }
                        .frame(minHeight: 72, maxHeight: 140)
                        HStack {
                            Button { model.copyGGMURI() } label: {
                                Label("複製 gamaniagames URI", systemImage: "link")
                            }
                            .disabled(!model.isGGMLaunchTicketUsable)
                            Button { model.copyGGMSchemeCommand() } label: {
                                Label("複製 open 指令", systemImage: "terminal")
                            }
                            .disabled(!model.isGGMLaunchTicketUsable)
                            Button { model.copyGGMCyderCommand() } label: {
                                Label("複製 GGMWebStart 指令", systemImage: "terminal.fill")
                            }
                            .disabled(!model.isGGMLaunchTicketUsable)
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            model.launchSelectedAccountViaGGMScheme()
                        } label: {
                            Label("開啟 gamaniagames://", systemImage: "link.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.areLaunchButtonsDisabled || model.selectedAccount == nil)

                        Button {
                            model.launchSelectedAccountViaGGM()
                        } label: {
                            Label("以 GGMWebStart.exe 啟動", systemImage: "square.stack.3d.up.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.areLaunchButtonsDisabled || model.selectedAccount == nil)
                    }
                }
                .padding(10)
            }
        }
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

    private func updateStatusControls(for game: GameDefinition) -> some View {
        let status = model.classicUpdateStatus
        return VStack(alignment: .leading, spacing: 10) {
            if status == .checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在確認更新路線…")
                }
                .font(.callout).foregroundStyle(CitrusTheme.secondary)
            }
            if let caption = ClientUpdateUI.statusCaption(status) {
                Label(caption, systemImage: status == .completed ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
            }
            if !model.clientUpdateDetail.isEmpty {
                Text(model.clientUpdateDetail).font(.caption).foregroundStyle(CitrusTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if ClientUpdateUI.showsCheckButton(status) {
                    Button("檢查更新") { model.checkClientUpdate() }.buttonStyle(.bordered)
                }
                if ClientUpdateUI.showsPrimaryUpdateButton(status) {
                    Button("開始更新") {
                        if game.id == GameDefinition.mapleStoryClassic.id { model.updateClassicClient() }
                        else { model.updateMapleStoryClient() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if case .maintenanceOrError = status {
                    Button("重新檢查") { model.checkClientUpdate() }.buttonStyle(.borderedProminent)
                }
                if ClientUpdateUI.showsForceUpdateButton(status) {
                    Button(ClientUpdateUI.forceUpdateButtonTitle(gameID: game.id)) { model.forceUpdateClient() }
                        .buttonStyle(.bordered)
                }
            }
            .disabled(model.isDownloadingGameClient || model.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct ExecutablePickerSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let game = model.selectedGame {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: model.hasValidExecutable ? "checkmark.circle" : "folder.badge.questionmark")
                        .foregroundStyle(model.hasValidExecutable ? Color.green : CitrusTheme.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.hasValidExecutable ? "主程式已設定" : "準備遊戲主程式").font(.system(size: 12, weight: .semibold))
                        Text(model.hasValidExecutable ? URL(fileURLWithPath: model.executablePath).deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "選擇 \(game.executableName)，或先下載遊戲。")
                            .font(.system(size: 11)).foregroundStyle(CitrusTheme.secondary).lineLimit(2).truncationMode(.middle)
                            .help(model.executablePath)
                    }
                    Spacer(minLength: 0)
                    Button(model.hasValidExecutable ? "更換…" : "選擇…") { model.chooseExecutable() }
                        .buttonStyle(.link)
                        .disabled(model.isBusy)
                        .accessibilityLabel("選擇 \(game.executableName)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct GameArtwork: View {
    let game: GameDefinition

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if game.id == GameDefinition.mapleStory.id {
                    LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 0.89), Color(red: 0.82, green: 0.87, blue: 0.76)], startPoint: .topLeading, endPoint: .bottomTrailing)
                } else if game.id == "elsword" {
                    LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.23), Color(red: 0.24, green: 0.15, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
                } else { Color.white }
                if let url = Bundle.main.url(forResource: game.imageName, withExtension: nil, subdirectory: "GameImages"),
                   let image = NSImage(contentsOf: url) {
                    if game.id == GameDefinition.mapleStory.id || game.id == "elsword" {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: min(geometry.size.width * 0.78, game.id == "elsword" ? 112 : 169))
                    } else if game.id == GameDefinition.mapleStoryClassic.id {
                        Image(nsImage: image).resizable().scaledToFit().padding(8)
                    } else {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                } else {
                    Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(CitrusTheme.accent)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
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

            let targetWidth: CGFloat = mode == .standard ? 480 : 760
            let targetHeight: CGFloat
            targetHeight = mode == .standard ? 660 : 700

            let currentContentRect = window.contentRect(forFrameRect: window.frame)
            let shouldAnimate = false
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
