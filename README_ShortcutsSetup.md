# BATMANReader — Shortcuts Setup Guide

Two-part workflow:
1. **BATMANReader** scrapes and stores your schedule, sends day-before notifications.
2. **Shortcuts** (built-in iOS app) reads the stored shifts and creates Calendar events and Clock alarms.

---

## Step 1 — First-time app setup

1. Open **BATMANReader** → tap the **gear icon** → Settings.
2. Enter your Employee ID and password. Tap **Save Password**.
3. Set your **lead time** (hours before shift the notification fires). Default is 2h.
4. Tap **Done**, then tap **Fetch** on the main screen.
5. The app logs in, navigates to your Expanded Schedule Report, parses all shifts,
   and schedules a day-before notification for each one.
6. You should see your upcoming shifts listed. That's the data Shortcuts will use.

**You only need to run Fetch again when your schedule changes** (trade, bid update, etc.).

---

## Step 2 — Build the Shortcuts automation

Open the **Shortcuts** app on your iPhone/iPad.

### Shortcut: "Add Schedule to Calendar + Set Alarms"

Tap **+** to create a new Shortcut. Add these actions in order:

---

**Action 1 — Get My Shifts**
- Tap **Add Action** → search "Get My Shifts"
- Select **Get My Shifts** (from BATMANReader)
- Parameters:
  - Only upcoming shifts: **On**
  - Include off days: **Off**
- This returns a list of ShiftEntity objects. The output variable is called "Shifts".

---

**Action 2 — Repeat with Each**
- Tap **Add Action** → search "Repeat with Each"
- Set **Items** to the **Shifts** output from Action 1
- Everything inside the repeat loop runs once per shift.

---

**Action 3 (inside loop) — Add New Event**
- Tap **Add Action** inside the loop → search "Add New Event"
- Fill in each field by tapping the field, then tapping the variable picker (the magic wand):
  - **Title** → pick **Repeat Item** → tap the arrow → select **Title**
    (shows as "DSP @ 29", "OJT", etc.)
  - **Start Date** → tap the field → tap **Repeat Item** → **ISO Date**
    (then in the date picker, set time: tap **Repeat Item** → **Start Time**)
  - **End Date** → same as Start Date but use **End Time**
  - **Calendar** → pick "Work" or create a new one called "AA Schedule"
  - **Notes** → optional: pick **Role**, **Desk**, **Leave Code**

---

**Action 4 (inside loop) — Create Alarm**
- Tap **Add Action** inside the loop → search "Create Alarm"
- This is the **built-in iOS Shortcuts alarm** — it creates a real Clock alarm.
- Fill in:
  - **Label** → pick **Repeat Item** → **Title**
  - **Hour** → pick **Repeat Item** → **Alarm Hour (pre-calculated)**
    (This is already offset by your lead time — just use it directly)
  - **Minute** → type **0**
  - **Date** → pick **Repeat Item** → **ISO Date**
  - **Repeat** → **Never** (each shift is unique)

---

**Action 5 (after loop) — Show Alert** *(optional)*
- Tap **Add Action** → search "Show Alert"
- Message: "Done! Calendar events and alarms created."

---

### Name and save the Shortcut
- Tap the name at the top, call it **"Set Schedule Alarms"**
- Tap **Done**

---

## Step 3 — Run it

- Tap **"Set Schedule Alarms"** in the Shortcuts app.
- Or add it to your Home Screen for one-tap access.
- Or say **"Hey Siri, Set Schedule Alarms"**.

It will loop through every upcoming shift and:
- Add a calendar event (0500–1400 or 1300–2200) titled "DSP @ 29" etc.
- Set a Clock alarm for your pre-calculated alarm hour on each shift day.

---

## Notes

**Alarm Hour explained:**
`Alarm Hour = Shift Start Hour − Lead Time (hours)`
Example: shift starts at 0500, lead time = 2h → Alarm Hour = 3 → alarm fires at 03:00.
You set the lead time once in the app. BATMANReader pre-calculates the alarm hour
so Shortcuts just needs to read the number — no math in Shortcuts needed.

**When to re-run:**
- After any trade or bid change: tap **Fetch** in the app, then run the Shortcut again.
- The Shortcut does not check for duplicates — if you run it twice you'll get duplicate events/alarms. Delete the old ones first, or add a "Delete Calendar Events" action before the loop.

**Notification vs Alarm:**
- **Notification** (from BATMANReader): fires from Notification Center, works silently.
- **Alarm** (from Shortcuts): fires from the Clock app, makes the full alarm sound, works even in silent mode.
Both are scheduled — you'll get both for each shift.

---

## Calibration checklist (first run)

- [ ] `reportURL` in `WebController.swift` updated to the real Expanded Schedule Report URL
- [ ] Login works (status reaches "Reading schedule data…")
- [ ] Shift count in the main list looks correct
- [ ] One test shift appears correctly in Calendar
- [ ] One test alarm appears in Clock
- [ ] Day-before notification fires (test by temporarily setting a shift 10 minutes out)
