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
    case off = "Main View"
    case workingShifts = "Working Shifts"
    case daysOff = "Days Off"
    var id: String { rawValue }
}

/// Which optional overlays the calendar draws.
struct LayerVisibility {
    var notes = true          // DayNote markers
    var intentOverlays = true // intent tints
    var availability = true   // AM/PM/MID pickup markers on off days
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
    @State private var offBrush: ShiftAvailabilityType?   // nil = generic "want to work"
    @State private var workBrush: WorkingIntentState = .dontWantToWork
    @State private var pendingConflict: PendingConflict?
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showBanner, !changedDays.isEmpty {
                    updateBanner
                }
                StatusHeaderBar()
                HStack(spacing: 10) {
                    snapshotTag
                    VisibilityToolbar(layers: $layers)
                }
                .padding(.horizontal).padding(.top, 2)
                MarkIntentsToolbar(mode: $mode, offBrush: $offBrush, workBrush: $workBrush)
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
                    Button { showKey = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Color key")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTradeSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showTradeSettings) { TradeSettingsSheet() }
            .sheet(isPresented: $showKey) { IntentKeySheet() }
            .sheet(item: $editTarget) { target in
                DayIntentEditor(target: target)
                    .presentationDetents([.large])
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
            .alert("Change this day's intent?", isPresented: Binding(
                get: { pendingConflict != nil }, set: { if !$0 { pendingConflict = nil } })) {
                Button("Overwrite", role: .destructive) { pendingConflict?.apply(); pendingConflict = nil }
                Button("Cancel", role: .cancel) { pendingConflict = nil }
            } message: {
                Text("This day is already marked \"\(pendingConflict?.existing ?? "")\". Overwrite it?")
            }
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
    /// If the day already carries a *different* explicit intent, confirm first.
    private func handleTap(day: String, isOff: Bool) {
        switch mode {
        case .off:
            editTarget = DayEditTarget(dayID: day, isOff: isOff)
        case .workingShifts:
            guard !isOff else { return }
            applyWorking(workBrush, on: day)
        case .daysOff:
            guard isOff else { return }
            if let brush = offBrush {                       // AM/PM/MID pill brush
                // Only legal pickup types can be set.
                guard Legality.legalTypes(forDayID: day, shifts: store.shifts).contains(brush) else { return }
                intents.toggleAvailability(brush, forDay: day)
                return
            }
            let current = intents.offIntent(forDay: day)
            if let current, current != .wantToWork {
                pendingConflict = PendingConflict(dayID: day, existing: current.label) {
                    intents.setOffIntent(.wantToWork, forDay: day)
                }
                return
            }
            intents.setOffIntent(current == .wantToWork ? nil : .wantToWork, forDay: day)
        }
    }

    /// Apply the selected working-shift brush to a day (toggle off if same;
    /// confirm if it would overwrite a different intent).
    private func applyWorking(_ brush: WorkingIntentState, on day: String) {
        let current = intents.workingIntent(forDay: day)
        if current == brush { intents.setWorkingIntent(nil, forDay: day); return }
        if let current {
            pendingConflict = PendingConflict(dayID: day, existing: current.label) {
                intents.setWorkingIntent(brush, forDay: day)
            }
            return
        }
        intents.setWorkingIntent(brush, forDay: day)
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
    @Binding var offBrush: ShiftAvailabilityType?
    @Binding var workBrush: WorkingIntentState

    var body: some View {
        Group {
            if mode == .off {
                restingBar
            } else {
                editPanel.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Main View's resting state — clean, with one secondary entry into editing.
    private var restingBar: some View {
        HStack {
            Spacer()
            Button { withAnimation(.snappy) { mode = .workingShifts } } label: {
                Label("Mark Intents", systemImage: "pencil.and.list.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain).tint(.accentColor)
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    /// Secondary edit panel: a two-way Working/Days-Off switch + brushes + Done.
    private var editPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $mode.animation(.easeInOut)) {
                    Text("Working Shifts").tag(IntentMode.workingShifts)
                    Text("Days Off").tag(IntentMode.daysOff)
                }
                .pickerStyle(.segmented)
                Button { withAnimation(.snappy) { mode = .off } } label: {
                    Text("Done").font(.subheadline.weight(.bold))
                }
            }
            .padding(.horizontal)

            if mode == .workingShifts {
                workingPills
            } else if mode == .daysOff {
                availabilityPills
            }
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Working-shift intent brush: Trade away / Keep / Want to work.
    private var workingPills: some View {
        HStack(spacing: 6) {
            brushPill(.dontWantToWork, "Trade away", BrickPalette.change)
            brushPill(.mustWork, "Keep", BrickPalette.clear)
            Spacer()
        }
        .padding(.horizontal)
    }

    private func brushPill(_ state: WorkingIntentState, _ label: String, _ color: Color) -> some View {
        let on = workBrush == state
        return Button { workBrush = state } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(label).font(.caption2.weight(on ? .bold : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(on ? color.opacity(0.22) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// AM/PM/MID availability brush — pick one and tap off days. Deselecting every
    /// type on a day marks it unavailable (red ⊗).
    private var availabilityPills: some View {
        HStack(spacing: 6) {
            Text("Pick up:").font(.caption2).foregroundStyle(.secondary)
            ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                let on = offBrush == type
                Button {
                    offBrush = on ? nil : type
                } label: {
                    Text(type.rawValue)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? BrickPalette.availableOff : Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(offBrush == nil ? "Pick a type, tap off days" : "Tap off days to set")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
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
            toggle("note.text", on: $layers.notes, label: "Notes")
            toggle("paintpalette.fill", on: $layers.intentOverlays, label: "Intent colors")
            toggle("a.circle.fill", on: $layers.availability, label: "Availability")
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

/// A queued single-tap that would overwrite an existing, different intent.
struct PendingConflict: Identifiable {
    let dayID: String
    let existing: String
    let apply: () -> Void
    var id: String { dayID }
}

// MARK: - Color key

/// Explains what every calendar color / marker means.
struct IntentKeySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Working shifts") {
                    keyRow(BrickPalette.change, "Trade away", "You want to give this shift away")
                    keyRow(BrickPalette.clear, "Keep", "You want to work this shift")
                    keyRow(BrickPalette.neutral, "Neutral / open", "No strong preference")
                }
                Section("Days off") {
                    keyRow(BrickPalette.availableOff, "Available (AM/PM/MID)", "Legal pickup types you'll work")
                    iconRow("xmark.circle.fill", BrickPalette.critical, "Unavailable (deselected all)")
                }
                Section("Markers & borders") {
                    borderRow(BrickPalette.warning, "High-Demand date")
                    borderRow(BrickPalette.milestone, "Personal Milestone")
                    iconRow("note.text", BrickPalette.info, "Has a note (tap the day to read)")
                    iconRow("a.circle.fill", BrickPalette.clear, "AM/PM/MID pickup availability")
                }
            }
            .navigationTitle("Color Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func keyRow(_ color: Color, _ title: String, _ desc: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.62)).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func borderRow(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: 2).frame(width: 26, height: 26)
            Text(title).font(.subheadline.weight(.semibold))
        }
    }
    private func iconRow(_ symbol: String, _ color: Color, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 26)
            Text(title).font(.subheadline.weight(.semibold))
        }
    }
}
