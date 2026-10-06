//
//  LogSessionStore.swift
//  Managed Encryption Escrow
//
//  Lists Crypt's logs under /Library/Managed Encryption/logs: the current
//  crypt.log, which checkin and the login plugin both append to, the daily
//  rolls checkin makes of it (crypt-yyyy-MM-dd.log), and the launchd output
//  log. Each file is one entry, newest first.
//

import Foundation

struct LogSession: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let date: Date?
    let size: Int64

    var displayDate: String {
        guard let date else { return name }
        return LogSessionStore.displayDateFormatter.string(from: date)
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum LogSessionStore {
    static let currentLogName = "crypt.log"

    static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let rollStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The day a rolled log covers, from its name: crypt-2026-10-05.log.
    static func parseRollStamp(_ name: String) -> Date? {
        guard name.hasPrefix("crypt-"), name.hasSuffix(".log") else { return nil }
        let stamp = name.dropFirst("crypt-".count).dropLast(".log".count)
        return rollStampFormatter.date(from: String(stamp))
    }

    /// Every log under `root`, newest first. The current crypt.log always
    /// leads; rolled days follow by date, then any other log by modification.
    static func sessions(in root: String, fileManager fm: FileManager = .default) -> [LogSession] {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var found: [LogSession] = []
        for name in entries where name.hasSuffix(".log") {
            let path = (root as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let attributes = try? fm.attributesOfItem(atPath: path)
            let modified = attributes?[.modificationDate] as? Date
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            found.append(LogSession(
                id: name,
                name: name,
                path: path,
                date: name == currentLogName ? modified : (parseRollStamp(name) ?? modified),
                size: size
            ))
        }

        return found.sorted { lhs, rhs in
            if lhs.name == currentLogName { return true }
            if rhs.name == currentLogName { return false }
            let l = lhs.date ?? .distantPast
            let r = rhs.date ?? .distantPast
            return l == r ? lhs.name > rhs.name : l > r
        }
    }
}
