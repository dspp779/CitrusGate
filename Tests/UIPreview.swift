import AppKit
import CoreImage
import SwiftUI

/// Renders production SwiftUI views with synthetic states. No login, OTP request
/// or manifest refresh is performed. Built only by scripts/preview-ui.sh.
@main
struct UIPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = PreviewDefaults(suiteName: "CitrusGate.UIPreview.\(UUID())")!
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for state in ["games", "welcome", "qr", "expired", "accounts", "classic", "update", "minor", "readiness", "update-error", "verifying", "cancelling", "advanced"] {
                let model = AppModel(defaults: defaults)
                model.configurePreview(state)
                if state == "update-error" {
                    let fixture = output.appendingPathComponent("fixture-game/MapleStory.exe")
                    try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("UI fixture".utf8).write(to: fixture)
                    model.executablePath = fixture.path
                }
                let name = "\(state)-\(dark ? "dark" : "light").png"
                let view: AnyView
                if ["update", "minor", "verifying", "cancelling"].contains(state) {
                    view = AnyView(ClassicDownloadProgressView(model: model))
                } else if state == "readiness" {
                    view = AnyView(LaunchReadinessView(model: model))
                } else { view = AnyView(ContentView(model: model)) }
                let hosted = NSHostingView(rootView: view
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let size = ["update", "minor", "verifying", "cancelling"].contains(state) ? NSSize(width: 460, height: 350)
                    : state == "readiness" ? NSSize(width: 440, height: 380) : state == "advanced" ? NSSize(width: 760, height: 720) : NSSize(width: 480, height: 660)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosted
                window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
                window.orderFrontRegardless()
                hosted.frame = NSRect(origin: .zero, size: size)
                hosted.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                guard let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else {
                    throw NSError(domain: "UIPreview", code: 1)
                }
                hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "UIPreview", code: 2) }
                window.orderOut(nil)
                try png.write(to: output.appendingPathComponent(name))
                print(name, bitmap.pixelsWide, bitmap.pixelsHigh)
            }
        }
    }
}

final class PreviewDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {}
}
