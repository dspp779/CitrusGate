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
