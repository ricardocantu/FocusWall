import { initKioskCursor, connectStream } from './sse.js';

initKioskCursor();

const gridEl = document.getElementById('grid');
const clock  = document.getElementById('clock');

const STATUS_WORD = { idle: 'Idle', working: 'Working', waiting: 'Waiting', done: 'Done', error: 'Error' };

// Maps the StopFailure hook's short error slug to a human-readable reason.
// Falls back to the raw slug for any future value Claude Code adds that isn't
// in this list yet, so the card never shows a blank/undefined reason.
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
const activity = new Map();   // "host/sid" -> array of last 3 tool activities (live)
const prompts  = new Map();   // "host/sid" -> last truncated prompt (live)

// Ring of the last 3 tool activities per session, de-duping consecutive repeats
// so a burst of the same tool doesn't fill the trail.
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

// Mirror the hero's event→detail derivation for tool events, so a working
// card shows e.g. "Edit · app.js" or the bare event name.
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

// Rows/cards are built with textContent, never innerHTML — payload fields
// (message, cwd) are writable by anyone on the LAN via POST /events.
function render() {
  gridEl.replaceChildren();

  if (sessions.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'grid-empty';
    empty.textContent = 'No active sessions';
    gridEl.appendChild(empty);
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

    // Meta row: host, and the git branch when the wrapper supplied one.
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

    // "Working on" label — the truncated triggering prompt. Shown on working
    // and waiting cards (for a blocked session, this is what it was doing when
    // it stopped for you). Comes from the event stream, so it may be absent
    // until the first UserPromptSubmit arrives.
    if (s.status === 'working' || s.status === 'waiting' || s.status === 'error') {
      const wo = prompts.get(keyOf(s.key));
      if (wo) {
        const w = document.createElement('div');
        w.className = 'card-working-on';
        w.textContent = wo;
        card.appendChild(w);
      }
    }

    // Activity breadcrumb — last 3 tools (Read → Edit → Bash). Working cards
    // only. Updated in place by onEvent between snapshots.
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

    // Session age — total time since first event for this session, distinct
    // from time-in-status above. Subtle secondary line.
    if (s.startedAt) {
      const age = document.createElement('div');
      age.className = 'card-age';
      age.dataset.since = s.startedAt;
      age.textContent = `session ${fmtSince(s.startedAt)}`;
      card.appendChild(age);
    }

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

    gridEl.appendChild(card);
  }
}

function tick() {
  clock.textContent = new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', hour12: true });
  for (const el of gridEl.querySelectorAll('.card-time')) {
    el.textContent = fmtSince(el.dataset.since);
  }
  for (const el of gridEl.querySelectorAll('.card-age')) {
    el.textContent = `session ${fmtSince(el.dataset.since)}`;
  }
}
setInterval(tick, 1000);

// Cards + ordering come from the status snapshot (loudest-first from the
// server). The activity line comes from the event stream: status snapshots are
// coalesced (only broadcast on a session transition), so a working session's
// current tool would otherwise never refresh. We update the matching card's
// activity node in place — no full re-render, so the waiting pulse stays smooth.
function onEvent(ev) {
  const k = keyOf(ev.sessionKey);
  const p = ev.payload || {};

  // Truncated prompt → working-on label. Update in place; render() picks it up
  // on the next status snapshot too.
  if (p.hook_event_name === 'UserPromptSubmit' && typeof p.prompt === 'string' && p.prompt) {
    prompts.set(k, p.prompt);
    const wel = gridEl.querySelector(
      `.card[data-key="${CSS.escape(k)}"] .card-working-on`);
    if (wel) wel.textContent = p.prompt;
  }

  // Only tool events feed the breadcrumb, so the trail stays clean.
  if (p.hook_event_name === 'PreToolUse' || p.hook_event_name === 'PostToolUse') {
    const act = deriveActivity(ev);
    if (act) {
      pushActivity(k, act);
      const el = gridEl.querySelector(
        `.card[data-status="working"][data-key="${CSS.escape(k)}"] .card-activity`);
      if (el) el.textContent = activity.get(k).join(' → ');
    }
  }
}

connectStream({
  // SSE replays the ring buffer on every (re)connect, so reset the live maps
  // on open — same reason the hero resets its log/counters — otherwise a
  // reconnect re-pushes replayed tool events onto stale breadcrumb state.
  onOpen: () => { activity.clear(); prompts.clear(); },
  onStatus: (s) => { sessions = s.sessions || []; render(); },
  onEvent,
});
