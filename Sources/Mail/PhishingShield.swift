import Foundation

/// One thing the shield noticed about a message.
struct SecurityFinding: Identifiable, Hashable {
    enum Level: Int, Comparable {
        case caution = 1
        case danger = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    var id: String { title + detail }
    let level: Level
    let title: String
    let detail: String
}

struct SecurityReport {
    var findings: [SecurityFinding] = []
    /// Hosts of links that should not be opened without a confirmation.
    var suspiciousHosts: Set<String> = []

    var level: SecurityFinding.Level? { findings.map(\.level).max() }
    var isClean: Bool { findings.isEmpty }
}

/// Local, rule-based phishing detection. Nothing is sent anywhere: every check runs on
/// the message headers and HTML that are already on this Mac.
enum PhishingShield {

    // MARK: Brands people impersonate

    struct Brand {
        let name: String
        let keywords: [String]   // whole words in the display name; "=word" only when the name is just the brand (+ "support", "team"…)
        let domains: [String]    // registrable domains the real company sends from
    }

    private static let commonTLDs = ["com", "ca", "co.uk", "de", "fr", "it", "es", "nl", "in", "com.au", "co.jp", "com.br", "com.mx", "ae", "sa", "eg", "ie", "se", "pl", "com.tr"]

    private static func global(_ base: String) -> [String] { commonTLDs.map { "\(base).\($0)" } }

    static let brands: [Brand] = [
        Brand(name: "PayPal", keywords: ["paypal"], domains: global("paypal") + ["paypal.me", "paypal-communication.com"]),
        Brand(name: "Amazon", keywords: ["amazon", "aws", "prime video"], domains: global("amazon") + ["amazon-adsystem.com", "amazonaws.com", "amazonses.com", "primevideo.com", "audible.com", "audible.ca"]),
        Brand(name: "Apple", keywords: ["=apple", "icloud", "itunes", "app store", "apple id", "apple support"], domains: ["apple.com", "icloud.com", "me.com", "mac.com", "itunes.com"]),
        Brand(name: "Microsoft", keywords: ["microsoft", "outlook", "office 365", "microsoft 365", "onedrive", "xbox", "hotmail"], domains: ["microsoft.com", "outlook.com", "live.com", "hotmail.com", "office.com", "office365.com", "microsoftonline.com", "xbox.com", "skype.com", "onedrive.com", "microsoftstore.com"]),
        Brand(name: "Google", keywords: ["google", "gmail", "youtube", "google pay"], domains: ["google.com", "gmail.com", "youtube.com", "googlemail.com", "google.ca", "google-analytics.com", "googleusercontent.com"]),
        Brand(name: "Netflix", keywords: ["netflix"], domains: ["netflix.com"]),
        Brand(name: "Meta", keywords: ["facebook", "instagram", "whatsapp", "=meta"], domains: ["facebook.com", "facebookmail.com", "meta.com", "instagram.com", "whatsapp.com", "fb.com"]),
        Brand(name: "LinkedIn", keywords: ["linkedin"], domains: ["linkedin.com"]),
        Brand(name: "Dropbox", keywords: ["dropbox"], domains: ["dropbox.com", "dropboxmail.com"]),
        Brand(name: "DocuSign", keywords: ["docusign"], domains: ["docusign.com", "docusign.net"]),
        Brand(name: "RBC", keywords: ["rbc", "royal bank"], domains: ["rbc.com", "royalbank.com", "rbcroyalbank.com"]),
        Brand(name: "TD", keywords: ["td bank", "td canada trust", "td canada"], domains: ["td.com", "tdbank.com", "tdcanadatrust.com"]),
        Brand(name: "BMO", keywords: ["bmo", "bank of montreal"], domains: ["bmo.com"]),
        Brand(name: "Scotiabank", keywords: ["scotiabank", "=scotia"], domains: ["scotiabank.com", "scotiaonline.com"]),
        Brand(name: "CIBC", keywords: ["cibc"], domains: ["cibc.com", "cibc.ca"]),
        Brand(name: "Tangerine", keywords: ["tangerine"], domains: ["tangerine.ca"]),
        Brand(name: "Interac", keywords: ["interac", "e-transfer", "etransfer"], domains: ["interac.ca"]),
        Brand(name: "Chase", keywords: ["=chase", "chase bank", "jpmorgan"], domains: ["chase.com", "jpmorgan.com", "jpmchase.com"]),
        Brand(name: "Wells Fargo", keywords: ["wells fargo"], domains: ["wellsfargo.com"]),
        Brand(name: "Bank of America", keywords: ["bank of america"], domains: ["bankofamerica.com", "bofa.com"]),
        Brand(name: "American Express", keywords: ["american express", "amex"], domains: ["americanexpress.com", "aexp.com", "americanexpress.ca"]),
        Brand(name: "Capital One", keywords: ["capital one"], domains: ["capitalone.com", "capitalone.ca"]),
        Brand(name: "Canada Post", keywords: ["canada post", "postes canada"], domains: ["canadapost.ca", "canadapost-postescanada.ca", "postescanada.ca"]),
        Brand(name: "FedEx", keywords: ["fedex"], domains: ["fedex.com"]),
        Brand(name: "DHL", keywords: ["dhl"], domains: ["dhl.com", "dhl.ca", "dhl.de"]),
        Brand(name: "UPS", keywords: ["=ups"], domains: ["ups.com"]),
        Brand(name: "USPS", keywords: ["usps"], domains: ["usps.com", "usps.gov"]),
        Brand(name: "Canada Revenue Agency", keywords: ["canada revenue", "=cra", "service canada", "government of canada"], domains: ["canada.ca", "gc.ca"]),
        Brand(name: "IRS", keywords: ["=irs", "internal revenue"], domains: ["irs.gov"]),
        Brand(name: "Rogers", keywords: ["=rogers", "rogers communications", "rogers bank"], domains: ["rogers.com"]),
        Brand(name: "Bell", keywords: ["bell canada"], domains: ["bell.ca"]),
        Brand(name: "Telus", keywords: ["telus"], domains: ["telus.com"]),
        Brand(name: "eBay", keywords: ["ebay"], domains: ["ebay.com", "ebay.ca", "ebay.co.uk"]),
        Brand(name: "Walmart", keywords: ["walmart"], domains: ["walmart.com", "walmart.ca"]),
        Brand(name: "Costco", keywords: ["costco"], domains: ["costco.com", "costco.ca"]),
        Brand(name: "Coinbase", keywords: ["coinbase"], domains: ["coinbase.com"]),
        Brand(name: "Binance", keywords: ["binance"], domains: ["binance.com"]),
        Brand(name: "Affirm", keywords: ["affirm"], domains: ["affirm.com", "affirm.ca"]),
        Brand(name: "Shopify", keywords: ["shopify"], domains: ["shopify.com"]),
    ]

    static let freeMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yahoo.com", "yahoo.ca", "ymail.com", "hotmail.com", "outlook.com", "live.com",
        "msn.com", "aol.com", "icloud.com", "me.com", "proton.me", "protonmail.com", "gmx.com", "gmx.net", "mail.com",
        "mail.ru", "yandex.com", "yandex.ru", "zoho.com", "qq.com", "163.com",
    ]

    /// Click-tracking services that legitimately rewrite links in newsletters.
    static let trackingDomains: Set<String> = [
        "list-manage.com", "mcusercontent.com", "sendgrid.net", "mandrillapp.com", "hubspotlinks.com", "hubspotemail.net",
        "exacttarget.com", "exct.net", "rs6.net", "klaviyo.com", "klclick.com", "mailgun.org", "sparkpostmail.com",
        "createsend.com", "cmail19.com", "cmail20.com", "awstrack.me", "safelinks.protection.outlook.com", "urldefense.com",
        "mailchi.mp", "braze.com", "sailthru.com", "mktomail.com", "marketo.com", "eloqua.com", "constantcontact.com",
        "postmarkapp.com", "mailjet.com", "substack.com", "beehiiv.com", "convertkit-mail.com", "ck.page", "linktr.ee",
        "bit.ly", "t.co", "lnkd.in", "google.com", "doubleclick.net", "salesforce.com", "pardot.com", "intercom-mail.com",
    ]

    // MARK: Domain helpers

    private static let twoPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp", "com.br", "com.mx",
        "co.in", "co.nz", "com.tr", "com.sa", "com.eg", "co.za", "com.cn", "gc.ca", "qc.ca", "on.ca", "com.sg",
    ]

    /// "mail.e.paypal.co.uk" → "paypal.co.uk"
    static func registrableDomain(_ host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return h }
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoPartSuffixes.contains(lastTwo) { return parts.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    static func domain(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return String(email[email.index(after: at)...]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "> "))
    }

    private static func isOfficial(_ registrable: String, for brand: Brand) -> Bool {
        brand.domains.contains(registrable) || brand.domains.contains { registrable.hasSuffix("." + $0) }
    }

    private static func words(_ s: String) -> String {
        // Normalise punctuation to spaces so "PayPal-Service" matches "paypal".
        let mapped = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return " " + String(mapped).split(separator: " ").joined(separator: " ") + " "
    }

    /// Brands the display name claims to be.
    static func brandsClaimed(by displayName: String) -> [Brand] {
        let w = words(displayName)
        let serviceWords: Set<String> = ["support", "service", "services", "team", "bank", "billing", "security", "account",
                                         "accounts", "alert", "alerts", "notification", "notifications", "help", "customer",
                                         "care", "online", "id", "inc", "canada", "verify", "verification", "no", "reply", "noreply"]
        return brands.filter { b in
            b.keywords.contains { kw in
                if kw.hasPrefix("=") {
                    let k = words(String(kw.dropFirst())).trimmingCharacters(in: .whitespaces)
                    guard w.contains(" " + k + " ") else { return false }
                    // Only the brand word plus generic service words — not a person's name.
                    let rest = w.replacingOccurrences(of: " " + k + " ", with: " ").split(separator: " ").map(String.init)
                    return rest.allSatisfy { serviceWords.contains($0) }
                }
                return w.contains(" " + words(kw).trimmingCharacters(in: .whitespaces) + " ")
            }
        }
    }

    /// Replaces characters commonly swapped in fake domains: paypa1 → paypal, amaz0n → amazon, rn → m.
    static func deconfuse(_ label: String) -> String {
        var s = label.lowercased()
        let map: [Character: Character] = ["0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "@": "a", "$": "s", "!": "i", "|": "l"]
        s = String(s.map { map[$0] ?? $0 })
        s = s.replacingOccurrences(of: "rn", with: "m")
        s = s.replacingOccurrences(of: "vv", with: "w")
        s = s.replacingOccurrences(of: "-", with: "")
        return s
    }

    /// Brand names that are also common surnames/words — not checked for one-letter typos.
    private static let surnameLike: Set<String> = ["rogers", "telus", "affirm"]

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// If `registrable` imitates a brand domain without being one, returns that brand.
    static func lookalikeBrand(for registrable: String) -> Brand? {
        guard let label = registrable.split(separator: ".").first.map(String.init), label.count >= 4 else { return nil }
        let clean = deconfuse(label)
        // Same substitutions but keeping hyphens, for "amaz0n-security".
        let hyphenated = deconfuse(label.replacingOccurrences(of: "-", with: "\u{1}")).replacingOccurrences(of: "\u{1}", with: "-")
        if brands.contains(where: { isOfficial(registrable, for: $0) }) { return nil }
        for b in brands {
            let bases = Set(b.domains.compactMap { $0.split(separator: ".").first.map(String.init) }).filter { $0.count >= 4 }
            for base in bases {
                if clean == base && label != base { return b }                        // amaz0n, paypa1, rnicrosoft
                if clean != label && levenshtein(clean, base) <= 1 && base.count >= 5 { return b }
                if label != base && base.count >= 6 && !surnameLike.contains(base) && levenshtein(label, base) == 1 { return b }  // paypall, amazom
                if hyphenated.count > base.count + 2 &&
                    (hyphenated.hasPrefix(base + "-") || hyphenated.hasSuffix("-" + base) || hyphenated.contains("-" + base + "-")) {
                    return b                                                          // paypal-secure, amaz0n-support
                }
            }
        }
        return nil
    }

    // MARK: Checks

    /// Header-only checks (used for the list badge when a message arrives).
    static func headerFindings(from: MailAddress?, replyTo: [MailAddress], authenticationResults: String) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        guard let from else { return out }
        let fromDomain = domain(of: from.email)
        let fromReg = registrableDomain(fromDomain)
        let auth = authenticationResults.lowercased()
        let dmarcFail = auth.contains("dmarc=fail")
        let spfFail = auth.contains("spf=fail")
        let dkimFail = auth.contains("dkim=fail") && !auth.contains("dkim=pass")

        // 1. Display name claims a brand the address doesn't belong to.
        for brand in brandsClaimed(by: from.name) where !isOfficial(fromReg, for: brand) {
            // A brand name in the display name is common for resellers and shops, so it is
            // only "danger" when combined with another red flag.
            let personal = freeMailDomains.contains(fromReg)
            let strong = personal || dmarcFail || lookalikeBrand(for: fromReg) != nil
            out.append(SecurityFinding(
                level: strong ? .danger : .caution,
                title: "Sender name doesn’t match the address",
                detail: "It says “\(from.name)”, but the email comes from \(fromDomain), which is not a \(brand.name) address."))
            break
        }

        // 2. Domain imitates a well-known brand.
        if let b = lookalikeBrand(for: fromReg) {
            out.append(SecurityFinding(
                level: .danger,
                title: "Look-alike address",
                detail: "\(fromDomain) imitates \(b.name) but is not one of its real domains."))
        }
        if fromDomain.contains("xn--") {
            out.append(SecurityFinding(level: .caution, title: "Unusual characters in the address",
                                       detail: "\(fromDomain) uses international characters that can disguise a fake domain."))
        }

        // 3. Your mail provider's own verification.
        if dmarcFail {
            out.append(SecurityFinding(level: .danger, title: "Failed sender verification (DMARC)",
                                       detail: "Your mail provider could not confirm this really came from \(fromDomain)."))
        } else if spfFail || dkimFail {
            out.append(SecurityFinding(level: .caution, title: "Sender verification failed",
                                       detail: "\(spfFail ? "SPF" : "DKIM") check failed — the message may not really be from \(fromDomain)."))
        }

        // 4. Replies go to a personal mailbox.
        if let r = replyTo.first {
            let rReg = registrableDomain(domain(of: r.email))
            if rReg != fromReg && freeMailDomains.contains(rReg) && !freeMailDomains.contains(fromReg) {
                out.append(SecurityFinding(level: .caution, title: "Replies go somewhere else",
                                           detail: "Sent from \(fromDomain), but replying would go to \(r.email)."))
            }
        }
        return out
    }

    /// Risk score stored with the message summary: 0, 1 (caution) or 2 (danger).
    static func headerRisk(_ m: ParsedMessage) -> Int {
        headerFindings(from: m.from.first, replyTo: m.replyTo, authenticationResults: m.authenticationResults)
            .map(\.level.rawValue).max() ?? 0
    }

    /// Full analysis for the reader: headers plus every link in the body.
    static func analyze(_ m: ParsedMessage) -> SecurityReport {
        var report = SecurityReport()
        report.findings = headerFindings(from: m.from.first, replyTo: m.replyTo, authenticationResults: m.authenticationResults)
        if let html = m.htmlBody {
            let (findings, hosts) = linkFindings(html)
            report.findings += findings
            report.suspiciousHosts = hosts
        }
        report.findings.sort { $0.level > $1.level }
        return report
    }

    private static let anchorRegex = try! NSRegularExpression(
        pattern: "<a\\b[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>", options: [.caseInsensitive])
    private static let domainLike = try! NSRegularExpression(
        pattern: "^(https?://)?(www\\.)?([a-z0-9-]+\\.)+[a-z]{2,}(/\\S*)?$", options: [.caseInsensitive])

    static func linkFindings(_ html: String) -> ([SecurityFinding], Set<String>) {
        var findings: [SecurityFinding] = []
        var hosts = Set<String>()
        var reported = Set<String>()
        let ns = html as NSString
        let matches = anchorRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(400)
        for m in matches {
            let href = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawText = ns.substring(with: m.range(at: 2))
            guard let url = URL(string: href), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased() else { continue }
            let hrefReg = registrableDomain(host)

            // A link pointing at a bare IP address, or hiding the real host behind "user@".
            if host.range(of: "^[0-9.]+$", options: .regularExpression) != nil || url.user != nil {
                hosts.insert(host)
                if reported.insert("ip|" + host).inserted {
                    findings.append(SecurityFinding(level: .danger, title: "Disguised link",
                                                    detail: "A link points to \(host) instead of a normal website address."))
                }
                continue
            }
            if host.contains("xn--") {
                hosts.insert(host)
                if reported.insert("puny|" + host).inserted {
                    findings.append(SecurityFinding(level: .caution, title: "Link uses unusual characters",
                                                    detail: "\(host) uses international characters that can disguise a fake site."))
                }
            }
            if let b = lookalikeBrand(for: hrefReg) {
                hosts.insert(host)
                if reported.insert("look|" + hrefReg).inserted {
                    findings.append(SecurityFinding(level: .danger, title: "Link to a look-alike site",
                                                    detail: "\(hrefReg) imitates \(b.name)."))
                }
            }

            // Visible text that is itself an address, but a different one from the real target.
            let text = HTMLText.plainText(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count < 120, !text.contains(" "),
                  domainLike.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else { continue }
            let shown = text.lowercased().hasPrefix("http") ? text : "https://" + text
            guard let shownHost = URL(string: shown)?.host?.lowercased() else { continue }
            let shownReg = registrableDomain(shownHost)
            if shownReg == hrefReg || trackingDomains.contains(hrefReg) || trackingDomains.contains(where: { host.hasSuffix($0) }) { continue }
            hosts.insert(host)
            if reported.insert("mis|" + shownReg + ">" + hrefReg).inserted {
                let claimsBrand = brands.contains { isOfficial(shownReg, for: $0) }
                findings.append(SecurityFinding(level: claimsBrand ? .danger : .caution, title: "Link goes somewhere else",
                                                detail: "A link shows \(shownHost) but actually opens \(host)."))
            }
            if findings.count >= 6 { break }
        }
        return (findings, hosts)
    }
}
