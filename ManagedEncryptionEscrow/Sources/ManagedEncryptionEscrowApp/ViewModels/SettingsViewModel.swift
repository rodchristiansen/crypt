//
//  SettingsViewModel.swift
//  Managed Encryption Escrow
//
//  Crypt's preferences for the Prefs tab. Values are read the way checkin
//  reads them as root; managed keys are shown locked and never written.
//  Every field is read-only until an administrator unlocks the window, and
//  edits then auto-save through the privileged helper.
//

import Foundation
import ManagedEncryptionEscrowXPC

/// The editable preferences, as the window holds them. Defaults match
/// Crypt's built-in defaults, so an unset key shows what Crypt will use.
struct PreferenceSnapshot: Equatable {
    var serverURL = ""
    var skipUsers: [String] = []
    var validateKey = true
    var rotateUsedKey = true
    var removePlist = true
    var generateNewKey = false
    /// Hours between escrows of an unchanged key.
    var keyEscrowInterval = 1
    var serverTimeout = 30
    var serverRetryAttempts = 3
    var manageAuthMechs = true
    var logLevel = "INFO"
}

/// One write the helper performs.
enum PreferenceWrite: Equatable {
    case bool(CryptPreferenceKey, Bool)
    case int(CryptPreferenceKey, Int)
    case string(CryptPreferenceKey, String)
    case array(CryptPreferenceKey, [String])
    case remove(CryptPreferenceKey)
}

@Observable
@MainActor
final class SettingsViewModel {

    static let logLevels = ["DEBUG", "INFO", "WARN", "ERROR"]

    // MARK: - Values

    var serverURL = "" { didSet { scheduleAutoSave() } }
    var skipUsersText = "" { didSet { scheduleAutoSave() } }
    var validateKey = true { didSet { scheduleAutoSave() } }
    var rotateUsedKey = true { didSet { scheduleAutoSave() } }
    var removePlist = true { didSet { scheduleAutoSave() } }
    var generateNewKey = false { didSet { scheduleAutoSave() } }
    var keyEscrowInterval = 1 { didSet { scheduleAutoSave() } }
    var serverTimeout = 30 { didSet { scheduleAutoSave() } }
    var serverRetryAttempts = 3 { didSet { scheduleAutoSave() } }
    var manageAuthMechs = true { didSet { scheduleAutoSave() } }
    var logLevel = "INFO" { didSet { scheduleAutoSave() } }

    /// Whether an API key is configured. Its value is never read into the window.
    enum SecretState: Equatable {
        case notSet, set, managed
    }
    private(set) var apiKeyState: SecretState = .notSet
    /// Where Crypt keeps the recovery key; shown, never edited here.
    private(set) var keyStorage = "the System keychain"

    private(set) var managedKeys: Set<String> = []

    // MARK: - Save Status

    enum SaveStatus: Equatable {
        case idle, saving, saved, failed(String)
    }
    private(set) var saveStatus: SaveStatus = .idle

    // MARK: - Auto-Save

    private let source: PreferenceSource
    private var xpcClient: XPCClient?
    private var autoSaveTask: Task<Void, Never>?
    private var isLoading = false
    private var saved = PreferenceSnapshot()

    init(source: PreferenceSource = SystemPreferenceSource()) {
        self.source = source
    }

    func configure(client: XPCClient) {
        xpcClient = client
    }

    private func scheduleAutoSave() {
        guard !isLoading, let client = xpcClient, client.isUnlocked else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.75))
            guard !Task.isCancelled, let self else { return }
            await self.save()
        }
    }

    func isManaged(_ key: CryptPreferenceKey) -> Bool {
        managedKeys.contains(key.rawValue)
    }

    // MARK: - Load

    func load() {
        isLoading = true
        defer { isLoading = false }

        managedKeys = Set(CryptPreferenceKey.allCases.map(\.rawValue).filter(source.isManaged))
        let snapshot = Self.read(from: source)
        apply(snapshot)
        saved = snapshot

        if source.isManaged("APIKey") {
            apiKeyState = .managed
        } else if let key = source.value(forKey: "APIKey") as? String, !key.isEmpty {
            apiKeyState = .set
        } else {
            apiKeyState = .notSet
        }

        let inKeychain = Self.boolValue(source.value(forKey: "StoreRecoveryKeyInKeychain")) ?? true
        if inKeychain {
            keyStorage = "the System keychain"
        } else {
            let path = source.value(forKey: "OutputPath") as? String
            keyStorage = path.flatMap { $0.isEmpty ? nil : $0 } ?? "/var/root/crypt_output.plist"
        }
    }

    /// Reads each value, falling back to Crypt's own default when unset.
    static func read(from source: PreferenceSource) -> PreferenceSnapshot {
        var snapshot = PreferenceSnapshot()
        func value(_ key: CryptPreferenceKey) -> Any? { source.value(forKey: key.rawValue) }

        snapshot.serverURL = value(.serverURL) as? String ?? ""
        snapshot.skipUsers = value(.skipUsers) as? [String] ?? []
        snapshot.validateKey = boolValue(value(.validateKey)) ?? snapshot.validateKey
        snapshot.rotateUsedKey = boolValue(value(.rotateUsedKey)) ?? snapshot.rotateUsedKey
        snapshot.removePlist = boolValue(value(.removePlist)) ?? snapshot.removePlist
        snapshot.generateNewKey = boolValue(value(.generateNewKey)) ?? snapshot.generateNewKey
        snapshot.keyEscrowInterval = intValue(value(.keyEscrowInterval)) ?? snapshot.keyEscrowInterval
        snapshot.serverTimeout = intValue(value(.serverTimeout)) ?? snapshot.serverTimeout
        snapshot.serverRetryAttempts = intValue(value(.serverRetryAttempts)) ?? snapshot.serverRetryAttempts
        snapshot.manageAuthMechs = boolValue(value(.manageAuthMechs)) ?? snapshot.manageAuthMechs
        if let level = (value(.logLevel) as? String)?.uppercased(), logLevels.contains(level) {
            snapshot.logLevel = level
        } else if (value(.logLevel) as? String)?.uppercased() == "WARNING" {
            snapshot.logLevel = "WARN"
        }
        return snapshot
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func apply(_ snapshot: PreferenceSnapshot) {
        serverURL = snapshot.serverURL
        skipUsersText = snapshot.skipUsers.joined(separator: ", ")
        validateKey = snapshot.validateKey
        rotateUsedKey = snapshot.rotateUsedKey
        removePlist = snapshot.removePlist
        generateNewKey = snapshot.generateNewKey
        keyEscrowInterval = snapshot.keyEscrowInterval
        serverTimeout = snapshot.serverTimeout
        serverRetryAttempts = snapshot.serverRetryAttempts
        manageAuthMechs = snapshot.manageAuthMechs
        logLevel = snapshot.logLevel
    }

    private var current: PreferenceSnapshot {
        PreferenceSnapshot(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            skipUsers: Self.parseUsers(skipUsersText),
            validateKey: validateKey,
            rotateUsedKey: rotateUsedKey,
            removePlist: removePlist,
            generateNewKey: generateNewKey,
            keyEscrowInterval: keyEscrowInterval,
            serverTimeout: serverTimeout,
            serverRetryAttempts: serverRetryAttempts,
            manageAuthMechs: manageAuthMechs,
            logLevel: logLevel
        )
    }

    /// Splits the skip-users field on commas and whitespace, keeping the
    /// first occurrence of each name.
    static func parseUsers(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// True for a server URL Crypt can use: empty (unset), or an https URL
    /// with a host. Plain http would send the recovery key in the clear.
    static func isAcceptableServerURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    // MARK: - Save

    /// The writes that take the stored preferences from `old` to `new`,
    /// skipping managed keys. An empty string or list removes the key, so
    /// Crypt falls back to its default.
    static func writes(from old: PreferenceSnapshot, to new: PreferenceSnapshot, managed: Set<String>) -> [PreferenceWrite] {
        var writes: [PreferenceWrite] = []
        func allowed(_ key: CryptPreferenceKey) -> Bool { !managed.contains(key.rawValue) }
        func bool(_ key: CryptPreferenceKey, _ a: Bool, _ b: Bool) {
            if a != b, allowed(key) { writes.append(.bool(key, b)) }
        }
        func int(_ key: CryptPreferenceKey, _ a: Int, _ b: Int) {
            if a != b, allowed(key) { writes.append(.int(key, b)) }
        }

        if old.serverURL != new.serverURL, allowed(.serverURL), isAcceptableServerURL(new.serverURL) {
            writes.append(new.serverURL.isEmpty ? .remove(.serverURL) : .string(.serverURL, new.serverURL))
        }
        if old.skipUsers != new.skipUsers, allowed(.skipUsers) {
            writes.append(new.skipUsers.isEmpty ? .remove(.skipUsers) : .array(.skipUsers, new.skipUsers))
        }
        bool(.validateKey, old.validateKey, new.validateKey)
        bool(.rotateUsedKey, old.rotateUsedKey, new.rotateUsedKey)
        bool(.removePlist, old.removePlist, new.removePlist)
        bool(.generateNewKey, old.generateNewKey, new.generateNewKey)
        int(.keyEscrowInterval, old.keyEscrowInterval, new.keyEscrowInterval)
        int(.serverTimeout, old.serverTimeout, new.serverTimeout)
        int(.serverRetryAttempts, old.serverRetryAttempts, new.serverRetryAttempts)
        bool(.manageAuthMechs, old.manageAuthMechs, new.manageAuthMechs)
        if old.logLevel != new.logLevel, allowed(.logLevel) {
            writes.append(.string(.logLevel, new.logLevel))
        }
        return writes
    }

    func save() async {
        guard let client = xpcClient, client.isUnlocked else { return }
        let target = current
        let pending = Self.writes(from: saved, to: target, managed: managedKeys)
        guard !pending.isEmpty else {
            if !Self.isAcceptableServerURL(target.serverURL) {
                saveStatus = .failed("The server URL must be an https address")
            }
            return
        }

        saveStatus = .saving
        var failed: [String] = []
        var applied = saved
        for write in pending {
            let ok: Bool
            let key: CryptPreferenceKey
            switch write {
            case .bool(let k, let value): key = k; ok = await client.setBoolPreference(key: k, value: value)
            case .int(let k, let value): key = k; ok = await client.setIntPreference(key: k, value: value)
            case .string(let k, let value): key = k; ok = await client.setStringPreference(key: k, value: value)
            case .array(let k, let value): key = k; ok = await client.setArrayPreference(key: k, value: value)
            case .remove(let k): key = k; ok = await client.removePreference(key: k)
            }
            if ok { Self.record(write, into: &applied) } else { failed.append(key.rawValue) }
        }
        saved = applied

        if !failed.isEmpty {
            saveStatus = .failed("Could not save \(failed.joined(separator: ", ")): the helper refused or is not available")
        } else if !Self.isAcceptableServerURL(target.serverURL) {
            saveStatus = .failed("The server URL must be an https address")
        } else {
            saveStatus = .saved
            try? await Task.sleep(for: .seconds(2.5))
            if saveStatus == .saved { saveStatus = .idle }
        }
    }

    /// Updates the saved snapshot for one write that succeeded, so a failed
    /// write is retried with the next edit.
    private static func record(_ write: PreferenceWrite, into snapshot: inout PreferenceSnapshot) {
        let defaults = PreferenceSnapshot()
        switch write {
        case .bool(let key, let value):
            switch key {
            case .validateKey: snapshot.validateKey = value
            case .rotateUsedKey: snapshot.rotateUsedKey = value
            case .removePlist: snapshot.removePlist = value
            case .generateNewKey: snapshot.generateNewKey = value
            case .manageAuthMechs: snapshot.manageAuthMechs = value
            default: break
            }
        case .int(let key, let value):
            switch key {
            case .keyEscrowInterval: snapshot.keyEscrowInterval = value
            case .serverTimeout: snapshot.serverTimeout = value
            case .serverRetryAttempts: snapshot.serverRetryAttempts = value
            default: break
            }
        case .string(let key, let value):
            if key == .serverURL { snapshot.serverURL = value }
            if key == .logLevel { snapshot.logLevel = value }
        case .array(let key, let value):
            if key == .skipUsers { snapshot.skipUsers = value }
        case .remove(let key):
            if key == .serverURL { snapshot.serverURL = defaults.serverURL }
            if key == .skipUsers { snapshot.skipUsers = defaults.skipUsers }
        }
    }
}
