/*
 Crypt

 Copyright 2025 The Crypt Project.

 Licensed under the Apache License, Version 2.0 (the "License").
 See LICENSE for the full text.
 */
import Foundation
import Security

/// What the Crypt server says in reply to a check-in.
public struct CheckinResponse: Decodable, Sendable {
  public let rotationRequired: Bool

  enum CodingKeys: String, CodingKey {
    case rotationRequired = "rotation_required"
  }

  public init(rotationRequired: Bool) {
    self.rotationRequired = rotationRequired
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rotationRequired = try container.decodeIfPresent(Bool.self, forKey: .rotationRequired) ?? false
  }
}

/// How the client reaches the Crypt server. Assembled from preferences by
/// `ServerConfiguration.fromPreferences()` so the transport has no opinion
/// about where its settings come from.
public struct ServerConfiguration: Sendable {
  public var url: URL
  public var timeout: TimeInterval
  public var retryAttempts: Int
  public var apiKey: String?
  public var apiKeyHeader: String
  public var clientCertificateCommonName: String?

  public init(url: URL, timeout: TimeInterval = 30, retryAttempts: Int = 3,
              apiKey: String? = nil, apiKeyHeader: String = "X-API-Key",
              clientCertificateCommonName: String? = nil) {
    self.url = url
    self.timeout = timeout
    self.retryAttempts = retryAttempts
    self.apiKey = apiKey
    self.apiKeyHeader = apiKeyHeader
    self.clientCertificateCommonName = clientCertificateCommonName
  }

  /// The check-in endpoint, tolerating a server URL written with or without a
  /// trailing slash.
  public var checkinURL: URL {
    var text = url.absoluteString
    if !text.hasSuffix("/") { text += "/" }
    return URL(string: text + "checkin/") ?? url
  }

  public static func fromPreferences() throws -> ServerConfiguration {
    let serverURL = prefString(.ServerURL).trimmingCharacters(in: .whitespaces)
    guard !serverURL.isEmpty, let url = URL(string: serverURL), url.scheme != nil else {
      throw CryptError(.configurationError, "ServerURL is not set to a usable URL")
    }
    let commonName = prefString(.CommonNameForEscrow)
    let apiKey = prefString(.APIKey)
    return ServerConfiguration(
      url: url,
      timeout: TimeInterval(max(prefInt(.ServerTimeout), 1)),
      retryAttempts: max(prefInt(.ServerRetryAttempts), 1),
      apiKey: apiKey.isEmpty ? nil : apiKey,
      apiKeyHeader: prefString(.APIKeyHeader).isEmpty ? "X-API-Key" : prefString(.APIKeyHeader),
      clientCertificateCommonName: commonName.isEmpty ? nil : commonName
    )
  }
}

/// Posts recovery keys to the Crypt server over URLSession. This replaces the
/// previous approach of writing a curl configuration file and shelling out to
/// /usr/bin/curl, so timeouts, retries and client certificates are handled in
/// process and the key never passes through an argument or a temporary file.
public struct ServerClient: Sendable {
  let configuration: ServerConfiguration

  public init(configuration: ServerConfiguration) {
    self.configuration = configuration
  }

  /// Escrows a key and returns what the server asked the client to do next.
  public func escrow(_ data: CryptData) async throws -> CheckinResponse {
    let fields = [
      "serial": data.serialNumber,
      "recovery_password": data.recoveryKey,
      "username": data.enabledUser,
      "macname": DeviceInfo.computerName,
    ]
    let body = try await post(form: fields)
    guard let response = try? JSONDecoder().decode(CheckinResponse.self, from: body) else {
      // A server that answers with something other than JSON has still accepted
      // the key; only the rotation instruction is lost.
      cryptLog(.warning, serverLog, "Server reply was not JSON, assuming no rotation was requested")
      return CheckinResponse(rotationRequired: false)
    }
    return response
  }

  func post(form fields: [String: String]) async throws -> Data {
    var request = URLRequest(url: configuration.checkinURL, timeoutInterval: configuration.timeout)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    if let apiKey = configuration.apiKey {
      request.setValue(apiKey, forHTTPHeaderField: configuration.apiKeyHeader)
    }
    request.httpBody = Data(Self.formEncode(fields).utf8)

    let session = try makeSession()
    defer { session.finishTasksAndInvalidate() }

    var lastError: Error = CryptError(.serverUnreachable, "no attempt was made")
    for attempt in 1...configuration.retryAttempts {
      do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw CryptError(.escrowFailed, "server did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
          let detail = String(data: data, encoding: .utf8) ?? ""
          throw CryptError(.escrowFailed, "server returned \(http.statusCode): \(detail.prefix(200))")
        }
        return data
      } catch {
        lastError = error
        if attempt < configuration.retryAttempts {
          cryptLog(.warning, serverLog, "Escrow attempt \(attempt) failed (\(error)), retrying")
          try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }
      }
    }
    throw lastError
  }

  func makeSession() throws -> URLSession {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
    sessionConfiguration.timeoutIntervalForResource = configuration.timeout * Double(configuration.retryAttempts)
    sessionConfiguration.httpCookieStorage = nil

    guard let commonName = configuration.clientCertificateCommonName else {
      return URLSession(configuration: sessionConfiguration)
    }
    let identity = try ClientCertificate.identity(commonName: commonName)
    cryptLog(.info, serverLog, "Using mutual TLS with the certificate for \(commonName)")
    let delegate = ClientCertificateDelegate(identity: identity)
    return URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
  }

  /// Percent-encodes a form body. Sorted so the encoding is deterministic and
  /// can be asserted in a test.
  static func formEncode(_ fields: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.sorted { $0.key < $1.key }.map { key, value in
      let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
  }
}

/// Finds the client identity used for mutual TLS. The private key stays in the
/// keychain; only a reference to it is handed to URLSession.
public enum ClientCertificate {
  public static func identity(commonName: String) throws -> SecIdentity {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecReturnRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
      throw CryptError(.configurationError,
                       "no client identities are available for mutual TLS (\(status))")
    }
    for identity in identities {
      var certificate: SecCertificate?
      guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
            let certificate else { continue }
      var name: CFString?
      guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess,
            let found = name as String? else { continue }
      if found == commonName { return identity }
    }
    throw CryptError(.configurationError,
                     "no client certificate with the common name \(commonName) was found")
  }
}

/// Answers the server's certificate request with the configured identity.
final class ClientCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  let identity: SecIdentity

  init(identity: SecIdentity) {
    self.identity = identity
  }

  func urlSession(_ session: URLSession,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    completionHandler(.useCredential, credential)
  }
}
