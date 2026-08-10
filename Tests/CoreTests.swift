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
        try testNxdlVerifiedFileNameParser()
        try testIsCheckingIntegrityIgnoresFileExistence()
        try testNxdlOutputStreamParser()
        try testOpenLauncherArguments()
        try testWindowsPathFilenameNormalizer()
        try testNormalizeWindowsPathFilenamesOnDisk()
        try testNxdlBinaryIntegrity()
        try testCmsdlBinaryPin()
        try testNxdlFailureMessage()
        try testDiskSpaceGate()
        try testClientCheckJSONParser()
        try testIncrementalSizeCalculator()
        try testNxdlManifestParser()
        try testSessionExpiredDetection()
        try testClassicUpdateStatusEnum()
        try testClientUpdateUIHelpers()
        try testNexonPlugHandlerStatus()
        print("CoreTests: 36 tests passed")
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

    private static func testNxdlVerifiedFileNameParser() throws {
        let name = try require(
            NxdlProgressParser.parseVerifiedFileName(
                "Data/Base/Base.wz already present and verified (skipping download)."
            ),
            "verified path"
        )
        try expect(name == "Data/Base/Base.wz", "verified basename path")

        try expect(
            NxdlProgressParser.parseVerifiedFileName("下載中：1 / 2") == nil,
            "non-verified line"
        )

        let tracker = NxdlProgressTracker()
        tracker.setDestinationURL(URL(fileURLWithPath: "/Games/MapleStory"))
        _ = NxdlProgressParser.ingestLine(
            "⠙ [00:00:01] [===>----] 1.0 GiB/10.0 GiB (2.5 GiB/s, ETA 4s)",
            into: tracker
        )
        _ = NxdlProgressParser.ingestLine(
            "Data/Base/Base.wz already present and verified (skipping download).",
            into: tracker
        )
        try expect(tracker.state.isCheckingIntegrity, "GiB/s → checking")
        try expect(
            tracker.state.currentFileNamesText == "Base.wz"
                || tracker.state.currentFileNamesText?.contains("Base.wz") == true,
            "verified line publishes file name"
        )
    }

    /// Regression for the false-positive fixed alongside the check-update
    /// button: `currentFileNames` stores display basenames, not paths
    /// relative to `destinationURL`. A basename that happens to already
    /// exist on disk under the destination (e.g. from a previous partial
    /// download) must not, by itself, be treated as an integrity check —
    /// only the speed heuristic or an explicit verified-file note may do so.
    private static func testIsCheckingIntegrityIgnoresFileExistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beanfunotp-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let currentFileName = "Base.wz"
        try Data("stale".utf8).write(to: root.appendingPathComponent(currentFileName))

        let tracker = NxdlProgressTracker()
        tracker.setDestinationURL(root)
        _ = NxdlProgressParser.ingestLine(
            "⠙ [00:00:01] [===>----] 1.0 GiB/10.0 GiB (65.06 MiB/s, ETA 4s)",
            into: tracker
        )
        _ = NxdlProgressParser.ingestLine(
            "  [==>-------] 84.00 MiB/586.71 MiB ( 6.88 MiB/s) Data\\\(currentFileName)",
            into: tracker
        )
        try expect(tracker.state.currentFileName == currentFileName, "current file basename set")
        try expect(
            !tracker.state.isCheckingIntegrity,
            "existing basename + normal MiB/s speed must not be checking"
        )

        tracker.noteVerifiedFile(currentFileName)
        try expect(tracker.state.isCheckingIntegrity, "noteVerifiedFile marks checking")

        let file = try require(
            NxdlProgressParser.parseFileProgress(
                "  [==>-------] 84.00 MiB/586.71 MiB ( 6.88 MiB/s) Data\\\(currentFileName)"
            ),
            "file progress"
        )
        tracker.upsert(file)
        try expect(!tracker.state.isCheckingIntegrity, "real file progress clears checking flag")
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

        // Parallel workers render one bar each per frame; all of them belong to
        // the aggregate bar that opens the frame.
        func renderFrame(files: [String]) -> String {
            var text = "⠙ [00:00:14] [====>-----] 950.77 MiB/2.76 GiB (65.06 MiB/s, ETA 29s)\r\n"
            for name in files {
                text += "  [==>-------] 84.00 MiB/586.71 MiB ( 6.88 MiB/s) Data\\\(name)\r\n"
            }
            return text
        }

        let parallel = NxdlOutputStreamParser()
        _ = parallel.ingest(renderFrame(files: ["a.bundle", "b.bundle", "c.bundle"]))
        try expect(
            parallel.state.currentFileNamesText == "a.bundle, b.bundle, c.bundle",
            "parallel files joined"
        )

        // A frame with fewer files only replaces the list once the frame ends,
        // which is signalled by the next aggregate line.
        _ = parallel.ingest(renderFrame(files: ["d.bundle"]))
        try expect(
            parallel.state.currentFileNamesText == "a.bundle, b.bundle, c.bundle",
            "shorter frame waits for frame end"
        )
        _ = parallel.ingest(renderFrame(files: ["d.bundle"]))
        try expect(parallel.state.currentFileNamesText == "d.bundle", "shorter frame committed")
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

    private static func testCmsdlBinaryPin() throws {
        try expect(
            GameClientToolConfig.cmsdlMapleStory.releaseTag == "v0.2.5",
            "cmsdl tag"
        )
        try expect(
            GameClientToolConfig.cmsdlMapleStory.sha256Hex
                == "706efcf17608a807c884e1eb8e0c8b97084f67dfbec29f7664e9aba77d0a0b78",
            "cmsdl sha"
        )
        try expect(
            GameClientToolConfig.cmsdlMapleStory.gameAlias == "tms",
            "cmsdl alias"
        )
        try expect(
            GameClientToolConfig.cmsdlMapleStory.primaryExecutableName == "MapleStory.exe",
            "cmsdl exe"
        )
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

    private static func testDiskSpaceGate() throws {
        let gib: UInt64 = 1_024 * 1_024 * 1_024

        try expect(
            DiskSpaceGate.evaluate(totalBytes: 10 * gib, freeBytes: 12 * gib).verdict == .ok,
            "small plenty → ok"
        )
        try expect(
            DiskSpaceGate.evaluate(totalBytes: 10 * gib, freeBytes: 11 * gib).verdict == .ok,
            "small at +1GiB still ≥ 1.05 → ok"
        )
        try expect(
            DiskSpaceGate.evaluate(totalBytes: 10 * gib, freeBytes: UInt64(10.7 * Double(gib))).verdict == .blocked,
            "small between 1.05 and +1GiB → blocked"
        )

        let largeTotal: UInt64 = 50 * gib
        try expect(
            DiskSpaceGate.evaluate(totalBytes: largeTotal, freeBytes: 53 * gib).verdict == .ok,
            "large comfortable → ok"
        )
        let warn = DiskSpaceGate.evaluate(totalBytes: largeTotal, freeBytes: 52 * gib)
        try expect(warn.verdict == .warn, "large mid band → warn")
        try expect(warn.minimumBytes == largeTotal + gib, "minimum = total + 1GiB")
        try expect(
            DiskSpaceGate.evaluate(totalBytes: largeTotal, freeBytes: 50 * gib + gib / 2).verdict == .blocked,
            "large below minimum → blocked"
        )
    }

    private static func testClientCheckJSONParser() throws {
        let cmsdl = #"{"region":"tms","build":0,"version":"V280","files":10,"total_size":13245678901}"#
        let cmsdlTotal = try ClientCheckJSONParser.totalSizeBytes(fromJSONText: cmsdl)
        try expect(cmsdlTotal == 13_245_678_901, "cmsdl total")

        let nxdl = #"{"appid":"2982@2141","game_name":"x","files_to_download":168,"total_size":2962637533}"#
        let nxdlTotal = try ClientCheckJSONParser.totalSizeBytes(fromJSONText: nxdl)
        try expect(nxdlTotal == 2_962_637_533, "nxdl total")

        do {
            _ = try ClientCheckJSONParser.totalSizeBytes(fromJSONText: #"{"files":1}"#)
            throw TestFailure(message: "missing total_size should throw")
        } catch is ClientCheckError {
            // ok
        } catch let error as TestFailure {
            throw error
        } catch {
            throw TestFailure(message: "unexpected error \(error)")
        }
    }

    private static func testIncrementalSizeCalculator() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file1 = tmpDir.appendingPathComponent("file1.txt")
        let subDir = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let file2 = subDir.appendingPathComponent("file2.txt")

        try Data("hello world".utf8).write(to: file1)
        try Data("12345".utf8).write(to: file2)

        let manifest = ["file1.txt", "sub\\file2.txt"]
        let totalManifestBytes: UInt64 = 16

        let required = IncrementalSizeCalculator.calculateRequiredDownloadBytes(
            manifestFiles: manifest,
            totalManifestBytes: totalManifestBytes,
            destination: tmpDir
        )
        try expect(required == 0, "all files exist -> 0 required bytes")

        let missingManifest = ["file1.txt", "sub\\file2.txt", "missing.txt"]
        let reqMissing = IncrementalSizeCalculator.calculateRequiredDownloadBytes(
            manifestFiles: missingManifest,
            totalManifestBytes: 100,
            destination: tmpDir
        )
        try expect(reqMissing == 84, "missing file -> 100 - 16 = 84 required bytes")
    }

    private static func testNxdlManifestParser() throws {
        let sampleCmsdl = """
        cmsdl 0.2.5: checking for updates from region 'TMS'.
          product:    新楓之谷
          version:    V281
          files:      2
          total size: 66.19 GB (71,075,714,473 bytes)

        2 file(s):
          BlackCipher/BlackCall64.aes
          Data/Base/Base.wz
        """
        let cmsdlBytes = NxdlManifestParser.extractTotalBytes(from: sampleCmsdl)
        try expect(cmsdlBytes == 71_075_714_473, "parsed cmsdl total bytes")

        let cmsdlPaths = NxdlManifestParser.parseFilePaths(from: sampleCmsdl, config: .cmsdlMapleStory)
        try expect(cmsdlPaths == ["BlackCipher/BlackCall64.aes", "Data/Base/Base.wz"], "parsed cmsdl file paths")

        let sampleNxdl = """
        nxdl v0.1.2-prerelease2
          total size:          2.84 GiB (3,047,501,776 bytes)

        PATH                                                                     CHUNKS         SIZE
        ---------------------------------------------------------------------- -------- ------------
        D3D12\\D3D12Core.dll                                                           2      4.5 MiB
        GameAssembly.dll                                                             30    116.6 MiB
        """
        let nxdlBytes = NxdlManifestParser.extractTotalBytes(from: sampleNxdl)
        try expect(nxdlBytes == 3_047_501_776, "parsed nxdl total bytes")

        let nxdlPaths = NxdlManifestParser.parseFilePaths(from: sampleNxdl, config: .nxdlClassic)
        try expect(nxdlPaths == ["D3D12\\D3D12Core.dll", "GameAssembly.dll"], "parsed nxdl file paths")
    }

    private static func testSessionExpiredDetection() throws {
        let expiredError = BeanfunError.expired(BeanfunError.defaultExpiredMessage)
        try expect(expiredError.isSessionExpired, "expired error should be session expired")
        try expect(expiredError.localizedDescription == "登入階段已過期，請重新取得 QR Code 並掃描登入", "expired error message")

        let parseError = BeanfunError.parse("找不到 LongPolling key，登入可能已過期")
        try expect(parseError.isSessionExpired, "parse error with login phrase should be session expired")

        let rejectedError = BeanfunError.rejected("0;登入逾時")
        try expect(rejectedError.isSessionExpired, "rejected error with 登入逾時 should be session expired")

        let networkError = BeanfunError.network("連線逾時")
        try expect(!networkError.isSessionExpired, "network timeout is not session expiration")
    }

    private static func testClientUpdateUIHelpers() throws {
        try expect(
            ClientUpdateUI.forceUpdateButtonTitle(gameID: GameDefinition.mapleStory.id) == "嘗試更新",
            "maple force title"
        )
        try expect(
            ClientUpdateUI.forceUpdateButtonTitle(gameID: GameDefinition.mapleStoryClassic.id) == "完整下載",
            "classic force title"
        )
        try expect(ClientUpdateUI.showsCheckButton(.none), "none → check")
        try expect(!ClientUpdateUI.showsCheckButton(.upToDate), "upToDate → no check")
        try expect(!ClientUpdateUI.showsCheckButton(.checking), "checking → no check")
        try expect(!ClientUpdateUI.showsPrimaryUpdateButton(.checking), "checking → no primary")
        try expect(!ClientUpdateUI.showsForceUpdateButton(.checking), "checking → no force")
        try expect(ClientUpdateUI.showsForceUpdateButton(.upToDate), "upToDate → force")
        try expect(ClientUpdateUI.showsForceUpdateButton(.maintenanceOrError("x")), "error → force")
        try expect(!ClientUpdateUI.showsForceUpdateButton(.updateAvailable), "available → no force")
        try expect(ClientUpdateUI.showsPrimaryUpdateButton(.updateAvailable), "available → update")
        try expect(!ClientUpdateUI.showsPrimaryUpdateButton(.upToDate), "upToDate → no primary update")
        try expect(ClientUpdateUI.statusCaption(.upToDate) == "已是最新版本", "upToDate caption")
        try expect(ClientUpdateUI.statusCaption(.updateAvailable) == "發現可用更新", "available caption")
        try expect(ClientUpdateUI.statusCaption(.checking) == nil, "checking has no caption")
        try expect(ClientUpdateUI.statusCaption(.none) == nil, "none has no caption")
        if let msg = ClientUpdateUI.statusCaption(.maintenanceOrError("無法檢查更新")) {
            try expect(msg == "無法檢查更新", "error caption passthrough")
        } else {
            throw TestFailure(message: "expected error caption")
        }
    }

    private static func testNexonPlugHandlerStatus() throws {
        try expect(
            !NexonPlugHandlerStatus.isBound(currentHandlerBundleID: nil, selfBundleID: "local.ogom.beanfunotp"),
            "nil handler → unbound"
        )
        try expect(
            !NexonPlugHandlerStatus.isBound(
                currentHandlerBundleID: "com.nexon.plug",
                selfBundleID: "local.ogom.beanfunotp"
            ),
            "other handler → unbound"
        )
        try expect(
            !NexonPlugHandlerStatus.isBound(
                currentHandlerBundleID: "local.ogom.beanfunotp.legacy",
                selfBundleID: "local.ogom.beanfunotp"
            ),
            "Legacy handler is not Modern bound"
        )
        try expect(
            NexonPlugHandlerStatus.isBound(
                currentHandlerBundleID: "local.ogom.beanfunotp",
                selfBundleID: "local.ogom.beanfunotp"
            ),
            "same Bundle ID → bound"
        )
        try expect(
            NexonPlugHandlerStatus.isBound(
                currentHandlerBundleID: "local.ogom.beanfunotp.legacy",
                selfBundleID: "local.ogom.beanfunotp.legacy"
            ),
            "Legacy same Bundle ID → bound"
        )
    }

    private static func testClassicUpdateStatusEnum() throws {
        let none: ClassicUpdateStatus = .none
        let checking: ClassicUpdateStatus = .checking
        let upToDate: ClassicUpdateStatus = .upToDate
        let updateAvailable: ClassicUpdateStatus = .updateAvailable
        let maintenance: ClassicUpdateStatus = .maintenanceOrError("無法檢查更新（可能是伺服器維修中）")

        try expect(none == .none, "none equality")
        try expect(checking == .checking, "checking equality")
        try expect(upToDate == .upToDate, "upToDate equality")
        try expect(updateAvailable == .updateAvailable, "updateAvailable equality")
        try expect(maintenance != .upToDate, "maintenance inequality")
        if case let .maintenanceOrError(msg) = maintenance {
            try expect(msg.contains("伺服器維修中"), "maintenance message string")
        } else {
            throw TestFailure(message: "expected maintenanceOrError case")
        }
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
