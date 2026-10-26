import Foundation

/// Sends mail over SMTP submission (RFC 6409) with TLS or STARTTLS.
final class SMTPClient {
    let host: String
    let port: Int
    let security: TransportSecurity

    init(host: String, port: Int, security: TransportSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    private struct Reply {
        let code: Int
        let lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    private func readReply(_ s: MailSocket) async throws -> Reply {
        var lines: [String] = []
        while true {
            let line = try await s.readStringLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else { throw MailError.protocolError(line) }
            lines.append(line.count > 4 ? String(line.dropFirst(4)) : "")
            let sep = line.count > 3 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
            if sep != "-" { return Reply(code: code, lines: lines) }
        }
    }

    @discardableResult
    private func command(_ s: MailSocket, _ text: String, expect: ClosedRange<Int> = 200...399) async throws -> Reply {
        try await s.write(text + "\r\n")
        let r = try await readReply(s)
        guard expect.contains(r.code) else { throw MailError.server("Send failed (\(r.code)): \(r.text)") }
        return r
    }

    /// Connects and signs in without sending anything (used when adding an account).
    func verify(auth: MailAuth) async throws {
        let s = MailSocket(host: host, port: port)
        s.readTimeout = 30
        s.open(security: security)
        defer { s.close() }
        _ = try await login(s, auth: auth)
        _ = try? await command(s, "QUIT")
    }

    /// Sends a fully-formed RFC 5322 message.
    func send(message: Data, from: String, recipients: [String], auth: MailAuth) async throws {
        let s = MailSocket(host: host, port: port)
        s.readTimeout = 60
        s.open(security: security)
        defer { s.close() }
        let caps = try await login(s, auth: auth)

        let utf8 = caps.contains { $0.hasPrefix("SMTPUTF8") }
        try await command(s, "MAIL FROM:<\(from)>" + (utf8 ? " SMTPUTF8" : ""), expect: 250...250)
        for r in recipients {
            try await command(s, "RCPT TO:<\(r)>", expect: 250...251)
        }
        try await command(s, "DATA", expect: 354...354)
        try await s.write(SMTPClient.dotStuff(message))
        try await command(s, ".", expect: 250...250)
        _ = try? await command(s, "QUIT")
    }

    /// Greeting, EHLO, STARTTLS and AUTH. Returns the EHLO capability lines.
    private func login(_ s: MailSocket, auth: MailAuth) async throws -> [String] {
        let greeting = try await readReply(s)
        guard greeting.code == 220 else { throw MailError.server(greeting.text) }

        var ehlo = try await command(s, "EHLO [127.0.0.1]")
        if security == .startTLS {
            try await command(s, "STARTTLS", expect: 220...220)
            s.upgradeToTLS()
            ehlo = try await command(s, "EHLO [127.0.0.1]")
        }
        let caps = ehlo.lines.map { $0.uppercased() }
        let authLine = caps.first { $0.hasPrefix("AUTH") } ?? ""

        do {
            switch auth {
            case .oauth(let user, let token):
                try await command(s, "AUTH XOAUTH2 " + MailAuth.xoauth2(user: user, token: token), expect: 235...235)
            case .password(let user, let password):
                if authLine.contains("PLAIN") || !authLine.contains("LOGIN") {
                    let token = Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
                    try await command(s, "AUTH PLAIN " + token, expect: 235...235)
                } else {
                    try await command(s, "AUTH LOGIN", expect: 334...334)
                    try await command(s, Data(user.utf8).base64EncodedString(), expect: 334...334)
                    try await command(s, Data(password.utf8).base64EncodedString(), expect: 235...235)
                }
            }
        } catch MailError.server(let msg) {
            throw MailError.authenticationFailed("The outgoing server rejected the sign-in. \(msg)")
        }
        return caps
    }

    /// Normalizes line endings to CRLF and escapes lines starting with ".".
    static func dotStuff(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 1024)
        var atLineStart = true
        var prev: UInt8 = 0
        for b in data {
            if b == 0x0A && prev != 0x0D { out.append(0x0D) }
            if atLineStart && b == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(b)
            atLineStart = (b == 0x0A)
            prev = b
        }
        if !(out.count >= 2 && out[out.count - 2] == 0x0D && out[out.count - 1] == 0x0A) {
            out.append(contentsOf: [0x0D, 0x0A])
        }
        return out
    }
}
