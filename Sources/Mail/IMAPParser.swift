import Foundation

/// A parsed IMAP data item.
indirect enum IMAPValue: CustomStringConvertible {
    case atom(String)
    case string(Data)      // quoted string or literal
    case list([IMAPValue])
    case nilValue

    var description: String {
        switch self {
        case .atom(let s): return s
        case .string(let d): return "\"\(String(decoding: d, as: UTF8.self))\""
        case .list(let l): return "(" + l.map(\.description).joined(separator: " ") + ")"
        case .nilValue: return "NIL"
        }
    }

    /// Text form of an atom or string.
    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let s): return Data(s.utf8)
        default: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    var int: Int? { text.flatMap { Int($0) } }
}

/// One complete server response (all literals already read and inlined).
struct IMAPResponse {
    enum Kind { case untagged, tagged(String), continuation }
    let kind: Kind
    let raw: Data

    var line: String { String(decoding: raw, as: UTF8.self) }

    /// For tagged or status responses: OK / NO / BAD / BYE / PREAUTH.
    var status: String? {
        let tokens = headTokens(3)
        switch kind {
        case .tagged: return tokens.count > 1 ? tokens[1].uppercased() : nil
        case .untagged: return tokens.count > 1 ? tokens[1].uppercased() : nil
        case .continuation: return nil
        }
    }

    /// Human text after the status word (response code stripped).
    var statusText: String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        s = parts.count > 2 ? String(parts[2]) : ""
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {
            s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// The bracketed response code, e.g. "UIDVALIDITY 123".
    var responseCode: String? {
        let s = line
        guard let open = s.firstIndex(of: "["), let close = s[open...].firstIndex(of: "]") else { return nil }
        return String(s[s.index(after: open)..<close])
    }

    private func headTokens(_ n: Int) -> [String] {
        let firstLine = line.split(separator: "\r", maxSplits: 1).first.map(String.init) ?? line
        return firstLine.split(separator: " ", maxSplits: n, omittingEmptySubsequences: true).map(String.init)
    }

    /// Parses the payload of an untagged response into values ("*" removed).
    func values() -> [IMAPValue] {
        var p = IMAPTokenizer(raw)
        // skip "*" or tag
        _ = p.nextValue()
        var out: [IMAPValue] = []
        while let v = p.nextValue() { out.append(v) }
        return out
    }
}

/// Tokenizes raw IMAP wire bytes. Literals appear in the buffer exactly as on the
/// wire: "{n}\r\n" followed by n bytes.
struct IMAPTokenizer {
    private let bytes: [UInt8]
    private var i = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    private mutating func skipSpaces() {
        while i < bytes.count, bytes[i] == 0x20 { i += 1 }
    }

    var atEnd: Bool {
        var j = i
        while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x0D || bytes[j] == 0x0A { j += 1 }
        return j >= bytes.count
    }

    mutating func nextValue() -> IMAPValue? {
        skipSpaces()
        while i < bytes.count, bytes[i] == 0x0D || bytes[i] == 0x0A { i += 1; skipSpaces() }
        guard i < bytes.count else { return nil }
        let c = bytes[i]
        switch c {
        case UInt8(ascii: "("):
            i += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard i < bytes.count else { break }
                if bytes[i] == UInt8(ascii: ")") { i += 1; break }
                if bytes[i] == 0x0D || bytes[i] == 0x0A { i += 1; continue }
                guard let v = nextValue() else { break }
                items.append(v)
            }
            return .list(items)
        case UInt8(ascii: ")"):
            i += 1
            return nextValue()
        case UInt8(ascii: "\""):
            i += 1
            var out = [UInt8]()
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\\"), i + 1 < bytes.count {
                    out.append(bytes[i + 1]); i += 2; continue
                }
                if b == UInt8(ascii: "\"") { i += 1; break }
                out.append(b); i += 1
            }
            return .string(Data(out))
        case UInt8(ascii: "{"):
            let start = i
            i += 1
            var n = 0
            var ok = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 0x30 && b <= 0x39 { n = n * 10 + Int(b - 0x30); i += 1; continue }
                if b == UInt8(ascii: "+") { i += 1; continue }
                if b == UInt8(ascii: "}") { i += 1; ok = true }
                break
            }
            if ok {
                if i < bytes.count, bytes[i] == 0x0D { i += 1 }
                if i < bytes.count, bytes[i] == 0x0A { i += 1 }
                let end = min(bytes.count, i + n)
                let d = Data(bytes[i..<end])
                i = end
                return .string(d)
            }
            i = start + 1
            return .atom("{")
        default:
            var out = [UInt8]()
            var bracket = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "[") { bracket += 1 }
                if b == UInt8(ascii: "]") { bracket = max(0, bracket - 1) }
                if bracket == 0 {
                    if b == 0x20 || b == UInt8(ascii: "(") || b == UInt8(ascii: ")") || b == 0x0D || b == 0x0A { break }
                    if b == UInt8(ascii: "\"") || b == UInt8(ascii: "{") { break }
                } else if b == 0x0D || b == 0x0A {
                    break
                }
                out.append(b); i += 1
            }
            if out.isEmpty { i += 1; return nextValue() }
            // "<n>" partial suffixes are part of the atom (BODY[TEXT]<0>)
            let s = String(decoding: out, as: UTF8.self)
            if s.uppercased() == "NIL" { return .nilValue }
            return .atom(s)
        }
    }
}

// MARK: - Helpers for specific responses

extension IMAPResponse {
    /// For "* n FETCH (...)": returns sequence number and a dictionary of items.
    func fetchItems() -> (seq: Int, items: [String: IMAPValue])? {
        let v = values()
        guard v.count >= 3, let seq = v[0].int, v[1].text?.uppercased() == "FETCH", let list = v[2].list else { return nil }
        var dict: [String: IMAPValue] = [:]
        var idx = 0
        while idx + 1 < list.count {
            if let key = list[idx].text?.uppercased() {
                dict[key] = list[idx + 1]
            }
            idx += 2
        }
        return (seq, dict)
    }
}

extension Dictionary where Key == String, Value == IMAPValue {
    /// Finds a body section item whose key starts with a prefix, e.g. "BODY[HEADER]".
    func section(_ prefix: String) -> Data? {
        for (k, v) in self where k.hasPrefix(prefix) {
            if case .nilValue = v { return nil }
            return v.data
        }
        return nil
    }
}

// MARK: - Quoting

enum IMAPQuote {
    /// Returns a quoted string safe to put in a command, or nil if a literal is required.
    static func quoted(_ s: String) -> String? {
        if s.contains("\r") || s.contains("\n") { return nil }
        if s.unicodeScalars.contains(where: { $0.value > 0x7E }) { return nil }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func mailbox(_ name: String) -> String {
        let encoded = ModifiedUTF7.encode(name)
        return quoted(encoded) ?? "\"\(encoded)\""
    }
}

// MARK: - Modified UTF-7 (RFC 3501 §5.1.3) for mailbox names

enum ModifiedUTF7 {
    static func decode(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&" {
                guard let end = s[i...].firstIndex(of: "-") else { result.append(contentsOf: s[i...]); break }
                let chunk = s[s.index(after: i)..<end]
                if chunk.isEmpty {
                    result.append("&")
                } else {
                    var b64 = chunk.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64.append("=") }
                    if let data = Data(base64Encoded: b64) {
                        var units = [UInt16]()
                        let bytes = [UInt8](data)
                        var k = 0
                        while k + 1 < bytes.count { units.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])); k += 2 }
                        result.append(String(decoding: units, as: UTF16.self))
                    } else {
                        result.append(contentsOf: s[i...end])
                    }
                }
                i = s.index(after: end)
            } else {
                result.append(c)
                i = s.index(after: i)
            }
        }
        return result
    }

    static func encode(_ s: String) -> String {
        var result = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes = [UInt8]()
            for u in pending { bytes.append(UInt8(u >> 8)); bytes.append(UInt8(u & 0xFF)) }
            let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: ",")
            result += "&" + b64 + "-"
            pending.removeAll()
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return result
    }
}
