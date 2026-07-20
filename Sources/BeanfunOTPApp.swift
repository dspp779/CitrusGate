import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
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
}

@main
struct BeanfunOTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 520)
        .windowResizability(.contentSize)
        .commandsRemoved()
        .commands {
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
                Button("選擇 MapleStory 主程式…") {
                    model.chooseMapleStoryExecutable()
                }
            }
        }
    }
}
