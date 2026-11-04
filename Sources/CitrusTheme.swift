import SwiftUI

/// Small native design vocabulary shared by the main flow and update sheet.
enum CitrusTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 1, green: 0.64, blue: 0.29, alpha: 1)
            : NSColor(calibratedRed: 0.66, green: 0.27, blue: 0.06, alpha: 1)
    })
    static let secondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.73, alpha: 1)
            : NSColor(calibratedWhite: 0.39, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.10)
}

struct CitrusPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 20)
            .frame(minHeight: 42)
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.white)
            .background(enabled ? Color(red: 0.70, green: 0.30, blue: 0.07) : Color.gray)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct CitrusSectionHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow).font(.system(size: 10, weight: .bold)).tracking(1.6).foregroundStyle(CitrusTheme.accent)
            Text(title).font(.system(size: 27, weight: .bold, design: .rounded)).tracking(-0.5)
            Text(subtitle).font(.callout).foregroundStyle(CitrusTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LaunchReadinessView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CitrusSectionHeading(eyebrow: "READY TO PLAY", title: "啟動前檢查", subtitle: "確認遊戲檔案與啟動環境，讓登入順利完成。")
            ForEach(model.readinessItems) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(item.isReady ? Color.green : CitrusTheme.accent)
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.detail).font(.callout).foregroundStyle(CitrusTheme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title)，\(item.isReady ? "已就緒" : "需要處理")，\(item.detail)")
            }
            HStack {
                Button("選擇遊戲主程式…") { model.chooseExecutable(); model.refreshLaunchReadiness() }
                if model.selectedGame?.id == GameDefinition.mapleStoryClassic.id && !model.isNexonPlugHandler {
                    Button("設定登入連結") { model.claimNexonPlugHandler(); model.refreshLaunchReadiness() }
                }
            }
            Link("查看安裝說明", destination: URL(string: model.selectedGame?.id == GameDefinition.mapleStoryClassic.id
                ? "https://github.com/dspp779/CitrusGate/blob/main/docs/macos-player-guide-classic.md"
                : "https://github.com/dspp779/CitrusGate/blob/main/docs/macos-player-guide.md")!)
            Button("重新檢查") { model.refreshLaunchReadiness() }
        }
        .padding(28)
        .frame(width: 440)
        .tint(CitrusTheme.accent)
    }
}
