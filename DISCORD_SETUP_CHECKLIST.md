# Discord notifications — setup checklist (Phase 6b)

Do-this-now walkthrough to turn on Discord push notifications for the wall.
When any Claude Code session flips to **waiting**, the server posts an amber embed
to a Discord channel → phone push anywhere with signal. The code is already in the
repo (`DiscordNotifier.cs`, wired in `Program.cs` / `docker-compose.yml` /
`deploy.yml`); this covers the manual + deploy steps. Full design: `DISCORD.md`.

The notifier self-disables if `DISCORD_WEBHOOK_URL` is unset — the dashboard and
every other channel are unaffected. This flow uses a **GitHub Actions secret** as
the primary path (no hand-editing `.env` on the Pi).

## Step 1 — Create the Discord webhook
- [ ] Discord → pick or create a server → create a text channel (e.g. `#focus`; private is fine).
- [ ] Right-click the channel → **Edit Channel** → **Integrations** → **Webhooks** → **New Webhook**.
- [ ] Name it `Claude Focus Wall` → **Copy Webhook URL**.
- [ ] Keep it somewhere safe. It looks like `https://discord.com/api/webhooks/123.../aBcD...`. **Treat it like a password.**

## Step 2 — Turn on phone push
- [ ] On your phone: Discord → the channel → **Notification Settings** → **All Messages**.
- [ ] Confirm the Discord app has system notification permission.

## Step 3 — Smoke-test the webhook *before* the server
Verify the boring path first, from any machine:

```bash
curl -X POST "YOUR_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content": "focus wall smoke test"}'
```

- [ ] A message appears in the channel and your phone buzzes within a second.

**Don't proceed until this works** — a failure here is the URL (stray whitespace) or
phone settings, not the server.

## Step 4 — Add the webhook as a GitHub secret
- [ ] GitHub → your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.
- [ ] Name: `DISCORD_WEBHOOK_URL` (exact match). Value: your webhook URL. **Add secret.**
  - Must be a **secret**, not a variable — variables are plaintext and show up unmasked in logs.

## Step 5 — Commit & push the code changes
Review the diff and push these staged files to `main`:

- [ ] `src/FocusWall.Server/DiscordNotifier.cs` (new)
- [ ] `src/FocusWall.Server/Program.cs`
- [ ] `docker-compose.yml`
- [ ] `.github/workflows/deploy.yml` (injects the secret)
- [ ] `.env.example` (new)

The push triggers the Pi's runner, which injects the secret → compose interpolates
it → notifier enables. No SSH, no `.env` to hand-edit.

## Step 6 — Confirm the notifier came up
After the Actions job goes green, SSH to the Pi and check (in the runner's checkout
dir, where `docker-compose.yml` lives):

```bash
docker compose logs focus-wall | grep DiscordNotifier
# expect: "DiscordNotifier subscribed (cooldown 120s per session)"
```

- [ ] Saw `DiscordNotifier subscribed`.

If you see `DiscordNotifier disabled — DISCORD_WEBHOOK_URL not set`, the secret name
doesn't match or the deploy ran before the secret existed — re-run the job.

## Step 7 — End-to-end test against the Pi

```bash
curl -X POST http://focus-wall.local:5050/events \
  -H 'Content-Type: application/json' \
  -d '{"hook_event_name":"Notification","session_id":"smoke-test","message":"Permission requested for Edit"}'
```

- [ ] Within ~2 seconds: an amber embed in `#focus` + a phone push.
- [ ] Real proof: run a Claude Code session, let it hit a permission prompt — the wall goes amber *and* your phone buzzes.

## Step 8 (optional) — quiet hours / self-ping
- [ ] Quiet hours default to **22:00–07:30** (container-local via `TZ: Etc/UTC`). Change `DISCORD_QUIET_START/END` in `docker-compose.yml`, or delete both lines to always notify.
- [ ] Want a louder push? Add the `<@your-id>` self-ping from `DISCORD.md` §"Tuning" later, only if the plain embed under-alerts.

---

## Caveats worth remembering
- **Manual deploys.** The secret is only present *during the Actions deploy*. Normal
  push-to-deploy and reboots (`restart: unless-stopped`) keep the value fine. But a
  **manual** `docker compose up -d` on the Pi resolves the webhook to empty and
  silently disables the notifier — for that path, export the var first or keep a
  Pi-side `.env` as backup (`.env.example` documents it).
- **Debugging.** `docker compose logs focus-wall | tail -30`.
  - `Discord returned 4xx` = bad/stale webhook URL.
  - `Discord webhook call failed` = network.
  - Posts to the channel but no phone buzz = phone notification settings (Step 2).
