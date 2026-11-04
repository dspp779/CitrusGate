import SwiftUI

struct ClassicDownloadProgressView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let state = model.classicDownloadProgress
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("GETTING READY").font(.system(size: 10, weight: .bold)).tracking(1.6).foregroundStyle(CitrusTheme.accent)
                    Text(model.gameClientDownloadTitle).font(.system(size: 22, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: state.phase == .patching ? "wrench.and.screwdriver" : "arrow.down.circle")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(CitrusTheme.accent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(state.isCheckingIntegrity ? "檢查檔案完整性" : state.phase.rawValue).font(.headline)
                    Spacer()
                    if let overall = state.overall {
                        Text(overall.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(.title2, design: .rounded).bold()).monospacedDigit()
                    }
                }
                if let overall = state.overall {
                    ProgressView(value: overall.fraction).tint(CitrusTheme.accent)
                        .accessibilityLabel(state.phase.rawValue)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(overall.downloadedText) / \(overall.totalText)")
                        Spacer()
                        if !state.isCheckingIntegrity { Text(overall.speedText) }
                    }
                    .font(.callout.monospacedDigit()).foregroundStyle(CitrusTheme.secondary)
                    if !state.isCheckingIntegrity, let remaining = overall.remainingTimeText {
                        Text("預估剩餘 \(remaining)").font(.caption).foregroundStyle(CitrusTheme.secondary)
                    }
                } else {
                    ProgressView().progressViewStyle(.linear).tint(CitrusTheme.accent)
                    Text(phaseDescription(state.phase)).font(.callout).foregroundStyle(CitrusTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let names = state.currentFileNamesText {
                Label(names, systemImage: "doc")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(CitrusTheme.secondary)
                    .lineLimit(2).truncationMode(.middle).help(names)
            }
            Divider()
            HStack(alignment: .center, spacing: 16) {
                Text("取消會保留既有安裝；重試可能重新下載。")
                    .font(.caption).foregroundStyle(CitrusTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(model.isCancellingClientDownload ? "正在取消…" : "取消更新") { model.cancelClassicDownload() }
                    .disabled(model.isCancellingClientDownload)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .tint(CitrusTheme.accent)
    }

    private func phaseDescription(_ phase: ClientDownloadPhase) -> String {
        switch phase {
        case .preparing: return "正在確認本機版本、更新路線與磁碟空間。"
        case .checking: return "比對既有檔案，確認需要更新的內容。"
        case .downloading: return "正在取得遊戲檔案，進度將隨下載更新。"
        case .patching: return "正在將補丁套用至遊戲檔案，請保留此視窗。"
        case .minorPatch: return "正在更新遊戲主程式。"
        case .finishing: return "正在確認本次更新結果。"
        }
    }
}
