# Echo Show announcements — turn-on checklist (Phase 6a)

The `EchoAnnouncer` code ships **disabled**. It stays disabled (one info log line,
dashboard unaffected) until `VOICEMONKEY_TOKEN` **and** `VOICEMONKEY_DEVICE` are set.
Do these steps when you're ready to hear it. Full design + failure modes: `ECHO_SHOW.md`.

## 1. Voice Monkey account + OAuth
- [ ] Sign up at https://voicemonkey.io
- [ ] Link the **same Amazon account your Echo Show is registered to** (OAuth). Use your personal account, not a work one.
- [ ] In **Devices**, confirm Voice Monkey sees the Echo Show. Note its device name/ID exactly (case + spaces).

## 2. Create the announcement webhook
- [ ] **Monkeys → Create**. Name it `claude-focus-waiting` (label only).
- [ ] Type: **Announcement** (not "Routine").
- [ ] Target device: the Echo Show from step 1.
- [ ] Copy the **access token**.

## 3. Smoke test from your laptop (do this BEFORE touching the server)
```bash
curl "https://api-utility.voicemonkey.io/v2/announcement?token=YOUR_TOKEN&device=DEVICE_NAME&text=hello%20from%20claude%20focus"
```
- [ ] The Echo Show chimes and speaks the phrase. If not: check the Voice Monkey dashboard log (accepted/rejected + reason), that the device is online in the Alexa app, and Do Not Disturb.

**Do not proceed until the curl speaks.** Saves a lot of debugging.

## 4. Turn it on
- [ ] Add two GitHub Actions **secrets** (Settings → Secrets and variables → Actions): `VOICEMONKEY_TOKEN`, `VOICEMONKEY_DEVICE`. These are injected by `deploy.yml` and masked in logs. (Local/manual runs: put the same two lines in the gitignored `.env` next to `docker-compose.yml` instead.)
- [ ] Push to `main` (or on the Pi: `docker compose up -d --build`).
- [ ] Confirm it's live:
  ```bash
  docker compose logs focus-wall | grep EchoAnnouncer
  # expected: "EchoAnnouncer subscribed (cooldown 120s per session)"
  ```

## 5. End-to-end check
```bash
curl -X POST http://focus-wall.local:5050/events \
  -H 'Content-Type: application/json' \
  -d '{"hook_event_name":"Notification","message":"Permission requested for Edit"}'
```
- [ ] Echo Show speaks "Claude is waiting for your input…" within ~2s.
- [ ] If the dashboard updates but the Echo is silent: `docker compose logs focus-wall | tail -50` and look for `Voice Monkey returned` (HTTP error) or `Voice Monkey call failed` (network). Token/device mismatch is the most common cause.

## Notes
- `.env` is gitignored; the deploy workflow copies it aside before its clean checkout and restores it afterwards, so it survives redeploys.
- Tuning (cooldown, phrasing, quiet hours): `ECHO_SHOW.md § Tuning the experience` + the `VOICEMONKEY_*` env vars in `docker-compose.yml`.
