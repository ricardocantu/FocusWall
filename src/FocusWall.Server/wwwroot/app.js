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

const STATUS_WORD = { idle: 'Idle', working: 'Working', waiting: 'Waiting', done: 'Done' };

initKioskCursor();

const state = {
  status: 'idle',
  statusSince: new Date(),
  sessionCount: 0,
  waitingCount: 0,
  workingCount: 0,
  loudestSession: null,   // SessionState of the loudest session, if any
  lastEventAt: null,
  toolCount: 0,
  editCount: 0,
};

const STATUS_COPY = {
  idle:    { title: 'Idle',            detail: 'No active sessions' },
  working: { title: 'Working',         detail: 'Claude is doing its thing' },
  waiting: { title: 'Waiting for you', detail: 'Input needed' },
  done:    { title: 'Done',            detail: 'Turn complete · ready for review' },
};

function applyStatus(s) {
  state.status        = s.value;
  state.statusSince   = new Date(s.since);
  state.sessionCount  = s.sessionCount ?? 0;
  state.waitingCount  = s.waitingCount ?? 0;
  state.workingCount  = s.workingCount ?? 0;

  const sessions = s.sessions || [];
  state.loudestSession = sessions.find(x => x.status === state.status) || null;

  app.dataset.status = state.status;
  const copy = STATUS_COPY[state.status] || STATUS_COPY.idle;
  heroTitle.textContent = copy.title;

  // For "waiting", show the actual notification text (permission prompt vs
  // idle nudge) — the waiting session's last event is always the Notification.
  let detail = copy.detail;
  if (state.status === 'waiting') {
    const msg = state.loudestSession?.lastEvent?.payload?.message;
    if (msg) detail = msg;
  }

  // Prefer cwd of loudest session (e.g., "my-project") for the detail line
  const cwd = state.loudestSession?.cwd;
  heroDetail.textContent = cwd ? `${detail} · ${cwd}` : detail;

  // Fleet summary line
  if (state.sessionCount === 0) {
    heroSummary.textContent = '';
  } else {
    const parts = [];
    if (state.waitingCount) parts.push(`${state.waitingCount} waiting`);
    if (state.workingCount) parts.push(`${state.workingCount} working`);
    const others = state.sessionCount - state.waitingCount - state.workingCount;
    if (others > 0) parts.push(`${others} idle/done`);
    heroSummary.textContent = parts.join(' · ') + ` (${state.sessionCount} total)`;
  }

  mSessions.textContent = state.sessionCount;

  renderStrip(sessions, state.loudestSession);
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
    app.classList.remove('has-strip');
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
  app.classList.add('has-strip');
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
    ['time', at.toLocaleTimeString([], { hour12: false })],
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
  clock.textContent = now.toLocaleTimeString([], { hour12: false });

  if (state.lastEventAt) {
    const secs = Math.floor((now - state.lastEventAt) / 1000);
    mLast.textContent = secs < 60 ? `${secs}s` : `${Math.floor(secs / 60)}m`;
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
