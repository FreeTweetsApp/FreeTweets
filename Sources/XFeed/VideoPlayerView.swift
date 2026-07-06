import SwiftUI
import AVKit
import AppKit

/// User-Agent for every request. Deliberately *not* a browser string: instance
/// anti-bot walls (Anubis, Cloudflare interstitials) challenge browser-like
/// "Mozilla/…" agents, which a URLSession client can never solve, while several
/// instances serve plain non-browser clients directly (tiekoetter HTML, poast
/// RSS). xcancel also whitelists RSS readers by this exact string, so keep it
/// stable and quotable — it's the value users give xcancel to request access.
/// Direct pbs.twimg.com image fetches accept any agent.
enum Net {
    static let userAgent = "FreeTweets/1.0 (RSS Reader)"
    static let rssUserAgent = userAgent
}

/// Resolves a playable video stream from a tweet's Nitter page. Twitter's stream
/// isn't in the RSS feed, but the tweet page embeds a proxied HLS playlist
/// (`data-url`) or a direct `<source>` — fetched only when the user hits play.
enum VideoResolver {
    static func streamURL(forTweet pageURL: URL) async -> URL? {
        var req = URLRequest(url: pageURL)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              !data.isEmpty,
              let html = String(data: data, encoding: .utf8) else { return nil }

        let origin = "\(pageURL.scheme ?? "https")://\(pageURL.host ?? "")"

        func absolutize(_ raw: String) -> URL? {
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&")
            return URL(string: cleaned.hasPrefix("http") ? cleaned : origin + cleaned)
        }

        // Prefer a direct progressive MP4 from Twitter's CDN — it plays with any
        // User-Agent and doesn't depend on the (often walled) instance's own
        // /video/ proxy. For amplify videos the highest-resolution rendition is
        // listed first.
        let sources = allCaptures(#"<source[^>]+src="([^"]+)""#, in: html)
        if let direct = sources.first(where: { $0.contains("video.twimg.com") }),
           let url = absolutize(direct) {
            return url
        }

        // Otherwise fall back to the HLS playlist (`data-url`), any <source>,
        // then a proxied /video/ path.
        let patterns = [
            #"data-url="([^"]+)""#,
            #"<source[^>]+src="([^"]+)""#,
            #"(/video/[^"'<>\s]+)"#
        ]
        for pattern in patterns {
            if let raw = firstCapture(pattern, in: html), let url = absolutize(raw) {
                return url
            }
        }
        return nil
    }

    private static func allCaptures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

/// AppKit video surface. We deliberately avoid SwiftUI's `VideoPlayer`, whose
/// underlying `_AVKit_SwiftUI` representable fatal-errors during metadata setup
/// on certain macOS 15 releases; `AVPlayerView` is the stable AppKit equivalent.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

/// In-app video: resolves the stream, then plays it with AVPlayer. While loading
/// it shows the thumbnail; if resolution fails it offers the browser fallback.
struct InAppVideoView: View {
    @EnvironmentObject var store: FeedStore
    let item: MediaItem
    let tweetURL: URL?

    @State private var player: AVPlayer?
    @State private var state: LoadState = .loading

    enum LoadState { case loading, ready, failed }

    var body: some View {
        ZStack {
            switch state {
            case .loading:
                RemoteImage(url: item.url) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    Color.black
                }
                .overlay {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Loading video…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(16)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }

            case .ready:
                if let player {
                    // AppKit's AVPlayerView, not SwiftUI's `VideoPlayer`. The
                    // SwiftUI wrapper crashes during view construction on some
                    // macOS 15 builds (fatalError in _AVKit_SwiftUI while
                    // instantiating its representable's generic metadata).
                    AVPlayerViewRepresentable(player: player)
                }

            case .failed:
                fallback
            }
        }
        .task(id: item.url) { await resolve() }
        .onDisappear { player?.pause() }
    }

    private func resolve() async {
        state = .loading
        player?.pause()
        player = nil

        guard let tweetURL,
              let stream = await store.videoStream(forTweet: tweetURL) else {
            state = .failed
            return
        }
        // Pass the browser UA to the video proxy too.
        let asset = AVURLAsset(url: stream, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Net.userAgent]
        ])
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
        state = .ready
        newPlayer.play()
    }

    private var fallback: some View {
        ZStack {
            RemoteImage(url: item.url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Color.black
            }
            VStack(spacing: 10) {
                Button {
                    if let url = tweetURL { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(.black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                Text("Couldn't load stream — play on X")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
            }
        }
    }
}
