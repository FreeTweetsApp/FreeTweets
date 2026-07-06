import SwiftUI
import AppKit
import ImageIO

/// Loads images (avatars, media) with an aggressive two-level cache. Fetching
/// and decoding happen off the main actor, and callers can cap the decoded
/// pixel size so timeline thumbnails don't pay full-resolution decode cost.
@MainActor
final class RemoteImageModel: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false

    private static let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                diskCapacity: 256 * 1024 * 1024)
        return URLSession(configuration: cfg)
    }()

    private static func cacheKey(_ url: URL, _ maxPixel: CGFloat?) -> NSString {
        "\(url.absoluteString)|\(Int(maxPixel ?? 0))" as NSString
    }

    /// Synchronous memory-cache lookup, so already-seen images paint on the
    /// first frame instead of flashing a placeholder while `.task` spins up.
    static func cached(_ url: URL?, maxPixel: CGFloat? = nil) -> NSImage? {
        guard let url else { return nil }
        return memory.object(forKey: cacheKey(url, maxPixel))
    }

    func load(_ url: URL?, maxPixel: CGFloat? = nil) async {
        guard let url else {
            image = nil
            failed = true
            return
        }
        let key = Self.cacheKey(url, maxPixel)
        if let cached = Self.memory.object(forKey: key) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        do {
            guard let img = try await Self.fetchAndDecode(url, maxPixel: maxPixel) else {
                if !Task.isCancelled { failed = true }
                return
            }
            Self.memory.setObject(img, forKey: key)
            guard !Task.isCancelled else { return }
            image = img
        } catch {
            // A cancelled request means the row was recycled for a new URL —
            // don't mark the new load as failed.
            if !Task.isCancelled { failed = true }
        }
    }

    private nonisolated static func fetchAndDecode(_ url: URL, maxPixel: CGFloat?) async throws -> NSImage? {
        var req = URLRequest(url: url)
        req.setValue(Net.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await session.data(for: req)
        return decode(data, maxPixel: maxPixel)
    }

    /// Decode, optionally downsampled via ImageIO so a 4K photo displayed at
    /// 400 points never allocates or decodes full-size.
    private nonisolated static func decode(_ data: Data, maxPixel: CGFloat?) -> NSImage? {
        if let maxPixel, let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSImage(data: data)
    }
}

/// A URL-backed image with a loading shimmer and graceful failure. `content`
/// lets each call site decide sizing/clipping; `maxPixel` caps decode size.
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var maxPixel: CGFloat? = nil
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @StateObject private var model = RemoteImageModel()

    var body: some View {
        Group {
            if let ns = model.image ?? RemoteImageModel.cached(url, maxPixel: maxPixel) {
                content(Image(nsImage: ns))
            } else if model.failed {
                placeholder()
            } else {
                placeholder().overlay(ProgressView().scaleEffect(0.5))
            }
        }
        .task(id: url) { await model.load(url, maxPixel: maxPixel) }
    }
}
