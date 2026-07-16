// BATMANReaderApp.swift
// Entry point. Requests notification and calendar permissions on first launch.

import SwiftUI
import AppIntents
import SwiftData
import UIKit
import UserNotifications

@main
struct BATMANReaderApp: App {

    init() {
        Self.stripBarHairlines()
        // MUST register the background-refresh handler before launch completes (live daily digest).
        NotificationManager.shared.registerDigestRefresh()
        // Radar notification tap-routing + foreground presentation.
        UNUserNotificationCenter.current().delegate = RadarNotificationRouter.shared
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

    /// §11: kill the UIKit "chrome" hairline under navigation bars and above the tab bar, app-wide. Opaque
    /// system-background bars, `shadowColor = .clear`. This is the bar chrome only — tile/card glaze rims
    /// (drawn in SwiftUI) are untouched.
    private static func stripBarHairlines() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .systemBackground
        nav.shadowColor = .clear
        nav.shadowImage = UIImage()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = .systemBackground
        tab.shadowColor = .clear
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}
