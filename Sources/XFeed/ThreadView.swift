import SwiftUI
import AppKit

/// Full-window conversation reader. Tapping a tweet opens this to show the whole
/// thread — ancestor tweets, the focused tweet (highlighted), and replies —
/// fetched from the instance's status page and read entirely in-app.
struct ThreadView: View {
    @EnvironmentObject var store: FeedStore
    let rootPost: Post
    var onClose: () -> Void
    var onAuthorSelected: (String) -> Void

    /// The tweet the conversation is centered on. Tapping a reply re-centers
    /// here; Back walks this history before closing the reader.
    @State private var focus: Post
    @State private var history: [Post] = []
    @State private var entries: [NitterTimelineParser.ConversationEntry] = []
    @State private var state: LoadState = .loading
    /// Conversations already fetched this session, so Back is instant.
    @State private var cache: [String: [NitterTimelineParser.ConversationEntry]] = [:]
    /// Bumped after every successful load to trigger the scroll-to-focus.
    @State private var scrollGeneration = 0

    enum LoadState: Equatable { case loading, loaded, failed(String) }

    init(rootPost: Post,
         onClose: @escaping () -> Void,
         onAuthorSelected: @escaping (String) -> Void) {
        self.rootPost = rootPost
        self.onClose = onClose
        self.onAuthorSelected = onAuthorSelected
        _focus = State(initialValue: rootPost)
    }

    /// Standard macOS titlebar height. The reader fills the window top-to-bottom
    /// (no gap under the window chrome); the header is inset by this much so the
    /// Back button clears the titlebar's drag region and traffic lights.
    private static let titlebarInset: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        // Fill the whole window, including the titlebar strip, so no gap shows
        // above the reader. The header pads itself down past the titlebar.
        .ignoresSafeArea()
        .task(id: focus.id) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: goBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Back")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // Esc
            .help(history.isEmpty ? "Close thread (Esc)" : "Previous tweet (Esc)")

            Text("Thread")
                .font(.headline)

            Spacer()

            if let url = focus.xURL ?? focus.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open on X", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open this tweet on X")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, Self.titlebarInset + 8)
        .padding(.bottom, 10)
    }

    /// Back pops to the previously focused tweet; from the first tweet it
    /// closes the reader.
    private func goBack() {
        if let previous = history.popLast() {
            focus = previous
        } else {
            onClose()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Loading thread…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                HStack(spacing: 10) {
                    Button("Try Again") { Task { await load(force: true) } }
                    if let url = focus.xURL ?? focus.url {
                        Button("Open on X") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

        case .loaded:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries, id: \.post.id) { entry in
                            PostRow(
                                post: entry.post,
                                onAuthorSelected: onAuthorSelected,
                                onOpenThread: entry.isMain ? nil : { tapped in
                                    history.append(focus)
                                    focus = tapped
                                },
                                highlighted: entry.isMain
                            )
                            .id(entry.isMain ? Self.mainAnchor : entry.post.id)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: scrollGeneration) { _ in
                    // Jump to the focused tweet so its ancestors sit above it,
                    // just like on X.
                    guard entries.contains(where: \.isMain) else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.mainAnchor, anchor: .top)
                    }
                }
            }
        }
    }

    private static let mainAnchor = "main-tweet-anchor"

    private func load(force: Bool = false) async {
        if !force, let cached = cache[focus.id] {
            entries = cached
            state = .loaded
            scrollGeneration += 1
            return
        }
        state = .loading
        switch await store.loadConversation(for: focus) {
        case .success(let loaded):
            entries = loaded
            cache[focus.id] = loaded
            state = .loaded
            scrollGeneration += 1
        case .failure(let error):
            state = .failed(error.message)
        }
    }
}
