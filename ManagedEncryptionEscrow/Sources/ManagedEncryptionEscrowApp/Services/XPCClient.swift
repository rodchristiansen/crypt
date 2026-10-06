//
//  XPCClient.swift
//  Managed Encryption Escrow
//
//  Manages the NSXPCConnection to the privileged helper daemon.
//  Streams checkin's output back to the window and handles preference writes.
//

import Foundation
import ManagedEncryptionEscrowXPC

@Observable
@MainActor
final class XPCClient: NSObject {
    var outputLines: [OutputLine] = []
    var isRunning = false
    var lastExitCode: Int32?
    var helperStatus: HelperStatus = .unknown
    var connectionError: String?
    /// True once an administrator has authenticated in this window.
    var isUnlocked = false

    private var connection: NSXPCConnection?
    private let admin = AdminAuthorization()
    private var authorizationData: Data { admin.externalForm ?? Data() }

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let level: LineLevel
    }

    enum HelperStatus: String {
        case unknown = "Unknown"
        case available = "Available"
        case unavailable = "Unavailable"
    }

    var errorCount: Int {
        outputLines.filter { $0.level == .error }.count
    }

    /// The newest line worth showing as the run's progress caption.
    var latestProgressLine: String? {
        outputLines.last { $0.level == .info || $0.level == .header }?.text
    }

    // MARK: - Connection Management

    func connect() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = .escrowHelperInterface()
        conn.exportedInterface = NSXPCInterface(with: HelperXPCClientProtocol.self)
        conn.exportedObject = self

        conn.invalidationHandler = makeInvalidationHandler()
        conn.interruptionHandler = makeInterruptionHandler()

        conn.resume()
        connection = conn
        connectionError = nil

        // Ping the helper: the package installs it as a LaunchDaemon, so a reply
        // is the only check needed.
        helperProxy { [weak self] proxy in
            proxy.getHelperVersion { _ in
                Task { @MainActor [weak self] in
                    self?.helperStatus = .available
                    self?.connectionError = nil
                }
            }
        }
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Administrator

    /// Prompts for an administrator. Prefs become editable and Rotate
    /// available until `lock()` or the window closes.
    @discardableResult
    func unlock() -> Bool {
        isUnlocked = admin.unlock()
        return isUnlocked
    }

    func lock() {
        admin.lock()
        isUnlocked = false
    }

    // MARK: - Runs

    func run(mode: RunMode) {
        guard !isRunning else { return }
        if mode.requiresAdmin && !isUnlocked && !unlock() { return }

        outputLines.removeAll()
        lastExitCode = nil
        connectionError = nil

        isRunning = true
        connect()
        let authorization = mode.requiresAdmin ? authorizationData : Data()
        helperProxy { proxy in
            proxy.run(mode: mode.rawValue, authorization: authorization)
        }
    }

    func stop() {
        helperProxy { proxy in
            proxy.stop()
        }
        isRunning = false
        lastExitCode = nil
        outputLines.append(OutputLine(text: "WARN: Run stopped by user.", level: .warning))
    }

    // MARK: - Preference Management

    func setBoolPreference(key: CryptPreferenceKey, value: Bool) async -> Bool {
        let auth = authorizationData
        return await callHelper { proxy, reply in proxy.setBoolPreference(key: key.rawValue, value: value, authorization: auth, withReply: reply) }
    }

    func setIntPreference(key: CryptPreferenceKey, value: Int) async -> Bool {
        let auth = authorizationData
        return await callHelper { proxy, reply in proxy.setIntPreference(key: key.rawValue, value: value, authorization: auth, withReply: reply) }
    }

    func setStringPreference(key: CryptPreferenceKey, value: String) async -> Bool {
        let auth = authorizationData
        return await callHelper { proxy, reply in proxy.setStringPreference(key: key.rawValue, value: value, authorization: auth, withReply: reply) }
    }

    func setArrayPreference(key: CryptPreferenceKey, value: [String]) async -> Bool {
        let auth = authorizationData
        return await callHelper { proxy, reply in proxy.setArrayPreference(key: key.rawValue, value: value, authorization: auth, withReply: reply) }
    }

    func removePreference(key: CryptPreferenceKey) async -> Bool {
        let auth = authorizationData
        return await callHelper { proxy, reply in proxy.removePreference(key: key.rawValue, authorization: auth, withReply: reply) }
    }

    // MARK: - Private

    /// Calls the helper and waits for its reply; a refused or broken connection
    /// counts as a failed write rather than leaving the caller waiting.
    private func callHelper(
        _ body: @escaping @Sendable (HelperXPCProtocol, @escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        connect()
        guard let conn = connection else { return false }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in once.resume(false) }) as? HelperXPCProtocol else {
                once.resume(false)
                return
            }
            body(proxy) { ok in once.resume(ok) }
        }
    }

    /// Creates XPC callbacks in a nonisolated context so they don't inherit
    /// @MainActor isolation and crash when called on the XPC dispatch queue.
    private nonisolated func makeInvalidationHandler() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.helperStatus = .unavailable
                self?.reportConnectionFailure("Connection to helper was invalidated")
            }
        }
    }

    private nonisolated func makeInterruptionHandler() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.reportConnectionFailure("Connection to helper was interrupted")
            }
        }
    }

    private nonisolated func makeErrorHandler() -> @Sendable (any Error) -> Void {
        { [weak self] error in
            Task { @MainActor [weak self] in
                self?.reportConnectionFailure(error.localizedDescription)
            }
        }
    }

    /// A failed connection during a run must show up in the run output, in red.
    private func reportConnectionFailure(_ message: String) {
        connectionError = message
        if isRunning {
            outputLines.append(OutputLine(text: "ERROR: \(message). The helper refused the connection or is not running; see the system log for com.grahamgilbert.crypt.helper.", level: .error))
            isRunning = false
        }
    }

    private func helperProxy(block: @escaping (HelperXPCProtocol) -> Void) {
        guard let conn = connection else {
            connectionError = "No connection to helper"
            return
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler(makeErrorHandler()) as? HelperXPCProtocol else {
            connectionError = "Failed to get helper proxy"
            return
        }
        block(proxy)
    }
}

/// Resumes a continuation exactly once, whichever of the reply or the
/// connection error arrives first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - HelperXPCClientProtocol

extension XPCClient: HelperXPCClientProtocol {

    nonisolated func didReceiveOutput(_ line: String) {
        let level = LineLevel.classify(line)
        Task { @MainActor in
            outputLines.append(OutputLine(text: line, level: level))
        }
    }

    nonisolated func runDidComplete(success: Bool, exitCode: Int32) {
        Task { @MainActor in
            isRunning = false
            lastExitCode = exitCode
        }
    }

    nonisolated func didEncounterError(_ message: String) {
        Task { @MainActor in
            connectionError = message
            outputLines.append(OutputLine(text: "ERROR: \(message)", level: .error))
        }
    }
}
