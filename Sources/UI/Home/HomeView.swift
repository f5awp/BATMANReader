// HomeView.swift
// v2 Home tab — the evolved Schedule page: a robust vertical-scrolling month
// calendar with per-day trade-intent marking, layer toggles, a snapshot banner,
// and a tabbed Trade Settings sheet. Intent is read/written through DayIntentStore
// (the single source of truth); the calendar layout descends from
// ScheduleCalendarView.

import SwiftUI

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
    var deskAssignments = true // show the desk on worked days ("PM 32" vs just "PM")
}

// MARK: - Home

struct HomeView: View {

    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared
    private var intents  = DayIntentStore.shared

    @State private var mode: IntentMode = .off
    @State private var layers = LayerVisibility()
    @State private var editTarget: DayEditTarget?
    @State private var changedDays: Set<String> = []
    @State private var showBanner = false
    @AppStorage("batman.v2.lastReconciledFetch") private var lastReconciledFetch: Double = 0
    @State private var flashChanged = false
    @State private var offBrush: ShiftAvailabilityType?   // nil = generic "want to work"
    @State private var workBrush: WorkingIntentState = .dontWantToWork
    @State private var offIntentBrush: OffIntentState = .wantToWork   // direct off-day intent brush (F1)
    @State private var noteBrush = ""   // F2: when set, each tapped day also gets this note
    @State private var pendingConflict: PendingConflict?
    @State private var overwriteConfirmed = false   // #10: ask-overwrite ONCE per mass-action session
    @State private var showLeaveGuard = false        // C1 phase-2: Save-or-Discard when leaving with unsaved edits

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showBanner, !changedDays.isEmpty {
                    updateBanner
                }
                // ONE control row (not editing): primary action on the left; the ambient trades stat
                // + layers toggle grouped on the right. Collapses the old 3 stacked strips into one,
                // killing the dead space. While editing, the edit panel takes over this space.
                if mode == .off {
                    HStack(spacing: 10) {
                        markIntentsPill
                        Spacer(minLength: 8)
                        HomeMetricsHeader()
                        VisibilityToolbar(layers: $layers)
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                }
                homeNotesBar
                MarkIntentsToolbar(mode: $mode, offBrush: $offBrush, workBrush: $workBrush,
                                   offIntentBrush: $offIntentBrush, noteBrush: $noteBrush,
                                   layers: $layers,
                                   onSave: saveIntents, onDone: attemptLeaveEditing)
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
                        // Detailed per-day editor only inside Mark Intents — general view is read-only.
                        onLongPress: { day, isOff in
                            if mode != .off { editTarget = DayEditTarget(dayID: day, isOff: isOff) }
                        })
                }

                // Last-synced line pinned to the very bottom of the page.
                Divider()
                HStack { SyncTag(); Spacer() }
                    .padding(.horizontal).padding(.vertical, 4)
            }
            .navigationTitle("BATMAN Watcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // the shared AppTopBar is the header now
            .sheet(item: $editTarget) { target in
                DayIntentEditor(target: target)
                    .presentationDetents([.large])
            }
            .alert("Overwrite existing marks?", isPresented: Binding(
                get: { pendingConflict != nil }, set: { if !$0 { pendingConflict = nil } })) {
                Button("Overwrite", role: .destructive) { pendingConflict?.apply(); pendingConflict = nil }
                Button("Cancel", role: .cancel) { pendingConflict = nil }
            } message: {
                Text("This day is already marked \"\(pendingConflict?.existing ?? "")\". Overwrite it? You won't be asked again while painting with this brush.")
            }
            .confirmationDialog("Unsaved intent changes", isPresented: $showLeaveGuard, titleVisibility: .visible) {
                Button("Save") {
                    saveIntents()
                    withAnimation(.snappy) { mode = .off }
                }
                Button("Discard", role: .destructive) {
                    intents.discardChanges()
                    withAnimation(.snappy) { mode = .off }
                }
                Button("Keep Editing", role: .cancel) {}
            } message: { Text("You have unsaved marks. Save them so your trades update, or discard to revert.") }
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

    // MARK: Pieces

    /// Enters Mark-Intents (edit) mode — lives on the left of the header row.
    private var markIntentsPill: some View {
        Button { withAnimation(.snappy) { mode = .workingShifts } } label: {
            Label("Mark Intents", systemImage: "pencil.and.list.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(height: DS.controlSize)
                .padding(.horizontal, 14)
                .background(Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
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
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AppColor.pending)
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
        .background(AppColor.pending.opacity(0.12))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { flashChanged = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { flashChanged = false } }
        }
    }


    // MARK: Actions

    /// SAVE: persist baseline + bump the revision so the trade feeds recompute once,
    /// and re-publish availability. Clears the dirty flag (the glowing Save button dims).
    private func saveIntents() {
        intents.markIntentsSaved()
        Task { await TradeProfileStore.shared.publishMine() }
        Task { await PrivateStateStore.shared.publishLocalIntents() }   // B4-2: sync full intents across devices
    }

    /// Leaving the Mark Intents section: if there are unsaved edits, force Save-or-Discard;
    /// otherwise exit cleanly.
    private func attemptLeaveEditing() {
        if intents.hasUnsavedChanges { showLeaveGuard = true }
        else { withAnimation(.snappy) { mode = .off } }
    }

    /// Single tap: apply the mode's default intent, toggling it off if already set.
    /// If the day already carries a *different* explicit intent, confirm first.
    private func handleTap(day: String, isOff: Bool) {
        switch mode {
        case .off:
            break   // read-only outside Mark Intents — marking only happens in the section
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
    @Binding var layers: LayerVisibility   // layers menu rides in the top row while editing
    var onSave: () -> Void          // SAVE this session's marks (clears the dirty glow)
    var onDone: () -> Void          // leave the section (guarded if there are unsaved edits)
    private var intents = DayIntentStore.shared

    init(mode: Binding<IntentMode>, offBrush: Binding<ShiftAvailabilityType?>,
         workBrush: Binding<WorkingIntentState>, offIntentBrush: Binding<OffIntentState>,
         noteBrush: Binding<String>, layers: Binding<LayerVisibility>,
         onSave: @escaping () -> Void, onDone: @escaping () -> Void) {
        _mode = mode; _offBrush = offBrush; _workBrush = workBrush
        _offIntentBrush = offIntentBrush; _noteBrush = noteBrush; _layers = layers
        self.onSave = onSave; self.onDone = onDone
    }

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
                VisibilityToolbar(layers: $layers)
                Button { onDone() } label: {
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

            saveButton.padding(.horizontal)   // glowing primary action — transparent until you edit
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The session's Save action. Transparent/faded while clean, glowing green the moment
    /// there are unsaved edits — so it's obvious there's something to save. (C1 phase-2)
    private var saveButton: some View {
        let dirty = intents.hasUnsavedChanges
        return Button(action: onSave) {
            Label(dirty ? "Save Changes" : "Saved", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(dirty ? .white : AppColor.success.opacity(0.55))
                .background(dirty ? AppColor.success : AppColor.success.opacity(0.14), in: Capsule())
                .shadow(color: dirty ? AppColor.success.opacity(0.7) : .clear, radius: dirty ? 10 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!dirty)
        .animation(.easeInOut(duration: 0.25), value: dirty)
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
                Circle().fill(color).frame(width: 10, height: 10)
                Text(label).font(.subheadline.weight(.semibold))   // constant weight → selecting doesn't resize
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
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
        // A tight, self-sizing chip (no Spacer / full-width) so it sits inline in the Home control
        // row next to the layers toggle — successful-trade counts + a compact period menu.
        Menu {
            Picker("Period", selection: $period) {
                ForEach(MetricPeriod.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(AppColor.success)
                countPair(mine, "you")
                Text("·").foregroundStyle(.secondary)
                countPair(company, "PAFCA")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.caption2)
            .lineLimit(1)
            .frame(height: DS.controlSize)
            .padding(.horizontal, 12)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onLongPressGesture { if dev.unlocked { TradeHistoryStore.shared.resetMetrics() } }   // admin reset
        .accessibilityLabel("Successful trades: \(mine) you, \(company) PAFCA, \(period.label)")
        .task { await metrics.refresh() }
    }

    private func countPair(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text("\(n)").fontWeight(.bold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
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

    /// Collapsed into a single "layers" menu so it no longer occupies a full toolbar row.
    /// The icon fills accent when any layer is hidden (so it's obvious something is off).
    private var anyHidden: Bool {
        !(layers.notes && layers.intentOverlays && layers.availability && layers.deskAssignments)
    }

    var body: some View {
        Menu {
            Toggle(isOn: $layers.notes) { Label("Notes", systemImage: "note.text") }
            Toggle(isOn: $layers.intentOverlays) { Label("Intent colors", systemImage: "paintpalette.fill") }
            Toggle(isOn: $layers.availability) { Label("Shift availability", systemImage: "clock.badge.checkmark") }
            Toggle(isOn: $layers.deskAssignments) { Label("Desk numbers", systemImage: "number") }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: DS.controlSize, height: DS.controlSize)
                .foregroundStyle(anyHidden ? Color.white : Color.primary)
                .background(anyHidden ? Color.accentColor : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Layer visibility")
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

/// The comprehensive color key / legend — the single source of "what every color means" across
/// the app (calendars, intents, trade status, markers). Driven by `AppLegend`, so it can never
/// drift from the colors the UI actually draws.
struct IntentKeySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("One color = one meaning across the app. Everything below is drawn from the same palette the calendars and trade cards use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(AppLegend.sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { LegendRow(item: $0) }
                    }
                }
            }
            .navigationTitle("Colors & Legend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
