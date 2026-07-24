import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledOpenURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.handledOpenURL else { return }
            self.showAndQuit(
                title: "NXL Interceptor",
                message: "此 App 用來攔截 nxl:// 連結。\n請從網頁或終端機開啟 nxl://… 再試。"
            )
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledOpenURL = true
        let text: String
        if let url = urls.first {
            let absolute = url.absoluteString
            text = absolute.isEmpty ? "(empty absoluteString)" : absolute
        } else {
            text = "(no URL)"
        }
        showAndQuit(title: "nxl URL", message: text)
    }

    private func showAndQuit(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "確定")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
