// /wall — rotates between the grid and hero views without reloading either,
// and drives the news ticker along the top.
// Both iframes stay loaded; only `hidden` toggles, so each keeps its DOM and
// SSE connection alive — revealing a view is instant, with no reload or replay.
import { initKioskCursor } from './sse.js';

initKioskCursor(); // hides cursor when loaded as /wall?kiosk=1

// ── View rotation ──────────────────────────────────────────────────────────
// Interval is per view (a full grid→hero→grid cycle is 2×). ?rotate=<seconds>
// overrides the 30s default.
function initRotation() {
  const frames = [
    document.getElementById('frame-grid'),
    document.getElementById('frame-hero'),
  ];
  const secs = parseInt(new URLSearchParams(location.search).get('rotate'), 10) || 30;
  let shown = 0;
  setInterval(() => {
    frames[shown].hidden = true;
    shown ^= 1;
    frames[shown].hidden = false;
  }, secs * 1000);
}

initRotation();

// ── News ticker ────────────────────────────────────────────────────────────
// Reads the server-merged, same-origin /rss feed (browsers can't fetch external
// RSS — CORS). Feed titles are external/untrusted, so every node is built with
// textContent, never innerHTML.
const track = document.getElementById('ticker-track');

// Scroll speed in pixels/second — LOWER is SLOWER. This drives the marquee
// duration off the actual content width, so the speed stays constant no matter
// how many feeds/items are configured (a fixed CSS duration would speed up as
// you add feeds). Tune this one number to taste.
const TICKER_PX_PER_SEC = 40;

function makeItems(items) {
  return items.map(it => {
    const span = document.createElement('span');
    span.className = 'ticker-item';
    const src = document.createElement('span');
    src.className = 'ticker-src';
    src.textContent = it.source || 'news';
    const title = document.createElement('span');
    title.textContent = it.title;
    span.append(src, title);
    return span;
  });
}

function renderTicker(items) {
  track.replaceChildren();
  if (!items || items.length === 0) {
    const span = document.createElement('span');
    span.className = 'ticker-item';
    span.textContent = 'News unavailable';
    track.appendChild(span);
    track.classList.remove('scrolling');
    return;
  }
  // Duplicate the sequence so the CSS marquee (translateX 0 → -50%) loops seamlessly.
  for (const node of makeItems(items)) track.appendChild(node);
  for (const node of makeItems(items)) track.appendChild(node);
  track.classList.add('scrolling');
  // One animation cycle (0 → -50%) advances exactly one copy = scrollWidth / 2.
  // Derive the duration so the on-screen speed is a constant px/sec.
  const oneCopyPx = track.scrollWidth / 2;
  track.style.animationDuration = (oneCopyPx / TICKER_PX_PER_SEC) + 's';
}

async function refreshTicker() {
  try {
    const res = await fetch('/rss');
    if (!res.ok) throw new Error(String(res.status));
    renderTicker(await res.json());
  } catch {
    // Keep whatever is showing; only fall back to the placeholder if empty.
    if (!track.querySelector('.ticker-item')) renderTicker([]);
  }
}

refreshTicker();
setInterval(refreshTicker, 5 * 60 * 1000);
