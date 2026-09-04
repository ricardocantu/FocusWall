import { initKioskCursor, connectStream } from './sse.js';

const app          = document.getElementById('app');
const heroTitle    = document.getElementById('hero-title');
const heroDetail   = document.getElementById('hero-detail');
const heroSummary  = document.getElementById('hero-summary');
const heroSince    = document.getElementById('hero-since');
const clock        = document.getElementById('clock');
const logList      = document.getElementById('log-list');
const mSessions    = document.getElementById('m-sessions');
const mTools       = document.getElementById('m-tools');
const mEdits       = document.getElementById('m-edits');
const mLast        = document.getElementById('m-last');
const strip        = document.getElementById('sessions-strip');
const stripCards   = document.getElementById('strip-cards');

const STATUS_WORD = { idle: 'Idle', working: 'Working', waiting: 'Waiting', done: 'Done', error: 'Error' };

const ERROR_LABEL = {
  rate_limit: 'rate limited',
  overloaded: 'overloaded',
  authentication_failed: 'authentication failed',
  billing_error: 'billing issue',
  server_error: 'server error',
  invalid_request: 'invalid request',
  model_not_found: 'model not found',
  oauth_org_not_allowed: 'OAuth blocked for org',
  unknown: 'connection or unknown error',
};

initKioskCursor();

const state = {
  status: 'idle',
  statusSince: new Date(),
  sessionCount: 0,
  waitingCount: 0,
  workingCount: 0,
  errorCount: 0,
  loudestSession: null,   // SessionState of the loudest session, if any
  lastEventAt: null,
  toolCount: 0,
  editCount: 0,
  snoozedUntil: null,     // Date when snooze ends, or null. Overlay, not a status.
};

const STATUS_COPY = {
  idle:    { title: 'Idle',            detail: 'No active sessions' },
  working: { title: 'Working',         detail: 'Claude is doing its thing' },
  waiting: { title: 'Waiting for you', detail: 'Input needed' },
  done:    { title: 'Done',            detail: 'Turn complete · ready for review' },
  error:   { title: 'Error occurred',  detail: 'Something went wrong' },
};

let lastStatus = { value: 'idle', sessions: [] };

function applyStatus(s) {
  lastStatus = s;
  state.status        = s.value;
  state.statusSince   = new Date(s.since);
  state.sessionCount  = s.sessionCount ?? 0;
  state.waitingCount  = s.waitingCount ?? 0;
  state.workingCount  = s.workingCount ?? 0;
  state.errorCount    = s.errorCount ?? 0;

  const sessions = s.sessions || [];
  state.loudestSession = sessions.find(x => x.status === state.status) || null;

  // Snooze is an overlay: the real status/sessions stay honest, but while it's
  // active the hero shows "Snoozed (Nm left)" instead of the waiting pulse.
  const su = s.snoozedUntil ? new Date(s.snoozedUntil) : null;
  state.snoozedUntil = su && su > new Date() ? su : null;
  const snoozed = state.snoozedUntil !== null;

  app.dataset.status = snoozed ? 'snoozed' : state.status;
  const copy = STATUS_COPY[state.status] || STATUS_COPY.idle;
  heroTitle.textContent = snoozed ? 'Snoozed' : copy.title;

  // For "waiting", show the actual notification text (permission prompt vs
  // idle nudge) — the waiting session's last event is always the Notification.
  // For "error", show the human-readable reason — the errored session's last
  // event is always the StopFailure that put it there.
  let detail = copy.detail;
  if (state.status === 'waiting') {
    const msg = state.loudestSession?.lastEvent?.payload?.message;
    if (msg) detail = msg;
  } else if (state.status === 'error') {
    const slug = state.loudestSession?.lastEvent?.payload?.error;
    if (slug) detail = ERROR_LABEL[slug] || slug;
  }

  // Prefer cwd of loudest session (e.g., "my-project") for the detail line
  const cwd = state.loudestSession?.cwd;
  // While snoozed the detail is the countdown (kept fresh by tickClocks); paint
  // it now so there's no blank frame before the first tick.
  heroDetail.textContent = snoozed ? snoozeLeftText() : (cwd ? `${detail} · ${cwd}` : detail);

  // Fleet summary line
  if (state.sessionCount === 0) {
    heroSummary.textContent = '';
  } else {
    const parts = [];
    if (state.waitingCount) parts.push(`${state.waitingCount} waiting`);
    if (state.workingCount) parts.push(`${state.workingCount} working`);
    if (state.errorCount) parts.push(`${state.errorCount} error`);
    const others = state.sessionCount - state.waitingCount - state.workingCount - state.errorCount;
    if (others > 0) parts.push(`${others} idle/done`);
    heroSummary.textContent = parts.join(' · ') + ` (${state.sessionCount} total)`;
  }

  mSessions.textContent = state.sessionCount;

  renderStrip(sessions, state.loudestSession);
}

function snoozeLeftText() {
  if (!state.snoozedUntil) return '';
  const left = Math.floor((state.snoozedUntil - Date.now()) / 1000);
  const m = Math.floor(left / 60);
  return m >= 1 ? `${m}m left` : `${Math.max(left, 0)}s left`;
}

function fmtSince(iso) {
  const secs = Math.floor((Date.now() - new Date(iso)) / 1000);
  if (secs < 60) return `${secs}s`;
  const m = Math.floor(secs / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

// Compact cards for every session the hero isn't already featuring. Same
// per-session payload the grid uses; ordered loudest-first by the server.
// Cards are built with textContent — payload fields (cwd, hostname) are
// writable by anyone on the LAN via POST /events. Strip collapses to nothing
// (row removed) when there are no other sessions, so the lone-hero view is
// unchanged.
function renderStrip(sessions, loudest) {
  const others = sessions.filter(x => x !== loudest);
  stripCards.replaceChildren();

  if (others.length === 0) {
    strip.hidden = true;
    return;
  }

  for (const s of others) {
    const card = document.createElement('div');
    card.className = 'mini';
    card.dataset.status = s.status;

    const statusRow = document.createElement('div');
    statusRow.className = 'mini-status';
    const dot = document.createElement('span');
    dot.className = 'dot';
    const word = document.createElement('span');
    word.className = 'word';
    word.textContent = STATUS_WORD[s.status] || s.status;
    statusRow.append(dot, word);

    const project = document.createElement('div');
    project.className = 'mini-project';
    project.textContent = s.cwd || '—';

    const foot = document.createElement('div');
    foot.className = 'mini-foot';
    const host = document.createElement('span');
    host.className = 'mini-host';
    host.textContent = (s.key?.hostname || 'unknown').split('.')[0];
    const time = document.createElement('span');
    time.className = 'mini-time';
    time.dataset.since = s.statusSince;
    time.textContent = fmtSince(s.statusSince);
    foot.append(host, time);

    card.append(statusRow, project, foot);
    stripCards.appendChild(card);
  }

  strip.hidden = false;
}

function deriveDetail(ev) {
  if (!ev) return null;
  const p = ev.payload;
  const name = p.hook_event_name;
  if (name === 'Notification' && p.message) return p.message;
  if ((name === 'PreToolUse' || name === 'PostToolUse') && p.tool_name) {
    const fp = p.tool_input?.file_path;
    return fp ? `${p.tool_name} · ${fp}` : p.tool_name;
  }
  return name;
}

function badgeFor(ev) {
  const key = ev.sessionKey;
  if (!key) return '—';
  const host = (key.hostname || 'unknown').split('.')[0].slice(0, 10);
  const sid = (key.sessionId || 'unknown').slice(-4);
  return `${host}/${sid}`;
}

function addEvent(ev) {
  const p = ev.payload;
  const at = new Date(ev.receivedAt);
  const name = p.hook_event_name || 'unknown';

  state.lastEventAt = at;
  if (name === 'PreToolUse') state.toolCount++;
  if (name === 'PreToolUse' && (p.tool_name === 'Edit' || p.tool_name === 'Write')) state.editCount++;

  // Rows are built with textContent, never innerHTML — payload fields
  // (notification messages, file paths) are writable by anyone on the LAN
  // via POST /events and must not be able to inject markup into the kiosk.
  const li = document.createElement('li');
  li.dataset.kind = name;
  const badge = badgeFor(ev);
  for (const [cls, text] of [
    ['time', at.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', hour12: true })],
    ['dot', ''],
    ['badge', badge],
    ['type', name],
    ['detail', deriveDetail(ev) || ''],
  ]) {
    const span = document.createElement('span');
    span.className = cls;
    span.textContent = text;
    if (cls === 'badge') span.title = badge;
    li.appendChild(span);
  }
  logList.prepend(li);
  while (logList.children.length > 50) logList.lastElementChild.remove();

  mTools.textContent = state.toolCount;
  mEdits.textContent = state.editCount;
}

function tickClocks() {
  const now = new Date();
  clock.textContent = now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', hour12: true });

  if (state.lastEventAt) {
    const secs = Math.floor((now - state.lastEventAt) / 1000);
    mLast.textContent = secs < 60 ? `${secs}s` : `${Math.floor(secs / 60)}m`;
  }

  // Snooze countdown self-corrects locally: when it lapses, drop the overlay
  // even before the server's next heartbeat rebroadcast catches up.
  if (state.snoozedUntil) {
    const left = Math.floor((state.snoozedUntil - now) / 1000);
    if (left <= 0) {
      // Re-derive the hero from the real status (server rebroadcast will follow).
      state.snoozedUntil = null;
      applyStatus(lastStatus);
    } else {
      heroDetail.textContent = snoozeLeftText();
    }
  }

  if (state.status === 'waiting' || state.status === 'done') {
    const secs = Math.floor((now - state.statusSince) / 1000);
    heroSince.textContent = secs < 60 ? `${secs}s` : `${Math.floor(secs / 60)}m ${secs % 60}s`;
  } else {
    heroSince.textContent = '';
  }

  for (const el of stripCards.querySelectorAll('.mini-time')) {
    el.textContent = fmtSince(el.dataset.since);
  }
}
setInterval(tickClocks, 1000);

// Other-sessions strip stays a single row (app.css: flex-wrap: nowrap +
// overflow: hidden) instead of wrapping to a second line — once the cards
// overflow the row's width, slowly ping-pong scrollLeft back and forth so
// every card is still readable from across the room. Runs as one persistent
// rAF loop (not re-armed per renderStrip call) so it survives cards being
// replaced on every status update.
const stripScroll = { dir: 1, pauseUntil: 0, last: null };
const STRIP_SCROLL_SPEED = 40; // px/s — deliberately slow, this is a wall display
const STRIP_SCROLL_PAUSE_MS = 1200;

function tickStripScroll(now) {
  requestAnimationFrame(tickStripScroll);
  if (strip.hidden) return;

  const maxScroll = stripCards.scrollWidth - stripCards.clientWidth;
  if (maxScroll <= 0) {
    stripCards.scrollLeft = 0;
    stripScroll.last = null;
    return;
  }
  if (now < stripScroll.pauseUntil) return;
  if (stripScroll.last == null) { stripScroll.last = now; return; }

  const dt = now - stripScroll.last;
  stripScroll.last = now;

  let next = stripCards.scrollLeft + stripScroll.dir * STRIP_SCROLL_SPEED * dt / 1000;
  if (next >= maxScroll) {
    next = maxScroll;
    stripScroll.dir = -1;
    stripScroll.pauseUntil = now + STRIP_SCROLL_PAUSE_MS;
  } else if (next <= 0) {
    next = 0;
    stripScroll.dir = 1;
    stripScroll.pauseUntil = now + STRIP_SCROLL_PAUSE_MS;
  }
  stripCards.scrollLeft = next;
}
requestAnimationFrame(tickStripScroll);

// The server replays its ring buffer on every (re)connect — and EventSource
// reconnects on any blip (Wi-Fi hiccup, nightly Chromium restart, container
// redeploy). Start from a clean slate each time so replayed events don't
// duplicate log rows or double-count the metrics.
function resetLog() {
  logList.replaceChildren();
  state.toolCount = 0;
  state.editCount = 0;
  mTools.textContent = '0';
  mEdits.textContent = '0';
}

connectStream({
  onOpen: resetLog,
  onStatus: applyStatus,
  onEvent: addEvent,
});

// ── Bottom-band crossfade ────────────────────────────────────────────────────
// Rotates metrics → recent events → usage → calendar in place. The usage panel
// is fed by usage.js and the calendar panel by calendar.js (each refreshes its
// own content independently). ?rotate=<secs> overrides.
//
// #panel-calendar can be legitimately hidden (no Calendar:Sources configured),
// toggled dynamically by calendar.js after this array is already snapshotted —
// skip hidden panels each tick so the rotation never lands on one and blanks
// that slot (CSS `[hidden]` forces display:none regardless of `.active`).
const bandPanels = [...document.querySelectorAll('.band-panel')];
if (bandPanels.length > 1) {
  const bandSecs = parseInt(new URLSearchParams(location.search).get('rotate'), 10) || 15;
  let bandIdx = 0;
  setInterval(() => {
    if (bandPanels.filter(p => !p.hidden).length < 2) return; // nothing to rotate to
    bandPanels[bandIdx].classList.remove('active');
    do {
      bandIdx = (bandIdx + 1) % bandPanels.length;
    } while (bandPanels[bandIdx].hidden);
    bandPanels[bandIdx].classList.add('active');
  }, bandSecs * 1000);
}
