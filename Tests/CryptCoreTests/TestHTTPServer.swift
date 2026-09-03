import Foundation
import Network

/// A minimal HTTP server on the loopback interface, so the escrow client can be
/// exercised over a real socket rather than against a stubbed URLProtocol. It
/// understands only what these tests send: one request, headers, a body.
final class TestHTTPServer: @unchecked Sendable {
  struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: String
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "crypt.test.http")
  private let lock = NSLock()
  private var received: [Request] = []
  private var responses: [(status: Int, body: String)]

  var port: UInt16 { listener.port?.rawValue ?? 0 }

  var requests: [Request] {
    lock.withLock { received }
  }

  /// Replies with each response in turn; the last one repeats once exhausted.
  init(responses: [(status: Int, body: String)]) throws {
    self.responses = responses
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
  }

  func start() {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
  }

  func stop() {
    listener.cancel()
  }

  var baseURL: URL {
    URL(string: "http://127.0.0.1:\(port)")!
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
      guard let self else { return }
      var accumulated = buffer
      if let data { accumulated.append(data) }

      guard let request = Self.parse(accumulated) else {
        if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: accumulated) }
        return
      }

      self.lock.withLock { self.received.append(request) }
      let reply = self.lock.withLock { () -> (status: Int, body: String) in
        let next = self.responses.first ?? (status: 200, body: "{}")
        if self.responses.count > 1 { self.responses.removeFirst() }
        return next
      }
      connection.send(content: Self.encode(reply), completion: .contentProcessed { _ in
        connection.cancel()
      })
    }
  }

  /// Returns a request once the whole body named by Content-Length has arrived.
  private static func parse(_ data: Data) -> Request? {
    guard let text = String(data: data, encoding: .utf8),
          let headerEnd = text.range(of: "\r\n\r\n")
    else { return nil }

    let head = text[..<headerEnd.lowerBound]
    var lines = head.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }
    let requestLine = lines.removeFirst().components(separatedBy: " ")
    guard requestLine.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      headers[name.lowercased()] = value
    }

    let body = String(text[headerEnd.upperBound...])
    let expected = Int(headers["content-length"] ?? "0") ?? 0
    guard body.utf8.count >= expected else { return nil }

    return Request(method: requestLine[0], path: requestLine[1], headers: headers, body: body)
  }

  private static func encode(_ reply: (status: Int, body: String)) -> Data {
    let head = """
      HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Error")\r
      Content-Type: application/json\r
      Content-Length: \(reply.body.utf8.count)\r
      Connection: close\r
      \r

      """
    return Data(head.utf8) + Data(reply.body.utf8)
  }
}
