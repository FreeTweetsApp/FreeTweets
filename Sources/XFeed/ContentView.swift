import SwiftUI
import AppKit

/// Sidebar selection. "All" is the unified timeline; an account narrows it.
enum FeedSelection: Hashable {
    case all
    case account(String)   // account id (lowercased handle)
    case profile(String)   // author id opened from a post
}

/// The "free tweets" wordmark, bundled as a package resource so it ships inside
/// the .app. Loaded once and cached; renders nothing if the asset is missing so
/// a packaging slip never breaks the layout.
struct BrandLogo: View {
    var height: CGFloat = 22

    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "free1", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .accessibilityLabel("FreeTweets")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var lightbox: Lightbox
    @State private var selection: FeedSelection = .all
    @State private var newHandle = ""
    @State private var searchText = ""

    @State private var showSettings = false

    /// The tweet whose thread is open in the in-app reader, if any.
    @State private var threadPost: Post?

    private var isOverlayPresented: Bool { lightbox.isPresented || threadPost != nil }

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
                    .frame(minWidth: 220)
            } detail: {
                timeline
            }
            .toolbar { splitViewToolbar }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search tweets")
            // Hide the window toolbar while a full-window overlay is up so
            // nothing floats above it.
            .toolbar(isOverlayPresented ? .hidden : .visible, for: .windowToolbar)
            // Periodic background refresh, spaced well clear of rate limits.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                    if store.autoRefresh, !store.isLoading, !store.accounts.isEmpty {
                        await store.refresh()
                    }
                }
            }

            // In-app thread reader, above the timeline but below the media viewer
            // so tapping media inside a thread still opens the lightbox on top.
            // It fills the whole window (including under the titlebar) so no gap
            // shows between the window top and the reader; ThreadView insets its
            // own header below the titlebar so Back stays clickable.
            if let post = threadPost {
                ThreadView(
                    rootPost: post,
                    onClose: { withAnimation { threadPost = nil } },
                    onAuthorSelected: { handle in
                        threadPost = nil
                        selection = .profile(handle.lowercased())
                        Task { await store.loadProfile(handle) }
                    }
                )
                .id(post.id)   // fresh reader state per opened tweet
                .transition(.opacity)
            }

            // Full-window media viewer. Presented as an overlay (not a .sheet)
            // so it covers the sidebar and toolbar area edge-to-edge instead of
            // appearing as a card with the app chrome poking out around it.
            // Its dark backdrop ignores the safe area internally; the close
            // button stays inside it so it remains clickable below the titlebar.
            if lightbox.isPresented {
                LightboxView()
                    .environmentObject(lightbox)
                    .preferredColorScheme(.dark)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(store.appearance.colorScheme)
    }

    @ToolbarContentBuilder
    private var splitViewToolbar: some ToolbarContent {
            ToolbarItem(placement: .principal) {
                sortPicker
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoading)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh all feeds (⌘R)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    QuickSettingsView().environmentObject(store)
                }
            }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                BrandLogo(height: 68)
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.top, -12)
            .padding(.bottom, 4)

            List(selection: $selection) {
                Label("All Tweets", systemImage: "square.stack")
                    .tag(FeedSelection.all)
                    .padding(.vertical, 2)

                Section("Following") {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 8) {
                            AvatarView(url: store.avatars[account.id], handle: account.handle, size: 24)
                            if let name = account.displayName, !name.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(account.atHandle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                Text(account.atHandle)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if store.issues[account.id] != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 11))
                                    .help(store.issues[account.id] ?? "")
                            }
                        }
                        .tag(FeedSelection.account(account.id))
                        .contextMenu {
                            Button("Unfollow @\(account.handle)", role: .destructive) {
                                if selection == .account(account.id) { selection = .all }
                                store.unfollow(account)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            addAccountBar
        }
    }

    private var addAccountBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "at")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Add username", text: $newHandle)
                .textFieldStyle(.plain)
                .onSubmit(addAccount)
            if !newHandle.isEmpty {
                Button(action: addAccount) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func addAccount() {
        let h = newHandle
        newHandle = ""
        store.follow(h)
    }

    // MARK: - Sort control

    private var sortPicker: some View {
        Picker("", selection: Binding(
            get: { store.sortOrder },
            set: { store.setSort($0) }
        )) {
            ForEach(SortOrder.allCases) { order in
                Label(order.label, systemImage: order.symbol).tag(order)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Timeline

    private var visiblePosts: [Post] {
        let base: [Post]
        switch selection {
        case .all:
            base = store.posts
        case .account(let id):
            // An account's feed is what *they* put on their timeline: their own
            // tweets plus anything they reposted.
            base = store.posts.filter { $0.authorID == id || $0.repostedByHandle?.lowercased() == id }
        case .profile(let id):
            base = store.posts(forProfile: id)
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.text.localizedCaseInsensitiveContains(query)
            || $0.authorHandle.localizedCaseInsensitiveContains(query)
            || $0.authorName.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let posts = visiblePosts
        Group {
            if store.accounts.isEmpty {
                emptyState(
                    icon: "person.crop.circle.badge.plus",
                    title: "Follow someone to begin",
                    subtitle: "Add an X username in the sidebar. Your timeline is built only from who you follow — no algorithm."
                )
            } else if posts.isEmpty && !store.isLoading {
                emptyState(
                    icon: "tray",
                    title: "Nothing to show yet",
                    subtitle: currentIssue ?? "Click refresh (⌘R), or check your instance in Settings (⌘,)."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let issue = currentIssue {
                            issueBanner(issue)
                        }
                        if case .profile(let id) = selection {
                            profileHeader(id)
                        }
                        postList(posts)
                        loadOlderFooter
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) {
            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(6)
            }
        }
        .navigationTitle(titleText)
        .navigationSubtitle(subtitleText)
    }

    @ViewBuilder
    private func postList(_ posts: [Post]) -> some View {
        ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
            PostRow(
                post: post,
                onAuthorSelected: { handle in
                    selection = .profile(handle.lowercased())
                    Task { await store.loadProfile(handle) }
                },
                onOpenThread: { tapped in withAnimation { threadPost = tapped } }
            )
            if !continuesThread(from: post, to: posts[safe: index + 1]) {
                Divider().opacity(0.4)
            }
        }
    }

    /// "Load older tweets" at the bottom of a single account's feed or profile,
    /// walking the instance's cursor pagination like nitter's "Load more".
    @ViewBuilder
    private var loadOlderFooter: some View {
        let id: String? = {
            switch selection {
            case .account(let id): return id
            case .profile(let id): return id
            case .all: return nil
            }
        }()
        if let id, store.hasOlder(id) {
            HStack {
                Spacer()
                Button {
                    Task { await store.loadOlder(id) }
                } label: {
                    if store.loadingOlder.contains(id) {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.5)
                            Text("Loading older tweets…")
                        }
                    } else {
                        Label("Load older tweets", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(store.loadingOlder.contains(id))
                Spacer()
            }
            .padding(.vertical, 16)
        }
    }

    @MainActor
    private func refreshNow() async {
        await store.refresh()
    }

    private func continuesThread(from post: Post, to next: Post?) -> Bool {
        guard let next,
              let threadID = post.threadID,
              threadID == next.threadID else { return false }
        return !post.isThreadEnd
    }

    private var currentIssue: String? {
        if case .account(let id) = selection { return store.issues[id] }
        if case .profile(let id) = selection { return store.issues[id] }
        return nil
    }

    private func profileHeader(_ id: String) -> some View {
        let isFollowing = store.isFollowing(id)
        // Best display name we've seen for this account in any fetched post.
        let displayName = visiblePosts.first { $0.authorID == id && !$0.authorName.isEmpty }?.authorName
        return HStack(spacing: 12) {
            Button {
                selection = .all
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back to All Tweets")

            AvatarView(url: store.avatars[id], handle: id, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName ?? "@\(id)")
                    .font(.headline)
                Text("@\(id) · \(isFollowing ? "Following" : "Not followed")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if isFollowing {
                    store.unfollow(handle: id)
                } else {
                    store.follow(id)
                }
            } label: {
                Label(isFollowing ? "Following" : "Follow",
                      systemImage: isFollowing ? "checkmark" : "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func issueBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.callout)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(12)
        .background(.orange.opacity(0.08))
    }

    private var titleText: String {
        switch selection {
        case .all: return "All Tweets"
        case .account(let id):
            return store.accounts.first { $0.id == id }?.atHandle ?? "Feed"
        case .profile(let id):
            return "@\(id)"
        }
    }

    private static let updatedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var subtitleText: String {
        let count = visiblePosts.count
        var s = "\(count) tweet\(count == 1 ? "" : "s")"
        if let d = store.lastRefreshed {
            s += " · updated \(Self.updatedFormatter.localizedString(for: d, relativeTo: Date()))"
        }
        // Make it clear when failover is serving from a different instance.
        if let host = store.activeHost {
            s += " · via \(host)"
        }
        return s
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
