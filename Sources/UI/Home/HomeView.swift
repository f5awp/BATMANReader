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

/// Days-Off granular painting: the AM/PM/MID pills mean EITHER "black these shifts out" or "I want to
/// work these shifts" — mutually exclusive per day (want-to-work overrides blackout). Selected shifts show
/// as a red ✕ in blackout mode, gold in work mode.
enum OffPaintMode: String, CaseIterable, Identifiable {
    case blackout = "Blackout Shifts"
    case work = "Work Shifts"
    var id: String { rawValue }
}

/// Which optional overlays the calendar draws.
struct LayerVisibility {
    var notes = true          // DayNote markers
    var intentOverlays = true // intent tints
    var availability = false  // §3: in-cell A/P/M chips OFF by default (toggle kept in VisibilityToolbar)
    var shiftType = true       // show the shift TYPE (AM/PM/MID) on worked days
    var deskAssignments = true // show the desk on worked days ("PM 32" vs just "PM")
}

// MARK: - Home

struct HomeView: View {

    private let store    = ShiftStore.shared
    private let settings = SettingsManager.shared
    private var intents  = DayIntentStore.shared

    @State private var mode: IntentMode = .off
    @State private var layers = LayerVisibility()
    @State private var editTarget: DayEditTarget?     // day tap (any mode) → full DayIntentEditor
    @State private var changedDays: Set<String> = []
    @State private var showBanner = false
    @AppStorage("batman.v2.lastReconciledFetch") private var lastReconciledFetch: Double = 0
    @AppStorage("batman.calendar.continuous") private var continuousCalendar = false   // opt-in continuous layout
    @State private var flashChanged = false
    @State private var offBrushes: Set<ShiftAvailabilityType> = []   // shift types to paint (multi-select)
    @State private var offMode: OffPaintMode = .blackout             // do those shifts mean blackout or want-to-work?
    @State private var workBrush: WorkingIntentState = .dontWantToWork
    @State private var noteBrush = ""   // F2: when set, each tapped day also gets this note
    @State private var eraseMode = false   // when on, tapping a day ERASES its intent + note (cleared state)
    @State private var showColorKey = false    // color key / legend (its own button, left of the layers toggle)
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
                        // Successful-trade stats moved to the shared bottom bar (TradeStatsBar) so the top
                        // of the calendar isn't crowded (B6-STATS). Color Key sits just left of the layers toggle.
                        calendarLayoutButton
                        colorKeyButton
                        VisibilityToolbar(layers: $layers)
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                    // Intent tally under the Mark Intents button (full "Want to Trade/Work" labels are too
                    // wide to sit inline without wrapping on iPhone). Centered; hidden when no intents.
                    IntentTallyBar(centered: true)
                }
                homeNotesBar
                MarkIntentsToolbar(mode: $mode, offBrushes: $offBrushes, offMode: $offMode, workBrush: $workBrush,
                                   noteBrush: $noteBrush,
                                   eraseMode: $eraseMode, layers: $layers,
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
                        continuous: continuousCalendar,
                        onTap: handleTap,
                        // Detailed per-day editor only inside Mark Intents — general view is read-only.
                        onLongPress: { day, isOff in
                            if mode != .off { editTarget = DayEditTarget(dayID: day, isOff: isOff) }
                        })
                }

                // (Last-synced + app version moved to App Settings; the Home page ends at the calendar.)
            }
            .navigationTitle(AppGuide.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)   // the shared AppTopBar is the header now
            .sheet(item: $editTarget) { target in
                Group {
                    if target.showTradeList { DayDetailSheet(target: target) }
                    else { DayIntentEditor(target: target) }
                }
                .magnifiable()
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showColorKey) { IntentKeySheet() }
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
            // R-B: load peers when Home appears so matching/status reflect what everyone published.
            // Also re-pull MY intents + trade prefs from the private DB so a change made on another
            // device shows here (LWW; won't clobber unsaved local edits). Was launch-only before.
            .task {
                await TradeProfileStore.shared.refreshOthers()
                await PrivateStateStore.shared.syncIntentsOnLaunch()
                await TradeProfileStore.shared.syncMyPreferences()
            }
            .onChange(of: mode) { _, new in
                overwriteConfirmed = false   // #10: new marking session re-asks once
                // Finished marking → publish updated availability pills for matching.
                if new == .off { Task { await TradeProfileStore.shared.publishMine() } }
            }
            .onChange(of: workBrush) { _, _ in overwriteConfirmed = false }
            .onChange(of: offBrushes) { _, _ in overwriteConfirmed = false }
        }
    }

    // MARK: CSV import (admin publishes the shared master roster)

    // MARK: Pieces

    /// Enters Mark-Intents (edit) mode — lives on the left of the header row.
    private var markIntentsPill: some View {
        Button { withAnimation(.snappy) { mode = .workingShifts } } label: {
            // §7: the compact bar's primary action — a NEUTRAL glazed control tile (same surface as the
            // dock's icon squircles) with the system accent as the LABEL, not a standalone neon-blue pill.
            Label("Mark Intents", systemImage: "pencil.and.list.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(height: DS.controlSize)
                .padding(.horizontal, 14)
                .dxControlTile()
        }
        .buttonStyle(.plain)
    }

    /// Toggles the calendar between the default paged month view and the opt-in continuous stream.
    private var calendarLayoutButton: some View {
        Button { withAnimation(.snappy) { continuousCalendar.toggle() } } label: {
            Image(systemName: continuousCalendar ? "calendar.day.timeline.left" : "calendar")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: DS.controlSize, height: DS.controlSize)
                .foregroundStyle(continuousCalendar ? Color.white : Color.primary)
                .background(continuousCalendar ? Color.accentColor : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
                .dxGlaze(radius: DS.controlRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(continuousCalendar ? "Continuous calendar on" : "Continuous calendar off")
    }

    /// Color key / legend — a dedicated icon button just left of the layers (visibility) toggle. Same
    /// control shape as VisibilityToolbar; opens the shared `IntentKeySheet`.
    private var colorKeyButton: some View {
        Button { showColorKey = true } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: DS.controlSize, height: DS.controlSize)
                .foregroundStyle(Color.primary)
                .background(Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
                .dxGlaze(radius: DS.controlRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colors & legend")
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
        // Clear-note brush: while active, a tap ONLY clears that day's note (no intent paint), so you can
        // sweep dates to wipe notes. Works in both Working and Days-Off sub-modes.
        if mode != .off, eraseMode {
            // Intent eraser: wipe any intent, availability, note, and significant-day flag back to the
            // cleared state — the day returns to its normal (unmarked) color.
            intents.clearIntent(forDay: day)
            intents.setNote(nil, forDay: day)
            intents.setTopology(nil, forDay: day)
            return
        }
        switch mode {
        case .off:
            // Outside Mark Intents a day tap opens the 2-tab day detail — Trade List (who you can trade
            // with that day + Watch Day) first, then Info (the full intent/reason/note/vacation editor).
            editTarget = DayEditTarget(dayID: day, isOff: isOff, showTradeList: true)
        case .workingShifts:
            guard !isOff else { return }
            stampNote(day)
            applyWorking(workBrush, on: day)
        case .daysOff:
            guard isOff else { return }
            stampNote(day)
            let legal = Legality.legalTypes(forDayID: day, shifts: store.shifts)
            // No specific shifts selected → the brush means the WHOLE day (all legal shifts).
            let types = offBrushes.isEmpty ? legal : offBrushes
            switch offMode {
            case .blackout:
                intents.setShiftBlackout(types, forDay: day, legal: legal)        // ✕ the chosen shifts
            case .work:
                intents.setShiftWantToWork(types, forDay: day, legal: legal)      // gold — want-to-work (overrides blackout)
            }
        }
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
    @Binding var offBrushes: Set<ShiftAvailabilityType>
    @Binding var offMode: OffPaintMode
    @Binding var workBrush: WorkingIntentState
    @Binding var noteBrush: String
    @Binding var eraseMode: Bool       // when on, tapping a day clears its note
    @Binding var layers: LayerVisibility   // layers menu rides in the top row while editing
    var onSave: () -> Void          // SAVE this session's marks (clears the dirty glow)
    var onDone: () -> Void          // leave the section (guarded if there are unsaved edits)
    private var intents = DayIntentStore.shared

    init(mode: Binding<IntentMode>, offBrushes: Binding<Set<ShiftAvailabilityType>>,
         offMode: Binding<OffPaintMode>, workBrush: Binding<WorkingIntentState>,
         noteBrush: Binding<String>, eraseMode: Binding<Bool>, layers: Binding<LayerVisibility>,
         onSave: @escaping () -> Void, onDone: @escaping () -> Void) {
        _mode = mode; _offBrushes = offBrushes; _offMode = offMode; _workBrush = workBrush
        _noteBrush = noteBrush; _eraseMode = eraseMode; _layers = layers
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
                DXSegmented(selection: $mode, options: [
                    .init(IntentMode.workingShifts, "Working"),
                    .init(IntentMode.daysOff, "Off"),
                ])
                VisibilityToolbar(layers: $layers)
                // Intent eraser — sits by Done; tapping days clears ALL intent + note back to cleared.
                Button {
                    eraseMode.toggle()
                    if eraseMode { noteBrush = "" }   // eraser + note-stamp are mutually exclusive
                } label: {
                    Label("Erase", systemImage: "eraser.line.dashed")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(eraseMode ? Color.white : AppColor.danger)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(eraseMode ? AppColor.danger : AppColor.danger.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(eraseMode ? "Intent eraser on" : "Erase intents and notes")
                DXCloseButton { onDone() }
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
                TextField(eraseMode ? "Eraser on — tap days to clear them" : "Stamp a note on tapped days (optional)",
                          text: $noteBrush)
                    .font(.subheadline)
                    .disabled(eraseMode)
                    .foregroundStyle(eraseMode ? .secondary : .primary)
                    .onChange(of: noteBrush) { _, v in if v.count > DayNote.maxLength { noteBrush = String(v.prefix(DayNote.maxLength)) } }
                if !eraseMode, !noteBrush.isEmpty {
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

    /// Working-shift intent — a two-way mode switch in the SAME format as the Off panel's
    /// Blackout ↔ Want-to-Work switch: "Want to Trade" (purple) ↔ "Keep" (green). Driven by
    /// `IntentBrushes.working` so the two states can never be silently omitted.
    private var workingPills: some View {
        DXSegmented(selection: $workBrush,
                    options: IntentBrushes.working.map { .init($0, $0.label) },
                    color: { $0.brickColor })
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

    /// Off-day brushes: a Blackout ↔ Work mode switch, then the AM/PM/MID shift pills. The SAME pills mean
    /// "black these shifts out" (✕, slate) or "I want to work these shifts" (gold) depending on the mode —
    /// mutually exclusive per day (want-to-work overrides blackout). No shift selected = the whole day.
    private var availabilityPills: some View {
        // The pill tint tracks the mode so the selection reads the way it'll paint: gold = work, slate = ✕.
        let selColor = offMode == .work ? OffIntentState.wantToWork.brickColor : AppColor.locked
        return VStack(spacing: 8) {
            DXSegmented(selection: $offMode, options: [
                .init(OffPaintMode.blackout, "Blackout"),
                .init(OffPaintMode.work, "Want to Work"),
            ], color: { $0 == .work ? OffIntentState.wantToWork.brickColor : AppColor.locked })
                .padding(.horizontal)

            HStack(spacing: 8) {
                Text(offMode == .work ? "Work shifts" : "Blackout shifts")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ShiftAvailabilityType.allCases, id: \.self) { type in
                    let on = offBrushes.contains(type)
                    Button { if on { offBrushes.remove(type) } else { offBrushes.insert(type) } } label: {
                        Text(type.rawValue)
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(on ? selColor : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(on ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Visibility toolbar (WSI-style icon strip)

/// A compact horizontal strip of icon toggles controlling which calendar layers
/// are drawn — modeled on the dispatch desk's icon toolbar, with Slack-grade
/// spacing and clear on/off states.
/// Compact "last synced" line, shown at the bottom of the Home page.
struct VisibilityToolbar: View {
    @Binding var layers: LayerVisibility

    /// Collapsed into a single "layers" menu so it no longer occupies a full toolbar row.
    /// The icon fills accent when any layer is hidden (so it's obvious something is off).
    private var anyHidden: Bool {
        !(layers.notes && layers.intentOverlays && layers.availability && layers.shiftType && layers.deskAssignments)
    }

    var body: some View {
        Menu {
            Toggle(isOn: $layers.notes) { Label("Notes", systemImage: "note.text") }
            Toggle(isOn: $layers.intentOverlays) { Label("Intent colors", systemImage: "paintpalette.fill") }
            Toggle(isOn: $layers.availability) { Label("Shift availability", systemImage: "clock.badge.checkmark") }
            Toggle(isOn: $layers.shiftType) { Label("Shift type (AM/PM/MID)", systemImage: "clock") }
            Toggle(isOn: $layers.deskAssignments) { Label("Desk numbers", systemImage: "number") }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: DS.controlSize, height: DS.controlSize)
                .foregroundStyle(anyHidden ? Color.white : Color.primary)
                .background(anyHidden ? Color.accentColor : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
                .dxGlaze(radius: DS.controlRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Layer visibility")
    }
}

// MARK: - Edit target

struct DayEditTarget: Identifiable {
    let dayID: String
    let isOff: Bool
    /// A Main-View tap opens the 2-tab day detail (Trade List + Info); a Mark-Intents long-press opens the
    /// plain intent editor. Same target type, two presentations.
    var showTradeList = false
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
        }
    }
}
