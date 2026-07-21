import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showDebug = false

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
                        VStack(spacing: 18) {
                            advancedContent
                            statusBar
                            debugSection
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(FixedWindowConfigurator(contentSize: windowSize))
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
    }

    private var windowSize: CGSize {
        model.mode == .standard
            ? CGSize(width: 400, height: 520)
            : CGSize(width: 720, height: 780)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Beanfun 楓之谷 OTP")
                    .font(.title2.bold())
                Text("\(model.mode.title) · 原生 macOS 工具")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.screen != .welcome {
                Button("重新登入") { model.startLogin() }
                    .disabled(model.isBusy)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.bar)
    }

    @ViewBuilder
    private var standardContent: some View {
        switch model.screen {
        case .welcome:
            standardWelcomeView
        case .qr:
            standardQRView
        case .accounts, .otp:
            standardAccountView
        }
    }

    private var standardWelcomeView: some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 70, weight: .light))
                .foregroundStyle(.orange)
            if model.isBusy {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var standardQRView: some View {
        VStack(spacing: 0) {
            if let image = model.qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 376, height: 376)
                    .padding(12)
                    .background(.white)
            }
            VStack(spacing: 10) {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var advancedContent: some View {
        switch model.screen {
        case .welcome:
            welcomeView
        case .qr:
            qrView
        case .accounts:
            advancedAccountView
        case .otp:
            otpView
        }
    }

    private var welcomeView: some View {
        GroupBox {
            VStack(spacing: 22) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(.orange)
                VStack(spacing: 7) {
                    Text("使用 Gama Play 掃碼登入")
                        .font(.title3.bold())
                    Text("登入成功後會自動列出楓之谷帳號，不需要事先知道 SN。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if model.mode == .standard, model.isBusy {
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
            }
            .frame(maxWidth: .infinity, minHeight: 330)
            .padding()
        }
    }

    private var qrView: some View {
        GroupBox("掃描登入 QR Code") {
            VStack(spacing: 14) {
                if let image = model.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 270, height: 270)
                        .padding(10)
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
        GroupBox(model.accounts.count == 1 ? "開啟楓之谷" : "選擇楓之谷帳號") {
            VStack(spacing: 16) {
                if model.accounts.count > 1 {
                    Text("請選擇要使用的帳號")
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
                                    Text(account.displayName)
                                        .font(.headline)
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
                } else if let account = model.selectedAccount {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.orange)
                    Text(account.displayName)
                        .font(.title2.bold())
                }

                if model.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.statusMessage)
                    }
                    .foregroundStyle(.secondary)
                } else if let account = model.selectedAccount,
                          model.launchedAccountID == account.id {
                    Label("以 \(account.displayName) 開啟遊戲，已啟動", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else if let account = model.selectedAccount {
                    Button {
                        model.launchSelectedAccount()
                    } label: {
                        Label("以 \(account.displayName) 開啟遊戲", systemImage: "play.fill")
                            .frame(minWidth: 190)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .padding()
        }
    }

    private var advancedAccountView: some View {
        GroupBox("選擇楓之谷帳號") {
            VStack(alignment: .leading, spacing: 14) {
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
        VStack(spacing: 16) {
            GroupBox {
                VStack(spacing: 15) {
                    if let account = model.selectedAccount {
                        Text(account.displayName)
                            .font(.title3.bold())
                        Text("SN \(account.sn)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(model.otp?.value ?? "—")
                        .font(.system(size: 38, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let retrievedAt = model.otp?.retrievedAt {
                        Text("更新時間：\(retrievedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
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
                    Picker("指令形式", selection: $model.advancedLaunchCommandStyle) {
                        ForEach(AdvancedLaunchCommandStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

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
                        Button("選擇其他帳號") { model.chooseAnotherAccount() }
                    }
                }
                .padding(10)
            }

            GroupBox("透過 Cyder 啟動遊戲") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("請先在 macOS 將 .exe 的預設開啟程式設為 Cyder.app。檔案位置會自動記住。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(
                            "MapleStory.exe 位置",
                            text: $model.maplestoryExecutablePath
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("選擇…") { model.chooseMapleStoryExecutable() }
                    }
                    HStack {
                        Text("使用 open -n，並將伺服器、帳號 ID 與 OTP 放在 --args 後傳入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { model.launchMapleStory() } label: {
                            Label("啟動 MapleStory", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.maplestoryExecutablePath.isEmpty || model.isBusy)
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
        .padding(12)
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
                .frame(height: 220)
                .background(Color.black.opacity(0.88))
                .foregroundStyle(.green.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("複製 Debug Log") { model.copyDebugLog() }
                }
            }
            .padding(.top, 10)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct FixedWindowConfigurator: NSViewRepresentable {
    let contentSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.contentMinSize = contentSize
            window.contentMaxSize = contentSize
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            if window.contentLayoutRect.size != contentSize {
                window.setContentSize(contentSize)
            }
        }
    }
}
