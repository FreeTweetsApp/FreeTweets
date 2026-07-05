import SwiftUI
import AppKit

/// Deterministic accent color per handle (stable across launches, unlike
/// Swift's randomized `hashValue`). Used as the avatar fallback.
func avatarColor(for handle: String) -> Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
    let sum = handle.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[sum % palette.count]
}

/// Profile picture: real image when available, colored initial while loading
/// or if it fails. Shape (circle / squircle) follows the user's setting.
struct AvatarView: View {
    @EnvironmentObject var store: FeedStore
    let url: URL?
    let handle: String
    var size: CGFloat = 40

    private var fallback: some View {
        avatarColor(for: handle)
            .overlay(
                Text(String(handle.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private var shape: AnyShape {
        switch store.avatarShape {
        case .circle:
            return AnyShape(Circle())
        case .squircle:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        }
    }

    var body: some View {
        RemoteImage(url: url, maxPixel: 160) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            fallback
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

struct PostRow: View {
    @EnvironmentObject var store: FeedStore
    let post: Post
    let onAuthorSelected: (String) -> Void
    /// Tapping the row opens the in-app thread. When nil (e.g. inside the thread
    /// view itself) the row isn't tappable for navigation.
    var onOpenThread: ((Post) -> Void)? = nil
    /// The focused tweet in a conversation, drawn with a subtle highlight.
    var highlighted: Bool = false
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if post.threadID != nil {
                threadRail
            }

            VStack(alignment: .leading, spacing: 6) {
                if post.threadID != nil && !post.isThreadContinuation {
                    threadBanner
                }
                if post.isRepost, let reposter = post.repostedByHandle {
                    repostBanner(reposter)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, post.threadID == nil ? 12 : 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let onOpenThread {
                onOpenThread(post)
            } else if let url = post.url {
                NSWorkspace.shared.open(url)
            }
        }
        .contextMenu {
            if onOpenThread != nil {
                Button("View Thread") { onOpenThread?(post) }
            }
            if let x = post.xURL {
                Button("Open on X") { NSWorkspace.shared.open(x) }
            }
            if let url = post.url {
                Button("Open on Nitter") { NSWorkspace.shared.open(url) }
            }
            if let share = post.xURL ?? post.url {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(share.absoluteString, forType: .string)
                }
            }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(post.text, forType: .string)
            }
        }
        // @mentions in tweet text link to x.com/<handle>; open those as in-app
        // profiles instead of bouncing out to the browser.
        .environment(\.openURL, OpenURLAction { url in
            if let handle = Self.mentionHandle(from: url) {
                onAuthorSelected(handle)
                return .handled
            }
            return .systemAction
        })
    }

    /// Recognizes profile links like https://x.com/naval (but not /status/…,
    /// /search, or other non-profile paths).
    private static func mentionHandle(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "x.com" || host == "www.x.com" || host == "twitter.com" || host == "www.twitter.com"
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 1, let handle = parts.first,
              handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil,
              !["home", "search", "explore", "notifications", "messages", "i", "intent", "hashtag", "share"]
                  .contains(handle.lowercased())
        else { return nil }
        return handle
    }

    private var rowBackground: Color {
        if highlighted { return Color.accentColor.opacity(0.08) }
        return hovering ? Color.primary.opacity(0.04) : Color.clear
    }

    private var threadRail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(post.isThreadContinuation ? Color.accentColor.opacity(0.45) : Color.clear)
                .frame(width: 2)
                .frame(height: 20)
            Circle()
                .fill(Color.accentColor.opacity(0.60))
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(post.isThreadEnd ? Color.clear : Color.accentColor.opacity(0.45))
                .frame(width: 2)
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .padding(.trailing, 6)
    }

    private var threadBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10, weight: .semibold))
            Text("Thread")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 28)
    }

    /// "🔁 <follower> reposted" — the account you follow, shown with their real
    /// name/avatar, distinct from the original author shown below.
    private func repostBanner(_ reposterHandle: String) -> some View {
        Button {
            onAuthorSelected(reposterHandle)
        } label: {
            HStack(spacing: 6) {
                AvatarView(url: post.repostedByAvatarURL ?? store.avatars[reposterHandle.lowercased()],
                           handle: reposterHandle, size: 16)
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("@\(reposterHandle) reposted")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("View @\(reposterHandle)")
        .padding(.leading, 28)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                onAuthorSelected(post.authorHandle)
            } label: {
                // Reposts pulled from RSS don't carry the original poster's
                // avatar; fall back to any avatar we've cached for that handle.
                AvatarView(url: post.avatarURL ?? store.avatars[post.authorID],
                           handle: post.authorHandle)
            }
            .buttonStyle(.plain)
            .help("View @\(post.authorHandle)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button {
                        onAuthorSelected(post.authorHandle)
                    } label: {
                        Text(post.authorName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("View @\(post.authorHandle)")
                    if post.authorName.lowercased() != post.authorHandle.lowercased() {
                        Button {
                            onAuthorSelected(post.authorHandle)
                        } label: {
                            Text("@\(post.authorHandle)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("View @\(post.authorHandle)")
                    }
                    Spacer(minLength: 4)
                    Text(Self.relative.localizedString(for: post.date, relativeTo: Date()))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                if !post.text.isEmpty {
                    Text(post.rich)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .tint(.accentColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !post.media.isEmpty {
                    MediaGrid(media: post.media, postURL: post.url, xURL: post.xURL)
                        .padding(.top, 4)
                }

                engagementBar
            }
        }
    }

    @ViewBuilder
    private var engagementBar: some View {
        if let engagement = post.engagement {
            let showComments = store.showComments && engagement.replies != nil
            let showRetweets = store.showRetweets && engagement.retweets != nil
            let showLikes = store.showLikes && engagement.likes != nil
            if showComments || showRetweets || showLikes {
                HStack(spacing: 16) {
                    if showComments, let replies = engagement.replies {
                        Label(Self.compactCount(replies), systemImage: "bubble.left")
                    }
                    if showRetweets, let retweets = engagement.retweets {
                        Label(Self.compactCount(retweets), systemImage: "arrow.2.squarepath")
                    }
                    if showLikes, let likes = engagement.likes {
                        Label(Self.compactCount(likes), systemImage: "heart")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
    }

    private static func compactCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".0", with: "")
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000).replacingOccurrences(of: ".0", with: "")
        }
        return "\(count)"
    }
}

/// Lays out attached media: one large image, or a 2-column grid for several.
/// Video thumbnails get a ▶ overlay and open the post to play.
struct MediaGrid: View {
    let media: [MediaItem]
    let postURL: URL?
    var xURL: URL? = nil
    @EnvironmentObject var lightbox: Lightbox

    private var shown: [MediaItem] { Array(media.prefix(4)) }

    var body: some View {
        // Stack media vertically and show each at its natural aspect ratio, so
        // infographics and screenshots are never cropped.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element.url) { idx, item in
                MediaThumb(item: item, maxHeight: shown.count == 1 ? 460 : 320)
                    .onTapGesture {
                        // Open the in-app modal instead of redirecting out.
                        lightbox.show(media, at: idx, postURL: postURL, xURL: xURL)
                    }
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
    }
}

struct MediaThumb: View {
    let item: MediaItem
    let maxHeight: CGFloat
    @StateObject private var model = RemoteImageModel()
    @State private var hovering = false

    /// Timeline thumbnails decode at most ~2x their largest display size.
    private static let thumbDecodeMaxPixel: CGFloat = 1000

    var body: some View {
        Group {
            if let img = model.image
                ?? RemoteImageModel.cached(item.thumbURL, maxPixel: Self.thumbDecodeMaxPixel) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400)
                    .frame(maxHeight: maxHeight)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(maxWidth: 400)
                    .frame(height: 220)
                    .overlay {
                        if model.failed {
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().scaleEffect(0.6)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if item.isVideo {
                ZStack {
                    Circle().fill(.black.opacity(0.55)).frame(width: 52, height: 52)
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .brightness(hovering ? -0.04 : 0)
        .onHover { hovering = $0 }
        .task(id: item.url) { await model.load(item.thumbURL, maxPixel: Self.thumbDecodeMaxPixel) }
    }
}
