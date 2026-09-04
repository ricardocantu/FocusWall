import { connectStream } from './sse.js';

// Phone companion view. Reuses the shared SSE module (connect/reconnect/watchdog)
// and the grid's .card markup, adding a sticky "loudest status" banner up top.
// Not a kiosk — no cursor hiding. The small helpers below (keyOf, deriveActivity,
// fmtSince, pushActivity) are intentionally duplicated from grid.js rather than
// refactored into a shared lib, to leave the load-bearing grid untouched.

const listEl    = document.getElementById('list');
const summaryEl = document.getElementById('summary');
const wordEl    = document.getElementById('summary-word');
const subEl     = document.getElementById('summary-sub');
const snoozeEl  = document.getElementById('snooze');
const clearBtn  = snoozeEl.querySelector('.m-snooze-clear');

let snoozedUntil = null;   // Date when snooze ends, or null. Overlay, not a status.

const STATUS_WORD  = { idle: 'Idle', working: 'Working', waiting: 'Waiting', done: 'Done', error: 'Error' };
const SUMMARY_WORD = { idle: 'All idle', working: 'Working', waiting: 'Waiting for you', done: 'Done', error: 'Error occurred' };

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

let sessions = [];
let lastStatus = { value: 'idle', sessions: [] };   // last status payload, for local snooze re-render
const activity = new Map();   // "host/sid" -> array of last 3 tool activities (live)
const prompts  = new Map();   // "host/sid" -> last truncated prompt (live)

function pushActivity(k, act) {
  const ring = activity.get(k) || [];
  if (ring[ring.length - 1] === act) return;
  ring.push(act);
  while (ring.length > 3) ring.shift();
  activity.set(k, ring);
}

function keyOf(sk) {
  return `${sk?.hostname || 'unknown'}/${sk?.sessionId || 'unknown'}`;
}

function deriveActivity(ev) {
  if (!ev) return null;
  const p = ev.payload || {};
  const name = p.hook_event_name;
  if ((name === 'PreToolUse' || name === 'PostToolUse') && p.tool_name) {
    const fp = p.tool_input?.file_path;
    return fp ? `${p.tool_name} · ${fp}` : p.tool_name;
  }
  return name || null;
}

function fmtSince(sinceIso) {
  const secs = Math.floor((Date.now() - new Date(sinceIso)) / 1000);
  if (secs < 60) return `${secs}s`;
  const m = Math.floor(secs / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

// Banner: loudest status + a compact count line. Both come from the same status
// payload the server already orders loudest-first, so they can't desync.
function renderSummary(s) {
  const value = s.value || 'idle';

  // Snooze is an overlay: sessions/counts stay honest below, but the banner
  // reads "Snoozed (Nm left)" instead of the waiting pulse while it's active.
  const su = s.snoozedUntil ? new Date(s.snoozedUntil) : null;
  snoozedUntil = su && su > new Date() ? su : null;
  clearBtn.hidden = snoozedUntil === null;

  if (snoozedUntil) {
    summaryEl.dataset.status = 'snoozed';
    wordEl.textContent = 'Snoozed';
    renderSnoozeSub();
    return;
  }

  summaryEl.dataset.status = value;
  wordEl.textContent = SUMMARY_WORD[value] || value;

  const total = s.sessionCount || 0;
  if (total === 0) { subEl.textContent = 'No active sessions'; return; }
  const parts = [];
  if (s.waitingCount) parts.push(`${s.waitingCount} waiting`);
  if (s.workingCount) parts.push(`${s.workingCount} working`);
  if (s.errorCount) parts.push(`${s.errorCount} error`);
  parts.push(`${total} session${total === 1 ? '' : 's'}`);
  subEl.textContent = parts.join(' · ');
}

function renderSnoozeSub() {
  if (!snoozedUntil) return;
  const left = Math.floor((snoozedUntil - Date.now()) / 1000);
  const m = Math.floor(left / 60);
  subEl.textContent = m >= 1 ? `${m}m left` : `${Math.max(left, 0)}s left`;
}

async function snooze(minutes) {
  try {
    await fetch(`/snooze?minutes=${minutes}`, { method: 'POST' });
    // No optimistic UI: the server broadcasts the new status back over SSE.
  } catch { /* fire-and-forget; SSE will reconcile on the next status */ }
}

snoozeEl.addEventListener('click', (e) => {
  const btn = e.target.closest('.m-snooze-btn');
  if (btn) snooze(Number(btn.dataset.minutes));
});

// Manual per-session close (idle/waiting/error only) — mirrors snooze's
// fire-and-forget pattern: no optimistic removal, the card disappears when
// SSE delivers the resulting status broadcast.
async function closeSession(hostname, sessionId) {
  try {
    const q = new URLSearchParams({ hostname, sessionId });
    await fetch(`/sessions/close?${q}`, { method: 'POST' });
  } catch { /* fire-and-forget; SSE will reconcile on the next status */ }
}

listEl.addEventListener('click', (e) => {
  const btn = e.target.closest('.card-close');
  if (btn) closeSession(btn.dataset.hostname, btn.dataset.sessionId);
});

// Cards built with textContent, never innerHTML — payload fields (message, cwd)
// are writable by anyone on the LAN via POST /events.
function renderList() {
  listEl.replaceChildren();

  if (sessions.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'grid-empty';
    empty.textContent = 'No active sessions';
    listEl.appendChild(empty);
    return;
  }

  for (const s of sessions) {
    const card = document.createElement('div');
    card.className = 'card';
    card.dataset.status = s.status;
    card.dataset.key = keyOf(s.key);

    const statusRow = document.createElement('div');
    statusRow.className = 'card-status';
    const dot = document.createElement('span');
    dot.className = 'dot';
    const word = document.createElement('span');
    word.className = 'status-word';
    word.textContent = STATUS_WORD[s.status] || s.status;
    statusRow.append(dot, word);
    card.appendChild(statusRow);

    const project = document.createElement('div');
    project.className = 'card-project';
    project.textContent = s.cwd || '—';
    card.appendChild(project);

    const meta = document.createElement('div');
    meta.className = 'card-meta';
    const host = document.createElement('span');
    host.className = 'card-host';
    host.textContent = s.key?.hostname || 'unknown';
    meta.appendChild(host);
    if (s.branch) {
      const br = document.createElement('span');
      br.className = 'card-branch';
      br.textContent = s.branch;
      meta.appendChild(br);
    }
    card.appendChild(meta);

    if (s.status === 'working' || s.status === 'waiting' || s.status === 'error') {
      const wo = prompts.get(keyOf(s.key));
      if (wo) {
        const w = document.createElement('div');
        w.className = 'card-working-on';
        w.textContent = wo;
        card.appendChild(w);
      }
    }

    if (s.status === 'working') {
      const ring = activity.get(keyOf(s.key));
      const text = ring && ring.length ? ring.join(' → ') : (deriveActivity(s.lastEvent) || '…');
      const a = document.createElement('div');
      a.className = 'card-activity';
      a.textContent = text;
      card.appendChild(a);
    }

    const time = document.createElement('div');
    time.className = 'card-time';
    time.dataset.since = s.statusSince;
    time.textContent = fmtSince(s.statusSince);
    card.appendChild(time);

    if (s.status === 'waiting') {
      const msg = s.lastEvent?.payload?.message;
      if (msg) {
        const m = document.createElement('div');
        m.className = 'card-msg';
        m.textContent = msg;
        card.appendChild(m);
      }
    }

    if (s.status === 'error') {
      const slug = s.lastEvent?.payload?.error;
      const m = document.createElement('div');
      m.className = 'card-msg';
      m.textContent = slug ? `Error occurred · ${ERROR_LABEL[slug] || slug}` : 'Error occurred';
      card.appendChild(m);
    }

    if (s.status === 'idle' || s.status === 'waiting' || s.status === 'error') {
      const close = document.createElement('button');
      close.type = 'button';
      close.className = 'card-close';
      close.dataset.hostname = s.key?.hostname || '';
      close.dataset.sessionId = s.key?.sessionId || '';
      close.textContent = 'Close';
      card.appendChild(close);
    }

    listEl.appendChild(card);
  }
}

function tick() {
  for (const el of listEl.querySelectorAll('.card-time')) {
    el.textContent = fmtSince(el.dataset.since);
  }
  // Snooze countdown self-corrects locally when it lapses, before the server's
  // next heartbeat rebroadcast catches up.
  if (snoozedUntil) {
    if (snoozedUntil - Date.now() <= 0) { snoozedUntil = null; renderSummary(lastStatus); }
    else renderSnoozeSub();
  }
}
setInterval(tick, 1000);

// Activity breadcrumb + working-on come from the event stream (status snapshots
// are coalesced), updated in place so a re-render doesn't interrupt the pulse.
function onEvent(ev) {
  const k = keyOf(ev.sessionKey);
  const p = ev.payload || {};

  if (p.hook_event_name === 'UserPromptSubmit' && typeof p.prompt === 'string' && p.prompt) {
    prompts.set(k, p.prompt);
    const wel = listEl.querySelector(
      `.card[data-key="${CSS.escape(k)}"] .card-working-on`);
    if (wel) wel.textContent = p.prompt;
  }

  if (p.hook_event_name === 'PreToolUse' || p.hook_event_name === 'PostToolUse') {
    const act = deriveActivity(ev);
    if (act) {
      pushActivity(k, act);
      const el = listEl.querySelector(
        `.card[data-status="working"][data-key="${CSS.escape(k)}"] .card-activity`);
      if (el) el.textContent = activity.get(k).join(' → ');
    }
  }
}

connectStream({
  // SSE replays the ring buffer on every (re)connect, so reset the live maps on
  // open — otherwise a reconnect re-pushes replayed tool events onto stale state.
  onOpen: () => { activity.clear(); prompts.clear(); },
  onStatus: (s) => { lastStatus = s; sessions = s.sessions || []; renderSummary(s); renderList(); },
  onEvent,
});
