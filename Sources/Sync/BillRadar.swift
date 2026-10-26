import Foundation
import UserNotifications

/// Keeps the list of bills found in your inboxes, their state, and the reminders.
@MainActor
final class BillRadar: ObservableObject {
    static let shared = BillRadar()

    enum Status: Int, Comparable {
        case overdue, dueSoon, upcoming, scheduled, noDate, paid
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .dueSoon: return "Due Soon"
            case .upcoming: return "Upcoming"
            case .scheduled: return "Autopay Scheduled"
            case .noDate: return "Bills Without a Due Date"
            case .paid: return "Paid"
            }
        }
    }

    struct Bill: Identifiable, Hashable {
        var id: String { message.id }
        let message: MessageSummary
        let info: BillInfo
        let markedPaid: Bool

        var vendor: String { message.from.displayName }

        var status: Status {
            if markedPaid || info.kind == .paid { return .paid }
            guard let due = info.dueDate else { return info.kind == .scheduled ? .scheduled : .noDate }
            let today = Calendar.current.startOfDay(for: Date())
            if due < today { return info.kind == .scheduled ? .paid : .overdue }
            if info.kind == .scheduled { return .scheduled }
            if due < today.addingTimeInterval(4 * 86_400) { return .dueSoon }
            return .upcoming
        }
    }

    @Published private(set) var bills: [Bill] = []
    @Published private(set) var scanning = false

    private struct SavedState: Codable {
        var paid: Set<String> = []
        var dismissed: Set<String> = []
    }
    private var saved = Preferences.load(SavedState.self, from: "bills.json") ?? SavedState()
    private var fetchedOnce = false
    private var lookback: TimeInterval { 150 * 86_400 }

    private init() {}

    // MARK: Queries

    func bill(for messageID: String) -> Bill? { bills.first { $0.id == messageID } }

    /// Overdue + due within a few days — shown on the sidebar badge.
    var attentionCount: Int { bills.filter { $0.status == .overdue || $0.status == .dueSoon }.count }
    var hasOverdue: Bool { bills.contains { $0.status == .overdue } }

    var upcomingTotal: (sum: Double, count: Int) {
        let open = bills.filter { [.overdue, .dueSoon, .upcoming].contains($0.status) }
        return (open.compactMap(\.info.amount).reduce(0, +), open.count)
    }

    // MARK: Scanning

    /// Scans cached inbox mail. With `fetchBodies`, also downloads the full text of
    /// recent candidates whose body isn't cached yet, for better amounts and dates.
    func refresh(fetchBodies: Bool = false) {
        guard !scanning else { return }
        scanning = true
        let store = MailStore.shared
        let boxes = store.accounts.map { ($0.id, store.inboxPath($0.id)) }
        let since = Date().addingTimeInterval(-lookback)
        let dismissed = saved.dismissed
        let shouldFetch = fetchBodies || !fetchedOnce
        fetchedOnce = true

        Task {
            let candidates = MailDatabase.shared.messages(in: boxes, limit: 4000)
                .filter { $0.date >= since && !dismissed.contains($0.id) }
                .filter { BillDetector.kind(subject: $0.subject, text: $0.snippet) != nil }

            var found = await Task.detached(priority: .utility) { () -> [(MessageSummary, BillInfo, Bool)] in
                candidates.map { m in
                    let body = BillRadar.cachedText(m)
                    let info = BillDetector.detect(subject: m.subject, text: body ?? m.snippet, received: m.date)
                    return (m, info ?? BillInfo(kind: .due), body != nil)
                }.filter { $0.1.amount != nil || $0.1.dueDate != nil || $0.1.kind != .due }
            }.value

            // Download the bodies of the most recent candidates that only had a snippet.
            if shouldFetch {
                let missing = candidates.filter { c in !found.contains { $0.0.id == c.id && $0.2 } }.prefix(30)
                for m in missing {
                    guard let parsed = try? await store.loadContent(m) else { continue }
                    let text = parsed.textBody ?? parsed.htmlBody.map(HTMLText.plainText) ?? m.snippet
                    if let info = BillDetector.detect(subject: m.subject, text: text, received: m.date) {
                        found.removeAll { $0.0.id == m.id }
                        found.append((m, info, true))
                    }
                }
            }

            apply(found.map { Bill(message: $0.0, info: $0.1, markedPaid: saved.paid.contains($0.0.id)) })
            scanning = false
        }
    }

    nonisolated private static func cachedText(_ m: MessageSummary) -> String? {
        guard let raw = MailDatabase.shared.body(account: m.accountID, folder: m.folderPath, uid: m.uid) else { return nil }
        let p = ParsedMessage(data: raw)
        return p.textBody ?? p.htmlBody.map(HTMLText.plainText)
    }

    private func apply(_ list: [Bill]) {
        // One entry per bill: if a vendor sent "bill ready" and later "payment received" for the
        // same amount, the payment marks the bill as paid.
        var result = list
        let payments = list.filter { $0.info.kind == .paid }
        result = result.map { b in
            guard b.status != .paid, let amt = b.info.amount else { return b }
            let settled = payments.contains { p in
                p.message.from.email.lowercased() == b.message.from.email.lowercased()
                    && p.message.date > b.message.date
                    && (p.info.amount.map { abs($0 - amt) < 0.01 } ?? false)
            }
            return settled ? Bill(message: b.message, info: b.info, markedPaid: true) : b
        }
        result.sort {
            if $0.status != $1.status { return $0.status < $1.status }
            let d0 = $0.info.dueDate ?? $0.message.date, d1 = $1.info.dueDate ?? $1.message.date
            return $0.status == .paid ? d0 > d1 : d0 < d1
        }
        bills = result
        scheduleReminders()
        if MailStore.shared.selection == .bills { MailStore.shared.reloadList() }
    }

    // MARK: User actions

    func setPaid(_ bill: Bill, _ paid: Bool) {
        if paid { saved.paid.insert(bill.id) } else { saved.paid.remove(bill.id) }
        persist()
        apply(bills.map { $0.id == bill.id ? Bill(message: $0.message, info: $0.info, markedPaid: paid) : $0 })
    }

    func dismiss(_ bill: Bill) {
        saved.dismissed.insert(bill.id)
        persist()
        apply(bills.filter { $0.id != bill.id })
    }

    private func persist() { Preferences.save(saved, to: "bills.json") }

    // MARK: Reminders

    private func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        let upcoming = bills.filter { [.dueSoon, .upcoming, .scheduled].contains($0.status) }
        let enabled = Preferences.shared.notificationsEnabled
        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0.hasPrefix("bill-") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard enabled else { return }
            let cal = Calendar.current
            for b in upcoming {
                guard let due = b.info.dueDate,
                      let dayBefore = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: due)),
                      let fireAt = cal.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore),
                      fireAt > Date() else { continue }
                let c = UNMutableNotificationContent()
                c.title = b.info.kind == .scheduled ? "Autopay tomorrow: \(b.vendor)" : "Bill due tomorrow: \(b.vendor)"
                c.body = [b.info.amountText, b.message.subject].compactMap { $0 }.joined(separator: " — ")
                c.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                center.add(UNNotificationRequest(identifier: "bill-" + b.id, content: c, trigger: trigger))
            }
        }
    }
}
