import AppKit

final class ClassicDownloadProgressWindowController: NSWindowController {
    private let onCancel: () -> Void
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let overallProgress = NSProgressIndicator()
    private let overallDetailLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let currentFileLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton(title: "取消更新", target: nil, action: nil)
    private var isCancelling = false
    private var phase: ClientDownloadPhase = .preparing

    init(title: String = "下載新楓之谷：經典版", onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildUI(in: panel.contentView!)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(relativeTo parent: NSWindow?) {
        guard let window else { return }
        window.center()
        if let parent {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
        }
        parent?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    func closeProgressWindow() {
        if let window, let parent = window.parent { parent.removeChildWindow(window) }
        window?.orderOut(nil)
    }

    func setCancelling() {
        isCancelling = true
        cancelButton.isEnabled = false
        cancelButton.title = "正在取消…"
        statusLabel.stringValue = "正在停止更新並清理暫存，請稍候。"
    }

    func apply(update: NxdlDownloadUpdate) {
        guard !isCancelling else { return }
        switch update {
        case let .message(message):
            var next = NxdlDownloadProgressState()
            next.phase = phase
            next.notePhase(message)
            if next.phase != phase {
                phase = next.phase
                clearProgressDetail()
            }
            statusLabel.stringValue = message
            currentFileLabel.stringValue = ""
            currentFileLabel.isHidden = true
        case let .progress(state):
            phase = state.phase
            statusLabel.stringValue = state.statusMessage.isEmpty ? state.phase.rawValue : state.statusMessage
            currentFileLabel.stringValue = state.currentFileNamesText ?? ""
            currentFileLabel.isHidden = currentFileLabel.stringValue.isEmpty
            if let overall = state.overall {
                overallDetailLabel.isHidden = false
                metaLabel.isHidden = false
                overallProgress.isIndeterminate = false
                overallProgress.stopAnimation(nil)
                overallProgress.doubleValue = overall.fraction * 100
                let speed = state.isCheckingIntegrity ? "檢查完整性中" : overall.speedText
                overallDetailLabel.stringValue = "\(overall.downloadedText) / \(overall.totalText)  ·  \(speed)"
                var details: [String] = []
                if let elapsed = overall.elapsedText { details.append("已用時間 \(elapsed)") }
                if !state.isCheckingIntegrity, let remaining = overall.remainingTimeText { details.append("預估剩餘 \(remaining)") }
                metaLabel.stringValue = details.joined(separator: "  ·  ")
                metaLabel.isHidden = details.isEmpty
            } else {
                // A new verification/synchronization phase has no byte estimate.
                // Never leave the previous download's 100% or ETA on screen.
                clearProgressDetail()
            }
        }
    }

    private func clearProgressDetail() {
        overallDetailLabel.isHidden = true
        metaLabel.isHidden = true
        overallProgress.doubleValue = 0
        overallProgress.isIndeterminate = true
        overallProgress.startAnimation(nil)
        overallDetailLabel.stringValue = ""
        metaLabel.stringValue = ""
    }

    private func buildUI(in contentView: NSView) {
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.maximumNumberOfLines = 3
        overallProgress.isIndeterminate = true
        overallProgress.maxValue = 100
        overallProgress.usesThreadedAnimation = true
        overallProgress.startAnimation(nil)
        overallProgress.setAccessibilityLabel("更新進度")
        overallDetailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        overallDetailLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = NSColor.secondaryLabelColor
        currentFileLabel.font = NSFont.systemFont(ofSize: 11)
        currentFileLabel.textColor = NSColor.secondaryLabelColor
        currentFileLabel.maximumNumberOfLines = 2
        currentFileLabel.lineBreakMode = .byTruncatingMiddle
        let notice = NSTextField(wrappingLabelWithString: "取消會保留既有安裝；重試可能重新下載。")
        notice.font = NSFont.systemFont(ofSize: 11)
        notice.textColor = NSColor.secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        overallDetailLabel.isHidden = true
        metaLabel.isHidden = true
        currentFileLabel.isHidden = true
        let root = NSStackView(views: [statusLabel, overallProgress, overallDetailLabel, metaLabel, currentFileLabel, notice, cancelButton])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ] + [statusLabel, overallProgress, overallDetailLabel, metaLabel, currentFileLabel, notice].map {
            $0.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40)
        })
    }

    #if UI_PREVIEW
    var previewIsIndeterminate: Bool { overallProgress.isIndeterminate }
    var previewHasStaleDetail: Bool { !overallDetailLabel.stringValue.isEmpty || !metaLabel.stringValue.isEmpty }
    var previewCancelEnabled: Bool { cancelButton.isEnabled }
    #endif

    @objc private func handleCancel() {
        guard !isCancelling else { return }
        setCancelling()
        onCancel()
    }
}
