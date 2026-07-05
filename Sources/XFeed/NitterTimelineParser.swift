import Foundation

struct NitterTimelinePage {
    let posts: [Post]
    let nextURL: URL?
}

enum NitterTimelineParser {
    static func parse(
        _ html: String,
        pageURL: URL,
        ownerHandle: String,
        channelTitle: String?,
        channelAvatarURL: URL?,
        instanceHost: String
    ) -> NitterTimelinePage {
        let blocks = timelineItemBlocks(in: html)
        let posts = blocks.compactMap { block in
            post(
                from: block.html,
                pageURL: pageURL,
                ownerHandle: ownerHandle,
                channelTitle: channelTitle,
                channelAvatarURL: channelAvatarURL,
                instanceHost: instanceHost,
                threadID: block.threadID,
                isThreadContinuation: block.isThreadContinuation,
                isThreadEnd: block.isThreadEnd
            )
        }
        return NitterTimelinePage(posts: posts, nextURL: nextURL(in: html, pageURL: pageURL))
    }

    private static func post(
        from block: String,
        pageURL: URL,
        ownerHandle: String,
        channelTitle: String?,
        channelAvatarURL: URL?,
        instanceHost: String,
        threadID: String?,
        isThreadContinuation: Bool,
        isThreadEnd: Bool,
        inferRepostFromHandleMismatch: Bool = true
    ) -> Post? {
        guard block.contains("tweet-body"),
              block.contains("tweet-content"),
              let rawLink = firstCapture(#"<a[^>]*class="[^"]*\btweet-link\b[^"]*"[^>]*href="([^"]+)""#, in: block)
                ?? firstCapture(#"href="([^"]*/status/\d+[^"]*)""#, in: block),
              let postURL = absoluteURL(rawLink, relativeTo: pageURL) else { return nil }

        let canonicalURL = withoutFragment(postURL)
        let idString = statusID(from: canonicalURL.absoluteString) ?? canonicalURL.absoluteString
        let authorHandle = cleanHandle(
            firstCapture(#"data-username="?([^"\s>]+)"?"#, in: block)
            ?? firstCapture(#"<a[^>]*class="[^"]*\busername\b[^"]*"[^>]*>\s*@?([^<]+)"#, in: block)
            ?? ownerHandle
        )
        let authorName = cleanText(
            firstCapture(#"<a[^>]*class="[^"]*\bfullname\b[^"]*"[^>]*>(.*?)</a>"#, in: block)
        )
        let contentHTML = firstCapture(
            #"<div[^>]*class="[^"]*\btweet-content\b[^"]*"[^>]*>(.*?)</div>"#,
            in: block
        ) ?? ""
        let retweetHTML = firstCapture(#"<div[^>]*class="[^"]*\bretweet-header\b[^"]*"[^>]*>(.*?)</div>"#, in: block)
        // In a conversation, replies by other people aren't reposts — only an
        // explicit retweet header means "reposted". In a timeline, a differing
        // author does imply the owner reposted someone else's tweet.
        let isRepost = retweetHTML != nil
            || (inferRepostFromHandleMismatch && authorHandle.lowercased() != ownerHandle.lowercased())
        let titleDate = firstCapture(
            #"<span[^>]*class="[^"]*\btweet-date\b[^"]*"[^>]*>.*?title="([^"]+)""#,
            in: block
        )
        let date = dateFromHTMLTitle(titleDate)
            ?? dateFromTweetID(in: canonicalURL.absoluteString)
            ?? Date(timeIntervalSince1970: 0)
        let avatarURL = avatarURL(in: block, pageURL: pageURL) ?? (isRepost ? nil : channelAvatarURL)

        return Post(
            id: idString,
            authorHandle: authorHandle,
            authorName: authorName ?? channelTitle ?? authorHandle,
            text: FeedText.plain(from: contentHTML),
            rich: RichText.make(from: contentHTML, instanceHost: instanceHost),
            date: date,
            url: canonicalURL,
            isRepost: isRepost,
            repostedByHandle: isRepost ? ownerHandle : nil,
            repostedByAvatarURL: isRepost ? channelAvatarURL : nil,
            avatarURL: avatarURL,
            media: mediaItems(in: block, pageURL: pageURL),
            engagement: engagement(in: block),
            threadID: threadID,
            isThreadContinuation: isThreadContinuation,
            isThreadEnd: isThreadEnd
        )
    }

    /// One tweet within a status-page conversation, plus whether it's the tweet
    /// the page is centered on (shown highlighted).
    struct ConversationEntry {
        let post: Post
        let isMain: Bool
    }

    /// Parses a Nitter status page (`/<user>/status/<id>`) into the full
    /// conversation: ancestor tweets, the focused tweet, then replies — in
    /// reading order.
    static func parseConversation(
        _ html: String,
        pageURL: URL,
        ownerHandle: String,
        instanceHost: String
    ) -> [ConversationEntry] {
        // Every tweet in the thread is either a `.timeline-item` (ancestors and
        // replies) or the single `.main-tweet` (the focused tweet).
        let boundary = #"<div[^>]*class="[^"]*\b(?:timeline-item|main-tweet)\b[^"]*"[^>]*>"#
        let starts = matches(boundary, in: html).map(\.range.location)
        guard !starts.isEmpty else { return [] }
        let ns = html as NSString

        var entries: [ConversationEntry] = []
        var seen = Set<String>()
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : ns.length
            guard end > start else { continue }
            let block = ns.substring(with: NSRange(location: start, length: end - start))
            let isMain = firstTagClass(in: block)?.contains("main-tweet") == true
            guard let post = post(
                from: block,
                pageURL: pageURL,
                ownerHandle: ownerHandle,
                channelTitle: nil,
                channelAvatarURL: nil,
                instanceHost: instanceHost,
                threadID: nil,
                isThreadContinuation: false,
                isThreadEnd: true,
                inferRepostFromHandleMismatch: false
            ) else { continue }
            let key = statusID(from: post.id) ?? post.id
            guard seen.insert(key).inserted else { continue }
            entries.append(.init(post: post, isMain: isMain))
        }
        return entries
    }

    private struct TimelineBlock {
        let html: String
        let threadID: String?
        let isThreadContinuation: Bool
        let isThreadEnd: Bool
    }

    private static func timelineItemBlocks(in html: String) -> [TimelineBlock] {
        let pattern = #"<div[^>]*class="[^"]*\btimeline-item\b[^"]*"[^>]*>"#
        let starts = matches(pattern, in: html).map(\.range.location)
        guard !starts.isEmpty else { return [] }
        let ns = html as NSString
        let rawBlocks: [(html: String, isThread: Bool)] = starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : ns.length
            guard end > start else { return nil }
            let block = ns.substring(with: NSRange(location: start, length: end - start))
            return (block, firstTagClass(in: block)?.contains("thread") == true)
        }

        var result: [TimelineBlock] = []
        var currentThreadID: String?
        var threadIndex = 0
        for index in rawBlocks.indices {
            let block = rawBlocks[index]
            let nextIsThread = index + 1 < rawBlocks.count && rawBlocks[index + 1].isThread
            if block.isThread {
                if currentThreadID == nil {
                    currentThreadID = firstStatusID(in: block.html) ?? UUID().uuidString
                    threadIndex = 0
                }
                result.append(.init(
                    html: block.html,
                    threadID: currentThreadID,
                    isThreadContinuation: threadIndex > 0,
                    isThreadEnd: !nextIsThread
                ))
                threadIndex += 1
                if !nextIsThread { currentThreadID = nil }
            } else {
                currentThreadID = nil
                result.append(.init(
                    html: block.html,
                    threadID: nil,
                    isThreadContinuation: false,
                    isThreadEnd: true
                ))
            }
        }
        return result
    }

    private static func nextURL(in html: String, pageURL: URL) -> URL? {
        let pattern = #"<div[^>]*class="[^"]*\bshow-more\b[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>\s*Load more\s*</a>"#
        let all = matches(pattern, in: html)
        guard let last = all.last else { return nil }
        let ns = html as NSString
        return absoluteURL(ns.substring(with: last.range(at: 1)), relativeTo: pageURL)
    }

    private static func avatarURL(in block: String, pageURL: URL) -> URL? {
        guard let raw = firstCapture(
            #"<a[^>]*class="[^"]*\btweet-avatar\b[^"]*"[^>]*>.*?<img[^>]*src="([^"]+)""#,
            in: block
        ) else { return nil }
        // Instance-proxied avatar paths (/pic/…) get rewritten to the CDN;
        // already-direct pbs URLs pass through unchanged.
        if let direct = FeedText.directImageURL(raw), direct.host?.hasSuffix("twimg.com") == true {
            return direct
        }
        return absoluteURL(raw, relativeTo: pageURL)
    }

    private static func mediaItems(in block: String, pageURL: URL) -> [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []

        func appendMatches(_ pattern: String, forceVideo: Bool = false) {
            let ns = block as NSString
            for match in matches(pattern, in: block) {
                let tag = ns.substring(with: match.range)
                let raw = ns.substring(with: match.range(at: 1))
                let lower = (tag + raw).lowercased()
                guard !lower.contains("tweet-avatar"),
                      !lower.contains("profile_images"),
                      !lower.contains("profile_banners"),
                      !lower.contains("emoji"),
                      !lower.contains("twemoji") else { continue }
                guard lower.contains("/pic/") || lower.contains("pbs.twimg.com/media")
                        || lower.contains("video_thumb") || lower.contains("amplify_video") else { continue }
                // Prefer the direct CDN URL over the instance's (often walled)
                // /pic/ proxy; fall back to instance-relative resolution.
                guard let url = FeedText.directImageURL(raw).flatMap({
                    $0.host?.hasSuffix("twimg.com") == true ? $0 : nil
                }) ?? absoluteURL(raw, relativeTo: pageURL) else { continue }
                guard seen.insert(url.absoluteString).inserted else { continue }
                let isVideo = forceVideo || lower.contains("video_thumb") || lower.contains("amplify_video")
                result.append(MediaItem(url: url, isVideo: isVideo))
            }
        }

        appendMatches(#"<img[^>]*\bsrc="([^"]+)"[^>]*>"#)
        appendMatches(#"<video[^>]*\bposter="([^"]+)"[^>]*>"#, forceVideo: true)
        return result
    }

    private static func engagement(in block: String) -> PostEngagement? {
        // Each stat sits in a nested `<div class="icon-container">…</div>`, so a
        // non-greedy `(.*?)</div>` on the `tweet-stats` container stops at the
        // first inner </div> and loses everything after the comment count. Take
        // the whole tail from `tweet-stats` and read each count off its icon.
        guard let statsRange = block.range(of: "tweet-stats") else { return nil }
        let stats = String(block[statsRange.lowerBound...])
        let engagement = PostEngagement(
            replies: statValue(afterIcon: "comment", in: stats),
            retweets: statValue(afterIcon: "retweet", in: stats),
            likes: statValue(afterIcon: "heart", in: stats)
        )
        return engagement.hasVisibleValue ? engagement : nil
    }

    /// Reads the number that follows a given stat icon, e.g. the `1,234` in
    /// `<span class="icon-heart"></span>&nbsp;1,234`.
    private static func statValue(afterIcon name: String, in stats: String) -> Int? {
        guard let raw = firstCapture(
            #"icon-\#(name)\b[^>]*>\s*</span>[^0-9<]*([0-9][0-9,\.]*\s*[KkMm]?)"#,
            in: stats
        ) else { return nil }
        return statValue(from: raw)
    }

    private static func statValue(from html: String) -> Int? {
        // Drop every space, not just the ends — "1.2 K" must parse as 1.2K.
        let text = String(
            FeedText.decodeEntities(stripTags(html))
                .replacingOccurrences(of: ",", with: "")
                .lowercased()
                .filter { !$0.isWhitespace }
        )
        guard !text.isEmpty else { return 0 }
        let multiplier: Double
        let numberText: String
        if text.hasSuffix("k") {
            multiplier = 1_000
            numberText = String(text.dropLast())
        } else if text.hasSuffix("m") {
            multiplier = 1_000_000
            numberText = String(text.dropLast())
        } else {
            multiplier = 1
            numberText = text
        }
        guard let value = Double(numberText) else { return nil }
        return Int((value * multiplier).rounded())
    }

    private static func dateFromHTMLTitle(_ raw: String?) -> Date? {
        guard var s = raw else { return nil }
        s = FeedText.decodeEntities(s)
            .replacingOccurrences(of: "·", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for formatter in htmlDateFormatters {
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    private static func dateFromTweetID(in text: String) -> Date? {
        guard let raw = firstCapture(#"/status/(\d+)"#, in: text),
              let id = UInt64(raw) else { return nil }
        let milliseconds = Int64(id >> 22) + 1_288_834_974_657
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
    }

    private static let htmlDateFormatters: [DateFormatter] = {
        [
            "MMM d, yyyy h:mm a zzz",
            "MMMM d, yyyy h:mm a zzz",
            "MMM d, yyyy HH:mm:ss zzz",
            "MMMM d, yyyy HH:mm:ss zzz"
        ].map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = pattern
            return formatter
        }
    }()

    private static func cleanHandle(_ raw: String) -> String {
        var handle = FeedText.decodeEntities(stripTags(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        handle = handle.replacingOccurrences(of: "@", with: "")
        if let slash = handle.firstIndex(of: "/") { handle = String(handle[..<slash]) }
        return handle
    }

    private static func cleanText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = FeedText.decodeEntities(stripTags(raw))
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func firstTagClass(in block: String) -> String? {
        firstCapture(#"^<div[^>]*class="([^"]+)""#, in: block)
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func withoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    private static func firstStatusID(in text: String) -> String? {
        statusID(from: firstCapture(#"href="([^"]*/status/\d+[^"]*)""#, in: text) ?? text)
    }

    private static func statusID(from text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"/status/(\d+)|^(\d{10,})$"#) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return ns.substring(with: match.range(at: index))
        }
        return nil
    }

    private static func absoluteURL(_ raw: String, relativeTo pageURL: URL) -> URL? {
        let cleaned = FeedText.decodeEntities(raw)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: cleaned, relativeTo: pageURL)?.absoluteURL
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let match = matches(pattern, in: text).first, match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
