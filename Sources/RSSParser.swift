import Foundation

/// Raw item as it appears in a Nitter RSS feed.
struct RSSItem {
    var title = ""
    var creator = ""
    var description = ""
    var pubDate = ""
    var link = ""
    var guid = ""
}

struct RSSFeed {
    var channelTitle = ""
    var channelImageURL = ""   // account avatar (channel <image><url>)
    var items: [RSSItem] = []
}

/// A small, dependency-free RSS parser built on `XMLParser`. It handles both
/// escaped-HTML and CDATA descriptions, which Nitter uses interchangeably.
final class RSSParser: NSObject, XMLParserDelegate {
    private var feed = RSSFeed()
    private var current: RSSItem?
    private var buffer = ""
    private var inItem = false
    private var inImage = false

    func parse(_ data: Data) -> RSSFeed {
        feed = RSSFeed()
        current = nil
        inItem = false
        inImage = false
        buffer = ""
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return feed
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        buffer = ""
        let name = qName ?? elementName
        if name == "item" {
            inItem = true
            current = RSSItem()
        } else if name == "image", !inItem {
            inImage = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = qName ?? elementName
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem {
            switch name {
            case "title":       current?.title = text
            case "dc:creator":  current?.creator = text
            case "description": current?.description = text
            case "pubDate":     current?.pubDate = text
            case "link":        current?.link = text
            case "guid":        current?.guid = text
            case "item":
                if let c = current { feed.items.append(c) }
                current = nil
                inItem = false
            default: break
            }
        } else if inImage {
            switch name {
            case "url":   if feed.channelImageURL.isEmpty { feed.channelImageURL = text }
            case "image": inImage = false
            default: break   // ignore <title>/<link> nested in <image>
            }
        } else if name == "title", feed.channelTitle.isEmpty {
            feed.channelTitle = text
        }
        buffer = ""
    }
}

// MARK: - Helpers

enum FeedText {
    private static let dateFormatters: [DateFormatter] = {
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",     // RFC-822 (abbrev month)
            "EEE, dd MMMM yyyy HH:mm:ss zzz",    // full month name
            "EEE, dd MMM yyyy HH:mm:ss Z"
        ]
        return patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = p
            return f
        }
    }()

    static func date(from raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in dateFormatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Instances proxy images through `/pic/<url-encoded path>`, but those proxy
    /// endpoints sit behind the same bot walls as the HTML pages (poast's returns
    /// 503 to everything). The encoded path is just a twimg.com location, so
    /// rewrite to the direct CDN URL — it serves any User-Agent, and it's the
    /// same bytes without a rate-limited middleman.
    static func directImageURL(_ raw: String) -> URL? {
        let cleaned = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let picRange = cleaned.range(of: "/pic/") else { return URL(string: cleaned) }
        var path = String(cleaned[picRange.upperBound...])
            .removingPercentEncoding ?? String(cleaned[picRange.upperBound...])
        // Encoded paths come in two shapes: "pbs.twimg.com/…" (host included)
        // and "media/…" or "video.twimg.com/…" (host-relative to pbs).
        if path.hasPrefix("http") { return URL(string: path) }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasPrefix("pbs.twimg.com") || path.hasPrefix("video.twimg.com") {
            return URL(string: "https://" + path)
        }
        return URL(string: "https://pbs.twimg.com/" + path)
    }

    /// Extract media (photos + video thumbnails) from an item's description HTML.
    /// Nitter marks video with `video_thumb` / `amplify_video_thumb` in the path.
    static func media(from html: String) -> [MediaItem] {
        let pattern = #"<img[^>]*\bsrc="([^"]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var result: [MediaItem] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let url = directImageURL(raw), seen.insert(url.absoluteString).inserted else { continue }
            let isVideo = raw.contains("video_thumb") || raw.contains("amplify_video")
            result.append(MediaItem(url: url, isVideo: isVideo))
        }
        return result
    }

    static func avatarURL(from html: String) -> URL? {
        let pattern = #"<img[^>]*\bsrc="([^"]+)"[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let raw = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
            let lower = (tag + raw).lowercased()
            if lower.contains("profile_images") || lower.contains("avatar") || lower.contains("tweet-avatar") {
                return directImageURL(raw)
            }
        }
        return nil
    }

    /// Decode the handful of HTML entities Nitter emits.
    static func decodeEntities(_ s: String) -> String {
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&hellip;": "…"
        ]
        var out = s
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    /// Strip HTML tags and decode entities, so the timeline shows clean plain text.
    static func plain(from html: String) -> String {
        var out = ""
        var insideTag = false
        for ch in html {
            if ch == "<" { insideTag = true; continue }
            if ch == ">" { insideTag = false; out += " "; continue }
            if !insideTag { out.append(ch) }
        }
        out = decodeEntities(out)

        // Collapse runs of whitespace introduced by removed tags.
        let collapsed = out
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return collapsed
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
