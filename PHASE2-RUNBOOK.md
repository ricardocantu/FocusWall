# Phase 2b + 3 Runbook — Pi Deploy (self-hosted runner) + Kiosk

A do-this-now, in-order checklist for getting the containerized server onto the
Pi and into fullscreen kiosk mode. This is the condensed, values-filled version
of `DEPLOYMENT.md` — follow it top to bottom, and jump to the referenced
`DEPLOYMENT.md §` for the full explanation of any step.

**Your specifics** (already filled in below):

| Setting | Value |
|---------|-------|
| Pi hostname | `focus-wall` (→ `focus-wall.local` over mDNS) |
| Repo | `<you>/<repo>` (private ✓ — required for the runner) |
| Runner label | `focus-wall-pi` (must match the workflow's `runs-on`) |
| Timezone | `Etc/UTC` (set yours in `docker-compose.yml`) |

Replace `<user>` with the Pi username you set when flashing.

---

## ⚠️ Prerequisite — push the Phase 2 artifacts to `main`

Phase 2a produced four files that must be on `main` before the runner can
deploy (it deploys whatever it checks out):

- `src/FocusWall.Server/Dockerfile`
- `docker-compose.yml`
- `src/FocusWall.Server/.dockerignore`
- `.github/workflows/deploy.yml`  ← the runner literally can't run a workflow it can't see

Stage, commit, and push these to `main` at some point before **Step 5**.
(Git operations are done by hand in this project — nothing in this runbook runs
them for you.)

**Local verification already passed** (Phase 2a): image builds, `/healthz` →
`ok`, hook smoke test stored with `_meta` injected, `bash /dev/tcp` healthcheck
flips to `healthy`. So the container itself is known-good before it ever
reaches the Pi.

---

## 1 · Flash the SD card — `DEPLOYMENT.md §1`

Raspberry Pi Imager → **Raspberry Pi OS (64-bit), full desktop** (you need a GUI
for the kiosk browser). Click the gear icon for OS customization:

- Hostname: `focus-wall`
- Username / password: your choice (avoid the default `pi`/`raspberry`)
- Wi-Fi credentials
- Locale / timezone: your locale / keyboard layout
- **Enable SSH** (password auth is fine for now)

Write the card, boot the Pi. First boot ~2 min.

## 2 · First connection — `DEPLOYMENT.md §2`

```bash
ssh <user>@focus-wall.local          # accept host key, log in
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

If `.local` doesn't resolve: macOS/Linux work out of the box via mDNS; on
Windows install Bonjour or use the router-assigned IP.

## 3 · Install Docker — `DEPLOYMENT.md §3`

```bash
ssh <user>@focus-wall.local
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
exit                                  # log out/in so the group takes effect
ssh <user>@focus-wall.local
docker run --rm hello-world           # verify
```

## 4 · Register the self-hosted runner — `DEPLOYMENT.md §4a`

**The repo must stay private for this** — a self-hosted runner on a public repo
lets PR-submitted workflow code execute on your physical Pi.

1. GitHub: **<you>/<repo> → Settings → Actions → Runners → New
   self-hosted runner** → OS **Linux**, Architecture **ARM64**.
2. GitHub shows download/config commands with a fresh, short-lived token. Copy
   them from that page (don't reuse an old token — it'll be expired) and run on
   the Pi:

   ```bash
   ssh <user>@focus-wall.local
   mkdir ~/actions-runner && cd ~/actions-runner
   # paste GitHub's curl + tar commands here, then:
   ./config.sh --url https://github.com/<you>/<repo> --token <TOKEN> --labels focus-wall-pi
   ```
3. Install as a service so it survives reboots:

   ```bash
   sudo ./svc.sh install
   sudo ./svc.sh start
   sudo ./svc.sh status               # confirm it's running
   ```

> The `focus-wall-pi` label **must** match the workflow's
> `runs-on: [self-hosted, focus-wall-pi]` or the job never schedules. The
> `self-hosted` label is applied automatically to all self-hosted runners.

## 5 · Trigger the first deploy

Push to `main` (the push from the Prerequisite section does this). Watch the
**Actions** tab — the job runs `docker compose up -d --build` right on the Pi
(no registry). First run is a cold build:

- **~3 min on a Pi 5**, **~6 min on a Pi 4**

Verify over LAN from your workstation:

```bash
curl http://focus-wall.local:5050/healthz   # → ok
```

From here, **every push to `main` auto-redeploys** — no SSH-and-pull.

## 6 · Point your workstation hooks at the Pi

Change the hook target from `localhost:5050` to the Pi (via the `FOCUSWALL_URL`
env var — e.g. an `"env"` block in `~/.claude/settings.json`, which hook
subprocesses inherit). Run a real Claude Code session and confirm events arrive
on the Pi-hosted dashboard.

> **Use a reserved IP, not `.local`.** On this build, `focus-wall.local` (mDNS)
> resolved fine initially but **stopped resolving after a reboot** (SSH by name
> failed too), while the Pi stayed reachable by IP the whole time. mDNS is too
> flaky to hang the hook path on. Fix: add a **DHCP reservation** on the router
> so the Pi's IP is permanent, then point the hooks at it —
> `FOCUSWALL_URL=http://<reserved-ip>:5050/events`. The
> kiosk autostart is unaffected — it uses `localhost`. Fixing avahi to get the
> hostname back is optional convenience, not required.

---

## 7 · Kiosk mode — `DEPLOYMENT.md §5`

Goal: boot → autologin → Chromium fullscreen on the dashboard → no cursor → no
screen blanking → survives reboot. Bookworm uses the **labwc** compositor
(Wayland) — the Pi 5 default, and **confirmed on the Pi 4** in this build too
(`pgrep -a labwc` shows it running; `loginctl show-session … -p Type` → `wayland`).
labwc reads `~/.config/labwc/autostart` and, on Raspberry Pi OS, still runs the
system panel/desktop alongside it, so the user autostart doesn't wipe the panel.

### 7a · Autologin — `§5a`
```bash
sudo raspi-config
# System Options → Boot / Auto Login → Desktop Autologin → Finish
```

### 7b · Chromium — `§5b`
```bash
sudo apt install -y chromium   # usually already present
which chromium                 # confirm the binary name (see note)
```
> **Binary name:** on current Bookworm the command is **`chromium`**, *not*
> `chromium-browser` (that older wrapper name is gone — `which chromium-browser`
> returns nothing). The autostart below uses `chromium`; if your build only has
> `chromium-browser`, swap it back.

Skip `unclutter` — it's X11-only and does nothing on Wayland; the dashboard
hides the cursor itself via `?kiosk=1`.

### 7c · Autostart — `§5c`
For **labwc** (Pi 5 default), create `~/.config/labwc/autostart`:

```bash
mkdir -p ~/.config/labwc
nano ~/.config/labwc/autostart
```

Contents (respawn loop — labwc does not restart dead children, and this loop is
also what makes the nightly restart in §6 work):

```bash
# Wait for the server to be reachable, then launch Chromium kiosk.
( while true; do
    while ! curl -sf http://localhost:5050/healthz > /dev/null; do sleep 1; done
    chromium \
      --ozone-platform=wayland \
      --password-store=basic \
      --kiosk \
      --noerrdialogs \
      --disable-infobars \
      --disable-translate \
      --no-first-run \
      --check-for-update-interval=31536000 \
      --app='http://localhost:5050/wall?kiosk=1&rotate=10'
    sleep 2   # avoid a tight respawn loop
  done
) &
```

Then `chmod +x ~/.config/labwc/autostart`.

> **Two Wayland-specific flags are load-bearing** (learned the hard way on the
> Pi 4 kiosk bring-up — without them the desktop just sits empty):
> - `--ozone-platform=wayland` — without it Chromium defaults to its X11 backend
>   and dies with `Missing X server or $DISPLAY`, since labwc runs no X server.
> - `--password-store=basic` — without it Chromium blocks on a "Keyring
>   authentication required" dialog trying to unlock gnome-keyring. `basic` skips
>   the system keyring (fine for a kiosk that logs into nothing).
>
> To test the flags without a reboot, launch from an SSH shell pointed at the
> live session: `export XDG_RUNTIME_DIR=/run/user/1000;
> export WAYLAND_DISPLAY=wayland-0` then run the `chromium …` line.

> **Which view?** The `--app=` URL above points at the **`/wall` rotator**
> (grid ⇄ hero every 30s, with the RSS ticker pinned on top) — the view built
> specifically for this wall. If you'd rather a single static view, use:
> - Grid only: `http://localhost:5050/?kiosk=1`
> - Hero only: `http://localhost:5050/hero?kiosk=1`
>
> `DEPLOYMENT.md §5c` ships the grid URL as its default; this runbook swaps to
> the rotator deliberately.

### 7d · Disable screen blanking — `§5d`
```bash
sudo raspi-config
# Display Options → Screen Blanking → No → Finish
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### 7e · Test — `§5e`
```bash
sudo reboot
```
Chromium should come up fullscreen on the dashboard within 30–45s.

## 8 · Nightly Chromium restart (recommended) — `DEPLOYMENT.md §6`

Chromium leaks memory over days. The autostart loop already respawns it, so cron
only needs to kill it:

```bash
crontab -e
# add:
0 3 * * * pkill -f chromium-browser
```

---

## ✅ Exit criteria — `DEPLOYMENT.md §13`

1. **Bench test:** Pi + monitor on the desk, run a real session for an hour,
   iterate on visuals.
2. **The real test:** pull the power cord, plug it back in → the dashboard
   returns within ~60s with no keyboard.

If it doesn't self-recover on the bench, it won't on the wall — go back and pull
the cord until it does.

## Troubleshooting — `DEPLOYMENT.md §11`

| Symptom | First check |
|---------|-------------|
| Push to `main` doesn't deploy | **Actions** tab for job status; on the Pi `sudo ~/actions-runner/svc.sh status` |
| Dashboard doesn't load | `docker compose logs focus-wall` on the Pi |
| Chromium doesn't start at boot | `cat ~/.config/labwc/autostart` — exists and executable? |
| Cursor visible | `--app=` URL must include `?kiosk=1` |
| Screen blanks | Re-run raspi-config display options (§7d); confirm sleep targets masked |
| `focus-wall.local` won't resolve | `avahi-resolve -n focus-wall.local` (Linux) or use the IP |
| Pi reboots randomly | Power supply — Pi 5 needs the 27W official supply |
| Wall blank / kiosk "won't open" **after a deploy** | `docker ps -a` — if `focus-wall` is `Restarting`, see "Corrupt build cache" below |

### Corrupt build cache → 0-byte `runtimeconfig.json` → blank wall (fixed 2026-07-14)

**Symptom:** right after a push deployed, the wall went blank and `:5050` was
unreachable from the LAN even though the Pi pinged fine and the deploy job showed
green. `docker ps -a` showed `focus-wall` = `Restarting`, and `docker logs
focus-wall` repeated:

```
Failed to map file. mmap(/app/FocusWall.Server.runtimeconfig.json) failed with error 22
Cannot use file stream for [...runtimeconfig.json]: Invalid argument
Invalid runtimeconfig.json [...]
```

**Root cause:** a **poisoned Docker build-cache layer** produced a **0-byte
`runtimeconfig.json`** in the image (`mmap` of a zero-length file returns EINVAL,
so the .NET host can't start → crash-loop → dead `:5050` → the kiosk has no page).
It was **not** the app code, config, disk space (disk was 39% full), the SD card
(no `dmesg` I/O errors), or the kernel page size (4096). The corruption lived in
Docker's cache under `/var/lib/docker`, *not* in the `_work` checkout.

**Confirm it** (bypasses the crashing host by running `sh` instead of `dotnet`):

```bash
docker run --rm --entrypoint sh focus-wall:latest -c 'ls -l /app/FocusWall.Server.runtimeconfig.json'
# a 0-byte size = corrupt build
```

**Fix** — clean rebuild that ignores the cache, then clear the poison:

```bash
cd /home/pi/actions-runner/_work/FocusWall/FocusWall
docker compose build --no-cache && docker compose up -d
curl -sf http://localhost:5050/healthz && echo OK
pkill -f 'chromium.*--kiosk' || true   # bring the wall back
docker builder prune -af               # evict the corrupt cache
```

**Prevention (now in `deploy.yml`):** the deploy is health-gated — if `/healthz`
doesn't answer within 60s it auto-rebuilds `--no-cache` and retries; if still
unhealthy it fails the job **without** reloading the kiosk (last good page stays
up); an `if: always()` step prunes the cache (keep ≤2GB) each run. So this should
now self-heal, and a genuinely broken build fails loudly instead of blanking the
wall.

When everything survives an unannounced power cycle, Phase 2 + 3 are done —
next up is Phase 4 (polish against the real wall).
