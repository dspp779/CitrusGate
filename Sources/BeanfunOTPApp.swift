import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Cold-start URLs can arrive via application(_:open:) before SwiftUI's
    // .onAppear has installed the handler; buffer them and flush once the
    // handler is set instead of silently dropping them.
    var onOpenURLs: (([URL]) -> Void)? {
        didSet {
            guard onOpenURLs != nil, !pendingURLs.isEmpty else { return }
            let urls = pendingURLs
            pendingURLs = []
            onOpenURLs?(urls)
        }
    }
    private var pendingURLs: [URL] = []

    /// True from launch until a short settle after first activation.
    /// URLs delivered while true are treated as cold-start by AppModel (Task 2).
    private(set) var isWithinColdStartURLWindow = true
    private var didScheduleColdStartWindowEnd = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let removedMenus = Set(["Edit", "View", "Window", "編輯", "顯示方式", "視窗"])
        DispatchQueue.main.async {
            guard let mainMenu = NSApp.mainMenu else { return }
            mainMenu.items
                .filter { removedMenus.contains($0.title) }
                .forEach { mainMenu.removeItem($0) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !didScheduleColdStartWindowEnd else { return }
        didScheduleColdStartWindowEnd = true
        // Allow Launch Services to deliver cold-start open: slightly after activate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.isWithinColdStartURLWindow = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpenURLs {
            onOpenURLs(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

@main
struct BeanfunOTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Beanfun OTP", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.onOpenURLs = { [appDelegate] urls in
                        let cold = appDelegate.isWithinColdStartURLWindow
                        urls.forEach { model.handleOpenedURL($0, fromColdStart: cold) }
                    }
                }
                .onOpenURL { url in
                    model.handleOpenedURL(url, fromColdStart: appDelegate.isWithinColdStartURLWindow)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 440)
        .windowResizability(.contentSize)
        .commandsRemoved()
        .commands {
            CommandGroup(after: .appInfo) {
                Button("關閉並結束 Beanfun OTP") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("結束 Beanfun OTP") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandMenu("模式") {
                ForEach(AppMode.allCases) { mode in
                    Button {
                        model.setMode(mode)
                    } label: {
                        if model.mode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }
            CommandMenu("遊戲") {
                ForEach(model.games) { game in
                    Button {
                        model.selectGame(game)
                    } label: {
                        if model.selectedGameID == game.id {
                            Label(game.name, systemImage: "checkmark")
                        } else {
                            Text(game.name)
                        }
                    }
                }
                Divider()
                Button("選擇\(model.selectedGame?.name ?? "遊戲")主程式…") {
                    model.chooseExecutable()
                }
                .disabled(model.selectedGame == nil)
            }
        }
    }
}
