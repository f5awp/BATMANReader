// BATMANReaderApp.swift
// Entry point. Requests notification and calendar permissions on first launch.

import SwiftUI
import AppIntents
import SwiftData

@main
struct BATMANReaderApp: App {

    init() {
        Task { @MainActor in
            // Both requests run concurrently — iOS shows one dialog at a time.
            async let notif    = NotificationManager.shared.requestPermission()
            async let calendar = EventKitManager.shared.requestPermission()
            _ = await (notif, calendar)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(RosterStore.shared.container)
    }
}
