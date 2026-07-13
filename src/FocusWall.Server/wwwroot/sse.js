// Shared connection + kiosk chrome for both dashboard views (grid + hero).
// Owns the single EventSource, reconnect, and the #conn badge so both views
// behave identically on Wi-Fi blips. No framework, no build step.

export function initKioskCursor() {
  // ?kiosk=1 hides the cursor — the reliable mechanism on the Pi (Wayland),
  // where unclutter does nothing.
  if (new URLSearchParams(location.search).has('kiosk')) {
    document.documentElement.style.cursor = 'none';
    document.body.style.cursor = 'none';
  }
}

// If no SSE traffic (event/status/heartbeat) arrives within this window, the
// renderer is presumed wedged (Chromium kiosks occasionally lock up with a
// silently-dead EventSource that neither errors nor delivers) and we hard-reload.
// 120s is 8× the 15s server heartbeat, so a healthy stream is never silent this
// long — no false positives, but a real wedge is caught fast.
const DEAD_STREAM_MS = 120_000;

export function connectStream({ onOpen, onStatus, onEvent } = {}) {
  const conn = document.getElementById('conn');
  let es;
  let lastActivity = Date.now();

  function bump() { lastActivity = Date.now(); }

  function connect() {
    if (es) es.close();
    if (conn) { conn.textContent = 'connecting…'; conn.className = 'conn'; }
    bump(); // fresh attempt — don't let a stale timestamp trip the watchdog
    es = new EventSource('/events/stream');

    es.addEventListener('open', () => {
      bump();
      if (conn) { conn.textContent = 'live'; conn.className = 'conn live'; }
      onOpen?.();
    });
    es.addEventListener('error', () => {
      if (conn) { conn.textContent = 'reconnecting…'; conn.className = 'conn dead'; }
    });
    es.addEventListener('status', (e) => { bump(); onStatus?.(JSON.parse(e.data)); });
    es.addEventListener('event', (e) => { bump(); if (onEvent) onEvent(JSON.parse(e.data)); });
    es.addEventListener('heartbeat', () => { bump(); /* keeps connection alive */ });
  }

  connect();
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && es?.readyState !== 1) connect();
  });

  // Watchdog: full page reload if the stream goes silent past the threshold.
  // Reconnect-on-error above handles clean drops; this catches wedged renderers
  // a JS-level reconnect can't recover. Guarded to the visible (wall) tab so a
  // throttled background tab doesn't reload. Self-heals if the server was down.
  setInterval(() => {
    if (document.visibilityState !== 'visible') return;
    if (Date.now() - lastActivity > DEAD_STREAM_MS) location.reload();
  }, 20_000);
}
