import Foundation

/// What a bill-related email says.
struct BillInfo: Hashable {
    enum Kind: String { case due, scheduled, paid }
    var kind: Kind
    var amount: Double?
    var amountText: String?
    var dueDate: Date?
}

/// Finds bills, statements and payment emails and pulls out the amount and due date.
/// Runs entirely on this Mac with plain text rules and Apple's date detector.
enum BillDetector {

    static let paidPhrases = [
        "thanks for your payment", "thank you for your payment", "payment received", "payment confirmation",
        "we've received your payment", "we have received your payment", "we received your payment", "payment successful",
        "payment was successful", "receipt for your payment", "payment complete", "paid in full", "payment has been processed",
        "your payment has been received", "payment posted",
    ]
    static let scheduledPhrases = [
        "automatic payment scheduled", "autopay", "auto-pay", "auto pay", "payment is scheduled", "payment scheduled",
        "scheduled payment", "pre-authorized", "preauthorized", "pre-authorised", "will be automatically",
        "automatic withdrawal", "upcoming automatic payment", "automatic payment",
    ]
    static let duePhrases = [
        "bill is ready", "bill is available", "new bill", "your bill", "statement is ready", "statement is available",
        "new statement", "e-bill", "ebill", "payment due", "amount due", "balance due", "total due", "minimum payment",
        "due date", "invoice", "payment reminder", "upcoming payment", "is due", "past due", "overdue", "amount owing",
        "balance owing", "please pay",
    ]
    /// Mail that mentions bills but isn't one.
    static let excludePhrases = ["unsubscribe from bill", "% off", "save up to", "webinar", "newsletter"]

    static func kind(subject: String, text: String) -> BillInfo.Kind? {
        let s = subject.lowercased()
        let t = text.lowercased().prefix(2500)
        if excludePhrases.contains(where: { s.contains($0) }) { return nil }
        // The subject is the strongest signal; fall back to the body.
        for source in [String(s), String(t)] {
            if paidPhrases.contains(where: { source.contains($0) }) { return .paid }
            if scheduledPhrases.contains(where: { source.contains($0) }) { return .scheduled }
            if duePhrases.contains(where: { source.contains($0) }) { return .due }
        }
        return nil
    }

    // MARK: Amount

    private static let amountRegex = try! NSRegularExpression(
        pattern: "(?:(?:CA|C|US|AU|NZ)?\\$|USD\\s?|CAD\\s?|EUR\\s?|€|£)\\s?(\\d{1,3}(?:,\\d{3})+(?:\\.\\d{2})?|\\d+(?:\\.\\d{2})?)|(\\d{1,3}(?:,\\d{3})*\\.\\d{2})\\s?(?:CAD|USD|\\$)",
        options: [.caseInsensitive])

    private static let amountHints = ["amount due", "total due", "balance", "payment of", "amount of", "total", "minimum payment",
                                      "new charges", "you owe", "due:", "amount:", "paid", "charged", "withdrawn", "owing"]

    static func amount(in text: String) -> (Double, String)? {
        let ns = text as NSString
        let matches = amountRegex.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 6000)))
        var best: (Double, String)?
        for m in matches {
            let numRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard numRange.location != NSNotFound else { continue }
            let raw = ns.substring(with: numRange).replacingOccurrences(of: ",", with: "")
            guard let value = Double(raw), value > 0, value < 1_000_000 else { continue }
            let shown = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            let start = max(0, m.range.location - 60)
            let before = ns.substring(with: NSRange(location: start, length: m.range.location - start)).lowercased()
            if amountHints.contains(where: { before.contains($0) }) { return (value, shown) }
            if best == nil { best = (value, shown) }
        }
        return best
    }

    // MARK: Due date

    private static let strongHints = ["due", "before", "scheduled for", "on or after", "will be withdrawn", "will be processed",
                                      "will be charged", "payment date", "debit date", "withdrawn on", "processed on", "deducted on", "pay by"]
    private static let weakHints = ["by ", "on "]
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func dueDate(in text: String, received: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: min(ns.length, 6000))
        let earliest = received.addingTimeInterval(-2 * 86_400)
        let latest = received.addingTimeInterval(200 * 86_400)
        var fallback: Date?
        var weak: Date?
        for m in detector.matches(in: text, range: range) {
            guard let date = m.date, date >= earliest, date <= latest else { continue }
            let matched = ns.substring(with: m.range).lowercased()
            // Ignore vague words like "today" or "Friday": they resolve relative to now, not the email.
            guard matched.rangeOfCharacter(from: .decimalDigits) != nil || monthNames.contains(where: { matched.contains($0) }) else { continue }
            let start = max(0, m.range.location - 50)
            let before = ns.substring(with: NSRange(location: start, length: m.range.location - start)).lowercased()
            if strongHints.contains(where: { before.contains($0) }) { return date }
            if weak == nil && weakHints.contains(where: { before.hasSuffix($0) || before.contains($0) }) && date >= received.addingTimeInterval(-86_400) { weak = date }
            if fallback == nil && date >= received.addingTimeInterval(-86_400) { fallback = date }
        }
        return weak ?? fallback
    }

    // MARK: All together

    static func detect(subject: String, text: String, received: Date) -> BillInfo? {
        guard let kind = kind(subject: subject, text: text) else { return nil }
        let full = subject + "\n" + text
        let amt = amount(in: full)
        let due = kind == .paid ? nil : dueDate(in: full, received: received)
        // A "due" email with neither an amount nor a date is too vague to be useful.
        if kind == .due && amt == nil && due == nil { return nil }
        return BillInfo(kind: kind, amount: amt?.0, amountText: amt?.1, dueDate: due)
    }
}
