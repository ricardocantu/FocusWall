# Calendar agenda pane — turn-on checklist

The wall's calendar pane shows today's meetings from one or more calendars,
read via each provider's **secret iCal feed URL** — a plain HTTP GET, no
OAuth, no app registration. Read-only: if a URL leaks, someone can view the
calendar but cannot act as you. LAN-only, like every other integration here.

> Menu paths below can drift as Google/Outlook update their UI — if a step
> doesn't match what you see, search "[provider] secret ical url" for the
> current location.

## 1. Get each calendar's secret ICS URL

**Google Calendar:**
1. On the web, open **Settings** → click the calendar under "Settings for my
   calendars" in the left sidebar.
2. Scroll to **"Integrate calendar"** → copy **"Secret address in iCal
   format"**.

**Outlook / Microsoft 365:**
1. Open **Settings** → **Calendar** → **Shared calendars**.
2. Under **"Publish a calendar"**, pick the calendar and permission level →
   **Publish**.
3. Copy the **ICS** link (not the HTML link).

## 2. Add GitHub Actions secrets

Repo → Settings → Secrets and variables → Actions → **New repository secret**:

| Secret | Value |
|---|---|
| `CAL_SRC0_LABEL`   | A short name, e.g. `Work (Google)` |
| `CAL_SRC0_ICS_URL` | The secret ICS URL from step 1 |

For a second calendar, repeat with `CAL_SRC1_*`. Leave a slot's secrets unset
to disable it.

## 3. Set the wall's timezone

"Today" is computed in the container's timezone, and `docker-compose.yml` ships
`TZ: "Etc/UTC"`. Set `TZ` there to the wall's own zone (e.g. `America/New_York`
— the same knob the Discord/Echo quiet hours use), or the agenda window runs
from 7 pm to 7 pm local and tonight's meetings never appear.

## 4. Deploy + verify

- Push to `main` (or re-run the deploy workflow) so the Pi redeploys with the
  secrets. The ICS URL is never written to the log: `CalendarService` logs only
  the source label and the exception type, and `appsettings.json` silences the
  HTTP client's per-request URL logging.
- On the wall (`/wall` or `/hero`), the bottom band gains a fourth panel,
  **Today's meetings**, in its rotation (metrics ⇄ recent events ⇄ usage ⇄
  calendar), showing today's agenda merged across configured calendars. With
  no calendars configured the panel stays hidden and the rotation skips it.
- Sanity check from any LAN machine:
  `curl -s http://focus-wall.local:5050/calendar/state | jq .`
