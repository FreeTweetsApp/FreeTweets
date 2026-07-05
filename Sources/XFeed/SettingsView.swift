import SwiftUI

/// A few well-known public Nitter instances. Availability changes over time, so
/// the field is also freely editable.
let knownInstances = [
    "nitter.poast.org",
    "nitter.privacyredirect.com",
    "xcancel.com",
    "nitter.tiekoetter.com"
]

// The full macOS Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject var store: FeedStore
    @State private var draftHost: String = ""

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: Binding(
                    get: { store.appearance },
                    set: { store.appearance = $0 })) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Profile picture", selection: Binding(
                    get: { store.avatarShape },
                    set: { store.avatarShape = $0 })) {
                    ForEach(AvatarShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Show comments", isOn: $store.showComments)
                Toggle("Show retweets", isOn: $store.showRetweets)
                Toggle("Show likes", isOn: $store.showLikes)
                Toggle("Auto-refresh every 10 minutes", isOn: $store.autoRefresh)
            } header: {
                Text("Timeline")
            }

            Section {
                HStack {
                    TextField("Instance host", text: $draftHost, prompt: Text("nitter.poast.org"))
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(knownInstances, id: \.self) { host in
                            Button(host) { draftHost = host }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .fixedSize()
                }
                Text("Feeds and thread pages are each read from the first instance that serves them, starting with this one, so a partially gated instance still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Apply & Refresh") {
                    let trimmed = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.instanceHost = trimmed.isEmpty ? "nitter.poast.org" : trimmed
                    Task { await store.refresh() }
                }
                .keyboardShortcut(.defaultAction)
            } header: {
                Text("Nitter instance")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { draftHost = store.instanceHost }
    }
}

/// Compact in-app settings shown from the toolbar gear button.
struct QuickSettingsView: View {
    @EnvironmentObject var store: FeedStore
    @State private var draftHost: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance")
                .font(.subheadline.weight(.semibold))

            Text("Theme")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { store.appearance },
                set: { store.appearance = $0 })) {
                ForEach(AppAppearance.allCases) { appearance in
                    Label(appearance.label, systemImage: symbol(appearance)).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Profile picture")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { store.avatarShape },
                set: { store.avatarShape = $0 })) {
                ForEach(AvatarShape.allCases) { shape in
                    Label(shape.label, systemImage: shapeSymbol(shape)).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            Text("Timeline")
                .font(.subheadline.weight(.semibold))
            Toggle("Show comments", isOn: $store.showComments)
            Toggle("Show retweets", isOn: $store.showRetweets)
            Toggle("Show likes", isOn: $store.showLikes)
            Toggle("Auto-refresh", isOn: $store.autoRefresh)

            Divider()

            Text("Nitter instance")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                TextField("host", text: $draftHost, prompt: Text("nitter.poast.org"))
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(knownInstances, id: \.self) { host in
                        Button(host) { draftHost = host }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .fixedSize()
            }
            Button {
                let trimmed = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
                store.instanceHost = trimmed.isEmpty ? "nitter.poast.org" : trimmed
                Task { await store.refresh() }
            } label: {
                Label("Apply & Refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { draftHost = store.instanceHost }
    }

    private func symbol(_ a: AppAppearance) -> String {
        switch a {
        case .light: return "sun.max"
        case .dark:  return "moon"
        }
    }

    private func shapeSymbol(_ s: AvatarShape) -> String {
        switch s {
        case .circle:   return "circle"
        case .squircle: return "app"
        }
    }
}
