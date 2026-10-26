import Foundation

/// How a connection is secured.
enum TransportSecurity: String, Codable, CaseIterable, Identifiable {
    case tls        // Implicit TLS from the first byte (IMAP 993, SMTP 465)
    case startTLS   // Plain connect, then upgrade (SMTP 587, IMAP 143)
    var id: String { rawValue }
    var label: String { self == .tls ? "SSL/TLS" : "STARTTLS" }
}

enum MailError: LocalizedError {
    case connectionClosed
    case timeout
    case protocolError(String)
    case authenticationFailed(String)
    case server(String)
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .connectionClosed: return "The server closed the connection."
        case .timeout: return "The server did not respond in time."
        case .protocolError(let s): return "Unexpected server response: \(s)"
        case .authenticationFailed(let s): return "Sign-in failed. \(s)"
        case .server(let s): return s
        case .notConfigured(let s): return s
        }
    }
}

/// A small line-oriented TCP client built on URLSessionStreamTask.
/// URLSessionStreamTask is used (rather than Network.framework) because it can
/// upgrade an existing plain connection to TLS, which STARTTLS requires.
/// Certificates are always validated by the system; there is no way to turn that off.
final class MailSocket {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: cfg)
    }()

    private let task: URLSessionStreamTask
    private var buffer = Data()
    private(set) var isSecure = false
    var readTimeout: TimeInterval = 60

    init(host: String, port: Int) {
        task = MailSocket.session.streamTask(withHostName: host, port: port)
    }

    func open(security: TransportSecurity) {
        task.resume()
        if security == .tls { upgradeToTLS() }
    }

    func upgradeToTLS() {
        task.startSecureConnection()
        isSecure = true
    }

    func close() {
        task.closeWrite()
        task.cancel()
    }

    // MARK: Writing

    func write(_ data: Data) async throws {
        try await task.write(data, timeout: 60)
    }

    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    // MARK: Reading

    private func fill() async throws {
        let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: readTimeout)
        if let data, !data.isEmpty {
            buffer.append(data)
        } else if eof {
            throw MailError.connectionClosed
        } else {
            throw MailError.timeout
        }
    }

    /// Reads one line including the trailing CRLF.
    func readLine() async throws -> Data {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<buffer.index(after: idx))
                buffer.removeSubrange(buffer.startIndex...idx)
                return line
            }
            try await fill()
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    /// Reads a line and returns it as a String without CRLF.
    func readStringLine() async throws -> String {
        let line = try await readLine()
        return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
