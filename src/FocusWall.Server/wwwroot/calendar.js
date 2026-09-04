// #panel-calendar — polls /calendar/state and renders today's merged agenda
// across all configured calendars. All feed content is attacker-influenced
// (it's whatever the configured ICS URL returns) → textContent only, never
// innerHTML, matching the RSS ticker and Slack panel convention.

function fmtTime(iso, allDay) {
  if (allDay) return 'All day';
  return new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', hour12: true });
}

function eventRow(ev) {
  const li = document.createElement('li');
  li.className = 'calendar-row' + (ev.allDay ? ' all-day' : '');

  const time = document.createElement('span');
  time.className = 'cal-time';
  time.textContent = fmtTime(ev.start, ev.allDay);

  const title = document.createElement('span');
  title.className = 'cal-title';
  title.textContent = ev.title;

  const source = document.createElement('span');
  source.className = 'cal-source';
  source.textContent = ev.source;

  li.append(time, title, source);
  return li;
}

function errorRow(label) {
  const li = document.createElement('li');
  li.className = 'calendar-row error';
  li.textContent = `⚠ ${label} unavailable`;
  return li;
}

function emptyRow() {
  const li = document.createElement('li');
  li.className = 'calendar-row empty';
  li.textContent = 'No meetings today.';
  return li;
}

async function refresh() {
  const panel = document.getElementById('panel-calendar');
  const list = document.getElementById('calendar-agenda');
  if (!panel || !list) return;

  try {
    const res = await fetch('/calendar/state');
    if (!res.ok) throw new Error(String(res.status));
    const { sources } = await res.json();

    if (!sources || sources.length === 0) {
      panel.hidden = true;
      return;
    }
    panel.hidden = false;

    const now = Date.now();
    const errors = sources.filter(s => s.error).map(s => s.label);
    const events = [];
    for (const src of sources) {
      for (const ev of src.events || []) {
        if (new Date(ev.end).getTime() <= now) continue; // already ended — only "now and later" is useful on a wall
        events.push({ ...ev, source: src.label });
      }
    }
    events.sort((a, b) => (Number(b.allDay) - Number(a.allDay)) || (new Date(a.start) - new Date(b.start)));

    list.replaceChildren();
    for (const label of errors) list.appendChild(errorRow(label));
    if (events.length === 0 && errors.length === 0) list.appendChild(emptyRow());
    else for (const ev of events) list.appendChild(eventRow(ev));
  } catch {
    /* keep last render on transient failure */
  }
}

// Guard the browser bootstrap so this module is importable in Node without a
// document/fetch ReferenceError (matches usage.js's convention).
if (typeof document !== 'undefined') {
  refresh();
  setInterval(refresh, 60000);
}

export { fmtTime };
