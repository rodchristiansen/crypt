import XCTest
@testable import CryptCore

final class AuthMechsTests: XCTestCase {
  /// A database that has never seen Crypt gets the mechanism immediately
  /// before the anchor.
  func testInsertsBeforeAnchor() {
    let result = AuthMechs.apply(to: ["builtin:policy-banner", "loginwindow:login", "loginwindow:done"])
    XCTAssertEqual(result, ["builtin:policy-banner", "loginwindow:login",
                            "Crypt:Check,privileged", "loginwindow:done"])
  }

  /// Mechanisms from older versions are cleared out rather than left behind.
  func testRemovesObsoleteMechanisms() {
    let existing = ["Crypt:CryptGUI", "Crypt:Enablement,privileged",
                    "loginwindow:login", "loginwindow:done"]
    XCTAssertEqual(AuthMechs.apply(to: existing),
                   ["loginwindow:login", "Crypt:Check,privileged", "loginwindow:done"])
  }

  /// Applying twice is a no-op, so an ensure on every check-in does not grow
  /// the list.
  func testIsIdempotent() {
    let once = AuthMechs.apply(to: ["loginwindow:done"])
    XCTAssertEqual(AuthMechs.apply(to: once), once)
  }

  func testRecognisesCorrectAndIncorrectDatabases() {
    XCTAssertTrue(AuthMechs.areCorrect(["Crypt:Check,privileged", "loginwindow:done"]))
    XCTAssertFalse(AuthMechs.areCorrect(["loginwindow:done", "Crypt:Check,privileged"]))
    XCTAssertFalse(AuthMechs.areCorrect(["loginwindow:done"]))
    XCTAssertFalse(AuthMechs.areCorrect([]))
  }
}
