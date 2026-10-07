//
//  HelperXPCProtocol.swift
//  Managed Encryption Escrow
//
//  The protocol, constants and run modes shared by the GUI and the privileged
//  helper. Nothing here touches Crypt itself; the helper runs the installed
//  checkin binary with the fixed arguments a run mode names.
//

import Foundation

/// Mach service name for the privileged helper.
public let kHelperMachServiceName = "com.grahamgilbert.crypt.helper"

public enum EscrowConstants {
    /// Crypt's preference domain. The helper writes only this domain.
    public static let preferenceDomain = "com.grahamgilbert.crypt"
    /// The signing identifier of the GUI. The helper accepts no other client.
    public static let appIdentifier = "com.grahamgilbert.crypt.gui"
    /// The checkin binary, as the Crypt package installs it.
    public static let checkinExecutablePath = "/Library/Crypt/checkin"
    /// Where checkin and the login plugin write crypt.log and its daily rolls.
    public static let logsDirectory = "/Library/Managed Encryption/logs"
    /// The authorization right an administrator must hold for a change: a
    /// preference write or a key rotation. A standard user can run the
    /// read-only and escrow modes, never redirect or discard the key.
    public static let adminRight = "system.privilege.admin"
}

/// The checkin runs that make sense to start by hand. Each maps to fixed
/// arguments; a caller names a mode and never supplies a command line.
public enum RunMode: String, CaseIterable, Identifiable, Sendable {
    // Picker order, read-only first.
    case verify = "verify"
    case escrow = "escrow"
    case checkAuthMechs = "check-auth-mechs"
    case rotate = "rotate"

    public var id: String { rawValue }

    /// The checkin arguments the helper runs for this mode.
    public var arguments: [String] {
        switch self {
        case .verify: ["verify"]
        case .escrow: ["escrow", "--force"]
        case .checkAuthMechs: ["auth-mechs", "check"]
        case .rotate: ["rotate"]
        }
    }

    /// Modes that change what this Mac holds need an administrator.
    public var requiresAdmin: Bool { self == .rotate }

    public var title: String {
        switch self {
        case .verify: "Verify"
        case .escrow: "Escrow now"
        case .checkAuthMechs: "Check login mechanisms"
        case .rotate: "Rotate if invalid"
        }
    }

    public var summary: String {
        switch self {
        case .verify:
            "Reports FileVault, whether Crypt holds a key and whether it still unlocks the disk, and when it was last escrowed. The key itself is never shown."
        case .escrow:
            "Sends the recovery key Crypt holds to the configured server now, even inside the escrow interval."
        case .checkAuthMechs:
            "Checks that Crypt's login-window mechanisms are in the authorization database."
        case .rotate:
            "Discards the held key only when it no longer unlocks the disk, so a new one is made at the next login. Needs an administrator."
        }
    }
}

public extension RunMode {
    /// What a non-zero checkin exit code means, in the words the banner uses.
    /// Verify reports a missing or invalid key through its exit code, so that
    /// is a finding about this Mac rather than a broken run.
    static func describeExit(_ code: Int32) -> String? {
        switch code {
        case 1: "general error"
        case 2: "checkin was not run as root"
        case 3: "configuration error"
        case 4: "no recovery key held"
        case 5: "escrow failed"
        case 6: "the held key no longer unlocks the disk"
        case 7: "login mechanisms missing"
        case 8: "server unreachable"
        default: nil
        }
    }
}

/// The Crypt preferences the window edits. The helper refuses every other key,
/// so a client cannot use it to rewrite escrow records, the API key, the key's
/// storage location or a command Crypt runs as root.
public enum CryptPreferenceKey: String, CaseIterable, Sendable {
    case serverURL = "ServerURL"
    case skipUsers = "SkipUsers"
    case validateKey = "ValidateKey"
    case rotateUsedKey = "RotateUsedKey"
    case removePlist = "RemovePlist"
    case generateNewKey = "GenerateNewKey"
    case keyEscrowInterval = "KeyEscrowInterval"
    case serverTimeout = "ServerTimeout"
    case serverRetryAttempts = "ServerRetryAttempts"
    case manageAuthMechs = "ManageAuthMechs"
    case logLevel = "LogLevel"

    public static func isWritable(_ key: String) -> Bool {
        CryptPreferenceKey(rawValue: key) != nil
    }
}

/// Protocol exposed by the privileged helper daemon. All methods run as root.
/// `authorization` is an AuthorizationExternalForm the GUI obtained after an
/// administrator authenticated; the helper checks it holds
/// `EscrowConstants.adminRight` before any change.
/// XPC proxies are thread-safe by design; Sendable conformance is safe.
@objc public protocol HelperXPCProtocol: Sendable {
    /// Run checkin in the named mode. Output streams back over the client
    /// protocol. `authorization` is empty for modes that need no administrator.
    func run(mode: String, authorization: Data)

    /// Stop the run in progress.
    func stop()

    /// Write a preference to /Library/Preferences/com.grahamgilbert.crypt.plist.
    func setBoolPreference(key: String, value: Bool, authorization: Data, withReply reply: @escaping (Bool) -> Void)
    func setIntPreference(key: String, value: Int, authorization: Data, withReply reply: @escaping (Bool) -> Void)
    func setStringPreference(key: String, value: String, authorization: Data, withReply reply: @escaping (Bool) -> Void)
    func setArrayPreference(key: String, value: [String], authorization: Data, withReply reply: @escaping (Bool) -> Void)
    func removePreference(key: String, authorization: Data, withReply reply: @escaping (Bool) -> Void)

    /// The helper's version, to confirm it is alive.
    func getHelperVersion(withReply reply: @escaping (String) -> Void)
}

/// Callback protocol from the helper back to the GUI.
@objc public protocol HelperXPCClientProtocol: Sendable {
    /// One line of output from the running checkin process.
    func didReceiveOutput(_ line: String)

    /// The checkin process finished.
    func runDidComplete(success: Bool, exitCode: Int32)

    /// The helper hit an error outside a normal run.
    func didEncounterError(_ message: String)
}

public extension NSXPCInterface {
    /// The helper interface with the string array argument of
    /// setArrayPreference allowed through secure coding.
    static func escrowHelperInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HelperXPCProtocol.self)
        let classes = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(
            classes,
            for: #selector(HelperXPCProtocol.setArrayPreference(key:value:authorization:withReply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return interface
    }
}

/// Redacts anything shaped like a FileVault personal recovery key
/// (six groups of four letters or digits) from a line of output, so a key can
/// never reach the window or a screenshot, whatever checkin prints.
public enum RecoveryKeyRedactor {
    public static func redact(_ line: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b[A-Z0-9]{4}(-[A-Z0-9]{4}){5}\\b",
            options: [.caseInsensitive]
        ) else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return regex.stringByReplacingMatches(in: line, range: range, withTemplate: "[recovery key redacted]")
    }
}

/// Splits a run's terminal output into lines, dropping the carriage returns
/// the terminal adds, any other control characters except tabs, and blank lines.
public enum TerminalOutput {
    public static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = String(raw.unicodeScalars.filter { $0 == "\t" || $0.value >= 0x20 })
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line
        }
    }
}
