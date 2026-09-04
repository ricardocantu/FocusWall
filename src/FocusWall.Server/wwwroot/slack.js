// slack.js — shared Slack panel renderer. Self-mounts by looking up
// #slack-panel/#slack-accounts at poll time (not as module-level consts),
// the same self-mounting contract usage.js already uses — a plain
// <script type="module"> tag on any page with the matching markup is
// enough, no explicit init call. Used by hero.html and mobile.html.
//
// Polls same-origin /slack/state (server calls Slack, not the browser). One
// labeled sub-block per configured account: presence + category unread rows
// + custom status. Config/Slack-derived text → textContent only. Panel
// hides entirely when no workspace is configured (self-disabled
// server-side).

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
  const slackPanel    = document.getElementById('slack-panel');
  const slackAccounts = document.getElementById('slack-accounts');
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

// Guard the browser bootstrap so this module is importable in Node without a
// document/fetch ReferenceError — matches usage.js's guard.
if (typeof document !== 'undefined') {
  refreshSlack();
  setInterval(refreshSlack, 30000);
}

export { slackCount };
