import XCTest
@testable import CryptCore

/// Exercises the escrow request against a real HTTP server on loopback, so the
/// request the Crypt server would receive is asserted rather than assumed.
final class EscrowIntegrationTests: XCTestCase {
  func testSendsTheKeyAsAFormPostAndReadsTheRotationInstruction() async throws {
    let server = try TestHTTPServer(responses: [(status: 200, body: #"{"rotation_required": true}"#)])
    server.start()
    defer { server.stop() }

    let client = ServerClient(configuration: ServerConfiguration(url: server.baseURL))
    let response = try await client.escrow(CryptData(serialNumber: "EXAMPLE-SERIAL",
                                                     recoveryKey: "ABCD-EFGH",
                                                     enabledUser: "student"))

    XCTAssertTrue(response.rotationRequired)

    let request = try XCTUnwrap(server.requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/checkin/")
    XCTAssertEqual(request.headers["content-type"], "application/x-www-form-urlencoded")
    XCTAssertTrue(request.body.contains("serial=EXAMPLE-SERIAL"), request.body)
    XCTAssertTrue(request.body.contains("recovery_password=ABCD-EFGH"), request.body)
    XCTAssertTrue(request.body.contains("username=student"), request.body)
  }

  func testSendsTheAPIKeyHeaderWhenOneIsConfigured() async throws {
    let server = try TestHTTPServer(responses: [(status: 200, body: "{}")])
    server.start()
    defer { server.stop() }

    let configuration = ServerConfiguration(url: server.baseURL,
                                            apiKey: "a-token",
                                            apiKeyHeader: "X-Escrow-Token")
    _ = try await ServerClient(configuration: configuration).escrow(CryptData())

    XCTAssertEqual(server.requests.first?.headers["x-escrow-token"], "a-token")
  }

  /// A server that rejects the first attempt is retried, and the second answer
  /// is the one that counts.
  func testRetriesAfterAServerError() async throws {
    let server = try TestHTTPServer(responses: [
      (status: 500, body: "upstream is unwell"),
      (status: 200, body: #"{"rotation_required": false}"#),
    ])
    server.start()
    defer { server.stop() }

    let configuration = ServerConfiguration(url: server.baseURL, timeout: 5, retryAttempts: 2)
    let response = try await ServerClient(configuration: configuration).escrow(CryptData())

    XCTAssertFalse(response.rotationRequired)
    XCTAssertEqual(server.requests.count, 2)
  }

  /// When every attempt fails the error names the status, and the failure is
  /// reported rather than swallowed.
  func testGivesUpAfterTheConfiguredAttempts() async throws {
    let server = try TestHTTPServer(responses: [(status: 503, body: "unavailable")])
    server.start()
    defer { server.stop() }

    let configuration = ServerConfiguration(url: server.baseURL, timeout: 5, retryAttempts: 2)
    do {
      _ = try await ServerClient(configuration: configuration).escrow(CryptData())
      XCTFail("the escrow should have failed")
    } catch let error as CryptError {
      XCTAssertEqual(error.code, .escrowFailed)
      XCTAssertTrue(error.message.contains("503"), error.message)
    }
    XCTAssertEqual(server.requests.count, 2)
  }

  /// A server that answers with something other than JSON has still taken the
  /// key; only the rotation instruction is lost.
  func testTreatsANonJSONReplyAsSuccessWithoutRotation() async throws {
    let server = try TestHTTPServer(responses: [(status: 200, body: "<html>hello</html>")])
    server.start()
    defer { server.stop() }

    let response = try await ServerClient(configuration: ServerConfiguration(url: server.baseURL))
      .escrow(CryptData())
    XCTAssertFalse(response.rotationRequired)
  }
}
