import Foundation
import SwiftUI
import AppKit

/// Central state: which accounts you follow, the aggregated posts, the chosen
/// ordering, and the Nitter instance to read from. All mutation happens on the
/// main actor so the UI stays consistent.
@MainActor
final class FeedStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var posts: [Post] = []
    @Published var sortOrder: SortOrder = .newest
    @Published var isLoading = false
    @Published var lastRefreshed: Date?

    /// Per-account problems (whitelist gates, network errors) surfaced to the UI.
    @Published var issues: [String: String] = [:]

    /// Cached avatar URL per account id, for the sidebar.
    @Published var avatars: [String: URL] = [:]

    /// Cached profile posts for accounts opened from reposts but not followed.
    @Published var profilePosts: [String: [Post]] = [:]

    /// Last-good posts per account id. A transient rate-limit no longer wipes the
    /// timeline — we keep showing what we last fetched.
    private var postsByAccount: [String: [Post]] = [:]

    /// Nitter instance host, e.g. "xcancel.com". Configurable so the app keeps
    /// working as instances come and go.
    @Published var instanceHost: String {
        didSet { UserDefaults.standard.set(instanceHost, forKey: Keys.host) }
    }

    /// Light / Dark / System, applied app-wide via `preferredColorScheme`.
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var showLikes: Bool {
        didSet { UserDefaults.standard.set(showLikes, forKey: Keys.showLikes) }
    }

    @Published var showComments: Bool {
        didSet { UserDefaults.standard.set(showComments, forKey: Keys.showComments) }
    }

    @Published var showRetweets: Bool {
        didSet { UserDefaults.standard.set(showRetweets, forKey: Keys.showRetweets) }
    }

    /// Circle vs squircle profile pictures, applied app-wide.
    @Published var avatarShape: AvatarShape {
        didSet { UserDefaults.standard.set(avatarShape.rawValue, forKey: Keys.avatarShape) }
    }

    /// Refresh all feeds every 10 minutes while the app is open.
    @Published var autoRefresh: Bool {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: Keys.autoRefresh) }
    }

    private enum Keys {
        static let accounts = "xfeed.accounts"
        static let host = "xfeed.host"
        static let sort = "xfeed.sort"
        static let appearance = "xfeed.appearance"
        static let showLikes = "xfeed.showLikes"
        static let showComments = "xfeed.showComments"
        static let showRetweets = "xfeed.showRetweets"
        static let avatarShape = "xfeed.avatarShape"
        static let autoRefresh = "xfeed.autoRefresh"
    }

    /// Timeline HTML pages fetched per account. Kept low on purpose: each page
    /// is a separate request, and public instances rate-limit on request volume,
    /// so fewer pages means far fewer throttled/empty responses. RSS still
    /// supplies the bulk of the text.
    private static let maxTimelinePages = 2

    /// The instance that most recently served data, when it isn't the one
    /// configured in Settings (i.e. failover kicked in). Surfaced in the UI so
    /// it's clear where posts are coming from.
    @Published var activeHost: String?

    /// Instances that most recently served each protocol, tried first next
    /// time. Tracked separately because the ecosystem has split: some hosts
    /// serve RSS but wall their HTML (poast), others the reverse (tiekoetter).
    private var lastGoodRSSHost: String?
    private var lastGoodHTMLHost: String?

    /// "Load more" cursor per account id, from the last timeline page fetched.
    private var olderPageURL: [String: URL] = [:]
    /// Accounts with a load-older fetch in flight.
    @Published var loadingOlder: Set<String> = []

    init() {
        let d = UserDefaults.standard
        // "nitter.net" was the old default and is now dead (connection refused),
        // so migrate anyone still pointed at it onto a host that serves feeds
        // rather than making them eat retries against a black hole every refresh.
        let savedHost = d.string(forKey: Keys.host)
        instanceHost = (savedHost == nil || savedHost == "nitter.net") ? "nitter.poast.org" : savedHost!
        // "System" appearance was removed; migrate to whatever the system
        // resolves to right now so nothing visibly changes on update.
        if let saved = AppAppearance(rawValue: d.string(forKey: Keys.appearance) ?? "") {
            appearance = saved
        } else {
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            appearance = dark ? .dark : .light
        }
        showLikes = d.object(forKey: Keys.showLikes) as? Bool ?? true
        showComments = d.object(forKey: Keys.showComments) as? Bool ?? true
        showRetweets = d.object(forKey: Keys.showRetweets) as? Bool ?? true
        avatarShape = AvatarShape(rawValue: d.string(forKey: Keys.avatarShape) ?? "") ?? .circle
        autoRefresh = d.object(forKey: Keys.autoRefresh) as? Bool ?? true
        if let raw = d.string(forKey: Keys.sort), let s = SortOrder(rawValue: raw) {
            sortOrder = s
        }
        if let data = d.data(forKey: Keys.accounts),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
    }

    // MARK: - Following

    func follow(_ rawHandle: String) {
        let handle = Self.normalize(rawHandle)
        // Valid X handles only — otherwise a stray paste becomes a permanently
        // failing sidebar entry.
        guard handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil else { return }
        guard !accounts.contains(where: { $0.id == handle.lowercased() }) else { return }
        accounts.append(Account(handle: handle, displayName: nil))
        persistAccounts()
        Task { await refresh(only: handle) }
    }

    func isFollowing(_ handle: String) -> Bool {
        let id = Self.normalize(handle).lowercased()
        return accounts.contains { $0.id == id }
    }

    func unfollow(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        postsByAccount[account.id] = nil
        issues[account.id] = nil
        rebuildTimeline()
        persistAccounts()
    }

    func unfollow(handle: String) {
        let id = Self.normalize(handle).lowercased()
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        unfollow(account)
    }

    func setSort(_ order: SortOrder) {
        sortOrder = order
        UserDefaults.standard.set(order.rawValue, forKey: Keys.sort)
        rebuildTimeline()
    }

    func posts(forProfile handle: String) -> [Post] {
        let id = Self.normalize(handle).lowercased()
        let fallback = posts.filter { $0.authorID == id }
        return ordered(dedupe((profilePosts[id] ?? []) + fallback))
    }

    func loadProfile(_ rawHandle: String) async {
        let handle = Self.normalize(rawHandle)
        guard !handle.isEmpty else { return }
        let id = handle.lowercased()
        if profilePosts[id] != nil { return }

        let result = await Self.fetchAcrossInstances(
            handle: handle, rssHosts: rssPool(), htmlHosts: htmlPool()
        )
        switch result {
        case .success(let fetched):
            profilePosts[id] = fetched.posts
            olderPageURL[id] = fetched.nextPageURL
            cacheAvatars(from: fetched.posts)
            if let a = preferredAvatar(for: id, in: fetched.posts) { avatars[id] = a }
            issues[id] = nil
            noteWorkingHosts(rss: fetched.rssHost, html: fetched.htmlHost)
        case .failure(let e):
            issues[id] = e.message
        }
    }

    /// Fetch the full conversation (ancestors, the focused tweet, and replies)
    /// for a tapped post from its Nitter status page, so threads can be read
    /// in-app instead of bouncing to the browser.
    func loadConversation(for post: Post) async -> Result<[NitterTimelineParser.ConversationEntry], FeedError> {
        guard let statusID = Self.statusID(from: post.id)
            ?? post.url.flatMap({ Self.statusID(from: $0.absoluteString) }) else {
            return .failure(.init(message: "Couldn't build the thread link."))
        }

        for host in htmlPool() {
            switch await Self.fetchConversation(handle: post.authorHandle, statusID: statusID, host: host) {
            case .success(let entries):
                cacheAvatars(from: entries.map(\.post))
                noteWorkingHosts(rss: nil, html: host)
                return .success(entries)
            case .failure:
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        // Every instance failed. Naming the last one tried (often a walled host
        // the user never chose) is just confusing — give a clean, actionable
        // message instead.
        return .failure(.init(
            message: "Couldn't load this thread from any instance right now. Try again, or open it on X.",
            retryable: true))
    }

    /// Resolve a playable video stream for a tapped post. The tweet's own URL
    /// usually points at the RSS host (e.g. poast), whose HTML is bot-walled —
    /// so the page must be re-fetched from an instance that actually serves
    /// HTML. Try the HTML pool, rebuilding the status URL per host, and fall
    /// back to the original URL as a last resort.
    func videoStream(forTweet pageURL: URL) async -> URL? {
        let handle = pageURL.path.split(separator: "/").first.map(String.init)
        let statusID = Self.statusID(from: pageURL.absoluteString)

        if let handle, let statusID {
            for host in htmlPool() {
                guard let url = URL(string: "https://\(Self.cleanHost(host))/\(handle)/status/\(statusID)"),
                      let stream = await VideoResolver.streamURL(forTweet: url) else { continue }
                noteWorkingHosts(rss: nil, html: host)
                return stream
            }
        }
        return await VideoResolver.streamURL(forTweet: pageURL)
    }

    private static func fetchConversation(
        handle: String, statusID: String, host: String
    ) async -> Result<[NitterTimelineParser.ConversationEntry], FeedError> {
        guard let url = URL(string: "https://\(host)/\(handle)/status/\(statusID)") else {
            return .failure(.init(message: "Couldn't build the thread link."))
        }
        var request = URLRequest(url: url)
        request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return .failure(.init(message: "This tweet isn't available on \(host)."))
            }
            guard !data.isEmpty, let html = String(data: data, encoding: .utf8) else {
                return .failure(.init(message: "\(host) returned nothing for this thread.", retryable: true))
            }
            // Parse first: if we extracted real tweets, this is a genuine thread
            // — never a bot wall. Scanning the whole body for challenge words
            // false-positives whenever a reply happens to contain "captcha",
            // "not a bot", etc., so only fall back to challenge detection (scoped
            // to the page title) when nothing parsed.
            let entries = NitterTimelineParser.parseConversation(
                html, pageURL: url, ownerHandle: handle, instanceHost: host
            )
            if !entries.isEmpty { return .success(entries) }
            if isChallengeHTML(html) {
                return .failure(.init(message: "\(host) is behind a bot wall."))
            }
            return .failure(.init(message: "Couldn't read this thread from \(host).", retryable: true))
        } catch {
            return .failure(.init(message: error.localizedDescription, retryable: true))
        }
    }

    // MARK: - Networking

    /// Refresh every followed account (or just one).
    ///
    /// Requests are issued **sequentially with spacing**, not as a concurrent
    /// burst — public Nitter instances rate-limit aggressively and answer a burst
    /// with empty `200`s. Each account is retried with backoff, and a failure
    /// keeps the last-good posts rather than clearing them.
    func refresh(only single: String? = nil) async {
        let targets: [Account]
        if let single {
            // A handle we don't follow (e.g. a profile) must not touch the
            // followed-accounts cache — an empty target list here used to wipe
            // the entire timeline.
            targets = accounts.filter { $0.id == single.lowercased() }
            guard !targets.isEmpty else { return }
        } else {
            targets = accounts
            guard !targets.isEmpty else {
                postsByAccount.removeAll()
                rebuildTimeline()
                return
            }
        }
        isLoading = true
        defer { isLoading = false }

        for (index, account) in targets.enumerated() {
            // Rebuild the pools per account so hosts that just worked are tried
            // first for the next one.
            let result = await Self.fetchAcrossInstances(
                handle: account.handle, rssHosts: rssPool(), htmlHosts: htmlPool()
            )
            switch result {
            case .success(let fetched):
                postsByAccount[account.id] = fetched.posts
                olderPageURL[account.id] = fetched.nextPageURL
                cacheAvatars(from: fetched.posts)
                if let a = preferredAvatar(for: account.id, in: fetched.posts) { avatars[account.id] = a }
                issues[account.id] = nil
                noteWorkingHosts(rss: fetched.rssHost, html: fetched.htmlHost)
                updateDisplayName(for: account.id, from: fetched.posts)
            case .failure(let e):
                // Keep whatever we already have for this account.
                issues[account.id] = e.message
            }
            rebuildTimeline()

            // Space out subsequent requests to stay under the rate limiter.
            if index < targets.count - 1 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        lastRefreshed = Date()
    }

    /// Walk further back in an account's timeline from the stored "Load more"
    /// cursor, appending older posts to what's already shown.
    func loadOlder(_ accountID: String) async {
        guard let next = olderPageURL[accountID],
              let host = next.host,
              !loadingOlder.contains(accountID) else { return }
        let handle = accounts.first { $0.id == accountID }?.handle ?? accountID
        loadingOlder.insert(accountID)
        defer { loadingOlder.remove(accountID) }

        switch await Self.fetchTimelinePages(
            handle: handle, host: host, startURL: next,
            channelTitle: nil, channelAvatarURL: avatars[accountID]
        ) {
        case .success(let page):
            olderPageURL[accountID] = page.nextURL
            cacheAvatars(from: page.posts)
            if accounts.contains(where: { $0.id == accountID }) {
                postsByAccount[accountID] = Self.dedupePosts((postsByAccount[accountID] ?? []) + page.posts)
                rebuildTimeline()
            } else {
                profilePosts[accountID] = Self.dedupePosts((profilePosts[accountID] ?? []) + page.posts)
            }
        case .failure(let e):
            issues[accountID] = e.message
        }
    }

    /// Whether more of this account's history can be paged in.
    func hasOlder(_ accountID: String) -> Bool { olderPageURL[accountID] != nil }

    /// Host order for RSS: the configured instance is the user's explicit
    /// choice, so it leads; then the last host that actually served RSS.
    private func rssPool() -> [String] {
        Self.dedupeHosts([instanceHost, lastGoodRSSHost].compactMap { $0 } + knownInstances)
    }

    /// Host order for HTML pages (timelines, threads): the last host that
    /// served HTML leads, because instances that wall their pages fail every
    /// time — no point re-probing the configured host on each account.
    private func htmlPool() -> [String] {
        Self.dedupeHosts([lastGoodHTMLHost, instanceHost].compactMap { $0 } + knownInstances)
    }

    private static func dedupeHosts(_ raw: [String]) -> [String] {
        var pool: [String] = []
        for entry in raw {
            let host = cleanHost(entry)
            if !host.isEmpty, !pool.contains(host) { pool.append(host) }
        }
        return pool
    }

    /// Record which hosts served data, and flag failover in the UI when neither
    /// matches the configured instance.
    private func noteWorkingHosts(rss: String?, html: String?) {
        if let rss { lastGoodRSSHost = rss }
        if let html { lastGoodHTMLHost = html }
        let configured = Self.cleanHost(instanceHost)
        let serving = html ?? rss
        activeHost = (serving == nil || serving == configured) ? nil : serving
    }

    /// Remember the best display name we've seen so the sidebar can show it.
    private func updateDisplayName(for id: String, from posts: [Post]) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }),
              let name = posts.first(where: { $0.authorID == id && !$0.authorName.isEmpty
                  && $0.authorName.lowercased() != id })?.authorName,
              accounts[idx].displayName != name else { return }
        accounts[idx].displayName = name
        persistAccounts()
    }

    /// Everything one account fetch produced, and where it came from.
    private struct AccountFetch {
        let posts: [Post]
        let rssHost: String?
        let htmlHost: String?
        let nextPageURL: URL?
    }

    /// Fetch RSS and timeline HTML **independently**, each from the first host
    /// that serves it. The instance ecosystem has split: some hosts serve RSS
    /// but wall their HTML pages (poast), others serve HTML but 403 their RSS
    /// (tiekoetter) — requiring one host to provide both would lose whichever
    /// half the "best" host is missing.
    private static func fetchAcrossInstances(
        handle: String, rssHosts: [String], htmlHosts: [String]
    ) async -> Result<AccountFetch, FeedError> {
        guard !rssHosts.isEmpty else {
            return .failure(.init(message: "No instance configured."))
        }

        var collected: [Post] = []
        var firstError: FeedError?
        var rssHost: String?
        var htmlHost: String?
        var nextPageURL: URL?
        var channelTitle: String?
        var channelAvatarURL: URL?

        for host in rssHosts {
            guard let url = URL(string: "https://\(rssEndpointHost(for: host))/\(handle)/rss") else { continue }
            switch await fetchRSS(handle: handle, host: host, url: url) {
            case .success(let snapshot):
                collected += snapshot.posts
                channelTitle = snapshot.channelTitle
                channelAvatarURL = snapshot.avatarURL
                rssHost = host
            case .failure(let error):
                firstError = firstError ?? error
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            break
        }

        for host in htmlHosts {
            guard let startURL = URL(string: "https://\(host)/\(handle)") else { continue }
            switch await fetchTimelinePages(
                handle: handle, host: host, startURL: startURL,
                channelTitle: channelTitle, channelAvatarURL: channelAvatarURL
            ) {
            case .success(let page):
                collected += page.posts
                nextPageURL = page.nextURL
                htmlHost = host
            case .failure(let error):
                firstError = firstError ?? error
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            break
        }

        let merged = dedupePosts(collected)
        guard !merged.isEmpty else {
            return .failure(firstError ?? .init(message: "No instances reachable.", retryable: true))
        }
        return .success(.init(
            posts: merged, rssHost: rssHost, htmlHost: htmlHost, nextPageURL: nextPageURL
        ))
    }

    /// The host to fetch RSS from. xcancel serves feeds from a dedicated `rss.`
    /// subdomain (`xcancel.com/…/rss` 302-redirects there); talk to it directly
    /// so the whitelisting User-Agent isn't at the mercy of redirect handling.
    private static func rssEndpointHost(for host: String) -> String {
        host == "xcancel.com" ? "rss.xcancel.com" : host
    }

    private static func cleanHost(_ raw: String) -> String {
        raw.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// True when a response body is an interstitial challenge (Cloudflare,
    /// Anubis "not a bot", a captcha, etc.) rather than real content. These are
    /// persistent per-host, so callers treat them as non-retryable and move to
    /// the next instance instead of hammering the same one.
    static func isChallengePage(_ lowercasedBody: String) -> Bool {
        let markers = [
            "cloudflare", "attention required", "verifying you", "verifying your",
            "just a moment", "making sure you", "not a bot",
            "enable javascript", "captcha", "anubis"
        ]
        return markers.contains { lowercasedBody.contains($0) }
    }

    /// Challenge detection for a full HTML page, scoped to the `<title>` only.
    /// Interstitial pages announce themselves in the title ("Just a moment…",
    /// "Verifying you are human"); scanning the whole body instead would
    /// false-positive on tweet text that merely mentions "captcha", "not a
    /// bot", etc. Use this only once a real parse has already come up empty.
    static func isChallengeHTML(_ html: String) -> Bool {
        let title = firstCapture(#"<title[^>]*>([^<]*)</title>"#, in: html)?.lowercased() ?? ""
        return isChallengePage(title)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private struct FeedSnapshot {
        let posts: [Post]
        let channelTitle: String?
        let avatarURL: URL?
    }

    private static func fetchRSS(handle: String, host cleanHost: String, url: URL) async -> Result<FeedSnapshot, FeedError> {
        var request = URLRequest(url: url)
        request.setValue(
            Net.rssUserAgent,
            forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return .failure(.init(message: "@\(handle) not found on \(cleanHost)."))
            }
            // Empty body with a 200 is this instance's rate-limit signal.
            if data.isEmpty {
                return .failure(.init(message: "\(cleanHost) is rate-limiting (empty response). Retrying…", retryable: true))
            }
            // A challenge page comes back as HTML, not RSS — catch it before the
            // XML parser turns it into a bogus empty feed.
            if let body = String(data: data, encoding: .utf8), isChallengePage(body.lowercased()) {
                return .failure(.init(message: "\(cleanHost) is behind a bot wall."))
            }
            let feed = RSSParser().parse(data)

            // Detect instance-level gating (e.g. xcancel RSS whitelist, bot walls).
            let title = feed.channelTitle.lowercased()
            if title.contains("whitelist") || title.contains("not yet") {
                return .failure(.init(message: "\(cleanHost) needs to whitelist this reader. Email them to whitelist the User-Agent “\(Net.rssUserAgent)”, then Apply & Refresh."))
            }
            if title.contains("bot") || title.contains("verifying") || isChallengePage(title) {
                return .failure(.init(message: "\(cleanHost) is behind a bot wall."))
            }
            if feed.items.isEmpty {
                return .failure(.init(message: "No posts returned by \(cleanHost). It may be rate-limited or down.", retryable: true))
            }

            let avatarURL = FeedText.directImageURL(feed.channelImageURL)
            let posts = feed.items.compactMap { item -> Post? in
                let date = FeedText.date(from: item.pubDate) ?? Date(timeIntervalSince1970: 0)
                let source = item.description.isEmpty ? item.title : item.description
                let text = FeedText.plain(from: source)
                let rich = RichText.make(from: source, instanceHost: cleanHost)
                let media = FeedText.media(from: item.description)
                // `dc:creator` is always the ORIGINAL poster, even when this is a
                // repost — the followed account only appears in the RSS title
                // ("RT by @NASA: …") or by simply differing from the feed owner.
                let creator = item.creator.replacingOccurrences(of: "@", with: "")
                let authorHandle = creator.isEmpty ? handle : creator
                let idString = item.guid.isEmpty ? item.link : item.guid
                guard !idString.isEmpty else { return nil }
                let canonicalID = Self.statusID(from: idString) ?? idString
                let isRepost = item.title.uppercased().hasPrefix("RT ")
                    || authorHandle.lowercased() != handle.lowercased()

                let authorName = isRepost
                    ? (FeedText.authorName(from: item.title, fallbackHandle: authorHandle) ?? authorHandle)
                    : (FeedText.displayName(from: feed.channelTitle) ?? authorHandle)
                let repostedByHandle = isRepost
                    ? (FeedText.reposterHandle(from: item.title) ?? handle)
                    : nil
                let itemAvatarURL = FeedText.avatarURL(from: item.description)
                let finalAvatarURL = isRepost ? itemAvatarURL : (itemAvatarURL ?? avatarURL)

                return Post(
                    id: canonicalID,
                    authorHandle: authorHandle,
                    authorName: authorName,
                    text: text,
                    rich: rich,
                    date: date,
                    url: URL(string: item.link),
                    isRepost: isRepost,
                    repostedByHandle: repostedByHandle,
                    repostedByAvatarURL: isRepost ? avatarURL : nil,
                    avatarURL: finalAvatarURL,
                    media: media,
                    engagement: nil,
                    threadID: nil,
                    isThreadContinuation: false,
                    isThreadEnd: true
                )
            }
            return .success(.init(
                posts: posts,
                channelTitle: FeedText.displayName(from: feed.channelTitle),
                avatarURL: avatarURL
            ))
        } catch {
            return .failure(.init(message: error.localizedDescription))
        }
    }

    /// Posts scraped from an instance's HTML timeline, plus the cursor URL for
    /// paging further back (nil when the account has no more history).
    struct TimelineFetch {
        let posts: [Post]
        let nextURL: URL?
    }

    private static func fetchTimelinePages(
        handle: String,
        host cleanHost: String,
        startURL: URL,
        channelTitle: String?,
        channelAvatarURL: URL?
    ) async -> Result<TimelineFetch, FeedError> {
        var nextURL: URL? = startURL
        var collected: [Post] = []

        for page in 0..<maxTimelinePages {
            guard let url = nextURL else { break }
            var request = URLRequest(url: url)
            request.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    return .failure(.init(message: "@\(handle) not found on \(cleanHost)."))
                }
                if data.isEmpty {
                    if collected.isEmpty {
                        return .failure(.init(message: "\(cleanHost) is rate-limiting (empty response). Retrying...", retryable: true))
                    }
                    break
                }
                guard let html = String(data: data, encoding: .utf8) else {
                    if collected.isEmpty { return .failure(.init(message: "Could not read timeline from \(cleanHost).", retryable: true)) }
                    break
                }

                let parsed = NitterTimelineParser.parse(
                    html,
                    pageURL: url,
                    ownerHandle: handle,
                    channelTitle: channelTitle,
                    channelAvatarURL: channelAvatarURL,
                    instanceHost: cleanHost
                )
                // Only treat an empty parse as a possible bot wall (title-scoped
                // so tweet text can't trigger it); a page that yielded posts is
                // real content regardless of what any tweet says.
                if parsed.posts.isEmpty {
                    if Self.isChallengeHTML(html) {
                        return .failure(.init(message: "\(cleanHost) is behind a bot wall."))
                    }
                    if collected.isEmpty {
                        return .failure(.init(message: "No timeline posts returned by \(cleanHost). It may be rate-limited or down.", retryable: true))
                    }
                    break
                }
                collected += parsed.posts
                guard let more = parsed.nextURL, more != url else { nextURL = nil; break }
                nextURL = more

                if page < maxTimelinePages - 1 {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            } catch {
                if collected.isEmpty { return .failure(.init(message: error.localizedDescription)) }
                break
            }
        }

        let posts = dedupePosts(collected)
        if posts.isEmpty {
            return .failure(.init(message: "No timeline posts returned by \(cleanHost). It may be rate-limited or down.", retryable: true))
        }
        return .success(.init(posts: posts, nextURL: nextURL))
    }

    // MARK: - Ordering & de-duplication

    /// Rebuild the visible `posts` from the per-account cache using the current
    /// sort order. Called after any fetch, sort change, or unfollow.
    private func rebuildTimeline() {
        let all = postsByAccount.values.flatMap { $0 }
        posts = ordered(dedupe(all))
    }

    private func cacheAvatars(from posts: [Post]) {
        for post in posts {
            if let avatarURL = post.avatarURL {
                avatars[post.authorID] = avatarURL
            }
            if let handle = post.repostedByHandle, let avatarURL = post.repostedByAvatarURL {
                avatars[handle.lowercased()] = avatarURL
            }
        }
    }

    private func preferredAvatar(for id: String, in posts: [Post]) -> URL? {
        posts.first { $0.authorID == id }?.avatarURL
            ?? posts.first { $0.repostedByHandle?.lowercased() == id }?.repostedByAvatarURL
            ?? posts.first?.avatarURL
    }

    /// Sort the timeline. Posts that belong to the same thread are kept together
    /// as one cluster and always read top-down (oldest → newest) inside it —
    /// otherwise "Newest" sort would show a 3-part thread as 3, 2, 1.
    private func ordered(_ input: [Post]) -> [Post] {
        struct Cluster {
            var posts: [Post]
            var newest: Date
            var oldest: Date
            let author: String
        }
        var indexByKey: [String: Int] = [:]
        var clusters: [Cluster] = []
        for post in input {
            let key = post.threadID.map { "thread-\($0)" } ?? "post-\(post.id)"
            if let i = indexByKey[key] {
                clusters[i].posts.append(post)
                clusters[i].newest = max(clusters[i].newest, post.date)
                clusters[i].oldest = min(clusters[i].oldest, post.date)
            } else {
                indexByKey[key] = clusters.count
                clusters.append(Cluster(
                    posts: [post], newest: post.date, oldest: post.date,
                    author: post.authorHandle.lowercased()
                ))
            }
        }

        // Reading order within a thread; tweet IDs are chronological (snowflake),
        // so they break ties for posts published the same minute.
        for i in clusters.indices where clusters[i].posts.count > 1 {
            clusters[i].posts.sort { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                if lhs.id.count != rhs.id.count { return lhs.id.count < rhs.id.count }
                return lhs.id < rhs.id
            }
        }

        switch sortOrder {
        case .newest:
            clusters.sort { $0.newest > $1.newest }
        case .byAccount:
            clusters.sort {
                if $0.author != $1.author { return $0.author < $1.author }
                return $0.newest > $1.newest
            }
        }
        return clusters.flatMap(\.posts)
    }

    private func dedupe(_ input: [Post]) -> [Post] {
        Self.dedupePosts(input)
    }

    private static func dedupePosts(_ input: [Post]) -> [Post] {
        var order: [String] = []
        var byKey: [String: Post] = [:]

        for post in input {
            let key = statusID(from: post.id)
                ?? post.url.flatMap { statusID(from: $0.absoluteString) }
                ?? post.id
            if let existing = byKey[key] {
                byKey[key] = richerPost(existing, post)
            } else {
                order.append(key)
                byKey[key] = post
            }
        }

        return order.compactMap { byKey[$0] }
    }

    private static func richerPost(_ lhs: Post, _ rhs: Post) -> Post {
        func score(_ post: Post) -> Int {
            var value = 0
            if post.engagement?.replies != nil { value += 8 }
            if post.engagement?.likes != nil { value += 8 }
            if post.threadID != nil { value += 5 }
            if post.avatarURL != nil { value += 3 }
            value += min(post.media.count, 4)
            value += min(post.text.count / 80, 4)
            return value
        }
        return score(rhs) > score(lhs) ? rhs : lhs
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

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Keys.accounts)
        }
    }

    private static func normalize(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = h.range(of: #"(x|twitter)\.com/"#, options: .regularExpression) {
            h = String(h[range.upperBound...])
        }
        h = h.replacingOccurrences(of: "@", with: "")
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if let q = h.firstIndex(of: "?") { h = String(h[..<q]) }
        return h.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FeedError: Error {
    let message: String
    var retryable: Bool = false
}

extension FeedText {
    /// Nitter channel titles look like "Display Name / @handle". Pull the name.
    static func displayName(from channelTitle: String) -> String? {
        let parts = channelTitle.components(separatedBy: " / ")
        let name = parts.first?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false) ? name : nil
    }

    /// Nitter tags reposts in the item title as "RT by @Handle: …". Extract the
    /// handle of the account that reposted (as distinct from the original author).
    static func reposterHandle(from title: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"^RT by @(\S+?):"#, options: .caseInsensitive) else { return nil }
        let ns = title as NSString
        guard let m = re.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func authorName(from title: String, fallbackHandle: String) -> String? {
        var text = title
        if let range = text.range(of: #"^RT by @\S+:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("@") { return fallbackHandle }
        return trimmed
    }
}
