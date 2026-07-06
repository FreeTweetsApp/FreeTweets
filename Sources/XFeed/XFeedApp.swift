import SwiftUI
import AppKit

@main
struct XFeedApp: App {
    @StateObject private var store = FeedStore()
    @StateObject private var lightbox = Lightbox()

    init() {
        // Ensure the app behaves as a normal windowed app when launched from a
        // bundle: real dock icon, foreground focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(lightbox)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    Task { await store.refresh() }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}
