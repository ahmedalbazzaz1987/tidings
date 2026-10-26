import Foundation

/// A message being sent.
struct OutgoingMessage {
    var from: MailAddress
    var to: [MailAddress] = []
    var cc: [MailAddress] = []
    var bcc: [MailAddress] = []
    var subject: String = ""
    var text: String = ""
    var html: String?
    var attachments: [MailAttachment] = []
    var inReplyTo: String?
    var references: [String] = []

    var allRecipients: [String] { (to + cc + bcc).map(\.email) }

    /// Builds the RFC 5322 message. Bcc is never written into the headers.
    func build(date: Date = Date()) -> (data: Data, messageID: String) {
        let domain = from.email.split(separator: "@").last.map(String.init) ?? "tidings.local"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"

        var h = ""
        func add(_ name: String, _ value: String) { h += "\(name): \(value)\r\n" }
        add("Date", MIMEDate.format(date))
        add("From", from.encoded)
        if !to.isEmpty { add("To", to.map(\.encoded).joined(separator: ",\r\n ")) }
        if !cc.isEmpty { add("Cc", cc.map(\.encoded).joined(separator: ",\r\n ")) }
        add("Subject", MIMEEncoding.encodeHeader(subject))
        add("Message-ID", messageID)
        if let inReplyTo { add("In-Reply-To", inReplyTo) }
        if !references.isEmpty { add("References", references.joined(separator: "\r\n ")) }
        add("MIME-Version", "1.0")

        let body = MIMEBuilder.textBody(text: text, html: html)
        var out: String
        if attachments.isEmpty {
            out = h + body
        } else {
            let boundary = MIMEBuilder.boundary()
            out = h + "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            out += "This is a multi-part message in MIME format.\r\n"
            out += "--\(boundary)\r\n" + body + "\r\n"
            for a in attachments {
                out += "--\(boundary)\r\n" + MIMEBuilder.attachmentPart(a) + "\r\n"
            }
            out += "--\(boundary)--\r\n"
        }
        return (Data(out.utf8), messageID)
    }
}

enum MIMEBuilder {
    static func boundary() -> String {
        "=_Tidings_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Returns headers + body for the text part(s), starting with Content-Type.
    static func textBody(text: String, html: String?) -> String {
        let plain = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            + MIMEEncoding.encodeQuotedPrintable(text) + "\r\n"
        guard let html else { return plain }
        let b = boundary()
        var s = "Content-Type: multipart/alternative; boundary=\"\(b)\"\r\n\r\n"
        s += "--\(b)\r\n" + plain
        s += "--\(b)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
        s += MIMEEncoding.encodeQuotedPrintable(html) + "\r\n"
        s += "--\(b)--\r\n"
        return s
    }

    static func attachmentPart(_ a: MailAttachment) -> String {
        let name = a.filename.isEmpty ? "attachment" : a.filename
        let ascii = name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" }
        let nameParam: String
        let fileParam: String
        if ascii {
            nameParam = "name=\"\(name)\""
            fileParam = "filename=\"\(name)\""
        } else {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let pct = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
            nameParam = "name=\"\(MIMEEncoding.encodeHeader(name).replacingOccurrences(of: "\r\n ", with: ""))\""
            fileParam = "filename*=utf-8''\(pct)"
        }
        var s = "Content-Type: \(a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType); \(nameParam)\r\n"
        s += "Content-Transfer-Encoding: base64\r\n"
        s += "Content-Disposition: \(a.isInline ? "inline" : "attachment"); \(fileParam)\r\n"
        if let cid = a.contentID { s += "Content-ID: <\(cid)>\r\n" }
        s += "\r\n"
        s += a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        s += "\r\n"
        return s
    }

    static func mimeType(forExtension ext: String) -> String {
        let map: [String: String] = [
            "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "gif": "image/gif", "heic": "image/heic", "webp": "image/webp", "txt": "text/plain",
            "html": "text/html", "csv": "text/csv", "zip": "application/zip", "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "mp3": "audio/mpeg", "mp4": "video/mp4", "mov": "video/quicktime", "ics": "text/calendar",
        ]
        return map[ext.lowercased()] ?? "application/octet-stream"
    }
}
