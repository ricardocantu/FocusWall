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
  snoozedUntil: null,     // Date when snooze ends, or null. Overlay, not a status.
};

const STATUS_COPY = {
  idle:    { title: 'Idle',            detail: 'No active sessions' },
  working: { title: 'Working',         detail: 'Claude is doing its thing' },
  waiting: { title: 'Waiting for you', detail: 'Input needed' },
  done:    { title: 'Done',            detail: 'Turn complete · ready for review' },
};

let lastStatus = { value: 'idle', sessions: [] };

function applyStatus(s) {
  lastStatus = s;
  state.status        = s.value;
  state.statusSince   = new Date(s.since);
  state.sessionCount  = s.sessionCount ?? 0;
  state.waitingCount  = s.waitingCount ?? 0;
  state.workingCount  = s.workingCount ?? 0;

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
  let detail = copy.detail;
  if (state.status === 'waiting') {
    const msg = state.loudestSession?.lastEvent?.payload?.message;
    if (msg) detail = msg;
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
    const others = state.sessionCount - state.waitingCount - state.workingCount;
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

// ── Slack panel ──────────────────────────────────────────────────────────────
// Polls same-origin /slack/state (server calls Slack, not the browser). One
// labeled sub-block per configured account: presence + category unread rows +
// custom status. Config/Slack-derived text → textContent only. Panel hides
// entirely when no workspace is configured (self-disabled server-side).
const slackPanel    = document.getElementById('slack-panel');
const slackAccounts = document.getElementById('slack-accounts');

const PRESENCE = {
  active: { cls: 'active', label: 'Active' },
  away:   { cls: 'away',   label: 'Away' },
};

function slackCount(n) { return n > 0 ? String(n) : '—'; }

function slackBlock(w) {
  const block = document.createElement('div');
  block.className = 'slack-block';

  const head = document.createElement('div');
  head.className = 'slack-head';
  const label = document.createElement('span');
  label.className = 'slack-label';
  label.textContent = w.label || 'Slack';
  const pres = document.createElement('span');
  pres.className = 'slack-presence';
  if (w.error) {
    pres.textContent = 'reconnect';
    pres.classList.add('warn');
  } else if (PRESENCE[w.presence]) {
    pres.textContent = PRESENCE[w.presence].label;
    pres.classList.add(PRESENCE[w.presence].cls);
  }
  head.append(label, pres);
  block.append(head);

  if (w.error) return block;   // counts are 0/unknown on error — show only the header

  const rows = document.createElement('div');
  rows.className = 'slack-rows';
  for (const [name, val] of [
    ['Mentions', w.channelMentions],
    ['Channels', w.channelsUnread],
    ['DMs',      w.dmMentions],
    ['Threads',  w.threadsUnread],
  ]) {
    const row = document.createElement('div');
    row.className = 'slack-row' + (val > 0 ? ' has' : '');
    const n = document.createElement('span');
    n.className = 'slack-row-name';
    n.textContent = name;
    const c = document.createElement('span');
    c.className = 'slack-row-count';
    c.textContent = slackCount(val);
    row.append(n, c);
    rows.append(row);
  }
  block.append(rows);

  if (w.statusText) {
    const st = document.createElement('div');
    st.className = 'slack-status';
    st.textContent = w.statusText;
    block.append(st);
  }
  return block;
}

function renderSlack(data) {
  const ws = data?.workspaces || [];
  if (ws.length === 0) { slackPanel.hidden = true; return; }
  slackPanel.hidden = false;
  // Pulse the whole panel (like the waiting hero) when something is directed at
  // you — mentions + unread DMs, the server's totalMentions aggregate.
  slackPanel.classList.toggle('alert', (data.totalMentions || 0) > 0);
  slackAccounts.replaceChildren();
  for (const w of ws) slackAccounts.append(slackBlock(w));
}

async function refreshSlack() {
  try {
    const res = await fetch('/slack/state');
    if (!res.ok) throw new Error(String(res.status));
    renderSlack(await res.json());
  } catch { /* keep last render on transient failure */ }
}
refreshSlack();
setInterval(refreshSlack, 30000);

// ── Bottom-band crossfade ────────────────────────────────────────────────────
// Rotates metrics → recent events → usage in place. The usage panel is fed by
// usage.js (it refreshes #usage-accounts on its own). ?rotate=<secs> overrides.
const bandPanels = [...document.querySelectorAll('.band-panel')];
if (bandPanels.length > 1) {
  const bandSecs = parseInt(new URLSearchParams(location.search).get('rotate'), 10) || 15;
  let bandIdx = 0;
  setInterval(() => {
    bandPanels[bandIdx].classList.remove('active');
    bandIdx = (bandIdx + 1) % bandPanels.length;
    bandPanels[bandIdx].classList.add('active');
  }, bandSecs * 1000);
}
