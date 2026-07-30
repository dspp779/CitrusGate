import AppKit

final class ClassicDownloadProgressWindowController: NSWindowController {
    private let onCancel: () -> Void
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let overallProgress = NSProgressIndicator()
    private let overallDetailLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let currentFileLabel = NSTextField(wrappingLabelWithString: "")

    init(title: String = "下載新楓之谷：經典版", onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildUI(in: panel.contentView!)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(relativeTo parent: NSWindow?) {
        guard let window else { return }
        window.center()
        if let parent {
            let parentFrame = parent.frame
            window.setFrameOrigin(NSPoint(
                x: parentFrame.midX - window.frame.width / 2,
                y: parentFrame.midY - window.frame.height / 2
            ))
        }
        parent?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    func closeProgressWindow() {
        if let parent = window?.parent {
            parent.removeChildWindow(window!)
        }
        window?.orderOut(nil)
    }

    func apply(update: NxdlDownloadUpdate) {
        switch update {
        case let .message(message):
            statusLabel.stringValue = message
            currentFileLabel.stringValue = ""
        case let .progress(state):
            if let fileName = state.currentFileName {
                currentFileLabel.stringValue = "正在下載 \(fileName)"
            } else if !state.statusMessage.isEmpty {
                statusLabel.stringValue = state.statusMessage
                currentFileLabel.stringValue = ""
            }
            if let overall = state.overall {
                overallProgress.isIndeterminate = false
                overallProgress.stopAnimation(nil)
                overallProgress.doubleValue = overall.fraction * 100
                overallDetailLabel.stringValue = "\(overall.downloadedText) / \(overall.totalText)  ·  \(overall.speedText)"
                var metaParts: [String] = []
                if let elapsed = overall.elapsedText {
                    metaParts.append("已用時間 \(elapsed)")
                }
                if let remaining = overall.remainingTimeText {
                    metaParts.append("預估剩餘時間 \(remaining)")
                }
                metaLabel.stringValue = metaParts.joined(separator: "  ·  ")
            }
        }
    }

    private func buildUI(in contentView: NSView) {
        statusLabel.alignment = .left
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3

        overallProgress.isIndeterminate = true
        overallProgress.maxValue = 100
        overallProgress.controlSize = .regular
        overallProgress.usesThreadedAnimation = true
        overallProgress.startAnimation(nil)

        overallDetailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        overallDetailLabel.textColor = NSColor.labelColor
        overallDetailLabel.lineBreakMode = .byTruncatingMiddle

        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = NSColor.secondaryLabelColor

        currentFileLabel.alignment = .left
        currentFileLabel.font = NSFont.systemFont(ofSize: 11)
        currentFileLabel.textColor = NSColor.secondaryLabelColor
        currentFileLabel.maximumNumberOfLines = 2
        currentFileLabel.lineBreakMode = .byTruncatingMiddle

        let cancelButton = NSButton(title: "取消下載", target: self, action: #selector(handleCancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let root = NSStackView(views: [
            statusLabel,
            overallProgress,
            overallDetailLabel,
            metaLabel,
            currentFileLabel,
            cancelButton,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            overallProgress.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            currentFileLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])
    }

    @objc private func handleCancel() {
        onCancel()
    }
}
