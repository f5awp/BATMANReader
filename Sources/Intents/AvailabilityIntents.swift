// AvailabilityIntents.swift
// App Intents for finding trade candidates from the v2 trade-profile system
// (published availability pills / openness in CloudKit — the same data the in-app
// matcher uses), so Siri/Shortcuts results match what the app would surface.
//
// ── Intent: GetAvailableDispatchersIntent ─────────────────────────────
// Returns dispatchers whose published profile shows them available on a given date.
// Filter by AM / PM / MID shift type or get all.
// Returns a list of AvailableDispatcherEntity — each one has the
// dispatcher's name and availability type for use in Shortcuts.
//
// ── Shortcuts workflow ────────────────────────────────────────────────
// 1. Get Available Dispatchers (date: June 20, filter: AM)
// 2. "Choose from List" → select who to contact
// 3. Look Up Contact [dispatcher name] → get phone number
// 4. Send Message [pre-composed trade request]
//
// OR with iOS 27 natural language:
//   "Hey Siri, find AM-available dispatchers on June 20 in BATMANReader"
//   Siri invokes the intent, shows the list, and can chain into Messages.
// ─────────────────────────────────────────────────────────────────────

import AppIntents
import Foundation
import UIKit

// MARK: - AvailableDispatcherEntity

struct AvailableDispatcherEntity: AppEntity, Hashable {

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Available Dispatcher"
    static var defaultQuery = AvailableDispatcherQuery()

    // id = "Name-isoDate" e.g. "Lee, Ervin-2026-06-20"
    var id: String

    @Property(title: "Name")
    var name: String          // "Smith, John"

    @Property(title: "Shift Type")
    var shiftType: String     // "AM", "PM", or "MID"

    @Property(title: "Date")
    var dateString: String    // "June 20, 2026"

    @Property(title: "ISO Date")
    var isoDate: String       // "2026-06-20" — for date math in Shortcuts

    @Property(title: "Message Opener")
    var messageBody: String   // Pre-composed opening for Messages

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name) — \(shiftType) on \(dateString)")
    }

    init(id: String, name: String, shiftType: String, dateString: String,
         isoDate: String, messageBody: String) {
        self.id          = id
        self.name        = name
        self.shiftType   = shiftType
        self.dateString  = dateString
        self.isoDate     = isoDate
        self.messageBody = messageBody
    }

    static func == (lhs: AvailableDispatcherEntity, rhs: AvailableDispatcherEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Entity query

struct AvailableDispatcherQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [AvailableDispatcherEntity] {
        // Live queries only — no persistent store for other dispatchers
        []
    }

    @MainActor
    func suggestedEntities() async throws -> [AvailableDispatcherEntity] {
        // Tomorrow's candidates, from the live v2 trade profiles.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        await TradeProfileStore.shared.refreshOthers()
        return TradeProfileStore.shared.availableDispatchers(on: tomorrow, type: nil)
            .map { AvailableDispatcherEntity.make(profile: $0.profile, type: $0.type, on: tomorrow) }
    }
}

// MARK: - Conversion (from a published v2 TradeProfile)

extension AvailableDispatcherEntity {

    static func make(profile: TradeProfile, type: ShiftAvailabilityType, on date: Date) -> AvailableDispatcherEntity {
        let long = DateFormatter(); long.dateStyle = .long; long.timeStyle = .none
        let iso  = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"

        let firstName = profile.displayName.components(separatedBy: ",").last?
            .trimmingCharacters(in: .whitespaces) ?? profile.displayName
        let body = "Hi \(firstName), are you interested in a trade on \(long.string(from: date))? I'm looking to trade my shift — let me know!"

        return AvailableDispatcherEntity(
            id:          "\(profile.workerID)-\(iso.string(from: date))-\(type.rawValue)",
            name:        profile.displayName,
            shiftType:   type.rawValue,
            dateString:  long.string(from: date),
            isoDate:     iso.string(from: date),
            messageBody: body
        )
    }
}

// MARK: - GetAvailableDispatchersIntent

struct GetAvailableDispatchersIntent: AppIntent {

    static var title: LocalizedStringResource = "Get Available Dispatchers"
    static var description = IntentDescription(
        "Returns dispatchers whose published trade profile shows them available on a given date. Filter by AM, PM, or MID shift type to find trade candidates."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Date", description: "The date to check for available dispatchers.")
    var date: Date

    @Parameter(
        title: "Shift type filter",
        description: "Filter by AM, PM, or MID. Leave unset to see all types.",
        requestValueDialog: "Which shift type are you looking for?"
    )
    var shiftTypeFilter: ShiftAvailabilityType?

    @MainActor
    func perform() async throws -> some IntentResult
        & ReturnsValue<[AvailableDispatcherEntity]>
        & ProvidesDialog {

        // Pull the latest published profiles, then query the v2 availability pills.
        await TradeProfileStore.shared.refreshOthers()
        let matches = TradeProfileStore.shared.availableDispatchers(on: date, type: shiftTypeFilter)

        let f = DateFormatter()
        f.dateStyle = .medium
        let dateStr    = f.string(from: date)
        let filterStr  = shiftTypeFilter.map { "\($0.rawValue) " } ?? ""
        let entities   = matches.map { AvailableDispatcherEntity.make(profile: $0.profile, type: $0.type, on: date) }

        let dialog: IntentDialog
        if entities.isEmpty {
            dialog = IntentDialog(stringLiteral:
                "No \(filterStr)available dispatchers found on \(dateStr). " +
                "Check back later or try a different date."
            )
        } else {
            let names = entities.prefix(3).map { $0.name }.joined(separator: ", ")
            let more  = entities.count > 3 ? " and \(entities.count - 3) more" : ""
            dialog = IntentDialog(stringLiteral:
                "\(entities.count) \(filterStr)available dispatcher\(entities.count == 1 ? "" : "s") on \(dateStr): \(names)\(more)."
            )
        }

        return .result(value: entities, dialog: dialog)
    }
}

// MARK: - ComposeTradeMessageIntent

/// Takes a list of available dispatchers (from GetAvailableDispatchersIntent)
/// and opens Messages with a pre-composed trade broadcast body.
/// The user still selects recipients from their Contacts.
struct ComposeTradeMessageIntent: AppIntent {

    static var title: LocalizedStringResource = "Compose Trade Message"
    static var description = IntentDescription(
        "Opens Messages with a pre-written trade request body listing available dispatchers. Use after 'Get Available Dispatchers'."
    )
    static var openAppWhenRun: Bool = true  // Must open app to trigger Messages URL

    @Parameter(title: "Dispatchers", description: "The available dispatchers to message.")
    var dispatchers: [AvailableDispatcherEntity]

    @Parameter(title: "Your shift details",
               description: "e.g. 'June 20, DSP @ 29, 0500–1400'",
               default: "")
    var shiftDetails: String

    @Parameter(title: "What you want in return",
               description: "e.g. 'ECB×9' or 'day-for-day'",
               default: "ECB×9")
    var desiredReturn: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !dispatchers.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: "No dispatchers provided."))
        }

        let myName   = SettingsManager.shared.displayName.isEmpty
            ? SettingsManager.shared.username
            : SettingsManager.shared.displayName
        let nameList = dispatchers
            .map { "• \($0.name) (\($0.shiftType) available)" }
            .joined(separator: "\n")

        let shiftStr = shiftDetails.isEmpty ? "my upcoming shift" : shiftDetails
        let body = "Hi all — \(myName) here. Looking to trade \(shiftStr) for \(desiredReturn). " +
            "The following dispatchers are available:\n\n\(nameList)\n\n" +
            "Please reply or call if you're interested. Thanks!"

        let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "sms:?body=\(encoded)") {
            _ = await UIApplication.shared.open(url)
        }

        return .result(dialog: IntentDialog(stringLiteral:
            "Messages opened with trade broadcast for \(dispatchers.count) dispatcher\(dispatchers.count == 1 ? "" : "s")."
        ))
    }
}
