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
    var availability = true   // AM/PM/MID pickup markers on off days (#2: now toggleable)
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
    @AppStorage("batman.v2.lastReconciledFetch") private var lastReconciledFetch: Double = 0
    @State private var flashChanged = false
    @State private var showImporter = false
    @State private var importResult: String?
    @State private var importError: String?
    @State private var offBrush: ShiftAvailabilityType?   // nil = generic "want to work"
    @State private var workBrush: WorkingIntentState = .dontWantToWork
    @State private var offIntentBrush: OffIntentState = .wantToWork   // direct off-day intent brush (F1)
    @State private var noteBrush = ""   // F2: when set, each tapped day also gets this note
    @State private var pendingConflict: PendingConflict?
    @State private var overwriteConfirmed = false   // #10: ask-overwrite ONCE per mass-action session
    @State private var showKey = false
    @State private var showAppSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showBanner, !changedDays.isEmpty {
                    updateBanner
                }
                HomeMetricsHeader()   // pinned metrics, first thing seen (H1)
                StatusHeaderBar()
                HStack(alignment: .center, spacing: 10) {
                    if mode == .off { markIntentsPill }
                    Spacer()
                    VisibilityToolbar(layers: $layers)
                }
                .padding(.horizontal).padding(.top, 2)
                homeNotesBar
                MarkIntentsToolbar(mode: $mode, offBrush: $offBrush, workBrush: $workBrush,
                                   offIntentBrush: $offIntentBrush, noteBrush: $noteBrush)
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

                // Last-synced line pinned to the very bottom of the page.
                Divider()
                HStack { SyncTag(); Spacer() }
                    .padding(.horizontal).padding(.vertical, 4)
            }
            .navigationTitle("BATMAN Watcher")
            .navigationBarTitleDisplayMode(.inline)
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
                    Menu {
                        Button { showTradeSettings = true } label: { Label("Trade Settings", systemImage: "arrow.left.arrow.right") }
                        Button { showAppSettings = true } label: { Label("App Settings", systemImage: "gearshape") }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showTradeSettings) { TradeSettingsSheet() }
            .sheet(isPresented: $showAppSettings) { SettingsView() }
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
            .alert("Overwrite existing marks?", isPresented: Binding(
                get: { pendingConflict != nil }, set: { if !$0 { pendingConflict = nil } })) {
                Button("Overwrite", role: .destructive) { pendingConflict?.apply(); pendingConflict = nil }
                Button("Cancel", role: .cancel) { pendingConflict = nil }
            } message: {
                Text("This day is already marked \"\(pendingConflict?.existing ?? "")\". Overwrite it? You won't be asked again while painting with this brush.")
            }
            .onAppear(perform: reconcileSnapshot)
            // R-B: load peers when Home appears so matching/status reflect what everyone
            // published (peer status/intents were blank cross-device).
            .task { await TradeProfileStore.shared.refreshOthers() }
            .onChange(of: mode) { _, new in
                overwriteConfirmed = false   // #10: new marking session re-asks once
                // Finished marking → publish updated availability pills for matching.
                if new == .off { Task { await TradeProfileStore.shared.publishMine() } }
            }
            .onChange(of: workBrush) { _, _ in overwriteConfirmed = false }
            .onChange(of: offIntentBrush) { _, _ in overwriteConfirmed = false }
            .onChange(of: offBrush) { _, _ in overwriteConfirmed = false }
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
                    // G4: post-import sanity check — surface malformed/partial imports instead of shipping them.
                    let report = ImportAudit.validate(workers: workers.map { ($0.id, $0.name) }, selfID: username)
                    lines.append(report.ok ? "Import check: looks good ✓"
                                           : "⚠️ Import check: " + report.warnings.joined(separator: " "))
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

    /// Enters Mark-Intents (edit) mode — lives on the left of the header row.
    private var markIntentsPill: some View {
        Button { withAnimation(.snappy) { mode = .workingShifts } } label: {
            Label("Mark Intents", systemImage: "pencil.and.list.clipboard")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain).tint(.accentColor)
    }

    /// Read-only one-line view of your private notes (from Trade Settings), swipe to
    /// read overflow. Hidden when empty. No vertical padding — sits tight under the row.
    @ViewBuilder private var homeNotesBar: some View {
        if !settings.privateNotes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(settings.privateNotes)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal)
            }
        }
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


    // MARK: Actions

    /// Single tap: apply the mode's default intent, toggling it off if already set.
    /// If the day already carries a *different* explicit intent, confirm first.
    private func handleTap(day: String, isOff: Bool) {
        switch mode {
        case .off:
            editTarget = DayEditTarget(dayID: day, isOff: isOff)
        case .workingShifts:
            guard !isOff else { return }
            stampNote(day)
            applyWorking(workBrush, on: day)
        case .daysOff:
            guard isOff else { return }
            stampNote(day)
            if let brush = offBrush {                       // AM/PM/MID granular pill brush
                // Only legal pickup types can be set.
                guard Legality.legalTypes(forDayID: day, shifts: store.shifts).contains(brush) else { return }
                intents.toggleAvailability(brush, forDay: day)
                return
            }
            applyOff(offIntentBrush, on: day)               // direct off-intent brush
        }
    }

    /// Apply the selected off-day intent brush to a day (toggle off if same;
    /// confirm if it would overwrite a different intent). Mirrors `applyWorking`.
    private func applyOff(_ brush: OffIntentState, on day: String) {
        // #1: Want-to-Work needs a legally-coverable shift; a fully rest-blocked off day can't be marked.
        if brush == .wantToWork, Legality.legalTypes(forDayID: day, shifts: store.shifts).isEmpty { return }
        let current = intents.offIntent(forDay: day)
        if current == brush { intents.setOffIntent(nil, forDay: day); return }
        if let current, !overwriteConfirmed {
            pendingConflict = PendingConflict(dayID: day, existing: current.label) {
                overwriteConfirmed = true                 // #10: confirm once, then paint freely
                intents.setOffIntent(brush, forDay: day)
            }
            return
        }
        intents.setOffIntent(brush, forDay: day)
    }

    /// Apply the selected working-shift brush to a day (toggle off if same;
    /// confirm if it would overwrite a different intent).
    private func applyWorking(_ brush: WorkingIntentState, on day: String) {
        let current = intents.workingIntent(forDay: day)
        if current == brush { intents.setWorkingIntent(nil, forDay: day); return }
        if let current, !overwriteConfirmed {
            pendingConflict = PendingConflict(dayID: day, existing: current.label) {
                overwriteConfirmed = true                 // #10: confirm once, then paint freely
                intents.setWorkingIntent(brush, forDay: day)
            }
            return
        }
        intents.setWorkingIntent(brush, forDay: day)
    }

    /// F2: while a note-stamp is set, every tapped day also gets that note.
    private func stampNote(_ day: String) {
        let text = noteBrush.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        intents.setNote(DayNote(dayID: day, message: text), forDay: day)
    }

    /// On appear: clear intent for any date whose worked/off status flipped since
    /// the last snapshot, and surface a banner so the user can re-map them.
    private func reconcileSnapshot() {
        // Diff-based: reset intents ONLY for days the new master actually changed,
        // never the unchanged majority (SPEC_STRUCTURAL.md S-PARSE-2). Run once per
        // fetch so a user's fresh re-mark of a changed day isn't wiped on re-appear.
        guard let diff = store.lastDiff, diff.hasChanges else { return }
        let fetchStamp = store.lastFetchDate?.timeIntervalSince1970 ?? 0
        guard fetchStamp > lastReconciledFetch else { return }
        lastReconciledFetch = fetchStamp
        let wiped = intents.reconcile(diff: diff)
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
    @Binding var offIntentBrush: OffIntentState
    @Binding var noteBrush: String

    var body: some View {
        Group {
            if mode != .off {
                editPanel.transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
            // F2: optional note stamped onto every day you tap.
            HStack(spacing: 8) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                TextField("Stamp a note on tapped days (optional)", text: $noteBrush)
                    .font(.subheadline)
                    .onChange(of: noteBrush) { _, v in if v.count > DayNote.maxLength { noteBrush = String(v.prefix(DayNote.maxLength)) } }
                if !noteBrush.isEmpty {
                    CharCounter(text: noteBrush, limit: DayNote.maxLength)
                    Button { noteBrush = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Working-shift intent brushes — EVERY meaningful working intent (F1), driven by
    /// `IntentBrushes.working` so none can be silently omitted.
    private var workingPills: some View {
        HStack(spacing: 6) {
            ForEach(IntentBrushes.working) { state in
                brushPill(on: workBrush == state, label: state.label, color: state.brickColor) { workBrush = state }
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private func brushPill(on: Bool, label: String, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 11, height: 11)
                Text(label).font(.subheadline.weight(on ? .bold : .regular))
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(on ? color : Color.primary)
            .background(on ? color.opacity(0.22) : Color(.tertiarySystemFill), in: Capsule())
            .overlay(Capsule().stroke(on ? color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    /// Off-day brushes: direct intent brushes (Must Be Off / Want to Work / Open — EVERY
    /// OffIntentState, F1) on top, plus AM/PM/MID granular pills for "want to work".
    private var availabilityPills: some View {
        // #10: intent brushes + AM/PM/MID on ONE line (scrolls if narrow), larger/clearer buttons.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(IntentBrushes.off) { state in
                    brushPill(on: offBrush == nil && offIntentBrush == state, label: state.label, color: state.brickColor) {
                        offIntentBrush = state; offBrush = nil
                    }
                }
                Divider().frame(height: 24)
                Text("Shift Availability").font(.caption).foregroundStyle(.secondary)
                ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                    let on = offBrush == type
                    Button { offBrush = on ? nil : type } label: {
                        Text(type.rawValue)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(on ? BrickPalette.availableOff : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(on ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Home metrics header (H1)

/// Pinned at top of Home: TOTAL successful trades — yours and the whole company — for the
/// selected period (#9). "Successful" = accepted + archived. One period control switches both totals.
struct HomeMetricsHeader: View {
    private var metrics = MetricsStore.shared
    private var dev = DevAccess.shared
    @State private var period: MetricPeriod = .month

    private var myID: String { SettingsManager.shared.username }
    private var mine: Int { Metrics.count(metrics.globalEvents, kind: .trade, period: period, now: Date(), workerID: myID) }
    private var company: Int { Metrics.count(metrics.globalEvents, kind: .trade, period: period, now: Date()) }

    var body: some View {
        HStack(spacing: DS.l) {
            total("You", mine)
            Divider().frame(height: 30)
            total("Company", company)
            Spacer()
            Picker("", selection: $period) {
                ForEach(MetricPeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 160)
        }
        .padding(.horizontal, DS.cardPadding).padding(.vertical, DS.s)
        .background(.bar)
        .contentShape(Rectangle())
        .onLongPressGesture { if dev.unlocked { TradeHistoryStore.shared.resetMetrics() } }   // admin reset
        .accessibilityElement(children: .combine)
        .task { await metrics.refresh() }
    }

    private func total(_ label: String, _ n: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(n)").font(.title3.monospacedDigit().bold())
            Text("\(label) · trades cleared").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Visibility toolbar (WSI-style icon strip)

/// A compact horizontal strip of icon toggles controlling which calendar layers
/// are drawn — modeled on the dispatch desk's icon toolbar, with Slack-grade
/// spacing and clear on/off states.
/// Compact "last synced" line, shown at the bottom of the Home page.
struct SyncTag: View {
    private var store = ShiftStore.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(text)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private var text: String {
        guard let date = store.lastFetchDate else { return "Not synced yet" }
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return "Synced \(f.string(from: date))"
    }
}

struct VisibilityToolbar: View {
    @Binding var layers: LayerVisibility

    var body: some View {
        HStack(spacing: 2) {
            toggle("note.text", on: $layers.notes, label: "Notes")
            toggle("paintpalette.fill", on: $layers.intentOverlays, label: "Intent colors")
            toggle("clock.badge.checkmark", on: $layers.availability, label: "Shift availability")
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
