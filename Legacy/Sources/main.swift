import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    private var controller: AppController?
    private var pendingURLs: [URL] = []
    private(set) var isWithinColdStartURLWindow = true
    private var didScheduleColdStartWindowEnd = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        assert(GameDefinition.all.count == 4)
        let controller = AppController()
        self.controller = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Beanfun OTP Legacy"
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        flushPendingURLs()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !didScheduleColdStartWindowEnd else { return }
        didScheduleColdStartWindowEnd = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.isWithinColdStartURLWindow = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        processOpenedURL(url)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls {
            processOpenedURL(url)
        }
    }

    private func processOpenedURL(_ url: URL) {
        if let controller = controller {
            controller.handleOpenedURL(url, fromColdStart: isWithinColdStartURLWindow)
        } else {
            pendingURLs.append(url)
        }
    }

    private func flushPendingURLs() {
        guard let controller = controller, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        for url in urls {
            controller.handleOpenedURL(url, fromColdStart: isWithinColdStartURLWindow)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
