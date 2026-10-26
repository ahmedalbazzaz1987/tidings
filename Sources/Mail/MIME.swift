import Foundation

// MARK: - Addresses

struct MailAddress: Codable, Hashable, Identifiable {
    var name: String
    var email: String
    var id: String { email.lowercased() }

    var displayName: String { name.isEmpty ? email : name }

    /// RFC 5322 form with the display name encoded when needed.
    var encoded: String {
        guard !name.isEmpty else { return email }
        return "\(MIMEEncoding.encodePhrase(name)) <\(email)>"
    }

    var initials: String {
        let source = name.isEmpty ? email : name
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.joined().isEmpty ? "?" : letters.joined()
    }

    /// Parses a header value such as `"Doe, John" <john@x.com>, jane@y.org`.
    static func parseList(_ raw: String) -> [MailAddress] {
        var out: [MailAddress] = []
        var current = ""
        var inQuote = false
        var angle = 0
        var paren = 0
        for ch in raw {
            if ch == "\"" && paren == 0 { inQuote.toggle() }
            if !inQuote {
                if ch == "<" { angle += 1 }
                if ch == ">" { angle = max(0, angle - 1) }
                if ch == "(" { paren += 1 }
                if ch == ")" { paren = max(0, paren - 1) }
                if (ch == "," || ch == ";") && angle == 0 && paren == 0 {
                    if let a = parseOne(current) { out.append(a) }
                    current = ""
                    continue
                }
                if ch == ":" && angle == 0 && paren == 0 && !current.contains("@") {
                    current = "" // group name "Friends: a@b, c@d;"
                    continue
                }
            }
            current.append(ch)
        }
        if let a = parseOne(current) { out.append(a) }
        return out
    }

    static func parseOne(_ raw: String) -> MailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let lt = s.lastIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            name = MIMEEncoding.decodeWords(name)
            guard email.contains("@") else { return nil }
            return MailAddress(name: name, email: email)
        }
        // bare address, possibly with a (comment) name
        var email = s
        var name = ""
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            name = MIMEEncoding.decodeWords(String(s[s.index(after: open)..<close]))
            email = String(s[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard email.contains("@") else { return nil }
        return MailAddress(name: name, email: email)
    }

    static func isValidEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !s.contains(" ")
    }
}

// MARK: - Encoding helpers

enum MIMEEncoding {
    static func stringEncoding(forCharset charset: String?) -> String.Encoding {
        guard var cs = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased(), !cs.isEmpty else { return .utf8 }
        if cs == "utf8" { cs = "utf-8" }
        if cs == "ks_c_5601-1987" { cs = "euc-kr" }
        if cs == "gb2312" { cs = "gbk" }
        let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
        if cf == kCFStringEncodingInvalidId { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func decodeText(_ data: Data, charset: String?) -> String {
        let enc = stringEncoding(forCharset: charset)
        if let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeQuotedPrintable(_ data: Data, header: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }                 // soft break (LF)
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue } // soft break (CRLF)
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l); i += 3; continue
                }
                if i + 1 >= bytes.count { i += 1; continue } // trailing "=" in truncated data
            }
            if header && b == UInt8(ascii: "_") { out.append(0x20); i += 1; continue }
            out.append(b); i += 1
        }
        return Data(out)
    }

    static func decodeBase64(_ data: Data) -> Data {
        var cleaned = [UInt8]()
        cleaned.reserveCapacity(data.count)
        for b in data {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, UInt8(ascii: "+"), UInt8(ascii: "/"): cleaned.append(b)
            default: continue
            }
        }
        // tolerate truncated input (summaries only fetch the first few KB)
        let usable = cleaned.count - cleaned.count % 4
        var chunk = Array(cleaned[0..<usable])
        let rem = cleaned.count % 4
        if rem >= 2 {
            chunk.append(contentsOf: cleaned[usable...])
            chunk.append(contentsOf: Array(repeating: UInt8(ascii: "="), count: 4 - rem))
        }
        return Data(base64Encoded: Data(chunk)) ?? Data()
    }

    /// Decodes RFC 2047 encoded-words: =?charset?B?...?= / =?charset?Q?...?=
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var result = ""
        var rest = Substring(s)
        var lastWasEncoded = false
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            let afterStart = rest[start.upperBound...]
            // charset?enc?text?=
            guard let q1 = afterStart.firstIndex(of: "?") else { break }
            let charsetPart = afterStart[..<q1]
            let afterQ1 = afterStart[afterStart.index(after: q1)...]
            guard let q2 = afterQ1.firstIndex(of: "?") else { break }
            let enc = afterQ1[..<q2].uppercased()
            let afterQ2 = afterQ1[afterQ1.index(after: q2)...]
            guard let end = afterQ2.range(of: "?=") else { break }
            let text = afterQ2[..<end.lowerBound]

            if !(lastWasEncoded && before.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })) {
                result += before
            }
            let charset = charsetPart.split(separator: "*").first.map(String.init) // strip RFC 2231 language
            let raw = Data(text.utf8)
            let bytes: Data
            if enc == "B" { bytes = decodeBase64(raw) }
            else if enc == "Q" { bytes = decodeQuotedPrintable(raw, header: true) }
            else { bytes = raw }
            result += decodeText(bytes, charset: charset)
            lastWasEncoded = true
            rest = afterQ2[end.upperBound...]
        }
        result += rest
        return result
    }

    /// Encodes a header value only when it contains non-ASCII characters.
    static func encodeHeader(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return s }
        // split into chunks so each encoded word stays under 75 chars
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if (chunk + String(ch)).utf8.count > 42 {
                words.append(chunk); chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func encodePhrase(_ s: String) -> String {
        if !s.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return encodeHeader(s) }
        let special = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if s.rangeOfCharacter(from: special) != nil {
            return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return s
    }

    static func encodeQuotedPrintable(_ text: String) -> String {
        var out = ""
        var lineLen = 0
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (li, line) in lines.enumerated() {
            let bytes = Array(line.utf8)
            for (bi, b) in bytes.enumerated() {
                var piece: String
                let isLast = bi == bytes.count - 1
                if (b >= 33 && b <= 126 && b != 61) || (b == 32 && !isLast) || (b == 9 && !isLast) {
                    piece = String(UnicodeScalar(b))
                } else {
                    piece = String(format: "=%02X", b)
                }
                if lineLen + piece.count > 75 {
                    out += "=\r\n"; lineLen = 0
                }
                out += piece
                lineLen += piece.count
            }
            if li < lines.count - 1 { out += "\r\n"; lineLen = 0 }
        }
        return out
    }
}

// MARK: - Headers

struct MIMEHeaders {
    private(set) var fields: [(name: String, value: String)] = []

    init(raw: Data) {
        let text = String(decoding: raw, as: UTF8.self).contains("\u{FFFD}")
            ? (String(data: raw, encoding: .isoLatin1) ?? "")
            : String(decoding: raw, as: UTF8.self)
        var current: (String, String)?
        for line in text.components(separatedBy: "\n") {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if l.isEmpty { continue }
            if l.first == " " || l.first == "\t" {
                if current != nil { current!.1 += " " + l.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if let c = current { fields.append((c.0, c.1)) }
            if let colon = l.firstIndex(of: ":") {
                current = (String(l[..<colon]).trimmingCharacters(in: .whitespaces),
                           String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            } else {
                current = nil
            }
        }
        if let c = current { fields.append((c.0, c.1)) }
    }

    func raw(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    func decoded(_ name: String) -> String? {
        raw(name).map { MIMEEncoding.decodeWords($0) }
    }

    func addresses(_ name: String) -> [MailAddress] {
        all(name).flatMap { MailAddress.parseList($0) }
    }

    var date: Date? { raw("Date").flatMap(MIMEDate.parse) }
}

/// "type/subtype; key=value; ..." parsing with RFC 2231 support.
struct HeaderValue {
    let value: String
    let params: [String: String]

    init(_ raw: String?) {
        guard let raw else { value = ""; params = [:]; return }
        var parts: [String] = []
        var cur = ""
        var inQuote = false
        for ch in raw {
            if ch == "\"" { inQuote.toggle() }
            if ch == ";" && !inQuote { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur)
        value = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var p: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            var extended = false
            if key.hasSuffix("*") { extended = true; key.removeLast() }
            if let star = key.firstIndex(of: "*"), let idx = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: []].append((idx, val, extended))
                continue
            }
            p[key] = extended ? HeaderValue.decode2231(val, first: true, charset: nil).0 : MIMEEncoding.decodeWords(val)
        }
        for (base, pieces) in continuations {
            var charset: String?
            var joinedBytes = Data()
            for (i, piece) in pieces.sorted(by: { $0.0 < $1.0 }).enumerated() {
                if piece.2 {
                    let (_, cs, bytes) = HeaderValue.decode2231Bytes(piece.1, first: i == 0)
                    if i == 0 { charset = cs }
                    joinedBytes.append(bytes)
                } else {
                    joinedBytes.append(Data(piece.1.utf8))
                }
            }
            p[base] = MIMEEncoding.decodeText(joinedBytes, charset: charset ?? "utf-8")
        }
        params = p
    }

    static func decode2231(_ s: String, first: Bool, charset: String?) -> (String, String?) {
        let (_, cs, bytes) = decode2231Bytes(s, first: first)
        return (MIMEEncoding.decodeText(bytes, charset: cs ?? charset ?? "utf-8"), cs)
    }

    static func decode2231Bytes(_ s: String, first: Bool) -> (String, String?, Data) {
        var value = s
        var charset: String?
        if first {
            let comps = s.components(separatedBy: "'")
            if comps.count >= 3 {
                charset = comps[0].isEmpty ? nil : comps[0]
                value = comps[2...].joined(separator: "'")
            }
        }
        var out = Data()
        var i = value.startIndex
        while i < value.endIndex {
            let c = value[i]
            if c == "%", let n1 = value.index(i, offsetBy: 1, limitedBy: value.endIndex), n1 < value.endIndex,
               let n2 = value.index(i, offsetBy: 2, limitedBy: value.endIndex), n2 < value.endIndex,
               let byte = UInt8(String(value[n1...n2]), radix: 16) {
                out.append(byte)
                i = value.index(i, offsetBy: 3)
            } else {
                out.append(contentsOf: Array(String(c).utf8))
                i = value.index(after: i)
            }
        }
        return (value, charset, out)
    }
}

// MARK: - Dates

enum MIMEDate {
    private static let formatters: [DateFormatter] = {
        let fmts = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yy HH:mm:ss Z",
        ]
        return fmts.map { f in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            return df
        }
    }()

    static func parse(_ raw: String) -> Date? {
        var s = raw
        // drop comments like "(UTC)" and extra whitespace
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.removeSubrange(open...close)
        }
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    static func format(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return df.string(from: date)
    }
}

// MARK: - Parts

struct MailAttachment: Identifiable, Hashable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var contentID: String?
    var isInline: Bool

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
}

final class MIMEPart {
    let headers: MIMEHeaders
    let contentType: HeaderValue
    let disposition: HeaderValue
    var body: Data            // transfer-decoded
    var children: [MIMEPart] = []

    init(data: Data) {
        let (h, b) = MIMEPart.splitHeaderBody(data)
        let hdrs = MIMEHeaders(raw: h)
        let ct = HeaderValue(hdrs.raw("Content-Type") ?? "text/plain; charset=us-ascii")
        let disp = HeaderValue(hdrs.raw("Content-Disposition"))
        var decoded = Data()
        var kids: [MIMEPart] = []
        if ct.value.hasPrefix("multipart/"), let boundary = ct.params["boundary"] {
            kids = MIMEPart.splitMultipart(b, boundary: boundary).map { MIMEPart(data: $0) }
        } else if ct.value == "message/rfc822" && disp.value != "attachment" {
            kids = [MIMEPart(data: b)]
            decoded = b
        } else {
            let cte = (hdrs.raw("Content-Transfer-Encoding") ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            switch cte {
            case "base64": decoded = MIMEEncoding.decodeBase64(b)
            case "quoted-printable": decoded = MIMEEncoding.decodeQuotedPrintable(b)
            default: decoded = b
            }
        }
        headers = hdrs
        contentType = ct
        disposition = disp
        body = decoded
        children = kids
    }

    var charset: String? { contentType.params["charset"] }
    var text: String { MIMEEncoding.decodeText(body, charset: charset) }

    var filename: String? {
        disposition.params["filename"] ?? contentType.params["name"]
    }

    var contentID: String? {
        headers.raw("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    var isAttachment: Bool {
        if disposition.value == "attachment" { return true }
        if contentType.value.hasPrefix("text/") && filename == nil { return false }
        if contentType.value.hasPrefix("multipart/") { return false }
        return filename != nil || contentID != nil || !contentType.value.hasPrefix("text/")
    }

    static func splitHeaderBody(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var i = 0
        // A part with no headers starts with a blank line.
        if bytes.first == 0x0A { return (Data(), Data(bytes[1...])) }
        if bytes.count >= 2, bytes[0] == 0x0D, bytes[1] == 0x0A { return (Data(), Data(bytes[2...])) }
        while i + 1 < bytes.count {
            if bytes[i] == 0x0A {
                if bytes[i + 1] == 0x0A { return (Data(bytes[..<i]), Data(bytes[(i + 2)...])) }
                if bytes[i + 1] == 0x0D, i + 2 < bytes.count, bytes[i + 2] == 0x0A {
                    return (Data(bytes[..<i]), Data(bytes[(i + 3)...]))
                }
            }
            i += 1
        }
        return (data, Data())
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = [UInt8](("--" + boundary).utf8)
        let bytes = [UInt8](body)
        var parts: [Data] = []
        var positions: [(start: Int, lineEnd: Int, isFinal: Bool)] = []
        var i = 0
        while i + delimiter.count <= bytes.count {
            // delimiter must be at the start of a line
            let atLineStart = i == 0 || bytes[i - 1] == 0x0A
            if atLineStart && bytes[i] == 0x2D && Array(bytes[i..<(i + delimiter.count)]) == delimiter {
                let after = i + delimiter.count
                let isFinal = after + 1 < bytes.count && bytes[after] == 0x2D && bytes[after + 1] == 0x2D
                var lineEnd = after
                while lineEnd < bytes.count && bytes[lineEnd] != 0x0A { lineEnd += 1 }
                positions.append((i, min(lineEnd + 1, bytes.count), isFinal))
                i = lineEnd + 1
                if isFinal { break }
                continue
            }
            // jump to next line
            while i < bytes.count && bytes[i] != 0x0A { i += 1 }
            i += 1
        }
        for (idx, p) in positions.enumerated() where !p.isFinal {
            let start = p.lineEnd
            var end = idx + 1 < positions.count ? positions[idx + 1].start : bytes.count
            // remove the CRLF that belongs to the next delimiter
            if end > start && end <= bytes.count && end - 1 >= 0 && bytes[end - 1] == 0x0A { end -= 1 }
            if end > start && bytes[end - 1] == 0x0D { end -= 1 }
            if end > start { parts.append(Data(bytes[start..<end])) } else { parts.append(Data()) }
        }
        return parts
    }

    /// Depth-first walk.
    func walk(_ visit: (MIMEPart) -> Void) {
        visit(self)
        for c in children { c.walk(visit) }
    }
}

// MARK: - Whole message

struct ParsedMessage {
    var subject: String
    var from: [MailAddress]
    var to: [MailAddress]
    var cc: [MailAddress]
    var replyTo: [MailAddress]
    var date: Date?
    var messageID: String?
    var inReplyTo: String?
    var references: [String]
    var textBody: String?
    var htmlBody: String?
    var attachments: [MailAttachment]
    var listUnsubscribe: String?
    /// Topmost Authentication-Results header (added by your own mail provider).
    var authenticationResults: String

    init(data: Data) {
        let root = MIMEPart(data: data)
        let h = root.headers
        subject = h.decoded("Subject") ?? ""
        from = h.addresses("From")
        to = h.addresses("To")
        cc = h.addresses("Cc")
        replyTo = h.addresses("Reply-To")
        date = h.date
        messageID = h.raw("Message-ID")?.trimmingCharacters(in: .whitespaces)
        inReplyTo = h.raw("In-Reply-To")?.trimmingCharacters(in: .whitespaces)
        references = (h.raw("References") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        listUnsubscribe = h.raw("List-Unsubscribe")
        authenticationResults = h.raw("Authentication-Results") ?? ""

        var text: String?
        var html: String?
        var atts: [MailAttachment] = []
        ParsedMessage.collect(root, text: &text, html: &html, attachments: &atts)
        textBody = text
        htmlBody = html
        attachments = atts
    }

    private static func collect(_ part: MIMEPart, text: inout String?, html: inout String?, attachments: inout [MailAttachment]) {
        let type = part.contentType.value
        if type == "multipart/alternative" {
            // prefer the richest alternative, but still take plain text if present
            for c in part.children { collect(c, text: &text, html: &html, attachments: &attachments) }
            return
        }
        if type.hasPrefix("multipart/") || (type == "message/rfc822" && !part.children.isEmpty && part.disposition.value != "attachment") {
            for c in part.children { collect(c, text: &text, html: &html, attachments: &attachments) }
            return
        }
        if part.isAttachment {
            var name = part.filename ?? ""
            if name.isEmpty {
                let ext = type.split(separator: "/").last.map(String.init) ?? "bin"
                name = "attachment.\(ext)"
            }
            attachments.append(MailAttachment(filename: name, mimeType: type, data: part.body,
                                              contentID: part.contentID,
                                              isInline: part.disposition.value == "inline" && part.contentID != nil))
            return
        }
        if type == "text/html" {
            html = (html ?? "") + part.text
        } else if type.hasPrefix("text/") {
            text = (text.map { $0 + "\n\n" } ?? "") + part.text
        }
    }

    /// First meaningful characters for list previews.
    var snippet: String {
        let source = textBody ?? htmlBody.map(HTMLText.plainText) ?? ""
        return ParsedMessage.makeSnippet(source)
    }

    static func makeSnippet(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines).filter { !$0.hasPrefix(">") }
        let joined = lines.joined(separator: " ")
        let collapsed = joined.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
        return String(collapsed.prefix(220))
    }
}

enum HTMLText {
    static func plainText(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head", "title"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>|</li>|</h[1-6]>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&zwnj;": "", "&#8203;": ""]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        s = s.replacingOccurrences(of: "&#(\\d+);", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Plain text → safe HTML with clickable links.
    static func htmlFromPlain(_ text: String) -> String {
        var esc = escape(text)
        esc = esc.replacingOccurrences(of: "(https?://[^\\s<]+)", with: "<a href=\"$1\">$1</a>", options: .regularExpression)
        let lines = esc.components(separatedBy: "\n").map { line -> String in
            line.hasPrefix("&gt;") ? "<span class=\"quote\">\(line)</span>" : line
        }
        return "<div class=\"plain\">" + lines.joined(separator: "<br>") + "</div>"
    }
}
