import Foundation

@main
enum CoreTests {
    static func main() throws {
        try testKnownDESVector()
        try testHexDecoder()
        try testMapleStoryLaunchArguments()
        try testAppModes()
        try testShellQuote()
        try testOpenFullLaunchCommand()
        print("CoreTests: 6 tests passed")
    }

    private static func testKnownDESVector() throws {
        let ciphertext = try require(Data(hexString: "897923ff842ec7e7"), "hex decode failed")
        let plaintext = try DESCipher.decryptECB(
            ciphertext: ciphertext,
            asciiKey: Data("12345678".utf8)
        )
        try expect(String(data: plaintext, encoding: .utf8) == "OTP12345", "DES vector mismatch")
    }

    private static func testHexDecoder() throws {
        try expect(Data(hexString: "000102ff") == Data([0, 1, 2, 255]), "hex bytes mismatch")
        try expect(Data(hexString: "abc") == nil, "odd-length hex should fail")
        try expect(Data(hexString: "zz") == nil, "invalid hex should fail")
    }

    private static func testMapleStoryLaunchArguments() throws {
        let arguments = MapleStoryLaunch.openArguments(
            executablePath: "/Games/Maple Story/MapleStory.exe",
            accountID: "T9ACCOUNT",
            otp: "12345678"
        )
        try expect(arguments == [
            "-n",
            "/Games/Maple Story/MapleStory.exe",
            "--args",
            "tw.login.maplestory.beanfun.com",
            "8484",
            "BeanFun",
            "T9ACCOUNT",
            "12345678",
        ], "open launch arguments mismatch")
    }

    private static func testAppModes() throws {
        try expect(AppMode.allCases == [.standard, .advanced], "app mode order mismatch")
        try expect(AppMode.defaultMode == .standard, "standard mode should be the default")
        try expect(AppMode.standard.title == "一般模式", "standard mode title mismatch")
        try expect(AppMode.advanced.title == "進階模式", "advanced mode title mismatch")
    }

    private static func testShellQuote() throws {
        try expect(LaunchCommandBuilder.shellQuote("/Games/MapleStory.exe") == "'/Games/MapleStory.exe'", "plain path quote mismatch")
        try expect(
            LaunchCommandBuilder.shellQuote("/Games/Maple Story/MapleStory.exe") == "'/Games/Maple Story/MapleStory.exe'",
            "spaced path quote mismatch"
        )
        try expect(
            LaunchCommandBuilder.shellQuote("/Games/O'Brien/MapleStory.exe") == "'/Games/O'\\''Brien/MapleStory.exe'",
            "single-quote path escaping mismatch"
        )
    }

    private static func testOpenFullLaunchCommand() throws {
        let command = LaunchCommandBuilder.openCommand(
            executablePath: "/Games/Maple Story/MapleStory.exe",
            game: .mapleStory,
            accountID: "T9ACCOUNT",
            otp: "12345678"
        )
        try expect(
            command == "open -n '/Games/Maple Story/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun T9ACCOUNT 12345678",
            "MapleStory open full command mismatch"
        )

        let lineage = try require(GameDefinition.all.first { $0.id == "lineage" }, "Lineage missing")
        let manual = LaunchCommandBuilder.openCommand(
            executablePath: "/Games/Lineage.exe",
            game: lineage,
            accountID: "id",
            otp: "otp"
        )
        try expect(manual == "open -n '/Games/Lineage.exe'", "manual open full command must omit --args")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message: message) }
        return value
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
