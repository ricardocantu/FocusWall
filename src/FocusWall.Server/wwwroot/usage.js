// /usage — polls /usage/state and renders one card of limit gauges per account.
// All report fields are attacker-controlled (POST /usage/report is unauth) →
// build every node with textContent, never innerHTML.

const SEV_COLOR = { normal: '#1D9E75', warning: '#BA7517', critical: '#C0392B' };

function sevColor(sev) { return SEV_COLOR[sev] || '#888780'; }

function fmtResets(iso, now = Date.now()) {
  if (!iso) return '';
  const t = new Date(iso).getTime();
  if (isNaN(t)) return '';
  const ms = t - now;
  if (ms <= 0) return 'resetting…';
  const mins = Math.round(ms / 60000);
  if (mins < 60) return `resets in ${mins}m`;
  // Beyond an hour, an absolute clock time reads better than "123h".
  const d = new Date(t);
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', hour12: true });
  if (d.toDateString() === new Date(now).toDateString()) return `resets at ${time}`;
  const day = d.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
  return `resets ${day}, ${time}`;
}

function limitLabel(lim) {
  const base = lim.group === 'session' ? 'Session'
    : lim.kind === 'weekly_all' ? 'Weekly'
    : lim.group === 'weekly' ? 'Weekly'
    : lim.kind || 'Limit';
  return lim.model ? `${base} · ${lim.model}` : base;
}

function gauge(lim) {
  const wrap = document.createElement('div');
  wrap.className = 'usage-gauge ' + (lim.severity || 'normal') + (lim.is_active ? ' active' : '');

  const label = document.createElement('div');
  label.className = 'usage-gauge-label';
  const name = document.createElement('span');
  name.textContent = limitLabel(lim);
  const pct = document.createElement('span');
  pct.textContent = `${Math.round(lim.percent)}%`;
  label.append(name, pct);

  const bar = document.createElement('div');
  bar.className = 'usage-bar';
  const fill = document.createElement('div');
  fill.className = 'usage-bar-fill';
  fill.style.width = Math.min(100, Math.max(0, lim.percent)) + '%';
  fill.style.background = sevColor(lim.severity);
  bar.appendChild(fill);

  const reset = document.createElement('div');
  reset.className = 'usage-reset';
  reset.textContent = fmtResets(lim.resets_at);

  wrap.append(label, bar, reset);
  return wrap;
}

function card(acct) {
  const el = document.createElement('section');
  el.className = 'usage-card';
  const h = document.createElement('h2');
  h.textContent = acct.label || acct.host;
  el.appendChild(h);

  if (acct.status === 'auth_expired' || acct.status === 'no_token' || acct.status === 'timeout') {
    const note = document.createElement('p');
    note.className = 'usage-note';
    note.textContent = acct.status === 'timeout'
      ? `Keychain read timed out on ${acct.host} (unlock the login keychain)`
      : `Sign in on ${acct.host} (run claude)`;
    el.appendChild(note);
    return el;
  }
  for (const lim of acct.limits || []) el.appendChild(gauge(lim));
  return el;
}

async function refresh() {
  const root = document.getElementById('usage-accounts');
  try {
    const res = await fetch('/usage/state');
    if (!res.ok) throw new Error(String(res.status));
    const { accounts } = await res.json();
    // Drop stale accounts (no report in 15+ min) entirely rather than dimming
    // them — a workstation that goes idle/offline should disappear immediately,
    // not linger greyed-out on the wall. `stale` is computed server-side.
    const active = (accounts || []).filter((a) => !a.stale);
    root.replaceChildren();
    if (active.length === 0) {
      const p = document.createElement('p');
      p.className = 'usage-empty';
      p.textContent = 'No usage reports yet.';
      root.appendChild(p);
      return;
    }
    for (const acct of active) root.appendChild(card(acct));
  } catch {
    /* keep last render on transient failure */
  }
}

// Guard the browser bootstrap so this module is importable in Node (for the
// pure-helper test in Step 4) without a `document`/`fetch` ReferenceError.
if (typeof document !== 'undefined') {
  refresh();
  setInterval(refresh, 30000);
}

export { fmtResets, sevColor, limitLabel };
