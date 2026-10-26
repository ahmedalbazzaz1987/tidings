import SwiftUI
import AppKit

// MARK: - Window access

/// Gives SwiftUI code a reference to the NSWindow it is shown in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { onWindow?(w) }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
        if let w = nsView.window { DispatchQueue.main.async { onWindow(w) } }
    }
}

// MARK: - Keep content out from under the toolbar

/// On recent macOS versions a split-view column can be laid out starting at the very
/// top of the window, so its first rows sit underneath the toolbar. This modifier
/// measures where the view actually starts and, only if it overlaps the toolbar,
/// pushes the content down by exactly the overlapping amount. When the system already
/// places the column correctly the padding stays at zero.
struct ToolbarClearance: ViewModifier {
    @ViewState private var toolbarBottom: CGFloat = 0
    @ViewState private var minY: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.top, max(0, toolbarBottom - minY))
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { minY = g.frame(in: .global).minY }
                        .onChange(of: g.frame(in: .global).minY) { minY = $0 }
                }
            )
            .background(
                WindowReader { window in
                    let h = ToolbarClearance.toolbarHeight(of: window)
                    if abs(h - toolbarBottom) > 0.5 { toolbarBottom = h }
                }
                .frame(width: 0, height: 0)
            )
    }

    /// Height of the title bar + toolbar, measured from the top of the window content.
    static func toolbarHeight(of window: NSWindow) -> CGFloat {
        guard let content = window.contentView else { return 0 }
        let total = content.bounds.height
        let layout = window.contentLayoutRect.height
        let h = total - layout
        return h > 0 && h < 200 ? h : 0
    }
}

extension View {
    func clearsToolbar() -> some View { modifier(ToolbarClearance()) }
}

// MARK: - Always-visible scroller

/// Makes the enclosing NSScrollView show a permanent vertical scroller, regardless of
/// the "Show scroll bars: when scrolling" system setting.
struct PersistentScroller: NSViewRepresentable {
    final class ProbeView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                // macOS resets scroller style when the system preference changes.
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = false
                scroll.scrollerStyle = .legacy
                scroll.verticalScroller?.controlSize = .small
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.apply() }
}
