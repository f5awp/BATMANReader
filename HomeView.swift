// HomeView.swift
// v2 Home tab — the evolved Schedule page: a robust vertical-scrolling month
// calendar with per-day trade-intent marking, layer toggles, a snapshot banner,
// and a tabbed Trade Settings sheet. Intent is read/written through DayIntentStore
// (the single source of truth); the calendar layout descends from
// ScheduleCalendarView.

import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showImporter = false
    @State private var importResult: String?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showBanner, !changedDays.isEmpty {
                    updateBanner
                }
                HStack(spacing: 10) {
                    snapshotTag
                    VisibilityToolbar(layers: $layers)
                }
                .padding(.horizontal).padding(.top, 2)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("Import schedule CSV")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTradeSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showTradeSettings) { TradeSettingsSheet() }
            .sheet(item: $editTarget) { target in
                DayIntentEditor(target: target)
                    .presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                          allowsMultipleSelection: false) { handleImport($0) }
            .alert("Import Error", isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importError ?? "") }
            .alert("Schedule Imported", isPresented: Binding(
                get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importResult ?? "") }
            .onAppear(perform: reconcileSnapshot)
        }
    }

    // MARK: CSV import (admin publishes the shared master roster)

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let csv = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            importError = "Could not read the file as text."
            return
        }
        let username = settings.username
        Task {
            do {
                let workers = try await Task.detached { try ScheduleParser().parseAllWorkers(csv: csv) }.value
                var lines: [String] = []
                let mine = workers.first(where: { $0.id == username }) ?? (workers.count == 1 ? workers.first : nil)
                if let mine {
                    let diff = await ShiftStore.shared.save(mine.shifts)
                    await AvailabilityManager.shared.buildFromSchedule()
                    await NotificationManager.shared.scheduleAll(for: mine.shifts)
                    let restored = EventKitManager.shared.resyncPersonalEvents(for: mine.shifts)
                    lines.append("\(mine.shifts.filter { !$0.isOff }.count) of your working shifts imported. \(diff.summary)")
                    if restored > 0 { lines.append("\(restored) calendar events restored.") }
                }
                if workers.count > 1 {
                    let rows = await RosterStore.shared.importRoster(workers)
                    lines.append("Roster: \(workers.count) dispatchers loaded for matching (\(rows) rows).")
                    if DevAccess.shared.unlocked {
                        let ok = await RosterStore.shared.publishMaster(csv: csv)
                        lines.append(ok ? "Published as MASTER roster — all users get this on their next launch."
                                        : "(Not published as master — turn on iCloud Trade Sync first.)")
                    }
                }
                if lines.isEmpty {
                    importError = "Couldn't find your employee ID (\(username)) in this file, and there's no roster to load."
                } else {
                    importResult = lines.joined(separator: "\n")
                }
                WidgetData.update()
            } catch {
                importError = error.localizedDescription
            }
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
                swatch(BrickPalette.change, "Trade away")
                swatch(BrickPalette.critical, "Keep")
            } else {
                swatch(BrickPalette.clear, "Want to work")
                swatch(BrickPalette.critical, "Must be off")
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

// MARK: - Visibility toolbar (WSI-style icon strip)

/// A compact horizontal strip of icon toggles controlling which calendar layers
/// are drawn — modeled on the dispatch desk's icon toolbar, with Slack-grade
/// spacing and clear on/off states.
struct VisibilityToolbar: View {
    @Binding var layers: LayerVisibility

    var body: some View {
        HStack(spacing: 2) {
            toggle("circle.grid.2x2.fill", on: $layers.shiftCircles, label: "Shift circles")
            toggle("note.text", on: $layers.notes, label: "Notes")
            toggle("paintpalette.fill", on: $layers.intentOverlays, label: "Intent colors")
        }
        .padding(3)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
    }

    private func toggle(_ symbol: String, on: Binding<Bool>, label: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .foregroundStyle(on.wrappedValue ? Color.white : Color.secondary)
                .background(on.wrappedValue ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on.wrappedValue ? [.isSelected] : [])
    }
}

// MARK: - Edit target

struct DayEditTarget: Identifiable {
    let dayID: String
    let isOff: Bool
    var id: String { dayID }
}
