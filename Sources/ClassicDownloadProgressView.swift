import SwiftUI

struct ClassicDownloadProgressView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("下載新楓之谷：經典版")
                .font(.title3.bold())

            if let overall = model.classicDownloadProgress.overall {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: overall.fraction)
                        .progressViewStyle(.linear)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(overall.downloadedText) / \(overall.totalText)")
                            .font(.callout.monospacedDigit())
                        Spacer()
                        Text(overall.speedText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if let elapsed = overall.elapsedText {
                            Text("已用時間 \(elapsed)")
                        }
                        if let remaining = overall.remainingTimeText {
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

            if let fileName = model.classicDownloadProgress.currentFileName {
                Text("正在下載 \(fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
