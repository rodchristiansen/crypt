import XCTest
@testable import CryptCore

final class LoggingTests: XCTestCase {
  /// A log whose records are from yesterday is rolled under yesterday's date,
  /// and the oldest generations beyond the retention limit are removed.
  func testRollsYesterdaysLogAndPrunesOldGenerations() throws {
    let fm = FileManager.default
    let directory = NSTemporaryDirectory() + "crypt-log-\(UUID().uuidString)"
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: directory) }

    let current = directory + "/crypt.log"
    let yesterday = Date().addingTimeInterval(-86_400)
    fm.createFile(atPath: current, contents: Data("[\(day(yesterday)) 10:00:00] INFO  Crypt: yesterday\n".utf8))

    // More rolled files than we keep, so pruning has something to do.
    for day in 1...(managedLogGenerations + 5) {
      let stamp = Date().addingTimeInterval(-86_400 * Double(day + 1))
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      fm.createFile(atPath: "\(directory)/crypt-\(formatter.string(from: stamp)).log", contents: Data())
    }

    ManagedLog.roll(directory: directory, name: "crypt.log", now: Date())

    XCTAssertFalse(fm.fileExists(atPath: current), "the current log should have been rolled away")
    let rolled = try fm.contentsOfDirectory(atPath: directory).filter { $0.hasPrefix("crypt-") }
    XCTAssertEqual(rolled.count, managedLogGenerations)
  }

  /// A log written today is left alone, so several runs an hour do not each
  /// start a new file.
  func testLeavesTodaysLogInPlace() throws {
    let fm = FileManager.default
    let directory = NSTemporaryDirectory() + "crypt-log-\(UUID().uuidString)"
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: directory) }

    let current = directory + "/crypt.log"
    fm.createFile(atPath: current, contents: Data("today\n".utf8))

    ManagedLog.roll(directory: directory, name: "crypt.log", now: Date())

    XCTAssertTrue(fm.fileExists(atPath: current))
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory), ["crypt.log"])
  }

  /// Records are filed by the date that opens each one, so a file holding
  /// yesterday's and today's records keeps today's in place and loses nothing.
  func testSplitsRecordsByTheirOwnDate() throws {
    let fm = FileManager.default
    let directory = NSTemporaryDirectory() + "crypt-log-\(UUID().uuidString)"
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: directory) }

    let yesterday = day(Date().addingTimeInterval(-86_400))
    let today = day(Date())
    let current = directory + "/crypt.log"
    let text = "[\(yesterday) 23:59:00] INFO  Crypt: one\n[\(today) 00:01:00] INFO  Crypt: two\n"
    fm.createFile(atPath: current, contents: Data(text.utf8))

    ManagedLog.roll(directory: directory, name: "crypt.log", now: Date())

    XCTAssertEqual(try String(contentsOfFile: "\(directory)/crypt-\(yesterday).log", encoding: .utf8),
                   "[\(yesterday) 23:59:00] INFO  Crypt: one\n")
    XCTAssertEqual(try String(contentsOfFile: current, encoding: .utf8), "[\(today) 00:01:00] INFO  Crypt: two\n")
    XCTAssertFalse(fm.fileExists(atPath: directory + "/.crypt.rolling"))
  }

  /// A Swift String logged with an os_log `%{public}s` specifier is rendered
  /// by description, never read as a C pointer.
  func testRendersOsLogSpecifiersWithoutStringFormat() {
    XCTAssertEqual(renderManagedLog("label: [%{public}s] code %d, 100%%", ["key", 7]),
                   "label: [key] code 7, 100%")
    XCTAssertEqual(managedLogRecords("a\nb", level: "INFO", category: "Keychain", stamp: "S"),
                   "[S] INFO  Keychain: a\n[S] INFO  Keychain: b\n")
  }

  private func day(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  func testLevelsAreOrdered() {
    XCTAssertTrue(CryptLogLevel.debug < .info)
    XCTAssertTrue(CryptLogLevel.warning < .error)
    XCTAssertEqual(CryptLogLevel.warning.label, "WARN")
  }
}
