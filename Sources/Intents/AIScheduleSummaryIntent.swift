// AIScheduleSummaryIntent.swift
// Uses iOS 27's Foundation Models framework (LanguageModelSession)
// to generate a natural-language summary of your upcoming schedule.
//
// The on-device model is FREE — no API key, no network, no cost.
// Runs entirely on-device using Apple's Neural Engine.
//
// iOS 27 also lets you swap the model with one line:
//   let session = LanguageModelSession()          // Apple on-device (free)
//   let session = LanguageModelSession(model: geminiModel)  // Gemini
//   let session = LanguageModelSession(model: claudeModel)  // Claude
//
// ── Xcode setup ───────────────────────────────────────────────────────
// This file requires iOS 27+. The #available check below means it
// compiles on iOS 26 but the intent only surfaces on iOS 27 devices.
// No additional packages needed for the Apple on-device model.
// ─────────────────────────────────────────────────────────────────────

import AppIntents
import Foundation
import FoundationModels

// MARK: - AI Schedule Summary Intent

struct AIScheduleSummaryIntent: AppIntent {

    static var title: LocalizedStringResource = "Summarize My Schedule"
    static var description = IntentDescription(
        "Uses on-device AI to give a natural-language summary of your upcoming shifts. Free, private, no internet required. iOS 27+ only."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Days ahead",
        description: "How many days to summarize (default: 7)",
        default: 7,
        inclusiveRange: (1, 30)
    )
    var daysAhead: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard #available(iOS 27, *) else {
            return .result(dialog: IntentDialog(stringLiteral:
                "AI summaries require iOS 27 or later."
            ))
        }

        let shifts = await ShiftStore.shared.upcomingWorkingShifts(days: daysAhead)

        guard !shifts.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral:
                "You have no working shifts in the next \(daysAhead) days."
            ))
        }

        let scheduleText = buildScheduleText(from: shifts)
        let summary      = try await generateSummary(for: scheduleText, days: daysAhead)

        return .result(dialog: IntentDialog(stringLiteral: summary))
    }

    // MARK: - Foundation Models

    @available(iOS 27, *)
    private func generateSummary(for scheduleText: String, days: Int) async throws -> String {
        // FoundationModels is imported automatically in iOS 27 SDK
        // LanguageModelSession() uses Apple's on-device model — free, private, offline
        let session = LanguageModelSession()

        let name           = await SettingsManager.shared.displayName
        let dispatcherName = name.isEmpty ? "the dispatcher" : name

        let prompt = """
        You are a concise assistant for an airline dispatcher named \
        \(dispatcherName).

        Summarize their upcoming work schedule in 2-3 natural sentences.
        Mention the total number of shifts, any patterns (consecutive days, \
        early vs late shifts), and any shifts with leave codes.
        Be conversational and brief.

        Schedule data for the next \(days) days:
        \(scheduleText)
        """

        let response = try await session.respond(to: prompt)
        return response.content
    }

    // MARK: - Schedule text builder

    private func buildScheduleText(from shifts: [Shift]) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return shifts.map { shift in
            var line = "\(f.string(from: shift.date)): \(shift.title) (\(shift.startTimeString)–\(shift.endTimeString))"
            if let lc = shift.leaveCode, !lc.isEmpty {
                line += " [Leave: \(lc)]"
            }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: - AI Trade Broadcast Composer Intent

struct AITradeBroadcastIntent: AppIntent {

    static var title: LocalizedStringResource = "Compose Trade Broadcast"
    static var description = IntentDescription(
        "Uses on-device AI to draft a trade broadcast message. You tell it what you want to trade and what you're looking for, and it composes a professional message ready to send. iOS 27+ only."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Shift date to trade", description: "Which shift do you want to trade?")
    var shiftDate: Date

    @Parameter(title: "What you want in return",
               description: "ECB points, specific date, or 'day-for-day'",
               default: "ECB x9")
    var desiredReturn: String

    @Parameter(title: "Days you CAN work",
               description: "Comma-separated dates you're available, e.g. 'June 17, 18, 22'",
               default: "")
    var availableDays: String

    @Parameter(title: "Days you CANNOT work",
               description: "Comma-separated dates you're NOT available",
               default: "")
    var unavailableDays: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard #available(iOS 27, *) else {
            return .result(
                value: "",
                dialog: IntentDialog(stringLiteral: "AI compose requires iOS 27 or later.")
            )
        }

        // Find the shift on the requested date
        guard let shift = await ShiftStore.shared.shift(on: shiftDate) else {
            return .result(
                value: "",
                dialog: IntentDialog(stringLiteral: "No shift found on that date. Check your schedule.")
            )
        }

        let message = try await composeBroadcast(
            shift: shift,
            desiredReturn: desiredReturn,
            availableDays: availableDays,
            unavailableDays: unavailableDays
        )

        return .result(
            value: message,
            dialog: IntentDialog(stringLiteral: "Trade broadcast drafted. Check the result and send via Messages.")
        )
    }

    @available(iOS 27, *)
    private func composeBroadcast(
        shift: Shift,
        desiredReturn: String,
        availableDays: String,
        unavailableDays: String
    ) async throws -> String {
        let session = LanguageModelSession()

        let avail   = availableDays.isEmpty   ? "not specified" : availableDays
        let unavail = unavailableDays.isEmpty ? "not specified" : unavailableDays

        let displayName = await SettingsManager.shared.displayName
        let username    = await SettingsManager.shared.username
        let dispatcher  = displayName.isEmpty ? username : displayName

        let prompt = """
        Compose a brief, professional dispatcher trade broadcast message.

        Use this format (adapt as needed):
        - Who is offering the trade
        - What shift they're offering (date, time, role/desk)
        - What they want in return (points, day-for-day)
        - Days they can work
        - Days they cannot work
        - Contact info note (optional)

        Details:
        - Dispatcher: \(dispatcher)
        - Shift to trade: \(shift.formattedDate), \(shift.title), \(shift.startTimeString)–\(shift.endTimeString)
        - Wants in return: \(desiredReturn)
        - Can work: \(avail)
        - Cannot work: \(unavail)

        Keep it under 100 words. Professional but friendly tone.
        Write only the message, no subject line.
        """

        let response = try await session.respond(to: prompt)
        return response.content
    }
}
