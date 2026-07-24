import Foundation

@main
enum CoreTests {
    static func main() throws {
        try testKnownDESVector()
        try testHexDecoder()
        try testMapleStoryLaunchArguments()
        try testMultiGameCatalog()
        try testGameLaunchArguments()
        try testAppModes()
        try testShellQuote()
        try testOpenFullLaunchCommand()
        try testNexonWineFullLaunchCommand()
        try testNexonPlugURLParser()
        try testClassicOpenArguments()
        print("CoreTests: 11 tests passed")
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

    private static func testMultiGameCatalog() throws {
        let games = GameDefinition.all
        try expect(games.count == 9, "expected nine supported Beanfun services")
        try expect(Set(games.map(\.id)).count == games.count, "game IDs must be unique")
        try expect(!games.contains { $0.name.contains("爆爆王") }, "BnB must not be included")
        try expect(games.contains { $0.serviceKey == "600309_A2" }, "Mabinogi service missing")
        try expect(games.contains { $0.serviceKey == "300148_AF" }, "Elsword service missing")
        try expect(games.contains { $0.serviceKey == "611653_VA" }, "Dragon Nest service missing")
        try expect(games.contains { $0.serviceKey == "610153_TN" }, "CSO service missing")
    }

    private static func testGameLaunchArguments() throws {
        let mabinogi = try require(
            GameDefinition.all.first { $0.id == "mabinogi" },
            "Mabinogi definition missing"
        )
        try expect(
            mabinogi.gameArguments(accountID: "A2ACCOUNT", otp: "OTP123")
                == ["/N:A2ACCOUNT", "/V:OTP123", "/T:gamania"],
            "Mabinogi arguments mismatch"
        )
        let elsword = try require(
            GameDefinition.all.first { $0.id == "elsword" },
            "Elsword definition missing"
        )
        try expect(
            elsword.gameArguments(accountID: "AFACCOUNT", otp: "OTP456")
                == ["AFACCOUNT", "OTP456", "TW"],
            "Elsword arguments mismatch"
        )
        let lineage = try require(
            GameDefinition.all.first { $0.id == "lineage" },
            "Lineage definition missing"
        )
        try expect(
            lineage.openArguments(executablePath: "/Games/Lineage.exe", accountID: "id", otp: "otp")
                == ["-n", "/Games/Lineage.exe"],
            "manual launch must not pass unverified arguments"
        )
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

    private static func testNexonWineFullLaunchCommand() throws {
        let command = LaunchCommandBuilder.nexonWineCommand(
            executablePath: "/Users/jjc/Documents/ogs/gamania Games/MapleStory/MapleStory.exe",
            accountID: "T9ACCOUNT",
            otp: "12345678"
        )
        let expected = """
        export CX_ROOT='/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna'
        export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
        export LANG=zh_TW.UTF-8
        export LC_ALL=zh_TW.UTF-8
        export LC_CTYPE=zh_TW.UTF-8

        wine --bottle maplestory --workdir '/Users/jjc/Documents/ogs/gamania Games/MapleStory' '/Users/jjc/Documents/ogs/gamania Games/MapleStory/MapleStory.exe' tw.login.maplestory.beanfun.com 8484 BeanFun T9ACCOUNT 12345678
        """
        try expect(command == expected, "Nexon Wine full command mismatch")

        let openFallback = LaunchCommandBuilder.fullCommand(
            style: .nexonWine,
            game: try require(GameDefinition.all.first { $0.id == "mabinogi" }, "Mabinogi missing"),
            executablePath: "/Games/mabinogi.exe",
            accountID: "A2ACCOUNT",
            otp: "OTP123"
        )
        try expect(
            openFallback.hasPrefix("open -n "),
            "non-MapleStory must not emit Wine command even if style is nexonWine"
        )
    }

    private static func testNexonPlugURLParser() throws {
        let url = try require(
            URL(string: "nexonplug://?game=2982@2141&passarg=4554314%20sessabc%202373%20944"),
            "classic url"
        )
        let parsed = try require(NexonPlugURLParser.parse(url), "parse classic")
        try expect(parsed.gameCode == "2982", "gameCode")
        try expect(parsed.obdTag == "2141", "obdTag")
        try expect(
            parsed.passargTokens == ["4554314", "sessabc", "2373", "944"],
            "passarg tokens"
        )
        try expect(NexonPlugURLParser.isMapleStoryClassic(gameCode: parsed.gameCode), "is classic")

        let plus = try require(
            URL(string: "NexonPlug://?game=2982@1&passarg=a+b"),
            "plus url"
        )
        let plusParsed = try require(NexonPlugURLParser.parse(plus), "parse plus")
        try expect(plusParsed.passargTokens == ["a", "b"], "plus as space")

        let other = try require(URL(string: "nexonplug://?game=9999@1&passarg=x"), "other")
        let otherParsed = try require(NexonPlugURLParser.parse(other), "parse other")
        try expect(!NexonPlugURLParser.isMapleStoryClassic(gameCode: otherParsed.gameCode), "not classic")

        try expect(NexonPlugURLParser.parse(URL(string: "https://example.com")!) == nil, "wrong scheme")
        try expect(NexonPlugURLParser.parse(URL(string: "nexonplug://?passarg=x")!) == nil, "missing game")
    }

    private static func testClassicOpenArguments() throws {
        let args = NexonPlugURLParser.classicOpenArguments(
            executablePath: "/Games/Classic/Maplestory_Classic.exe",
            passargTokens: ["4554314", "sessabc", "2373", "944"]
        )
        try expect(args == [
            "-n",
            "/Games/Classic/Maplestory_Classic.exe",
            "--args",
            "4554314",
            "sessabc",
            "2373",
            "944",
        ], "classic open argv")
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
