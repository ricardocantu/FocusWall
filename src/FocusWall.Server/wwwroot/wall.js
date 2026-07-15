// /wall — the kiosk shell: the composed dashboard (/hero) in a single iframe,
// wrapped by the two news tickers (news along the top, sports along the bottom).
// This file only drives the tickers and hides the cursor in kiosk mode; the
// iframe keeps its own DOM and SSE connection alive, and the in-page view
// rotation now lives inside the dashboard (app.js bottom-band crossfade).
import { initKioskCursor } from './sse.js';

initKioskCursor(); // hides cursor when loaded as /wall?kiosk=1

// ── News ticker ────────────────────────────────────────────────────────────
// Reads the server-merged, same-origin /rss feed (browsers can't fetch external
// RSS — CORS). Feed titles are external/untrusted, so every node is built with
// textContent, never innerHTML.
// Two rows: news along the top, sports along the bottom.
const track = document.getElementById('ticker-track');
const trackSports = document.getElementById('ticker-track-sports');

// Scroll speed in pixels/second — LOWER is SLOWER. This drives the marquee
// duration off the actual content width, so the speed stays constant no matter
// how many feeds/items are configured (a fixed CSS duration would speed up as
// you add feeds). Tune this one number to taste.
const TICKER_PX_PER_SEC = 40;

// Date stamp: always shows month/day; same-day items also append the time.
// Guards against missing/unparseable publishedAt (returns '' → span omitted).
function fmtStamp(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const date = d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  const sameDay = d.toDateString() === new Date().toDateString();
  if (!sameDay) return date;
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  return `${date}, ${time}`;
}

function makeItems(items) {
  return items.map(it => {
    const span = document.createElement('span');
    span.className = 'ticker-item';
    const src = document.createElement('span');
    src.className = 'ticker-src';
    src.textContent = it.source || 'news';
    span.append(src);
    const stamp = fmtStamp(it.publishedAt);
    if (stamp) {
      const date = document.createElement('span');
      date.className = 'ticker-date';
      date.textContent = stamp;
      span.append(date);
    }
    const title = document.createElement('span');
    title.textContent = it.title;
    span.append(title);
    return span;
  });
}

function renderTicker(el, items, emptyLabel) {
  el.replaceChildren();
  if (!items || items.length === 0) {
    const span = document.createElement('span');
    span.className = 'ticker-item';
    span.textContent = emptyLabel;
    el.appendChild(span);
    el.classList.remove('scrolling');
    return;
  }
  // Duplicate the sequence so the CSS marquee (translateX 0 → -50%) loops seamlessly.
  for (const node of makeItems(items)) el.appendChild(node);
  for (const node of makeItems(items)) el.appendChild(node);
  el.classList.add('scrolling');
  // One animation cycle (0 → -50%) advances exactly one copy = scrollWidth / 2.
  // Derive the duration so the on-screen speed is a constant px/sec.
  const oneCopyPx = el.scrollWidth / 2;
  el.style.animationDuration = (oneCopyPx / TICKER_PX_PER_SEC) + 's';
}

async function refreshTicker() {
  try {
    const res = await fetch('/rss');
    if (!res.ok) throw new Error(String(res.status));
    const data = await res.json();
    renderTicker(track, data.news, 'News unavailable');
    renderTicker(trackSports, data.sports, 'Sports unavailable');
  } catch {
    // Keep whatever is showing; only fall back to the placeholder if empty.
    if (!track.querySelector('.ticker-item')) renderTicker(track, [], 'News unavailable');
    if (!trackSports.querySelector('.ticker-item')) renderTicker(trackSports, [], 'Sports unavailable');
  }
}

refreshTicker();
setInterval(refreshTicker, 5 * 60 * 1000);
