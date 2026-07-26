import Foundation

enum MapleStoryWineLauncher {
    static let cxRoot =
        "/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna"
    static let bottle = "maplestory"

    static func wineExecutableURL(cxRoot: String = cxRoot) -> URL {
        URL(fileURLWithPath: cxRoot)
            .appendingPathComponent("MapleStory Launcher", isDirectory: true)
            .appendingPathComponent("wine", isDirectory: false)
    }

    static func processEnvironment(
        cxRoot: String = cxRoot,
        enableMetalHUD: Bool = false
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let wineDir = URL(fileURLWithPath: cxRoot)
            .appendingPathComponent("MapleStory Launcher", isDirectory: true)
            .path
        env["CX_ROOT"] = cxRoot
        env["PATH"] = wineDir + ":" + (env["PATH"] ?? "")
        env["LANG"] = "zh_TW.UTF-8"
        env["LC_ALL"] = "zh_TW.UTF-8"
        env["LC_CTYPE"] = "zh_TW.UTF-8"
        if enableMetalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        } else {
            env.removeValue(forKey: "MTL_HUD_ENABLED")
        }
        return env
    }

    static func arguments(
        executablePath: String,
        accountID: String,
        otp: String
    ) -> [String] {
        let workdir = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .path
        let gameArgs = GameDefinition.mapleStory.gameArguments(
            accountID: accountID,
            otp: otp
        )
        return ["--bottle", bottle, "--wait-children", "--enable-alt-loader", "macdrv", "--workdir", workdir, executablePath] + gameArgs
    }
}
