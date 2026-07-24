import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let removedMenus = Set(["Edit", "View", "Window", "編輯", "顯示方式", "視窗"])
        DispatchQueue.main.async {
            guard let mainMenu = NSApp.mainMenu else { return }
            mainMenu.items
                .filter { removedMenus.contains($0.title) }
                .forEach { mainMenu.removeItem($0) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenURLs?(urls)
    }
}

@main
struct BeanfunOTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        urls.forEach { model.handleOpenedURL($0) }
                    }
                }
                .onOpenURL { model.handleOpenedURL($0) }
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
