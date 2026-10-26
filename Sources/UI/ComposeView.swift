import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposeView: View {
    @ObservedObject var model: ComposeModel
    @EnvironmentObject var store: MailStore
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            fields
            FormatBar(model: model)
            Divider()
            ZStack(alignment: .top) {
                TextViewHost(scrollView: model.scrollView)
                if model.isPreparing {
                    ProgressView().controlSize(.small).padding(8)
                }
            }
            if !model.attachments.isEmpty {
                Divider()
                attachmentList
            }
            if let err = model.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.addFiles([url]) } }
                }
            }
            return true
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { if await model.send() { close() } }
            } label: {
                HStack(spacing: 6) {
                    if model.isSending { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane.fill") }
                    Text(model.isSending ? "Sending…" : "Send")
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(GradientButtonStyle(theme: Preferences.shared.theme))
            .help("Send (⌘↩)")
            .disabled(model.isSending)

            Spacer()

            Button { model.chooseFiles() } label: { Label("Attach", systemImage: "paperclip") }
                .help("Attach Files (or drag them here)")
            Menu {
                if store.templates.isEmpty { Text("No templates yet — add them in Settings") }
                ForEach(store.templates) { t in
                    Button(t.name) { model.insertTemplate(t) }
                }
            } label: {
                Label("Templates", systemImage: "text.badge.plus")
            }
            .fixedSize()
            .help("Insert a Template")
            Button {
                Task { if await model.saveDraft() { model.didSend = true; close() } }
            } label: { Label("Save Draft", systemImage: "square.and.arrow.down") }
                .help("Save to Drafts")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Preferences.shared.theme.softGradient.opacity(0.6))
    }

    private var fields: some View {
        VStack(spacing: 0) {
            if store.accounts.count > 1 {
                FieldRow(label: "From") {
                    Picker("", selection: $model.fromAccountID) {
                        ForEach(store.accounts) { a in
                            Text(a.displayName.isEmpty ? a.email : "\(a.displayName) <\(a.email)>").tag(a.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
                Divider().padding(.leading, 14)
            }
            AddressField(label: "To", text: $model.to, trailing: AnyView(
                Button(model.showCcBcc ? "Hide Cc/Bcc" : "Cc/Bcc") { withAnimation { model.showCcBcc.toggle() } }
                    .buttonStyle(.borderless).font(.callout)
            ))
            Divider().padding(.leading, 14)
            if model.showCcBcc {
                AddressField(label: "Cc", text: $model.cc)
                Divider().padding(.leading, 14)
                AddressField(label: "Bcc", text: $model.bcc)
                Divider().padding(.leading, 14)
            }
            FieldRow(label: "Subject") {
                TextField("", text: $model.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
            }
            Divider()
        }
    }

    private var attachmentList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { a in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill").foregroundStyle(.secondary)
                        Text(a.filename).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                        Text(a.sizeText).foregroundStyle(.secondary)
                        Button {
                            model.attachments.removeAll { $0.id == a.id }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                if model.attachmentsSize > 20_000_000 {
                    Label("Large attachments may be rejected by the server (limit is usually 20–25 MB).", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10)
        }
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Recipient field with suggestions from people who have emailed you.
private struct AddressField: View {
    let label: String
    @Binding var text: String
    var trailing: AnyView? = nil
    @FocusState private var focused: Bool
    @ViewState private var suggestions: [MailAddress] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldRow(label: label) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: text) { _ in updateSuggestions() }
                    .onChange(of: focused) { f in if !f { suggestions = [] } }
                if let trailing { trailing }
            }
            if focused && !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions) { s in
                            Button { accept(s) } label: {
                                HStack(spacing: 5) {
                                    Avatar(address: s, size: 18)
                                    Text(s.name.isEmpty ? s.email : "\(s.name) · \(s.email)").lineLimit(1)
                                }
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 80)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var currentToken: String {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",;"))
        return (parts.last ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func updateSuggestions() {
        let token = currentToken
        guard token.count >= 2, !token.contains("<") else { suggestions = []; return }
        suggestions = MailDatabase.shared.contacts(matching: token)
    }

    private func accept(_ a: MailAddress) {
        var parts = text.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(a.encodedForDisplay)
        text = parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
        suggestions = []
    }
}

private struct FormatBar: View {
    @ObservedObject var model: ComposeModel

    var body: some View {
        HStack(spacing: 2) {
            fmt("bold", "Bold") { model.toggleTrait(.boldFontMask) }
            fmt("italic", "Italic") { model.toggleTrait(.italicFontMask) }
            fmt("underline", "Underline") { model.toggleUnderline() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            fmt("textformat.size.smaller", "Smaller") { model.changeSize(by: -2) }
            fmt("textformat.size.larger", "Larger") { model.changeSize(by: 2) }
            fmt("paintpalette", "Text Color") {
                model.textView.window?.makeFirstResponder(model.textView)
                NSApp.orderFrontColorPanel(nil)
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            fmt("list.bullet", "Bulleted List") { model.insertBullets() }
            fmt("text.alignleft", "Align Left") { model.textView.alignLeft(nil) }
            fmt("text.aligncenter", "Center") { model.textView.alignCenter(nil) }
            fmt("text.alignright", "Align Right") { model.textView.alignRight(nil) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            fmt("arrow.right.to.line", "Left-to-Right") { model.textView.makeBaseWritingDirectionLeftToRight(nil) }
            fmt("arrow.left.to.line", "Right-to-Left (Arabic)") { model.textView.makeBaseWritingDirectionRightToLeft(nil) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            fmt("eraser", "Clear Formatting") { model.clearFormatting() }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func fmt(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 20)
        }
        .help(help)
    }
}

private struct TextViewHost: NSViewRepresentable {
    let scrollView: NSScrollView
    func makeNSView(context: Context) -> NSScrollView { scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

// MARK: - Windows

@MainActor
enum ComposeWindow {
    private static var openWindows: [NSWindow: ComposeWindowDelegate] = [:]

    static func open(_ kind: ComposeKind) {
        guard !MailStore.shared.accounts.isEmpty else {
            MailStore.shared.showAddAccount = true
            return
        }
        let model = ComposeModel(kind: kind)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = model.subject.isEmpty ? "New Message" : model.subject
        window.identifier = NSUserInterfaceItemIdentifier("tidings.compose")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        let delegate = ComposeWindowDelegate(model: model)
        window.delegate = delegate
        openWindows[window] = delegate
        let view = ComposeView(model: model, close: { [weak window] in window?.close() })
            .environmentObject(MailStore.shared)
            .environmentObject(Preferences.shared)
            .environmentObject(BillRadar.shared)
            .preferredColorScheme(Preferences.shared.colorScheme)
            .tint(Preferences.shared.theme.accent)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 760, height: 640))
        window.center()
        if let key = NSApp.keyWindow {
            let f = key.frame
            window.setFrameOrigin(NSPoint(x: f.midX - 380 + CGFloat(openWindows.count * 22), y: f.midY - 300 - CGFloat(openWindows.count * 22)))
        }
        window.makeKeyAndOrderFront(nil)
        if case .new = kind {} else { window.makeFirstResponder(model.textView) }
    }

    /// ⌘↩ from the shortcut monitor.
    static func sendFromKeyWindow() {
        guard let window = NSApp.keyWindow, let delegate = openWindows[window] else { return }
        let model = delegate.model
        guard !model.isSending else { return }
        Task {
            if await model.send() { window.close() }
        }
    }

    fileprivate static func closed(_ window: NSWindow) {
        openWindows[window] = nil
    }
}

@MainActor
final class ComposeWindowDelegate: NSObject, NSWindowDelegate {
    let model: ComposeModel
    init(model: ComposeModel) { self.model = model }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.didSend || !model.hasContent || model.isSending { return true }
        let alert = NSAlert()
        alert.messageText = "Save this message as a draft?"
        alert.informativeText = "If you don’t save it, your changes will be lost."
        alert.addButton(withTitle: "Save Draft")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                if await model.saveDraft() { model.didSend = true; sender.close() }
            }
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow { ComposeWindow.closed(w) }
    }
}

@MainActor
enum ReaderWindow {
    private static var windows: [NSWindow] = []

    static func open(_ m: MessageSummary) {
        let view = MessageReaderView(summary: m)
            .environmentObject(MailStore.shared)
            .environmentObject(Preferences.shared)
            .environmentObject(BillRadar.shared)
            .preferredColorScheme(Preferences.shared.colorScheme)
            .frame(minWidth: 600, minHeight: 500)
        show(title: m.subject.isEmpty ? "(No Subject)" : m.subject, root: AnyView(view), size: NSSize(width: 820, height: 760))
    }

    static func openSource(_ m: MessageSummary) {
        let view = SourceView(summary: m).environmentObject(MailStore.shared)
        show(title: "Source — \(m.subject)", root: AnyView(view), size: NSSize(width: 820, height: 700))
    }

    private static func show(title: String, root: AnyView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier("tidings.reader")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.removeAll { !$0.isVisible }
        windows.append(window)
    }
}

private struct SourceView: View {
    @EnvironmentObject var store: MailStore
    let summary: MessageSummary
    @ViewState private var text = "Loading…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .task { text = String((await store.rawSource(summary)).prefix(400_000)) }
    }
}
