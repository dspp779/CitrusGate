import SwiftUI

struct ClassicDownloadProgressView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.gameClientDownloadTitle)
                .font(.title3.bold())

            if let overall = model.classicDownloadProgress.overall {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: overall.fraction)
                        .progressViewStyle(.linear)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(overall.downloadedText) / \(overall.totalText)")
                            .font(.callout.monospacedDigit())
                        Spacer()
                        if model.classicDownloadProgress.isCheckingIntegrity {
                            Text("檢查完整性中")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(overall.speedText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        if let elapsed = overall.elapsedText {
                            Text("已用時間 \(elapsed)")
                        }
                        if !model.classicDownloadProgress.isCheckingIntegrity, let remaining = overall.remainingTimeText {
                            Text("預估剩餘時間 \(remaining)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.classicDownloadStatus.isEmpty ? "正在準備下載…" : model.classicDownloadStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let fileNames = model.classicDownloadProgress.currentFileNamesText {
                let actionText = model.classicDownloadProgress.isCheckingIntegrity ? "正在檢查" : "正在下載"
                let suffixText = model.classicDownloadProgress.isCheckingIntegrity ? " 檔案完整性…" : ""
                Text("\(actionText) \(fileNames)\(suffixText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
            } else if !model.classicDownloadProgress.statusMessage.isEmpty {
                Text(model.classicDownloadProgress.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消下載", role: .destructive) {
                    model.cancelClassicDownload()
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
