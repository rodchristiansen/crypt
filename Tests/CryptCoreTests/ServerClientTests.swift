import XCTest
@testable import CryptCore

final class ServerClientTests: XCTestCase {
  func testFormEncodingIsDeterministicAndEscaped() {
    let encoded = ServerClient.formEncode([
      "serial": "EXAMPLE/SERIAL",
      "recovery_password": "ABCD-EFGH IJKL",
      "macname": "Studio Mac",
    ])
    XCTAssertEqual(encoded,
                   "macname=Studio%20Mac&recovery_password=ABCD-EFGH%20IJKL&serial=EXAMPLE%2FSERIAL")
  }

  /// A server URL written with or without a trailing slash reaches the same
  /// endpoint, which is what upstream pull request #124 asked for.
  func testCheckinURLTolerateseitherFormOfServerURL() throws {
    let withSlash = ServerConfiguration(url: try XCTUnwrap(URL(string: "https://crypt.example.com/")))
    let withoutSlash = ServerConfiguration(url: try XCTUnwrap(URL(string: "https://crypt.example.com")))
    XCTAssertEqual(withSlash.checkinURL.absoluteString, "https://crypt.example.com/checkin/")
    XCTAssertEqual(withoutSlash.checkinURL.absoluteString, "https://crypt.example.com/checkin/")
  }

  func testDecodesRotationInstruction() throws {
    let asked = try JSONDecoder().decode(CheckinResponse.self,
                                         from: Data(#"{"rotation_required": true}"#.utf8))
    XCTAssertTrue(asked.rotationRequired)

    // A server that says nothing about rotation is not asking for one.
    let silent = try JSONDecoder().decode(CheckinResponse.self, from: Data("{}".utf8))
    XCTAssertFalse(silent.rotationRequired)
  }
}
