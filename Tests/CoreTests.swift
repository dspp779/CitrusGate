import Foundation

@main
enum CoreTests {
    static func main() throws {
        try testKnownDESVector()
        try testHexDecoder()
        try testMapleStoryLaunchArguments()
        print("CoreTests: 3 tests passed")
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
        let arguments = MapleStoryLaunch.cyderArguments(
            executablePath: "/Games/Maple Story/MapleStory.exe",
            accountID: "T9ACCOUNT",
            otp: "12345678"
        )
        try expect(arguments == [
            "--launch-exe",
            "/Games/Maple Story/MapleStory.exe",
            "--",
            "tw.login.maplestory.beanfun.com",
            "8484",
            "BeanFun",
            "T9ACCOUNT",
            "12345678",
        ], "Cyder launch arguments mismatch")
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
