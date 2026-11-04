import AppKit
import CoreImage

/// Offline native Legacy snapshots and progress-control regressions.
@main
enum LegacyUIPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data("https://example.invalid/preview".utf8), forKey: "inputMessage")
        let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let qrImage = NSImage(cgImage: CIContext().createCGImage(qr, from: qr.extent)!, size: NSSize(width: 180, height: 180))
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            app.appearance = appearance
            for state in ["games", "qr", "expired", "accounts", "otp", "classic"] {
                let controller = AppController()
                _ = controller.view
                controller.configurePreview(state, qrImage: qrImage)
                controller.previewVerifyDownloadLock()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: controller.preferredContentSize.height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentViewController = controller
                window.appearance = appearance
                try snapshot(window, output: output, name: "legacy-\(state)-\(dark ? "dark" : "light")")
            }
            let progress = ClassicDownloadProgressWindowController(title: "更新新楓之谷", onCancel: {})
            progress.window!.appearance = appearance
            var state = NxdlDownloadProgressState()
            state.phase = .minorPatch
            state.currentFileNames = ["ExePatch.dat"]
            state.overall = NxdlProgressBarInfo(downloadedText: "176 MiB", totalText: "176 MiB", speedText: "10 MiB/s", etaText: "ETA 0s", elapsedText: "00:18", fraction: 1)
            progress.apply(update: .progress(state))
            assert(!progress.previewIsIndeterminate)
            progress.apply(update: .message("[progress] begin_apply(files=978)"))
            assert(progress.previewIsIndeterminate && !progress.previewHasStaleDetail)
            progress.apply(update: .progress(state))
            try snapshot(progress.window!, output: output, name: "legacy-minor-\(dark ? "dark" : "light")")
            state = NxdlDownloadProgressState(statusMessage: "正在驗證更新後的遊戲檔案…")
            state.phase = .finishing
            progress.apply(update: .progress(state))
            assert(progress.previewIsIndeterminate && !progress.previewHasStaleDetail)
            try snapshot(progress.window!, output: output, name: "legacy-verifying-\(dark ? "dark" : "light")")
            progress.setCancelling()
            progress.apply(update: .progress(state))
            assert(!progress.previewCancelEnabled)
            try snapshot(progress.window!, output: output, name: "legacy-cancelling-\(dark ? "dark" : "light")")
        }
        print("PASS: Legacy progress resets stale percent/ETA and locks cancellation and restores controls; 18 native snapshots")
    }

    private static func snapshot(_ window: NSWindow, output: URL, name: String) throws {
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let composite = NSImage(size: view.bounds.size)
        composite.lockFocus()
        window.appearance?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            NSImage(cgImage: bitmap.cgImage!, size: view.bounds.size).draw(in: view.bounds)
        }
        composite.unlockFocus()
        let result = NSBitmapImageRep(data: composite.tiffRepresentation!)!
        try result.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
        print(name, bitmap.pixelsWide, bitmap.pixelsHigh)
    }
}
