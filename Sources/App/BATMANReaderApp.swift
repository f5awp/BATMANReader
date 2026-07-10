// BATMANReaderApp.swift
// Entry point. Requests notification and calendar permissions on first launch.

import SwiftUI
import AppIntents
import SwiftData

@main
struct BATMANReaderApp: App {

    init() {
        // MUST register the background-refresh handler before launch completes (live daily digest).
        NotificationManager.shared.registerDigestRefresh()
        Task { @MainActor in
            // Both requests run concurrently — iOS shows one dialog at a time.
            async let notif    = NotificationManager.shared.requestPermission()
            async let calendar = EventKitManager.shared.requestPermission()
            _ = await (notif, calendar)
        }
    }

    var body: some Scene {
        WindowGroup {
            MagnifierHost { ContentView() }   // global accessibility magnifier wraps the whole app
        }
        .modelContainer(RosterStore.shared.container)
    }
}
