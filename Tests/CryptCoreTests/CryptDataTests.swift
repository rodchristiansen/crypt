import XCTest
@testable import CryptCore

final class CryptDataTests: XCTestCase {
  /// The plist fdesetup writes has no last_run or escrow_success until checkin
  /// adds them, so decoding has to tolerate their absence.
  func testDecodesTheOutputFdesetupWrites() throws {
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>RecoveryKey</key><string>ABCD-EFGH-IJKL-MNOP-QRST-UVWX</string>
        <key>SerialNumber</key><string>EXAMPLE-SERIAL</string>
        <key>EnabledUser</key><string>student</string>
      </dict>
      </plist>
      """
    let data = try PropertyListDecoder().decode(CryptData.self, from: Data(plist.utf8))
    XCTAssertEqual(data.recoveryKey, "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
    XCTAssertEqual(data.serialNumber, "EXAMPLE-SERIAL")
    XCTAssertEqual(data.enabledUser, "student")
    XCTAssertNil(data.lastRun)
    XCTAssertFalse(data.escrowSuccess)
  }

  func testRoundTripsThroughAFile() throws {
    let path = NSTemporaryDirectory() + "crypt-test-\(UUID().uuidString).plist"
    defer { try? FileManager.default.removeItem(atPath: path) }

    var original = CryptData(serialNumber: "EXAMPLE-SERIAL", recoveryKey: "KEY",
                             enabledUser: "student", hardwareUUID: "UUID")
    original.lastRun = Date(timeIntervalSince1970: 1_700_000_000)
    original.escrowSuccess = true
    try original.write(to: path)

    XCTAssertEqual(try CryptData.read(from: path), original)

    // The key is on disk in the clear, so nobody but root may read it.
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.int16Value, 0o600)
  }
}
