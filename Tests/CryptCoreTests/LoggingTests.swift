import XCTest
@testable import CryptCore

final class LoggingTests: XCTestCase {
  /// A log last written yesterday is rolled under yesterday's date, and the
  /// oldest generations beyond the retention limit are removed.
  func testRollsYesterdaysLogAndPrunesOldGenerations() throws {
    let fm = FileManager.default
    let directory = NSTemporaryDirectory() + "crypt-log-\(UUID().uuidString)"
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: directory) }

    let current = directory + "/crypt.log"
    fm.createFile(atPath: current, contents: Data("yesterday\n".utf8))
    let yesterday = Date().addingTimeInterval(-86_400)
    try fm.setAttributes([.modificationDate: yesterday], ofItemAtPath: current)

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

  func testLevelsAreOrdered() {
    XCTAssertTrue(CryptLogLevel.debug < .info)
    XCTAssertTrue(CryptLogLevel.warning < .error)
    XCTAssertEqual(CryptLogLevel.warning.label, "WARN")
  }
}
