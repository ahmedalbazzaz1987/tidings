import SwiftUI
import AppKit

/// The "Bills" view in the middle column.
struct BillsView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var radar: BillRadar

    private var groups: [(BillRadar.Status, [BillRadar.Bill])] {
        let byStatus = Dictionary(grouping: radar.bills, by: \.status)
        return byStatus.keys.sorted().map { ($0, byStatus[$0]!) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary
                if radar.bills.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.0) { group in
                        let status = group.0
                        let list = group.1
                        VStack(alignment: .leading, spacing: 6) {
                            Text(status.title.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(status == .overdue ? Color(hex: 0xE11D48) : .secondary)
                                .padding(.leading, 6)
                            ForEach(list) { bill in
                                BillRow(bill: bill, selected: store.selectedIDs.contains(bill.id))
                                    .onTapGesture { store.selectedIDs = [bill.id] }
                                    .contextMenu { BillActions(bill: bill) }
                            }
                        }
                    }
                }
                Text("Tidings finds bills in your inboxes from the last five months. Everything is read on this Mac — nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .padding(.horizontal, 6)
            }
            .padding(12)
            .background(PersistentScroller())
        }
        .scrollIndicators(.visible)
        .clearsToolbar()
        .background(ZStack { Color(nsColor: .controlBackgroundColor); prefs.theme.softGradient.opacity(0.35) })
        .navigationTitle("Bills")
        .navigationSubtitle(radar.scanning ? "Scanning…" : "\(radar.attentionCount) need attention")
        .onAppear { radar.refresh(fetchBodies: true) }
    }

    private var summary: some View {
        let total = radar.upcomingTotal
        let overdue = radar.bills.filter { $0.status == .overdue }.count
        let autopay = radar.bills.filter { $0.status == .scheduled }.count
        return HStack(spacing: 10) {
            SummaryTile(title: "To pay", value: total.sum > 0 ? Self.money(total.sum) : "—",
                        caption: "\(total.count) open bill\(total.count == 1 ? "" : "s")", colors: prefs.theme.colors)
            SummaryTile(title: "Overdue", value: "\(overdue)", caption: overdue == 0 ? "All good" : "Check these first",
                        colors: overdue > 0 ? [Color(hex: 0xFB7185), Color(hex: 0xE11D48)] : [Color(hex: 0x4ADE80), Color(hex: 0x16A34A)])
            SummaryTile(title: "Autopay", value: "\(autopay)", caption: "scheduled",
                        colors: [Color(hex: 0xA78BFA), Color(hex: 0x7C3AED)])
        }
        .overlay(alignment: .topTrailing) {
            if radar.scanning { ProgressView().controlSize(.small).padding(6) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(prefs.theme.softGradient).frame(width: 90, height: 90)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(prefs.theme.gradient)
            }
            Text(radar.scanning ? "Looking for bills…" : "No bills found").font(.headline)
            Text("Bills, statements and payment confirmations will appear here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencySymbol = "$"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let caption: String
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Color.white.opacity(0.85))
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.85)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: (colors.last ?? .black).opacity(0.25), radius: 6, y: 3)
    }
}

struct BillRow: View {
    @EnvironmentObject var prefs: Preferences
    let bill: BillRadar.Bill
    let selected: Bool
    @ViewState private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Avatar(address: bill.message.from, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(bill.vendor).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(bill.message.subject).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                DueChip(bill: bill)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(bill.info.amountText ?? "—")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(bill.status == .paid ? Color.secondary : Color.primary)
                    .strikethrough(bill.status == .paid, color: .secondary)
                Text(bill.message.date.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? prefs.theme.accent.opacity(0.18) : Color(nsColor: .textBackgroundColor).opacity(hover ? 1 : 0.75))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? prefs.theme.accent.opacity(0.5) : Color.primary.opacity(0.06)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hover = $0 }
    }
}

struct DueChip: View {
    let bill: BillRadar.Bill

    var body: some View {
        let d = describe()
        HStack(spacing: 4) {
            Image(systemName: d.2).font(.system(size: 9, weight: .bold))
            Text(d.0).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(d.1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(d.1.opacity(0.13)))
    }

    private func describe() -> (String, Color, String) {
        let cal = Calendar.current
        let dueText: String? = bill.info.dueDate.map { d in
            if cal.isDateInToday(d) { return "today" }
            if cal.isDateInTomorrow(d) { return "tomorrow" }
            return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        switch bill.status {
        case .overdue: return ("Overdue · was due \(dueText ?? "")", Color(hex: 0xE11D48), "exclamationmark.circle.fill")
        case .dueSoon: return ("Due \(dueText ?? "soon")", Color(hex: 0xEA580C), "clock.fill")
        case .upcoming: return ("Due \(dueText ?? "")", Color(hex: 0x2563EB), "calendar")
        case .scheduled: return (dueText.map { "Autopay \($0)" } ?? "Autopay scheduled", Color(hex: 0x7C3AED), "arrow.triangle.2.circlepath")
        case .noDate: return ("No due date found", Color.secondary, "questionmark.circle")
        case .paid: return (bill.markedPaid ? "Marked as paid" : "Paid", Color(hex: 0x16A34A), "checkmark.circle.fill")
        }
    }
}

struct BillActions: View {
    @EnvironmentObject var radar: BillRadar
    let bill: BillRadar.Bill

    var body: some View {
        if bill.status == .paid && bill.info.kind != .paid {
            Button { radar.setPaid(bill, false) } label: { Label("Mark as Unpaid", systemImage: "arrow.uturn.backward") }
        } else if bill.status != .paid {
            Button { radar.setPaid(bill, true) } label: { Label("Mark as Paid", systemImage: "checkmark.circle") }
        }
        Button { ReaderWindow.open(bill.message) } label: { Label("Open Email", systemImage: "envelope.open") }
        Divider()
        Button { radar.dismiss(bill) } label: { Label("Not a Bill", systemImage: "xmark.circle") }
    }
}

/// Shown at the top of a bill email in the reader.
struct BillCard: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var radar: BillRadar
    let bill: BillRadar.Bill

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "doc.text.fill", colors: prefs.theme.colors, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(bill.info.kind == .paid ? "Payment confirmation" : "Bill").font(.system(size: 13, weight: .bold))
                    if let amt = bill.info.amountText {
                        Text(amt).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(prefs.theme.accent)
                    }
                }
                DueChip(bill: bill)
            }
            Spacer()
            if bill.status != .paid {
                Button { radar.setPaid(bill, true) } label: { Label("Mark as Paid", systemImage: "checkmark") }
                    .buttonStyle(PillButtonStyle(theme: prefs.theme))
            } else if bill.markedPaid {
                Button { radar.setPaid(bill, false) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(PillButtonStyle(theme: prefs.theme))
            }
            Menu {
                BillActions(bill: bill)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(prefs.theme.softGradient))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}
