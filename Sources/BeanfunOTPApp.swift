import SwiftUI

@main
struct BeanfunOTPApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
