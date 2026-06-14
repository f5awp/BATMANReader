# BATMAN Watcher — Siri & Shortcuts Guide

BATMAN Watcher reads your dispatch schedule, manages your trade intent (openness,
availability, blacklists), and matches reciprocal trades. On top of that, it exposes
a set of **App Intents** so you can drive it from **Siri** and the **Shortcuts** app —
to wake-up alarms, calendar events, and quick "do I work tomorrow?" answers.

This guide covers the Shortcuts layer. Everything here works once you've completed
first-run setup and fetched your schedule at least once.

---

## Step 1 — First-time setup (in the app)

1. Open **BATMAN Watcher** and finish the first-run sign-in (Sign in with Apple +
   claim your employee ID).
2. On the **Home** tab, tap the **gear** (top-right) → **App Settings**.
3. Enter your Employee ID and password, then tap **Save Password**.
4. Set your **alert lead time** (how many hours before a shift reminders fire). Default 2h.
5. Close Settings and **Fetch your schedule** (the download button on Home). The app
   logs in, parses your Expanded Schedule Report, and stores every shift.

> Re-run **Fetch** only when your schedule changes (a trade, a bid update, etc.).

---

## Step 2 — Talk to Siri (zero setup)

These phrases work as soon as your schedule is fetched — just ask Siri:

| Say to Siri… | What it does |
|---|---|
| "Fetch my schedule in BATMAN Watcher" | Logs in and refreshes your shifts |
| "Do I work tomorrow in BATMAN Watcher" | Reads tomorrow's shift (or "you're off") |
| "When should I wake up for work in BATMAN Watcher" | Tomorrow's alarm time (start − lead time) |
| "Turn on shift alerts in BATMAN Watcher" | Schedules a reminder before every upcoming shift |
| "Get my shifts from BATMAN Watcher" | Returns your upcoming shifts |
| "What changed in my schedule in BATMAN Watcher" | Lists added/removed shifts from the last fetch |
| "Who can trade with me in BATMAN Watcher" | Finds dispatchers available on a date |
| "Summarize my schedule in BATMAN Watcher" | On-device AI summary of your week *(iOS 27+)* |
| "Compose a trade broadcast in BATMAN Watcher" | AI-drafted trade message *(iOS 27+)* |

All of these also appear in the **Shortcuts** app under BATMAN Watcher, so you can drop
them into your own automations.

---

## Step 3 — Build the wake-up + calendar automation

This Shortcut turns every upcoming shift into a Calendar event and a Clock alarm.

Open the **Shortcuts** app → tap **+** → add these actions in order:

**1. Get My Shifts** (from BATMAN Watcher)
- Only upcoming shifts: **On**
- Include off days: **Off**
- Output is a list of shifts.

**2. Repeat with Each** — set **Items** to the *Shifts* output. Actions 3–4 go inside.

**3. Add New Event** (inside the loop) — tap each field, then the variable picker:
- **Title** → Repeat Item → **Title** (e.g. "DSP @ 29")
- **Start Date** → Repeat Item → **Start Date/Time**
- **End Date** → Repeat Item → **End Date/Time**
- **Calendar** → your work calendar (or the default Calendar)
- **Notes** *(optional)* → Repeat Item → **Role / Desk / Leave Code**

**4. Create Alarm** (inside the loop) — a real Clock alarm that rings even on silent:
- **Label** → Repeat Item → **Title**
- **Hour** → Repeat Item → **Alarm Hour** (already offset by your lead time)
- **Minute** → **0**
- **Date** → Repeat Item → **ISO Date**
- **Repeat** → **Never**

**5. Show Alert** *(optional, after the loop)* — "Calendar + alarms set."

Name it (e.g. **"Set Schedule Alarms"**), tap **Done**, then run it from Shortcuts,
your Home Screen, or "Hey Siri, Set Schedule Alarms."

---

## How the alarm time is computed

`Alarm Hour = shift start hour − lead time`
Example: shift starts 0500, lead time 2h → Alarm Hour = 3 → the alarm rings at 03:00.
You set the lead time once in Settings; the app pre-calculates **Alarm Hour** so the
Shortcut needs no math.

**Notification vs. Alarm:** the app's own reminders fire silently from Notification
Center; the Shortcut's **alarm** rings from the Clock app even in silent mode. You can
use either or both.

**Re-running:** the Shortcut doesn't de-dupe. If you run it twice you'll get duplicate
events/alarms — delete the old ones first, or add a "Remove Calendar Events" action
before the loop.

---

## Troubleshooting

- **"Sign in failed"** — re-enter your password in App Settings → Save Password.
- **No shifts returned** — fetch your schedule on Home first; Siri reads stored data.
- **AI phrases do nothing** — the two AI shortcuts need iOS 27+ (on-device models).
- **Wrong alarm time** — check the lead time in App Settings.
