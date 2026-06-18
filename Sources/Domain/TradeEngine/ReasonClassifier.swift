// ReasonClassifier.swift
// Turns a dispatcher's free-text reason into an IntentReason category. Uses the
// on-device Foundation Models LLM on iOS 27+ (free, private, offline), falling
// back to keyword matching everywhere else.

import Foundation
import FoundationModels

enum ReasonClassifier {

    /// Classify free text into one IntentReason (nil for empty input).
    static func classify(_ text: String) async -> IntentReason? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if #available(iOS 27, *) {
            if let r = await aiClassify(t) { return r }
        }
        return keywordClassify(t)
    }

    @available(iOS 27, *)
    private static func aiClassify(_ text: String) async -> IntentReason? {
        let session = LanguageModelSession()
        let prompt = """
        Classify this airline dispatcher's reason for a schedule preference into \
        EXACTLY one of these category keywords: vacation, avoidWeekends, medical, \
        personalEvent, fatigueBlock.
        Reply with ONLY the single keyword, nothing else.

        Reason: "\(text)"
        """
        guard let response = try? await session.respond(to: prompt) else {
            return keywordClassify(text)
        }
        let raw = response.content.lowercased()
        return IntentReason.allCases.first { raw.contains($0.rawValue.lowercased()) }
            ?? keywordClassify(text)
    }

    /// Offline keyword fallback. Defaults to `.personalEvent` when nothing matches.
    private static func keywordClassify(_ text: String) -> IntentReason {
        let t = text.lowercased()
        let map: [(IntentReason, [String])] = [
            (.vacation,      ["vacation", "holiday", "trip", "travel", "pto", "leave", "getaway"]),
            (.medical,       ["sick", "doctor", "medical", "appointment", "surgery", "health", "dentist", "therapy"]),
            (.avoidWeekends, ["weekend", "saturday", "sunday"]),
            (.fatigueBlock,  ["tired", "rest", "fatigue", "sleep", "burnout", "exhausted", "recover", "recovery"]),
            (.personalEvent, ["wedding", "family", "event", "birthday", "party", "kid", "school", "game", "concert", "funeral"])
        ]
        for (reason, kws) in map where kws.contains(where: { t.contains($0) }) { return reason }
        return .personalEvent
    }
}
