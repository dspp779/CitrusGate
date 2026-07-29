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
        try testClassicOpenArgumentsPreferCyder()
        try testCyderInstallationDetectsPath()
        try testCyderInstallationMissingPath()
        try testMapleStoryWineLauncher()
        try testQuarantineStatusWithoutAttribute()
        try testQuarantineStatusWithAttribute()
        try testQuarantineRemovalErrorDescription()
        try testNxdlProgressParser()
        try testNxdlOutputStreamParser()
        try testOpenLauncherArguments()
        try testWindowsPathFilenameNormalizer()
        try testNormalizeWindowsPathFilenamesOnDisk()
        try testNxdlBinaryIntegrity()
        try testNxdlFailureMessage()
        print("CoreTests: 25 tests passed")
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
        try expect(games.count == 4, "expected four games including Classic")
        try expect(Set(games.map(\.id)).count == games.count, "game IDs must be unique")
        try expect(!games.contains { $0.name.contains("爆爆王") }, "BnB must not be included")
        try expect(games.contains { $0.serviceKey == "600309_A2" }, "Mabinogi service missing")
        try expect(games.contains { $0.serviceKey == "300148_AF" }, "Elsword service missing")
        try expect(games.contains { $0.id == "maplestory-classic" }, "Classic missing")
        let classic = try require(games.first { $0.id == "maplestory-classic" }, "classic")
        try expect(classic.authFlow == .webNexonPlug, "classic auth flow")
        try expect(classic.executableName == "Maplestory_Classic.exe", "classic exe name")
        try expect(
            classic.loginURL?.absoluteString == "https://maplestoryclassic.beanfun.com/Main",
            "classic login url"
        )
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
        let classic = try require(
            GameDefinition.all.first { $0.id == "maplestory-classic" },
            "Classic definition missing"
        )
        try expect(
            classic.openArguments(executablePath: "/Games/Maplestory_Classic.exe", accountID: "id", otp: "otp")
                == ["-n", "/Games/Maplestory_Classic.exe"],
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

        let cyderCommand = LaunchCommandBuilder.openCommand(
            executablePath: "/Games/Maple Story/MapleStory.exe",
            game: .mapleStory,
            accountID: "T9ACCOUNT",
            otp: "12345678",
            launcher: .cyderMapleStoryOEM
        )
        try expect(
            cyderCommand == "open -n -b 'local.cyder.maplestory-oem25' '/Games/Maple Story/MapleStory.exe' --args tw.login.maplestory.beanfun.com 8484 BeanFun T9ACCOUNT 12345678",
            "MapleStory Cyder OEM open command mismatch"
        )

        let standardCyderCommand = LaunchCommandBuilder.openCommand(
            executablePath: "/Games/mabinogi.exe",
            game: try require(GameDefinition.all.first { $0.id == "mabinogi" }, "Mabinogi missing"),
            accountID: "A2ACCOUNT",
            otp: "OTP123",
            launcher: .cyder
        )
        try expect(
            standardCyderCommand == "open -n -b 'local.cyder.app' '/Games/mabinogi.exe' --args /N:A2ACCOUNT /V:OTP123 /T:gamania",
            "standard Cyder open command mismatch"
        )

        let classic = try require(GameDefinition.all.first { $0.id == "maplestory-classic" }, "Classic missing")
        let manual = LaunchCommandBuilder.openCommand(
            executablePath: "/Games/Maplestory_Classic.exe",
            game: classic,
            accountID: "id",
            otp: "otp"
        )
        try expect(manual == "open -n '/Games/Maplestory_Classic.exe'", "manual open full command must omit --args")
    }

    private static func testNexonWineFullLaunchCommand() throws {
        let command = LaunchCommandBuilder.nexonWineCommand(
            executablePath: "/Games/Maple Story/MapleStory.exe",
            accountID: "T9ACCOUNT",
            otp: "12345678"
        )
        let expected = """
        export CX_ROOT='/Applications/MapleStory Launcher.app/Contents/SharedSupport/maplestoryna'
        export PATH="$CX_ROOT/MapleStory Launcher:$PATH"
        export LANG=zh_TW.UTF-8
        export LC_ALL=zh_TW.UTF-8
        export LC_CTYPE=zh_TW.UTF-8

        wine --bottle maplestory --wait-children --enable-alt-loader macdrv --workdir '/Games/Maple Story' '/Games/Maple Story/MapleStory.exe' tw.login.maplestory.beanfun.com 8484 BeanFun T9ACCOUNT 12345678
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

        let encodedPlus = try require(
            URL(string: "nexonplug://?game=2982@1&passarg=a%2Bb"),
            "encoded plus url"
        )
        let encodedPlusParsed = try require(NexonPlugURLParser.parse(encodedPlus), "parse encoded plus")
        try expect(encodedPlusParsed.passargTokens == ["a+b"], "encoded plus preserved")

        let other = try require(URL(string: "nexonplug://?game=9999@1&passarg=x"), "other")
        let otherParsed = try require(NexonPlugURLParser.parse(other), "parse other")
        try expect(!NexonPlugURLParser.isMapleStoryClassic(gameCode: otherParsed.gameCode), "not classic")

        try expect(NexonPlugURLParser.parse(URL(string: "https://example.com")!) == nil, "wrong scheme")
        try expect(NexonPlugURLParser.parse(URL(string: "nexonplug://?passarg=x")!) == nil, "missing game")
    }

    private static func testMapleStoryWineLauncher() throws {
        let exe = "/Games/Maple Story/MapleStory.exe"
        let args = MapleStoryWineLauncher.arguments(
            executablePath: exe,
            accountID: "T9ACCOUNT",
            otp: "12345678"
        )
        try expect(args == [
            "--bottle", "maplestory",
            "--wait-children",
            "--enable-alt-loader", "macdrv",
            "--workdir", "/Games/Maple Story",
            exe,
            "tw.login.maplestory.beanfun.com",
            "8484",
            "BeanFun",
            "T9ACCOUNT",
            "12345678",
        ], "wine argv mismatch")

        let wineURL = MapleStoryWineLauncher.wineExecutableURL()
        try expect(
            wineURL.path.hasSuffix("/MapleStory Launcher/wine"),
            "wine path suffix"
        )
        try expect(
            wineURL.path.contains("SharedSupport/maplestoryna"),
            "wine under CX_ROOT"
        )

        let env = MapleStoryWineLauncher.processEnvironment()
        try expect(env["CX_ROOT"] == MapleStoryWineLauncher.cxRoot, "CX_ROOT")
        try expect(env["LANG"] == "zh_TW.UTF-8", "LANG")
        try expect(env["LC_ALL"] == "zh_TW.UTF-8", "LC_ALL")
        try expect(env["LC_CTYPE"] == "zh_TW.UTF-8", "LC_CTYPE")
        let path = try require(env["PATH"], "PATH")
        try expect(path.hasPrefix(MapleStoryWineLauncher.cxRoot + "/MapleStory Launcher:"), "PATH prefix")
    }

    private static func testQuarantineStatusWithoutAttribute() throws {
        let status = AppModel.quarantineStatus(forExtendedAttributes: [
            "com.apple.metadata:kMDItemWhereFroms",
            "com.apple.lastuseddate#PS",
        ])
        try expect(status == .notQuarantined, "missing quarantine attribute should be not quarantined")
    }

    private static func testQuarantineStatusWithAttribute() throws {
        let status = AppModel.quarantineStatus(forExtendedAttributes: [
            "com.apple.quarantine",
            "com.apple.metadata:kMDItemWhereFroms",
        ])
        try expect(status == .quarantined, "quarantine attribute should be detected")
    }

    private static func testQuarantineRemovalErrorDescription() throws {
        let message = AppModel.quarantineRemovalErrorDescription(
            path: "/Games/Maple Story/MapleStory.exe",
            underlying: "Operation not permitted"
        )
        try expect(
            message == "無法解除檔案的 macOS quarantine，請檢查檔案權限後再試一次：/Games/Maple Story/MapleStory.exe\nOperation not permitted",
            "quarantine removal error copy mismatch"
        )
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

        let emptyArgs = NexonPlugURLParser.classicOpenArguments(
            executablePath: "/Games/Classic/Maplestory_Classic.exe",
            passargTokens: []
        )
        try expect(emptyArgs == [
            "-n",
            "/Games/Classic/Maplestory_Classic.exe",
        ], "classic open argv empty passarg")
    }

    private static func testClassicOpenArgumentsPreferCyder() throws {
        let args = NexonPlugURLParser.classicOpenArguments(
            executablePath: "/Games/Classic/Maplestory_Classic.exe",
            passargTokens: ["4554314", "sessabc", "2373", "944"],
            launcher: .cyder
        )
        try expect(args == [
            "-n",
            "-b",
            "local.cyder.app",
            "/Games/Classic/Maplestory_Classic.exe",
            "--args",
            "4554314",
            "sessabc",
            "2373",
            "944",
        ], "classic open argv with Cyder -b")
    }

    private static func testCyderInstallationDetectsPath() throws {
        var lookedUp: String?
        let installed = CyderInstallation.isOfficialCyderInstalled { id in
            lookedUp = id
            return "/Applications/Cyder.app"
        }
        try expect(lookedUp == OpenLauncher.cyderBundleIdentifier, "lookup must use official Cyder id")
        try expect(installed == true, "non-empty resolve path should count as installed")
    }

    private static func testCyderInstallationMissingPath() throws {
        try expect(
            CyderInstallation.isOfficialCyderInstalled { _ in nil } == false,
            "nil resolve should be not installed"
        )
        try expect(
            CyderInstallation.isOfficialCyderInstalled { _ in "" } == false,
            "empty resolve should be not installed"
        )
    }

    private static func testNxdlProgressParser() throws {
        let raw = "\u{001B}[32m[=========>          ]\u{001B}[0m  1.2 GiB/ 5.6 GiB (  3.4 MiB/s) Base.wz"
        let formatted = try require(
            NxdlProgressParser.formatProgressLine(raw),
            "progress line"
        )
        try expect(formatted.contains("1.2 GiB"), "downloaded bytes")
        try expect(formatted.contains("5.6 GiB"), "total bytes")
        try expect(formatted.contains("3.4 MiB/s"), "speed")
        try expect(formatted.contains("Base.wz"), "file name")

        let overallRaw =
            "⠙ [00:00:14] [=============>--------------------------] 950.77 MiB/2.76 GiB (65.06 MiB/s, ETA 29s)"
        let overall = try require(NxdlProgressParser.parseOverallProgress(overallRaw), "overall progress")
        try expect(overall.downloadedText == "950.77 MiB", "overall downloaded")
        try expect(overall.totalText == "2.76 GiB", "overall total")
        try expect(overall.speedText == "65.06 MiB/s", "overall speed")
        try expect(overall.etaText == "ETA 29s", "overall eta")
        try expect(overall.remainingTimeText == "29 秒", "overall remaining time")
        try expect(overall.elapsedText == "00:00:14", "overall elapsed")

        let expectedFraction = 950.77 / (2.76 * 1024.0)
        try expect(abs(overall.fraction - expectedFraction) < 0.000_001, "overall fraction from sizes")
        try expect(
            abs(
                NxdlProgressParser.fraction(
                    downloadedText: "950.77 MiB",
                    totalText: "2.76 GiB",
                    barFallback: "[====>----]"
                ) - expectedFraction
            ) < 0.000_001,
            "fraction helper from sizes"
        )
        try expect(
            NxdlProgressParser.parseByteCount("2.76 GiB") == 2.76 * 1024 * 1024 * 1024,
            "parse GiB"
        )
        try expect(
            NxdlProgressParser.remainingTimeText(fromETA: "ETA 1m 5s") == "1 分 5 秒",
            "remaining time minutes and seconds"
        )
        try expect(
            NxdlProgressParser.remainingTimeText(fromETA: "ETA 2h") == "2 小時",
            "remaining time hours"
        )
        try expect(
            NxdlProgressParser.remainingTimeText(fromETA: "ETA unknown") == "unknown",
            "remaining time falls back to raw text"
        )

        let fileRaw =
            #"  [===>---------------------]  84.00 MiB/586.71 MiB ( 6.88 MiB/s) Maplestory_Classic_Data\StreamingAssets\aa\w\spritesheet.bundle"#
        let file = try require(NxdlProgressParser.parseFileProgress(fileRaw), "file progress")
        try expect(file.displayName == "spritesheet.bundle", "file display name")
        try expect(file.downloadedText == "84.00 MiB", "file downloaded")
        try expect(file.speedText == "6.88 MiB/s", "file speed")

        let tracker = NxdlProgressTracker()
        _ = NxdlProgressParser.ingestLine(overallRaw, into: tracker)
        _ = NxdlProgressParser.ingestLine(fileRaw, into: tracker)
        try expect(tracker.state.overall != nil, "tracker overall")
        try expect(tracker.state.currentFileName == "spritesheet.bundle", "tracker current file")

        var oscBuffer = "progress\u{001B}]9;4;4;42\u{001B}\\more"
        let oscUpdates = NxdlProgressParser.consumeOSC94(from: &oscBuffer)
        try expect(oscUpdates.count == 1, "osc count")
        try expect(oscUpdates[0].state == 4, "osc state")
        try expect(oscUpdates[0].percent == 42, "osc percent")
        try expect(oscBuffer == "progressmore", "osc stripped from buffer")

        let plain = NxdlProgressParser.stripANSI("\u{001B}[1mhello\u{001B}[0m\u{001B}]9;4;4;7\u{0007}")
        try expect(plain == "hello", "ansi+osc strip")

        // A per-file line must never be mistaken for the aggregate bar, even when
        // a redraw glues it in front of the overall line.
        try expect(NxdlProgressParser.parseOverallProgress(fileRaw) == nil, "file line is not overall")
        let gluedRaw = "  [===>------] 84.00 MiB/586.71 MiB ( 6.88 MiB/s) a.bundle" + overallRaw
        let glued = try require(NxdlProgressParser.parseOverallProgress(gluedRaw), "glued overall")
        try expect(glued.totalText == "2.76 GiB", "glued overall keeps grand total")
    }

    private static func testNxdlOutputStreamParser() throws {
        // A PTY emits CRLF; Swift stores "\r\n" as one Character, so splitting on
        // "\n" or "\r" alone would merge every rendered line into one segment.
        let frame = "⠙ [00:00:14] [====>-----] 950.77 MiB/2.76 GiB (65.06 MiB/s, ETA 29s)\r\n"
            + #"  [==>-------] 84.00 MiB/586.71 MiB ( 6.88 MiB/s) Maplestory_Classic_Data\StreamingAssets\spritesheet.bundle"#
            + "\r\n"

        let parser = NxdlOutputStreamParser()
        _ = parser.ingest(frame)
        let overall = try require(parser.state.overall, "stream overall")
        try expect(overall.totalText == "2.76 GiB", "stream overall total")
        try expect(overall.downloadedText == "950.77 MiB", "stream overall downloaded")
        try expect(parser.state.currentFileName == "spritesheet.bundle", "stream current file")

        // Chunk boundaries must not corrupt parsing.
        let split = NxdlOutputStreamParser()
        let midpoint = frame.index(frame.startIndex, offsetBy: 40)
        _ = split.ingest(String(frame[..<midpoint]))
        _ = split.ingest(String(frame[midpoint...]))
        try expect(split.state.overall?.totalText == "2.76 GiB", "split chunk overall total")
        try expect(split.state.currentFileName == "spritesheet.bundle", "split chunk current file")
    }

    private static func testOpenLauncherArguments() throws {
        let mapleStoryArgs = GameDefinition.mapleStory.openArguments(
            executablePath: "/Games/MapleStory.exe",
            accountID: "T9ACCOUNT",
            otp: "12345678",
            launcher: .cyderMapleStoryOEM
        )
        try expect(mapleStoryArgs == [
            "-n",
            "-b",
            "local.cyder.maplestory-oem25",
            "/Games/MapleStory.exe",
            "--args",
            "tw.login.maplestory.beanfun.com",
            "8484",
            "BeanFun",
            "T9ACCOUNT",
            "12345678",
        ], "MapleStory Cyder OEM argv")

        let cyderArgs = GameDefinition.mapleStoryClassic.openArguments(
            executablePath: "/Games/Maplestory_Classic.exe",
            accountID: "id",
            otp: "otp",
            launcher: .cyder
        )
        try expect(cyderArgs == [
            "-n",
            "-b",
            "local.cyder.app",
            "/Games/Maplestory_Classic.exe",
        ], "Classic Cyder argv")
    }

    private static func testWindowsPathFilenameNormalizer() throws {
        let parts = try require(
            WindowsPathFilenameNormalizer.relativeComponents(
                from: #"Maplestory_Classic_Data\Plugins\x86_64\VuplexWebViewChromium\locales\af.pak"#
            ),
            "backslash basename"
        )
        try expect(parts == [
            "Maplestory_Classic_Data",
            "Plugins",
            "x86_64",
            "VuplexWebViewChromium",
            "locales",
            "af.pak",
        ], "components")

        try expect(
            WindowsPathFilenameNormalizer.relativeComponents(from: "af.pak") == nil,
            "plain name needs no rewrite"
        )
        try expect(
            WindowsPathFilenameNormalizer.relativeComponents(from: #"trailing\"#) == nil,
            "single component after split is invalid"
        )
    }

    private static func testNormalizeWindowsPathFilenamesOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanfunotp-nxdl-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let malformed = root.appendingPathComponent(
            #"Maplestory_Classic_Data\Plugins\x86_64\VuplexWebViewChromium\locales\af.pak"#
        )
        try Data("pak".utf8).write(to: malformed)

        let downloader = NxdlDownloader()
        let restored = try downloader.normalizeWindowsPathFilenames(in: root)
        try expect(restored == 1, "one file restored")

        let expected = root
            .appendingPathComponent("Maplestory_Classic_Data", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent("x86_64", isDirectory: true)
            .appendingPathComponent("VuplexWebViewChromium", isDirectory: true)
            .appendingPathComponent("locales", isDirectory: true)
            .appendingPathComponent("af.pak")
        try expect(FileManager.default.fileExists(atPath: expected.path), "normalized path exists")
        try expect(!FileManager.default.fileExists(atPath: malformed.path), "malformed name removed")
        let contents = try String(contentsOf: expected, encoding: .utf8)
        try expect(contents == "pak", "file contents preserved")
    }

    private static func testNxdlBinaryIntegrity() throws {
        // Empty SHA-256 (known vector).
        try expect(
            NxdlBinaryIntegrity.sha256Hex(of: Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "empty sha256"
        )
        try expect(
            NxdlBinaryIntegrity.sha256Hex(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "abc sha256"
        )
        try expect(
            NxdlDownloader.binarySHA256Hex == NxdlBinaryIntegrity.expectedSHA256Hex,
            "downloader pin matches integrity constant"
        )
        try expect(
            NxdlBinaryIntegrity.expectedSHA256Hex.count == 64,
            "sha256 hex length"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanfunotp-nxdl-hash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("sample.bin")
        try Data("abc".utf8).write(to: fileURL)
        let fileHash = try NxdlBinaryIntegrity.sha256Hex(ofFileAt: fileURL.path)
        try expect(
            fileHash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "file sha256"
        )

        do {
            try NxdlBinaryIntegrity.verifyFile(at: fileURL.path)
            throw TestFailure(message: "verify should reject non-nxdl payload")
        } catch let error as NxdlDownloaderError {
            guard case .binaryChecksumMismatch = error else {
                throw TestFailure(message: "expected checksum mismatch")
            }
        }
    }

    private static func testNxdlFailureMessage() throws {
        let preferred = NxdlFailureMessage.preferred(
            from: [
                "950.77 MiB/2.76 GiB",
                "Error: disk full while writing spritesheet.bundle",
                "nxdl: aborting",
            ],
            lastProgressLine: "950.77 MiB/2.76 GiB"
        )
        try expect(preferred == "nxdl: aborting", "prefer last error-like line")

        let progressOnly = NxdlFailureMessage.preferred(
            from: ["Manifest loaded: ok"],
            lastProgressLine: "100 MiB/2 GiB"
        )
        try expect(progressOnly == "100 MiB/2 GiB", "fall back to last progress")

        try expect(NxdlFailureMessage.isErrorLike("Error: boom"), "Error: prefix")
        try expect(NxdlFailureMessage.isErrorLike("nxdl: nope"), "nxdl: prefix")
        try expect(!NxdlFailureMessage.isErrorLike("950.77 MiB/2.76 GiB"), "progress is not error")
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
