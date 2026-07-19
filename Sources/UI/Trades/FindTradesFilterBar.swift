import SwiftUI

/// Shared, always-visible filter bar for the Find Trades modes. Every filter is a borderless tappable
/// chip laid out horizontally on the main form:
///   • Search depth — a Normal / Deeper dropdown (Deeper runs the intensive 3+/N-Way search),
///   • Give-back dates — the days you want traded back (opens a calendar directly),
///   • Connection — only trades that include a chosen dispatcher,
///   • Shift time — the shift types you'd pick up,
///   • Desk qual — desks requiring a chosen qual,
///   • Openness — a one-time override of your own openness for this search.
/// `onApply` re-runs the host's search at the CURRENT depth whenever any filter changes.
struct FindTradesFilterBar: View {
    @Binding var filter: SearchFilter
    @Binding var deeper: Bool
    var people: [(id: String, name: String)]
    var availableQuals: [String] = []
    var searchShiftCount: Int = 1
    var onApply: () -> Void

    // ONE sheet binding — stacking multiple `.sheet(isPresented:)` on one view makes some unresponsive.
    @State private var activeSheet: FilterSheet?
    private enum FilterSheet: Int, Identifiable { case dates, connection, quals, shifts; var id: Int { rawValue } }

    private var hasDates: Bool { filter.dateStart != nil || filter.dateEnd != nil || !(filter.dates?.isEmpty ?? true) }

    private static let chipFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private var dateLabel: String {
        guard hasDates else { return "Give-back Date" }
        if let d = filter.dates, !d.isEmpty { return "\(d.count) date\(d.count == 1 ? "" : "s")" }
        let s = filter.dateStart.map(Self.chipFmt.string(from:))
        let e = filter.dateEnd.map(Self.chipFmt.string(from:))
        switch (s, e) {
        case let (s?, e?): return s == e ? s : "\(s)–\(e)"
        case let (s?, nil): return "from \(s)"
        case let (nil, e?): return "thru \(e)"
        default: return "Give-back dates"
        }
    }
    private var connectionLabel: String {
        guard let id = filter.requiredWorkerID else { return "Connection" }
        return people.first { $0.id == id }?.name ?? "1 person"
    }
    private var shiftLabel: String {
        filter.receiveTypes.isEmpty ? "Shift" : filter.receiveTypes.map(\.rawValue).sorted().joined(separator: "/")
    }
    private var qualLabel: String {
        filter.deskQuals.isEmpty ? "Qual" : filter.deskQuals.sorted().joined(separator: "/")
    }
    private var opennessLabel: String {
        switch filter.myOpennessOverride {
        case .some(.all): return "Open to all"
        case .some(.bookends): return "Bookends only"
        default: return "Openness"
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Search depth — Normal vs the intensive 3+/N-Way generation.
                Menu {
                    Button { deeper = false; onApply() } label: { checkRow("Normal Search", on: !deeper) }
                    Button { deeper = true; onApply() } label: { checkRow("Deeper Search", on: deeper) }
                } label: {
                    chip(deeper ? "Deeper Search" : "Normal Search", systemImage: "wand.and.stars", active: deeper)
                }.buttonStyle(.plain)

                // Give-back dates — opens a calendar directly.
                Button { activeSheet = .dates } label: {
                    chip(dateLabel, systemImage: "calendar", active: hasDates)
                }.buttonStyle(.plain)

                // Connection — opens the searchable person picker.
                Button { activeSheet = .connection } label: {
                    chip(connectionLabel, systemImage: "person", active: filter.requiredWorkerID != nil)
                }.buttonStyle(.plain)

                // Shift time you'd pick up — a stay-open multi-select picker (doesn't close on each tap).
                Button { activeSheet = .shifts } label: {
                    chip(shiftLabel, systemImage: "clock", active: !filter.receiveTypes.isEmpty)
                }.buttonStyle(.plain)

                // Desk qualification — multi-select (opens a stay-open picker; only when results span quals).
                if !availableQuals.isEmpty {
                    Button { activeSheet = .quals } label: {
                        chip(qualLabel, systemImage: "q.square", active: !filter.deskQuals.isEmpty)
                    }.buttonStyle(.plain)
                }

                // My openness — one-time override for this search only.
                Menu {
                    Button { filter.myOpennessOverride = nil; onApply() } label: { checkRow("Use my setting", on: filter.myOpennessOverride == nil) }
                    Button { filter.myOpennessOverride = .bookends; onApply() } label: { checkRow("Bookends only", on: filter.myOpennessOverride == .bookends) }
                    Button { filter.myOpennessOverride = .all; onApply() } label: { checkRow("Open to all", on: filter.myOpennessOverride == .all) }
                } label: {
                    chip(opennessLabel, systemImage: "slider.horizontal.3", active: filter.myOpennessOverride != nil)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
        .sheet(item: $activeSheet) { which in
            switch which {
            case .dates:
                GiveBackDatesSheet(filter: $filter, onApply: onApply)
            case .connection:
                ConnectionPickerSheet(selected: Binding(get: { filter.requiredWorkerID }, set: { filter.requiredWorkerID = $0 }),
                                      people: people, onApply: onApply)
            case .quals:
                MultiSelectSheet(title: "Desk quals",
                                 options: availableQuals.map { ($0, "\($0) — \(DispatcherDirectory.qualName($0))") },
                                 selected: Binding(get: { filter.deskQuals }, set: { filter.deskQuals = $0 }),
                                 onApply: onApply)
            case .shifts:
                MultiSelectSheet(title: "Shift types",
                                 options: ShiftAvailabilityType.allCases.map { ($0.rawValue, $0.rawValue) },
                                 selected: Binding(get: { Set(filter.receiveTypes.map(\.rawValue)) },
                                                   set: { filter.receiveTypes = Set($0.compactMap(ShiftAvailabilityType.init(rawValue:))) }),
                                 onApply: onApply)
            }
        }
    }

    /// A borderless tappable filter chip: icon · value · caret. Active = SOLID app-accent + white (the same
    /// selected-state convention used across the app), so a set filter reads clearly instead of low-contrast
    /// blue-on-gray.
    private func chip(_ text: String, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .foregroundStyle(active ? .white : .primary)
        .background(active ? AppColor.primary : Color(.secondarySystemBackground), in: Capsule())
    }

    /// A menu row with a trailing checkmark when selected.
    @ViewBuilder private func checkRow(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// The give-back dates picker — pick a From→To **range**, or switch to **Specific days** and tap
/// individual dates on the calendar. Either way the window is stored as `dateStart…dateEnd`. Empty = any.
struct GiveBackDatesSheet: View {
    @Binding var filter: SearchFilter
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Int              // 0 = Range · 1 = Specific days
    @State private var picked: Set<DateComponents>
    @State private var from: Date
    @State private var to: Date

    init(filter: Binding<SearchFilter>, onApply: @escaping () -> Void) {
        _filter = filter; self.onApply = onApply
        let cal = Calendar.current
        let f = filter.wrappedValue
        let isoF = DateFormatter(); isoF.dateFormat = "yyyy-MM-dd"
        var set = Set<DateComponents>()
        if let specific = f.dates, !specific.isEmpty {
            // Specific-days mode: prefill the tapped days from the stored ISO set.
            for iso in specific { if let d = isoF.date(from: iso) { set.insert(cal.dateComponents([.year, .month, .day], from: d)) } }
        } else if let s = f.dateStart, let e = f.dateEnd {
            var d = cal.startOfDay(for: s); let end = cal.startOfDay(for: e); var guardN = 0
            while d <= end, guardN < 400 { set.insert(cal.dateComponents([.year, .month, .day], from: d))
                d = cal.date(byAdding: .day, value: 1, to: d) ?? end; guardN += 1 }
        }
        _picked = State(initialValue: set)
        _from = State(initialValue: f.dateStart ?? Date())
        _to = State(initialValue: f.dateEnd ?? f.dateStart ?? Date())
        _mode = State(initialValue: !(f.dates?.isEmpty ?? true) ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DXSegmented(selection: $mode, options: [.init(0, "Range"), .init(1, "Specific days")])

                if mode == 0 {
                    VStack(spacing: 10) {
                        HStack { Text("From").font(.subheadline); Spacer()
                            DatePicker("", selection: $from, displayedComponents: .date).labelsHidden() }
                        HStack { Text("To").font(.subheadline); Spacer()
                            DatePicker("", selection: $to, in: from..., displayedComponents: .date).labelsHidden() }
                    }
                    .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    MultiDatePicker("Give-back dates", selection: $picked).frame(maxHeight: 340)
                }

                Text("Only trades that return days inside this window are shown. Use Range for a span, or Specific days to tap individual dates.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Give-back Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { filter.dateStart = nil; filter.dateEnd = nil; filter.dates = nil; onApply(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) { DXCloseButton { apply(); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply() {
        let cal = Calendar.current
        if mode == 0 {
            filter.dates = nil                                  // range mode clears the specific-days set
            filter.dateStart = cal.startOfDay(for: min(from, to))
            filter.dateEnd = cal.startOfDay(for: max(from, to))
        } else {
            filter.dateStart = nil; filter.dateEnd = nil        // specific mode: store the exact days, NOT a range
            let iso = Set(picked.compactMap { cal.date(from: $0) }.map { SearchFilter.iso($0) })
            filter.dates = iso.isEmpty ? nil : iso
        }
        onApply()
    }
}

/// A stay-open multi-select picker (tap toggles each option, the sheet stays up so you can pick several).
/// Applies once on Done / Clear. Used for the desk-qual filters.
struct MultiSelectSheet: View {
    let title: String
    let options: [(value: String, label: String)]
    @Binding var selected: Set<String>
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(options, id: \.value) { opt in
                    Button {
                        if selected.contains(opt.value) { selected.remove(opt.value) } else { selected.insert(opt.value) }
                    } label: {
                        HStack {
                            Text(opt.label)
                            Spacer()
                            if selected.contains(opt.value) { Image(systemName: "checkmark").foregroundStyle(AppColor.primary) }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !selected.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { Button("Clear") { selected = []; onApply() } }
                }
                ToolbarItem(placement: .confirmationAction) { DXCloseButton { onApply(); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The searchable "Connection" picker reached from the bar's person chip — limit results to trades
/// that include one dispatcher (or Anyone). Self-loads the full roster so the list is populated even
/// before a search has run.
struct ConnectionPickerSheet: View {
    @Binding var selected: String?
    var people: [(id: String, name: String)]
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var loaded: [(id: String, name: String)] = []

    private var roster: [(id: String, name: String)] { people.isEmpty ? loaded : people }
    private var filtered: [(id: String, name: String)] {
        let base = query.isEmpty ? roster : roster.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
        return base.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                Button { selected = nil; onApply(); dismiss() } label: {
                    HStack { Text("Anyone"); Spacer(); if selected == nil { Image(systemName: "checkmark").foregroundStyle(AppColor.primary) } }
                }
                if roster.isEmpty {
                    ContentUnavailableView("Loading roster…", systemImage: "person.2")
                }
                ForEach(filtered, id: \.id) { p in
                    Button { selected = p.id; onApply(); dismiss() } label: {
                        HStack {
                            Text(p.name)
                            Spacer()
                            if selected == p.id { Image(systemName: "checkmark").foregroundStyle(AppColor.primary) }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Name or employee #")
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DXCloseButton { dismiss() } } }
            .task { if people.isEmpty, loaded.isEmpty { await loadRoster() } }
        }
    }

    private func loadRoster() async {
        if !TradeFeedCache.shared.allDispatchers.isEmpty { loaded = TradeFeedCache.shared.allDispatchers; return }
        let me = SettingsManager.shared.username
        let now = Date(); let end = Calendar.current.date(byAdding: .month, value: 12, to: now) ?? now
        let entries = await RosterStore.shared.entries(from: now, to: end)
        let out = await Task.detached(priority: .userInitiated) {
            var seen = Set<String>(); var out: [(id: String, name: String)] = []
            for e in entries where e.workerID != me && seen.insert(e.workerID).inserted {
                out.append((e.workerID, TradeNames.resolved(displayName: nil, rosterName: e.workerName, workerID: e.workerID)))
            }
            return out.sorted { $0.name < $1.name }
        }.value
        loaded = out
        TradeFeedCache.shared.allDispatchers = out
    }
}
