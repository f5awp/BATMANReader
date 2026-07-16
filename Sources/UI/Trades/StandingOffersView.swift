// StandingOffersView.swift
// Build 6 — manage STANDING CONDITIONAL OFFERS ("trade X to get Y"). Create/toggle/delete offers, see
// which are fillable right now, and propose to a satisfying peer in one tap. Data + matching live in
// StandingOfferStore / TradeRouter.evaluateStandingOffers.

import SwiftUI

struct StandingOffersView: View {
    private let store = StandingOfferStore.shared
    @State private var editing = false

    var body: some View {
        Group {
            if store.offers.isEmpty {
                ContentUnavailableView("No Standing Offers", systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Create a \"trade X to get Y\" offer and we'll watch for a peer who can fill it — then alert you."))
            } else {
                List {
                    ForEach(store.offers) { offer in
                        NavigationLink { StandingOfferDetail(offer: offer) } label: { row(offer) }
                    }
                    .onDelete { idx in idx.map { store.offers[$0].id }.forEach(store.remove) }
                }
            }
        }
        .navigationTitle("Standing Offers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { editing = true } label: { Image(systemName: "plus") } }
        }
        .sheet(isPresented: $editing) { StandingOfferEditor() }
    }

    @ViewBuilder private func row(_ offer: StandingOffer) -> some View {
        let fillable = store.isSatisfiable(offer.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Give \(offer.giveDayIDs.count) · get \(offer.getDayIDs.count)").font(.dsCardTitle)
                Spacer()
                KindChip(kind: offer.kind)
            }
            Text("Give \(StandingFmt.list(offer.giveDayIDs)) → get \(StandingFmt.list(offer.getDayIDs))")
                .font(.dsCardMeta).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: fillable ? "checkmark.seal.fill" : "clock")
                    .foregroundStyle(fillable ? AppColor.success : .secondary)
                Text(fillable ? "Fillable now · \(store.matches(for: offer.id).count) peer\(store.matches(for: offer.id).count == 1 ? "" : "s")"
                              : (offer.active ? "Watching…" : "Paused"))
                    .font(.caption).foregroundStyle(fillable ? AppColor.success : .secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { offer.active }, set: { store.setActive(offer.id, $0) })).labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Create a new standing offer: pick give-days (your working shifts) + get-days (future dates) + kind.
private struct StandingOfferEditor: View {
    private let store = StandingOfferStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var give: Set<String> = []
    @State private var getDates: Set<DateComponents> = []
    @State private var kind: TradeKind = .both
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Give away (your shifts)") {
                    ShiftSelectCalendar(shifts: ShiftStore.shared.shifts, selection: $give)
                }
                Section("Get in return (days to work)") {
                    MultiDatePicker("Get days", selection: $getDates, in: Date()...).frame(minHeight: 320)
                }
                Section("Kind") {
                    Picker("Trade as", selection: $kind) {
                        Text("Either").tag(TradeKind.both); Text("Day-for-day").tag(TradeKind.day); Text("ECB points").tag(TradeKind.ecb)
                    }.pickerStyle(.segmented)
                }
                Section("Note") { TextField("Optional", text: $note, axis: .vertical).lineLimit(1...3) }
            }
            .navigationTitle("New Offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.add(giveDayIDs: Array(give), getDayIDs: StandingFmt.iso(getDates), kind: kind, note: note)
                        dismiss()
                    }
                    .disabled(give.isEmpty || getDates.isEmpty)
                }
            }
        }
    }
}

/// A standing offer's current matches — propose to any satisfying peer.
private struct StandingOfferDetail: View {
    let offer: StandingOffer
    private let store = StandingOfferStore.shared
    private let messaging = MessagingStore.shared
    @State private var sentPeers: Set<String> = []

    var body: some View {
        List {
            let matches = store.matches(for: offer.id)
            if matches.isEmpty {
                Section {
                    Text(offer.active ? "No peer can fill this offer yet — we'll alert you the moment one can."
                                      : "This offer is paused. Turn it back on to keep watching.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Fillable with") {
                    ForEach(matches) { m in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Avatar(name: m.peerName, id: m.peerID, size: 30); Text(m.peerName).font(.dsCardTitle); Spacer() }
                            Text("You give \(StandingFmt.list(m.giveDayIDs)) → get \(StandingFmt.list(m.getDayIDs))")
                                .font(.dsCardMeta).foregroundStyle(.secondary)
                            Button {
                                Task {
                                    await messaging.sendRequest(to: m.peerID, toName: m.peerName,
                                        note: "Standing offer: give \(StandingFmt.list(m.giveDayIDs)), get \(StandingFmt.list(m.getDayIDs)).",
                                        take: m.getDayIDs, give: m.giveDayIDs, origin: .intents)
                                    sentPeers.insert(m.peerID)
                                }
                            } label: {
                                Label(sentPeers.contains(m.peerID) ? "Proposed" : "Propose",
                                      systemImage: sentPeers.contains(m.peerID) ? "checkmark.circle.fill" : "paperplane.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(AppColor.success)
                            .disabled(sentPeers.contains(m.peerID))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Offer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum StandingFmt {
    private static let inF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let outF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    static func list(_ ids: [String]) -> String {
        let names = ids.sorted().compactMap { inF.date(from: $0).map { outF.string(from: $0) } }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }
    static func iso(_ comps: Set<DateComponents>) -> [String] {
        let cal = Calendar.current
        return comps.compactMap { cal.date(from: $0) }.map { inF.string(from: $0) }
    }
}
