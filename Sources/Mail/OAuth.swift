import Foundation
import Network
import CryptoKit
import AppKit

/// OAuth 2.0 provider description (authorization code + PKCE, loopback redirect, RFC 8252).
struct OAuthProvider {
    let id: String
    let authorizeURL: String
    let tokenURL: String
    let scope: String
    let redirectHost: String
    let extraParams: [String: String]

    static let microsoft = OAuthProvider(
        id: "microsoft",
        authorizeURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        scope: "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access",
        redirectHost: "localhost",
        extraParams: ["prompt": "select_account"])

    static let google = OAuthProvider(
        id: "google",
        authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenURL: "https://oauth2.googleapis.com/token",
        scope: "https://mail.google.com/",
        redirectHost: "127.0.0.1",
        extraParams: ["access_type": "offline", "prompt": "consent"])

    static func named(_ id: String) -> OAuthProvider? {
        switch id {
        case "microsoft": return .microsoft
        case "google": return .google
        default: return nil
        }
    }

    /// Client credentials the user registered for their own copy of Tidings.
    var clientID: String {
        UserDefaults.standard.string(forKey: "oauth.\(id).clientID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    var clientSecret: String {
        UserDefaults.standard.string(forKey: "oauth.\(id).clientSecret")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

enum OAuthError: LocalizedError {
    case missingClientID(String)
    case cancelled
    case denied(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID(let p): return "No \(p) Client ID is set. Add it in Settings → Advanced first (see the README for the 3-minute setup)."
        case .cancelled: return "Sign-in was cancelled."
        case .denied(let s): return "Sign-in was declined: \(s)"
        case .badResponse(let s): return "Unexpected response from the sign-in server: \(s)"
        }
    }
}

enum OAuthFlow {
    /// Opens the browser, waits for the redirect and exchanges the code for tokens.
    static func authorize(provider: OAuthProvider, loginHint: String) async throws -> OAuthTokens {
        guard !provider.clientID.isEmpty else {
            throw OAuthError.missingClientID(provider.id == "microsoft" ? "Microsoft" : "Google")
        }
        let verifier = randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomURLSafe(24)

        let server = LoopbackServer()
        let port = try await server.start()
        let redirect = "http://\(provider.redirectHost):\(port)/"

        var comps = URLComponents(string: provider.authorizeURL)!
        var items = [
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: provider.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "login_hint", value: loginHint),
        ]
        for (k, v) in provider.extraParams { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        await MainActor.run { _ = NSWorkspace.shared.open(comps.url!) }

        let query = try await server.waitForRedirect(timeout: 300)
        server.stop()
        if let err = query["error"] { throw OAuthError.denied(query["error_description"] ?? err) }
        guard query["state"] == state, let code = query["code"] else { throw OAuthError.badResponse("missing code") }

        var form = [
            "client_id": provider.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ]
        if !provider.clientSecret.isEmpty { form["client_secret"] = provider.clientSecret }
        if provider.id == "microsoft" { form["scope"] = provider.scope }
        return try await tokenRequest(provider: provider, form: form, previousRefresh: nil)
    }

    static func refresh(provider: OAuthProvider, refreshToken: String) async throws -> OAuthTokens {
        var form = [
            "client_id": provider.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if !provider.clientSecret.isEmpty { form["client_secret"] = provider.clientSecret }
        if provider.id == "microsoft" { form["scope"] = provider.scope }
        return try await tokenRequest(provider: provider, form: form, previousRefresh: refreshToken)
    }

    private static func tokenRequest(provider: OAuthProvider, form: [String: String], previousRefresh: String?) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: provider.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let err = json["error"] as? String {
            throw OAuthError.denied((json["error_description"] as? String) ?? err)
        }
        guard let access = json["access_token"] as? String else { throw OAuthError.badResponse("no access token") }
        let refresh = (json["refresh_token"] as? String) ?? previousRefresh ?? ""
        let expires = (json["expires_in"] as? Double) ?? Double((json["expires_in"] as? String) ?? "3600") ?? 3600
        return OAuthTokens(accessToken: access, refreshToken: refresh, expiry: Date().addingTimeInterval(expires - 120))
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var d = Data(count: bytes)
        d.withUnsafeMutableBytes { buf in
            for i in 0..<bytes { buf[i] = UInt8.random(in: 0...255) }
        }
        return d.base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP server on the loopback interface that captures the OAuth redirect.
final class LoopbackServer {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let queue = DispatchQueue(label: "tidings.oauth.loopback")
    private var finished = false
    private var pending: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let p = self.pending { self.pending = nil; self.finished = true; cont.resume(with: p); return }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(OAuthError.cancelled))
                }
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        guard let c = continuation else { pending = result; return }
        finished = true
        continuation = nil
        c.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            var query: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://localhost" + parts[1]) {
                for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            let isCallback = query["code"] != nil || query["error"] != nil
            let body = isCallback
                ? "<html><body style='font:15px -apple-system;text-align:center;padding-top:80px'><h2>You're signed in to Tidings.</h2><p>You can close this tab and return to the app.</p></body></html>"
                : "<html><body></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback { self.finish(.success(query)) }
        }
    }
}
