import SwiftUI
import Foundation

enum RichText {
    /// Turn a tweet's description HTML into an AttributedString: plain text stays
    /// plain, `<a>` links become tappable, links that only reference the attached
    /// media or the post's own permalink are dropped, and whitespace is collapsed
    /// so paragraphs aren't separated by big gaps.
    static func make(from html: String, instanceHost: String) -> AttributedString {
        var s = html
        for (tag, repl) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"),
                            ("</p>", "\n\n"), ("<p>", "")] {
            s = s.replacingOccurrences(of: tag, with: repl, options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: #"<img[^>]*>"#, with: "", options: .regularExpression)

        // 1. Tokenize into characters tagged with an optional link.
        var chars: [(ch: Character, url: URL?)] = []
        func append(_ text: String, _ url: URL?) { for c in text { chars.append((c, url)) } }

        let ns = s as NSString
        let anchorRe = try! NSRegularExpression(
            pattern: #"<a\s+[^>]*?href="([^"]*)"[^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])

        var cursor = 0
        anchorRe.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                append(plainText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))), nil)
            }
            cursor = match.range.location + match.range.length

            let href = ns.substring(with: match.range(at: 1))
            let inner = FeedText.decodeEntities(stripTags(ns.substring(with: match.range(at: 2))))
            if isHiddenLink(href: href, text: inner, host: instanceHost) { return }
            append(inner, URL(string: normalizedHref(href, host: instanceHost)))
        }
        if cursor < ns.length {
            append(plainText(ns.substring(from: cursor)), nil)
        }

        // 2. Collapse whitespace: runs with ≥2 newlines → one blank line, a single
        //    newline → line break, otherwise a single space. Drop leading runs.
        var norm: [(ch: Character, url: URL?)] = []
        var i = 0
        while i < chars.count {
            if chars[i].ch.isWhitespace {
                var j = i, newlines = 0
                while j < chars.count, chars[j].ch.isWhitespace {
                    if chars[j].ch == "\n" { newlines += 1 }
                    j += 1
                }
                if !norm.isEmpty {
                    if newlines >= 2 { norm.append(("\n", nil)); norm.append(("\n", nil)) }
                    else if newlines == 1 { norm.append(("\n", nil)) }
                    else { norm.append((" ", nil)) }
                }
                i = j
            } else {
                norm.append(chars[i]); i += 1
            }
        }
        // Trim trailing whitespace and dangling quote separators ("— ", "·").
        let trailingJunk = Set<Character>([" ", "\n", "\t", "—", "–", "-", "·", "…"])
        while let last = norm.last, trailingJunk.contains(last.ch) { norm.removeLast() }

        // 3. Rebuild, grouping consecutive characters that share a link.
        var result = AttributedString()
        var k = 0
        while k < norm.count {
            let url = norm[k].url
            var str = ""
            while k < norm.count, norm[k].url == url { str.append(norm[k].ch); k += 1 }
            var run = AttributedString(str)
            if let url { run.link = url; run.foregroundColor = .accentColor }
            result += run
        }
        return result
    }

    // MARK: - Helpers

    private static func plainText(_ raw: String) -> String {
        var text = FeedText.decodeEntities(stripTags(raw))
        text = text.replacingOccurrences(of: #"https?://[^\s]*?/pic/[^\s]*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"pic\.(x|twitter)\.com/\S+"#, with: "", options: .regularExpression)
        return text
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    /// Hide links that only point at the post's media or its own/quoted permalink
    /// on the instance — the media is shown as a thumbnail, so the URL is noise.
    private static func isHiddenLink(href: String, text: String, host: String) -> Bool {
        if href.contains("/pic/") || href.contains("/video/") { return true }
        if text.range(of: #"^pic\.(x|twitter)\.com/"#, options: .regularExpression) != nil { return true }
        if href.hasPrefix("/"), href.contains("/status/") { return true }
        if let comps = URLComponents(string: href), let h = comps.host,
           h == host || h.contains("nitter"), comps.path.contains("/status/") {
            return true
        }
        // A visible link whose text is itself an instance URL.
        if text.contains(host) && (text.hasPrefix("http") || text.hasPrefix(host)) { return true }
        return false
    }

    /// Rewrite instance-internal links (mentions, hashtags) back to x.com; leave
    /// external links untouched.
    private static func normalizedHref(_ href: String, host: String) -> String {
        if href.hasPrefix("/") { return "https://x.com" + href }
        guard var comps = URLComponents(string: href) else { return href }
        if let h = comps.host, h == host || h.contains("nitter") {
            comps.scheme = "https"
            comps.host = "x.com"
            return comps.string ?? href
        }
        return href
    }
}
