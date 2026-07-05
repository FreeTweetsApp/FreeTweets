import Foundation
import SwiftUI

/// User-chosen appearance, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

/// Profile picture shape, user-chosen in Settings.
enum AvatarShape: String, CaseIterable, Identifiable {
    case circle, squircle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle:   return "Circle"
        case .squircle: return "Squircle"
        }
    }
}

/// An account the user follows. Identity is the lowercased handle so we never
/// follow the same person twice under different casing.
struct Account: Identifiable, Codable, Hashable {
    var handle: String            // stored without the leading "@"
    var displayName: String?

    var id: String { handle.lowercased() }
    var atHandle: String { "@" + handle }
}

/// A photo or video attached to a post. Nitter RSS only carries a still image
/// for video (a thumbnail), so `isVideo` posts open in the browser to play.
struct MediaItem: Hashable {
    let url: URL
    let isVideo: Bool

    /// pbs.twimg.com photo URLs support size variants. They arrive in two
    /// shapes depending on the source: bare (`…/ID.jpg`, from RSS) and
    /// query-tagged (`…/ID.jpg?name=small&format=webp`, from HTML timelines).
    /// Size via the modern `?name=` query so we never corrupt an existing
    /// query — the old approach of appending `:size` to the whole string turned
    /// `…format=webp` into `…format=webp:small`, a 404.
    private func pbsVariant(_ size: String) -> URL? {
        guard let host = url.host, host.hasSuffix("twimg.com"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.path.hasPrefix("/media/") else { return nil }
        // Drop any legacy ":size" suffix on the path (mutually exclusive with
        // query sizing).
        comps.path = comps.path.replacingOccurrences(
            of: #":(thumb|small|medium|large|orig)$"#, with: "", options: .regularExpression)
        var items = comps.queryItems?.filter { $0.name != "name" } ?? []
        items.append(URLQueryItem(name: "name", value: size))
        comps.queryItems = items
        return comps.url
    }

    /// Sized-down variant for timeline thumbnails (fast to fetch and decode).
    var thumbURL: URL { pbsVariant("small") ?? url }
    /// Full-resolution variant for the lightbox.
    var fullURL: URL { pbsVariant("large") ?? url }
}

struct PostEngagement: Hashable {
    let replies: Int?
    let retweets: Int?
    let likes: Int?

    var hasVisibleValue: Bool {
        replies != nil || retweets != nil || likes != nil
    }
}

/// A single post pulled from a Nitter RSS feed. There is deliberately no
/// score, rank, or "engagement" field — order is decided only by `date`.
struct Post: Identifiable, Hashable {
    let id: String                // stable guid / permalink
    let authorHandle: String      // without "@"
    let authorName: String
    let text: String              // plain text (copy, search)
    let rich: AttributedString    // display: clickable links, media links hidden
    let date: Date
    let url: URL?
    let isRepost: Bool
    /// Handle of the followed account that reposted this (only when `isRepost`).
    /// Distinct from `authorHandle`, which is always the original poster.
    let repostedByHandle: String?
    let repostedByAvatarURL: URL?
    let avatarURL: URL?
    let media: [MediaItem]
    let engagement: PostEngagement?
    let threadID: String?
    let isThreadContinuation: Bool
    let isThreadEnd: Bool

    var authorID: String { authorHandle.lowercased() }

    /// The tweet's canonical x.com URL. `url` points at the Nitter instance the
    /// post was read from; anything labeled "Open on X" or copied for sharing
    /// should use this instead.
    var xURL: URL? {
        for text in [id, url?.absoluteString ?? ""] {
            if let range = text.range(of: #"(?<=/status/)\d+"#, options: .regularExpression)
                ?? text.range(of: #"^\d{10,}$"#, options: .regularExpression) {
                return URL(string: "https://x.com/\(authorHandle)/status/\(text[range])")
            }
        }
        return url
    }

    static func == (lhs: Post, rhs: Post) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// How the unified timeline is ordered. Explicitly user-chosen, never inferred.
enum SortOrder: String, CaseIterable, Identifiable {
    case newest        // reverse chronological
    case byAccount     // grouped by handle, newest within each

    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest:    return "Newest"
        case .byAccount: return "By account"
        }
    }
    var symbol: String {
        switch self {
        case .newest:    return "arrow.down"
        case .byAccount: return "person.2"
        }
    }
}
