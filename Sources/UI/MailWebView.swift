import SwiftUI
import WebKit
import AppKit

/// Builds the sandboxed HTML document shown for a message.
enum MailHTML {
    static func hasRemoteContent(_ m: ParsedMessage) -> Bool {
        guard let html = m.htmlBody else { return false }
        return html.range(of: "(src|background)\\s*=\\s*[\"']?\\s*https?:", options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: "url\\(\\s*[\"']?\\s*https?:", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func unsubscribeURL(_ header: String) -> URL? {
        // List-Unsubscribe: <mailto:...>, <https://...>
        let parts = header.components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>\t")) }
        if let web = parts.first(where: { $0.lowercased().hasPrefix("https://") }) { return URL(string: web) }
        return nil
    }

    static func render(_ m: ParsedMessage, allowRemote: Bool, blockTrackers: Bool, dark: Bool) -> String {
        // Content-Security-Policy is the main line of defence: no scripts, no frames,
        // no forms, and no network access at all unless the user allowed remote images.
        let remote = allowRemote ? " https: http:" : ""
        let csp = "default-src 'none'; img-src data: cid:\(remote); style-src 'unsafe-inline'\(remote); font-src data:\(remote); media-src 'none'; script-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

        let isHTML = m.htmlBody != nil
        var content: String
        if var html = m.htmlBody {
            html = inlineCIDImages(html, attachments: m.attachments)
            html = stripDangerous(html)
            if allowRemote && blockTrackers { html = removeTrackingPixels(html) }
            content = html
        } else {
            content = HTMLText.htmlFromPlain(m.textBody ?? "")
        }

        let scheme = isHTML ? "light" : (dark ? "dark" : "light")
        let css = """
        :root { color-scheme: \(scheme); }
        html, body { margin: 0; padding: 0; }
        body { font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", "Geeza Pro", sans-serif;
               padding: 18px 22px 40px; word-wrap: break-word; overflow-wrap: anywhere;
               \(isHTML ? "background: #ffffff; color: #1d1d1f;" : (dark ? "background: #1e1e1e; color: #e8e8ea;" : "background: #ffffff; color: #1d1d1f;")) }
        img { max-width: 100%; height: auto; }
        table { max-width: 100%; }
        pre, code { white-space: pre-wrap; font-family: ui-monospace, Menlo, monospace; font-size: 12.5px; }
        blockquote { margin: 0 0 0 4px; padding-left: 12px; border-left: 3px solid #9aa4b2; color: #5b6573; }
        a { color: \(dark && !isHTML ? "#6cb4ff" : "#0a66d8"); }
        .plain { white-space: normal; unicode-bidi: plaintext; }
        .quote { color: \(dark && !isHTML ? "#9aa0a8" : "#6b7280"); }
        """

        return """
        <!DOCTYPE html>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        <body dir="auto">
        \(content)
        </body>
        """
    }

    /// Removes script/iframe/object/form elements and inline event handlers as a second layer
    /// (scripts are already disabled in the web view and blocked by CSP).
    static func stripDangerous(_ html: String) -> String {
        var s = html
        for tag in ["script", "iframe", "object", "embed", "applet", "frameset", "frame"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<meta\\b[^>]*http-equiv[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<base\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "javascript:", with: "blocked:", options: .caseInsensitive)
        return s
    }

    /// Drops 1×1 and hidden images that exist only to report that you opened the email.
    static func removeTrackingPixels(_ html: String) -> String {
        var s = html
        let patterns = [
            "<img\\b[^>]*\\b(width|height)\\s*=\\s*[\"']?[01](px)?[\"']?[^>]*\\b(width|height)\\s*=\\s*[\"']?[01](px)?[\"']?[^>]*>",
            "<img\\b[^>]*display\\s*:\\s*none[^>]*>",
            "<img\\b[^>]*(width|height)\\s*:\\s*[01]px[^>]*>",
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    static func inlineCIDImages(_ html: String, attachments: [MailAttachment]) -> String {
        var s = html
        for a in attachments {
            guard let cid = a.contentID, !cid.isEmpty, a.data.count < 8_000_000 else { continue }
            let uri = "data:\(a.mimeType);base64,\(a.data.base64EncodedString())"
            s = s.replacingOccurrences(of: "cid:\(cid)", with: uri, options: .caseInsensitive)
        }
        return s
    }
}

/// A locked-down WKWebView: JavaScript off, no persistent storage, links open in the browser.
struct MailWebView: NSViewRepresentable {
    let html: String
    /// Hosts the phishing shield flagged; opening them asks for confirmation first.
    var suspiciousHosts: Set<String> = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = true
        web.allowsLinkPreview = false
        web.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastHTML = html
        context.coordinator.suspiciousHosts = suspiciousHosts
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.suspiciousHosts = suspiciousHosts
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastHTML = ""

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .other && (url.scheme == "about" || url.scheme == nil) {
                decisionHandler(.allow)
                return
            }
            // Anything else (a clicked link) opens outside Tidings.
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto", "tel"].contains(scheme) {
                if scheme == "mailto" {
                    ComposeWindow.open(.mailto(url))
                } else if confirmIfSuspicious(url) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        var suspiciousHosts: Set<String> = []

        /// Returns true if the link may be opened.
        private func confirmIfSuspicious(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return true }
            let flagged = suspiciousHosts.contains(host)
                || host.range(of: "^[0-9.]+$", options: .regularExpression) != nil
                || url.user != nil
                || PhishingShield.lookalikeBrand(for: PhishingShield.registrableDomain(host)) != nil
            guard flagged else { return true }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "This link may not be safe"
            alert.informativeText = "It opens:\n\n\(host)\n\nThis isn’t the address the email shows, or it imitates a well-known company. Only continue if you trust it."
            alert.addButton(withTitle: "Don’t Open")
            alert.addButton(withTitle: "Open Anyway")
            return alert.runModal() == .alertSecondButtonReturn
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               confirmIfSuspicious(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
