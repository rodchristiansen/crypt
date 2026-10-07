//
//  HelperCommandRunner.swift
//  ManagedEncryptionEscrowHelper
//
//  Implements the XPC protocol: runs checkin in a fixed mode with output
//  streaming, and writes Crypt's system-level preferences once an
//  administrator has authorised the change.
//

import Foundation
import Security
import ManagedEncryptionEscrowXPC

final class HelperCommandRunner: NSObject, HelperXPCProtocol, @unchecked Sendable {
    // Safety invariant: `process` is only mutated on the XPC dispatch queue
    // which serializes all incoming calls. The connection holds a strong
    // reference to this object; invalidationHandler calls cancelRunningProcess
    // on the same queue.
    private let connection: NSXPCConnection
    private var process: Process?

    private static var domain: CFString { EscrowConstants.preferenceDomain as CFString }

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    // MARK: - Authorization

    /// True when `externalForm` is an authorization reference that already
    /// holds the admin right. The helper never prompts: the GUI asked the
    /// administrator, and this only confirms the credential it was given.
    static func isAdminAuthorized(_ externalForm: Data) -> Bool {
        guard externalForm.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { buffer in
            _ = externalForm.copyBytes(to: buffer)
        }
        var authRef: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &authRef) == errAuthorizationSuccess, let authRef else {
            return false
        }
        defer { AuthorizationFree(authRef, []) }

        return EscrowConstants.adminRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                let status = AuthorizationCopyRights(authRef, &rights, nil, [.extendRights], nil)
                return status == errAuthorizationSuccess
            }
        }
    }

    // MARK: - Runs

    func run(mode: String, authorization: Data) {
        let clientProxy = connection.remoteObjectProxy as? HelperXPCClientProtocol

        guard let runMode = RunMode(rawValue: mode) else {
            clientProxy?.didEncounterError("Unknown run mode: \(mode)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }
        guard process == nil else {
            clientProxy?.didEncounterError("A run is already in progress.")
            return
        }
        if runMode.requiresAdmin && !Self.isAdminAuthorized(authorization) {
            clientProxy?.didEncounterError("\(runMode.title) needs an administrator.")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }
        let executable = EscrowConstants.checkinExecutablePath
        if let problem = Self.untrustedPathProblem(executable) {
            clientProxy?.didEncounterError("Refusing to run checkin: \(problem)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = runMode.arguments
        task.standardInput = FileHandle.nullDevice
        // A minimal environment: checkin reads CRYPT_* variables ahead of its
        // preferences, so the helper's own environment is never passed on.
        task.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        // checkin writes with print(), which a pipe makes fully buffered, so a
        // run's report would arrive only at exit, or not at all when checkin
        // exits through an error. A pseudo-terminal keeps it line-buffered.
        var primary: Int32 = -1
        var secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
            clientProxy?.didEncounterError("Could not open a terminal for checkin's output.")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }
        let primaryFD = primary
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        task.standardOutput = secondaryHandle
        task.standardError = secondaryHandle

        process = task

        let send: @Sendable (String) -> Void = { text in
            for line in TerminalOutput.lines(text) {
                clientProxy?.didReceiveOutput(RecoveryKeyRedactor.redact(line))
            }
        }

        // Read until the terminal closes: read() returns 0 or fails with EIO
        // once checkin and the helper's copy of the secondary end are gone.
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(primaryFD, &buffer, buffer.count)
                if count <= 0 { break }
                pending.append(contentsOf: buffer[0..<count])
                if let newline = pending.lastIndex(of: UInt8(ascii: "\n")) {
                    let complete = pending[...newline]
                    pending.removeSubrange(...newline)
                    send(String(decoding: complete, as: UTF8.self))
                }
            }
            if !pending.isEmpty { send(String(decoding: pending, as: UTF8.self)) }
            close(primaryFD)
            drained.leave()
        }

        task.terminationHandler = { [weak self] proc in
            drained.notify(queue: .global()) {
                let exitCode = proc.terminationStatus
                clientProxy?.runDidComplete(success: exitCode == 0, exitCode: exitCode)
                self?.process = nil
            }
        }

        do {
            try task.run()
            // The child holds its own copy; closing ours lets the reader see EOF.
            try? secondaryHandle.close()
        } catch {
            try? secondaryHandle.close()
            close(primary)
            clientProxy?.didEncounterError("Failed to launch checkin: \(error.localizedDescription)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            process = nil
        }
    }

    func stop() {
        cancelRunningProcess()
    }

    func cancelRunningProcess() {
        process?.terminate()
        process = nil
    }

    /// Root runs only a binary that root alone can change: the file and every
    /// directory above it must be root-owned and not group- or world-writable,
    /// and none of them a symlink. Returns the reason when that does not hold.
    static func untrustedPathProblem(_ path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardized.path
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else {
                return "\(current) does not exist"
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return "\(current) is a symbolic link"
            }
            if info.st_uid != 0 {
                return "\(current) is not owned by root"
            }
            if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
                return "\(current) is writable by users other than root"
            }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
    }

    // MARK: - Preferences
    //
    // Writes land in /Library/Preferences/com.grahamgilbert.crypt.plist
    // (any user, any host), which checkin and the login plugin read as root.
    // The domain is fixed, only the keys the window edits are accepted, and
    // every write needs an administrator: the server URL decides where the
    // recovery key is sent.

    func setBoolPreference(key: String, value: Bool, authorization: Data, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFBoolean, authorization: authorization, reply: reply)
    }

    func setIntPreference(key: String, value: Int, authorization: Data, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFNumber, authorization: authorization, reply: reply)
    }

    func setStringPreference(key: String, value: String, authorization: Data, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFString, authorization: authorization, reply: reply)
    }

    func setArrayPreference(key: String, value: [String], authorization: Data, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFArray, authorization: authorization, reply: reply)
    }

    func removePreference(key: String, authorization: Data, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: nil, authorization: authorization, reply: reply)
    }

    private func write(key: String, value: CFPropertyList?, authorization: Data, reply: @escaping (Bool) -> Void) {
        guard CryptPreferenceKey.isWritable(key), Self.isAdminAuthorized(authorization) else {
            reply(false)
            return
        }
        CFPreferencesSetValue(key as CFString, value, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        reply(CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost))
    }

    // MARK: - Version

    func getHelperVersion(withReply reply: @escaping (String) -> Void) {
        reply(Self.bundleVersion)
    }

    /// The version of the app bundle the helper ships in.
    static let bundleVersion: String = {
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let infoPlist = ownPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlist) else { return "unknown" }
        let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short).\(build)"
    }()
}
