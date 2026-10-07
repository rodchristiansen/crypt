import Foundation
import Testing
@testable import ManagedEncryptionEscrowApp
import ManagedEncryptionEscrowXPC

// MARK: - Line levels, against the lines Crypt writes

@Suite struct LineLevelTests {
    @Test func logFileLevels() {
        #expect(LineLevel.classify("[2026-10-06 09:14:02] ERROR Escrow: the server returned 500") == .error)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] WARN  Escrow: retrying") == .warning)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] DEBUG Prefs: reading ServerURL") == .debug)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] INFO  Escrow: Checking that the current key is valid") == .info)
    }

    @Test func consoleLevels() {
        #expect(LineLevel.classify("ERROR: Refusing to run checkin: /Library/Crypt/checkin does not exist") == .error)
        #expect(LineLevel.classify("WARN: Run stopped by user.") == .warning)
        #expect(LineLevel.classify("FileVault:            on") == .info)
    }
}

// MARK: - Logs

@Suite struct LogSessionStoreTests {
    @Test func rollStampParsing() throws {
        let day = try #require(LogSessionStore.parseRollStamp("crypt-2026-10-05.log"))
        let next = try #require(LogSessionStore.parseRollStamp("crypt-2026-10-06.log"))
        #expect(next.timeIntervalSince(day) == 86_400)
        #expect(LogSessionStore.parseRollStamp("crypt.log") == nil)
        #expect(LogSessionStore.parseRollStamp("launchd-com.grahamgilbert.crypt.log") == nil)
    }

    @Test func currentLogLeadsThenRollsNewestFirst() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mee-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        func write(_ name: String, _ text: String = "x", modified: Date? = nil) throws {
            let path = (root as NSString).appendingPathComponent(name)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            if let modified {
                try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path)
            }
        }
        try write("crypt.log", "current", modified: Date(timeIntervalSince1970: 0))
        try write("crypt-2026-10-04.log")
        try write("crypt-2026-10-05.log", "longer content")
        try write("launchd-com.grahamgilbert.crypt.log", modified: Date(timeIntervalSince1970: 10))
        try write("notes.txt")
        try fm.createDirectory(atPath: (root as NSString).appendingPathComponent("old.log"), withIntermediateDirectories: true)

        let sessions = LogSessionStore.sessions(in: root)
        let names = sessions.map(\.name)
        #expect(names == ["crypt.log", "crypt-2026-10-05.log", "crypt-2026-10-04.log", "launchd-com.grahamgilbert.crypt.log"])
        #expect(sessions[1].size == 14)
    }

    @Test func missingRootListsNothing() {
        #expect(LogSessionStore.sessions(in: "/nonexistent/\(UUID().uuidString)").isEmpty)
    }
}

// MARK: - Run modes and the helper's limits

@Suite struct RunModeTests {
    @Test func fixedArguments() {
        #expect(RunMode.verify.arguments == ["verify"])
        #expect(RunMode.escrow.arguments == ["escrow", "--force"])
        #expect(RunMode.checkAuthMechs.arguments == ["auth-mechs", "check"])
        // Rotate never forces: it discards only a key that no longer unlocks the disk.
        #expect(RunMode.rotate.arguments == ["rotate"])
    }

    @Test func exitCodesAreDescribed() {
        #expect(RunMode.describeExit(4) == "no recovery key held")
        #expect(RunMode.describeExit(8) == "server unreachable")
        #expect(RunMode.describeExit(99) == nil)
    }

    @Test func onlyRotateNeedsAnAdministrator() {
        #expect(RunMode.allCases.filter(\.requiresAdmin) == [.rotate])
    }

    @Test func unknownModesAreRejected() {
        #expect(RunMode(rawValue: "auth-mechs") == nil)
        #expect(RunMode(rawValue: "config") == nil)
        #expect(RunMode(rawValue: "--force") == nil)
    }

    @Test func helperAcceptsOnlyWindowKeys() {
        #expect(CryptPreferenceKey.isWritable("ServerURL"))
        #expect(CryptPreferenceKey.isWritable("SkipUsers"))
        // Secrets, escrow records, the key's location and root commands stay out of reach.
        for key in ["APIKey", "APIKeyHeader", "PostRunCommand", "OutputPath", "StoreRecoveryKeyInKeychain",
                    "LastEscrow", "RotatedKey", "AppsAllowedToReadKey", "AppsAllowedToChangeKey"] {
            #expect(!CryptPreferenceKey.isWritable(key))
        }
    }

    @Test func terminalOutputIsCleaned() {
        #expect(TerminalOutput.lines("FileVault:   on\r\n\r\nRecovery key:\theld\r\n") == ["FileVault:   on", "Recovery key:\theld"])
        #expect(TerminalOutput.lines("^D\u{8}\u{8}partial") == ["^Dpartial"])
        #expect(TerminalOutput.lines("").isEmpty)
    }

    @Test func recoveryKeysAreRedacted() {
        let line = "Key: ABCD-1234-EFGH-5678-IJKL-9012 escrowed"
        #expect(RecoveryKeyRedactor.redact(line) == "Key: [recovery key redacted] escrowed")
        #expect(RecoveryKeyRedactor.redact("FileVault:            on") == "FileVault:            on")
        #expect(RecoveryKeyRedactor.redact("2026-10-06-0914") == "2026-10-06-0914")
    }
}

// MARK: - Preferences

private struct FakeSource: PreferenceSource {
    var values: [String: Any] = [:]
    var managed: Set<String> = []
    func value(forKey key: String) -> Any? { values[key] }
    func isManaged(_ key: String) -> Bool { managed.contains(key) }
}

@Suite @MainActor struct PreferenceTests {
    @Test func defaultsMatchCrypt() {
        let snapshot = SettingsViewModel.read(from: FakeSource())
        #expect(snapshot == PreferenceSnapshot())
        #expect(snapshot.validateKey && snapshot.rotateUsedKey && snapshot.removePlist && snapshot.manageAuthMechs)
        #expect(!snapshot.generateNewKey)
        #expect(snapshot.keyEscrowInterval == 1)
        #expect(snapshot.logLevel == "INFO")
    }

    @Test func readsStoredValues() {
        let snapshot = SettingsViewModel.read(from: FakeSource(values: [
            "ServerURL": "https://crypt.example.com",
            "SkipUsers": ["admin"],
            "ValidateKey": false,
            "KeyEscrowInterval": 12,
            "ServerTimeout": "45",
            "LogLevel": "warning",
        ]))
        #expect(snapshot.serverURL == "https://crypt.example.com")
        #expect(snapshot.skipUsers == ["admin"])
        #expect(!snapshot.validateKey)
        #expect(snapshot.keyEscrowInterval == 12)
        #expect(snapshot.serverTimeout == 45)
        #expect(snapshot.logLevel == "WARN")
    }

    @Test func loadMarksManagedKeysAndNeverReadsTheAPIKeyValue() {
        let model = SettingsViewModel(source: FakeSource(
            values: ["ServerURL": "https://crypt.example.com", "APIKey": "secret"],
            managed: ["ServerURL", "APIKey"]
        ))
        model.load()
        #expect(model.isManaged(.serverURL))
        #expect(!model.isManaged(.skipUsers))
        #expect(model.serverURL == "https://crypt.example.com")
        #expect(model.apiKeyState == .managed)
    }

    @Test func keyStorageFollowsTheKeychainSetting() {
        let model = SettingsViewModel(source: FakeSource(values: [
            "StoreRecoveryKeyInKeychain": false,
            "OutputPath": "/var/root/crypt_output.plist",
        ]))
        model.load()
        #expect(model.keyStorage == "/var/root/crypt_output.plist")
        #expect(model.apiKeyState == .notSet)
    }

    @Test func serverURLMustBeHTTPS() {
        #expect(SettingsViewModel.isAcceptableServerURL(""))
        #expect(SettingsViewModel.isAcceptableServerURL("https://crypt.example.com"))
        #expect(!SettingsViewModel.isAcceptableServerURL("http://crypt.example.com"))
        #expect(!SettingsViewModel.isAcceptableServerURL("crypt.example.com"))
        #expect(!SettingsViewModel.isAcceptableServerURL("https://"))
    }

    @Test func writesSkipManagedKeysAndInsecureURLs() {
        let old = PreferenceSnapshot()
        var new = PreferenceSnapshot()
        new.serverURL = "https://crypt.example.com"
        new.skipUsers = ["admin", "support"]
        new.validateKey = false
        new.keyEscrowInterval = 24
        new.logLevel = "DEBUG"

        let writes = SettingsViewModel.writes(from: old, to: new, managed: ["KeyEscrowInterval"])
        #expect(writes == [
            .string(.serverURL, "https://crypt.example.com"),
            .array(.skipUsers, ["admin", "support"]),
            .bool(.validateKey, false),
            .string(.logLevel, "DEBUG"),
        ])

        var insecure = old
        insecure.serverURL = "http://crypt.example.com"
        #expect(SettingsViewModel.writes(from: old, to: insecure, managed: []).isEmpty)

        var cleared = new
        cleared.serverURL = ""
        cleared.skipUsers = []
        #expect(SettingsViewModel.writes(from: new, to: cleared, managed: []) == [.remove(.serverURL), .remove(.skipUsers)])
        #expect(SettingsViewModel.writes(from: new, to: new, managed: []).isEmpty)
    }

    @Test func parsesSkipUsers() {
        #expect(SettingsViewModel.parseUsers(" admin, support\nadmin  guest,,") == ["admin", "support", "guest"])
        #expect(SettingsViewModel.parseUsers("").isEmpty)
    }
}

// MARK: - Launch arguments

@Suite @MainActor struct LaunchArgumentTests {
    private func defaults(_ values: [String: String]) -> UserDefaults {
        let suite = "mee-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    @Test func onlyReadOnlyRunsStartAtLaunch() {
        #expect(RunMode.launchRequested(defaults(["run": "verify"])) == .verify)
        #expect(RunMode.launchRequested(defaults(["run": "check-auth-mechs"])) == .checkAuthMechs)
        #expect(RunMode.launchRequested(defaults(["run": "rotate"])) == nil)
        #expect(RunMode.launchRequested(defaults(["run": "escrow"])) == nil)
        #expect(RunMode.launchRequested(defaults([:])) == nil)
    }

    @Test func tabFromArguments() {
        #expect(ContentView.ContentTab.fromLaunchArguments(defaults(["tab": "logs"])) == .logs)
        #expect(ContentView.ContentTab.fromLaunchArguments(defaults(["run": "verify"])) == .run)
        #expect(ContentView.ContentTab.fromLaunchArguments(defaults(["tab": "nonsense"])) == .prefs)
    }
}
