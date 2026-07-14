# WHATS-NEW-GUIDE.md — how to ship release notes in DX Trader

This is the exact procedure for every new version. The view code never changes;
you only edit `ReleaseNotes.swift`. Follow it literally (good instructions for
a human or for Claude in Xcode).

## Files

- `WhatsNewView.swift` — the screen. DO NOT edit for a new release.
- `ReleaseNotes.swift` — the data. THIS is the only file you touch.

## Per-release procedure

1. Open `ReleaseNotes.swift`.
2. Copy the newest `ReleaseNote(...)` block as a template.
3. Paste it at the TOP of `ReleaseNotes.all` (newest first — the view always
   renders `all[0]` and lists the rest under "Previous versions").
4. Set `version` — "v2.4" style, matching the marketing version in Xcode.
5. Write `headline` — ONE sentence, present tense, em-dash rhythm:
   "<the single biggest change> — <why it matters> — plus <2-3 secondary
   features>." No exclamation marks, no "we're excited."
6. Write 4–8 bullets, ordered by impact (biggest first, "Refinements" always
   last if present). Each bullet:
   - `icon`: one glyph. Reuse the established set where the topic recurs:
     ✦ matching/engine · ⇄ qual swaps · ½ partial accept · ▶ tour/onboarding ·
     ◧ visual theme · ▤ calendar views · » refinements/misc · ☰ lists ·
     ✓ confirmations. Pick a new single glyph only for a genuinely new topic.
   - `color`: one of the palette constants (violet, blue, green, gold, teal,
     orange, brand, gray). gray is reserved for "Refinements."
   - `title`: 2–5 words, no period.
   - `body`: 1–2 sentences, plain dispatcher language. Name concrete UI
     ("the amber Q", "twin calendars") instead of abstractions.
7. Build. `WhatsNewView` picks up the new note automatically.

## Copy rules (binding)

- Never claim ranking uses how individuals trade or their history.
- Never name the airline or any dispatcher.
- Call the group "the group," never "the shop."
- The schedule source is "the BATMAN schedule."
- Honest tone: name limitations plainly; no hype words.

## Presentation wiring (already in the app — for reference)

- After onboarding: when the welcome walkthrough finishes, present What's New
  ~0.45s after the cover dismisses.
- After updates: on launch, if `lastSeenChangelogBuild != current build`,
  present once, then record the build.
- Both gated by `SettingsManager.showUpdateOnLaunch` (default on), toggle
  "Show update notes on launch" in Settings.
- `onClose` must record the seen build:
  `lastSeenChangelogBuild = Bundle.main.buildNumber`.

## Asset

- The header expects an asset named `dx-logo` (the standard dark 1024 mark,
  already in Assets.xcassets from the welcome-walkthrough export).
