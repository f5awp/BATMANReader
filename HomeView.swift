// HomeView.swift
// v2 Home tab — the evolved Schedule page: a robust vertical-scrolling month
// calendar with per-day trade-intent marking, layer toggles, a snapshot banner,
// and a tabbed Trade Settings sheet. Intent is read/written through DayIntentStore
// (the single source of truth); the calendar layout descends from
// ScheduleCalendarView.

import SwiftUI

// MARK: - Marking mode

enum IntentMode: String, CaseIterable, Identifiable {
    case off = "View"
    case workingShifts = "Working Shifts"
    case daysOff = "Days Off"
    var id: String { rawValue }
}

/// Which optional overlays the calendar draws.
struct LayerVisibility {
    var shiftCircles = true   // AM/PM/MID
    var notes = true          // DayNote markers
    var intentOverlays = true // purple/green/red intent tints
}

// MARK: - Home

struct HomeView: View {

    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared
    private var intents  = DayIntentStore.shared

    @State private var mode: IntentMode = .off
    @State private var layers = LayerVisibility()
    @State private var showTradeSettings = false
    @State private var editTarget: DayEditTarget?
    @State private var changedDays: Set<String> = []
    @State private var showBanner = false
    @State private var flashChanged = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showBanner, !changedDays.isEmpty {
                    updateBanner
                }
                snapshotTag
                MarkIntentsToolbar(mode: $mode)
                Divider()

                if store.shifts.isEmpty {
                    ContentUnavailableView(
                        "No Schedule Loaded",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Import your schedule on the Trades tab or wait for the next master sync."))
                } else {
                    IntentCalendarView(
                        shifts: store.shifts,
                        mode: mode,
                        layers: layers,
                        flashDays: flashChanged ? changedDays : [],
                        onTap: handleTap,
                        onLongPress: { day, isOff in editTarget = DayEditTarget(dayID: day, isOff: isOff) })
                }
            }
            .navigationTitle("BATMAN Watcher")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { layerMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTradeSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showTradeSettings) { TradeSettingsSheet() }
            .sheet(item: $editTarget) { target in
                DayIntentEditor(target: target)
                    .presentationDetents([.medium, .large])
            }
            .onAppear(perform: reconcileSnapshot)
        }
    }

    // MARK: Pieces

    private var snapshotTag: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
            Text(lastSyncText).font(.caption2)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal).padding(.vertical, 4)
    }

    private var updateBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Schedule Updated").font(.subheadline.bold())
                Text("^[\(changedDays.count) date](inflect: true) changed. Tap to review and re-mark your intents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { withAnimation { showBanner = false } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.orange.opacity(0.12))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { flashChanged = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { flashChanged = false } }
        }
    }

    private var layerMenu: some View {
        Menu {
            Toggle(isOn: $layers.shiftCircles) { Label("Shift circles (AM/PM/MID)", systemImage: "circle.grid.2x2") }
            Toggle(isOn: $layers.notes) { Label("Date notes", systemImage: "note.text") }
            Toggle(isOn: $layers.intentOverlays) { Label("Intent overlays", systemImage: "paintpalette") }
        } label: {
            Image(systemName: "square.3.layers.3d")
        }
    }

    private var lastSyncText: String {
        guard let date = ShiftStore.shared.lastFetchDate else { return "Schedule not yet synced" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return "Schedule updated: \(f.string(from: date))"
    }

    // MARK: Actions

    /// Single tap: apply the mode's default intent, toggling it off if already set.
    private func handleTap(day: String, isOff: Bool) {
        switch mode {
        case .off:
            editTarget = DayEditTarget(dayID: day, isOff: isOff)
        case .workingShifts:
            guard !isOff else { return }
            intents.setWorkingIntent(intents.workingIntent(forDay: day) == .dontWantToWork ? nil : .dontWantToWork,
                                     forDay: day)
        case .daysOff:
            guard isOff else { return }
            intents.setOffIntent(intents.offIntent(forDay: day) == .wantToWork ? nil : .wantToWork, forDay: day)
        }
    }

    /// On appear: clear intent for any date whose worked/off status flipped since
    /// the last snapshot, and surface a banner so the user can re-map them.
    private func reconcileSnapshot() {
        let wiped = intents.reconcile(withShifts: store.shifts)
        if !wiped.isEmpty {
            changedDays = wiped
            withAnimation { showBanner = true }
        }
    }
}

// MARK: - Mark Intents toolbar (collapsible)

struct MarkIntentsToolbar: View {
    @Binding var mode: IntentMode

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $mode.animation(.easeInOut)) {
                ForEach(IntentMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if mode != .off {
                legend
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var legend: some View {
        HStack(spacing: 14) {
            if mode == .workingShifts {
                swatch(.purple, "Trade away")
                swatch(.red, "Keep")
            } else {
                swatch(.green, "Want to work")
                swatch(.red, "Must be off")
            }
            Spacer()
            Text("Tap to set · long-press for options")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption2)
        }
    }
}

// MARK: - Edit target

struct DayEditTarget: Identifiable {
    let dayID: String
    let isOff: Bool
    var id: String { dayID }
}
