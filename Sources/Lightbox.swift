import SwiftUI
import AppKit

/// Drives the in-app media modal. A single instance lives in the environment so
/// any post's media can present over the whole window.
@MainActor
final class Lightbox: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var media: [MediaItem] = []
    @Published var index: Int = 0
    /// Nitter page for the post — used to resolve video streams.
    private(set) var postURL: URL?
    /// Canonical x.com link — used for "Open on X".
    private(set) var xURL: URL?

    func show(_ media: [MediaItem], at index: Int, postURL: URL?, xURL: URL? = nil) {
        guard !media.isEmpty else { return }
        self.media = media
        self.index = min(max(0, index), media.count - 1)
        self.postURL = postURL
        self.xURL = xURL
        withAnimation(.easeOut(duration: 0.15)) { isPresented = true }
    }

    func close() {
        withAnimation(.easeIn(duration: 0.12)) { isPresented = false }
    }

    var current: MediaItem? { media.indices.contains(index) ? media[index] : nil }
    var canGoNext: Bool { index < media.count - 1 }
    var canGoPrev: Bool { index > 0 }
    func next() { if canGoNext { index += 1 } }
    func prev() { if canGoPrev { index -= 1 } }
}

/// Full-window media viewer. Photos display in-app; video shows its frame with a
/// play control (X streams the actual video, which the feed doesn't expose).
struct LightboxView: View {
    @EnvironmentObject var lightbox: Lightbox

    var body: some View {
        ZStack {
            // Dimmed backdrop — click anywhere to dismiss.
            Rectangle()
                .fill(.black.opacity(0.92))
                .ignoresSafeArea()
                .onTapGesture { lightbox.close() }

            if let item = lightbox.current {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)

                    Group {
                        if item.isVideo {
                            InAppVideoView(item: item, tweetURL: lightbox.postURL)
                        } else {
                            RemoteImage(url: item.fullURL) { img in
                                img.resizable().scaledToFit()
                            } placeholder: {
                                ProgressView().controlSize(.large)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Clicking the media itself shouldn't dismiss.
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .padding(.horizontal, 24)

                    footer
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 28)

                navigationArrows
            }

            closeButton
        }
        .transition(.opacity)
    }

    // MARK: - Controls

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: lightbox.close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc
                .help("Close (Esc)")
            }
            Spacer()
        }
        .padding(18)
    }

    @ViewBuilder
    private var navigationArrows: some View {
        if lightbox.media.count > 1 {
            HStack {
                arrow(system: "chevron.left", enabled: lightbox.canGoPrev, action: lightbox.prev)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                arrow(system: "chevron.right", enabled: lightbox.canGoNext, action: lightbox.next)
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .padding(.horizontal, 16)
        }
    }

    private func arrow(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if lightbox.media.count > 1 {
                Text("\(lightbox.index + 1) / \(lightbox.media.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let item = lightbox.current {
                Button {
                    // Videos → the tweet on X; photos → the full-res image.
                    let target = item.isVideo
                        ? (lightbox.xURL ?? lightbox.postURL ?? item.url)
                        : item.fullURL
                    NSWorkspace.shared.open(target)
                } label: {
                    Label(item.isVideo ? "Open on X" : "Open original",
                          systemImage: "arrow.up.forward.square")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.white.opacity(0.08), in: Capsule())
    }
}
