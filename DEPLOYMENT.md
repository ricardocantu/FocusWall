# Deployment

Step-by-step Pi setup, from flashing the SD card to a self-recovering wall display. Assumes Raspberry Pi OS Bookworm (64-bit) on a Pi 4 or Pi 5.

## 1. Flash the SD card

Use the official **Raspberry Pi Imager** (`brew install raspberry-pi-imager` on macOS, available on apt/winget elsewhere).

1. Choose device: Raspberry Pi 5 (or 4)
2. Choose OS: **Raspberry Pi OS (64-bit)** — full desktop version (you need a GUI for the kiosk browser)
3. Choose storage: your microSD card
4. **Click the gear icon for OS customization**, set:
   - Hostname: `focus-wall`
   - Username/password: your choice (avoid the default `pi`/`raspberry`)
   - Wi-Fi credentials
   - Locale, timezone, keyboard layout
   - Enable SSH (password auth fine for now; key auth is one step later)

Write the card. Boot the Pi with the card inserted. First boot takes ~2 minutes.

## 2. First connection

```bash
ssh focuswall@focus-wall.local
# accept the host key, log in
```

If `.local` doesn't resolve from your machine, you have two options:

- macOS / Linux: works out of the box via mDNS (Avahi).
- Windows: install Apple's Bonjour Print Services, or find the IP via your router and use that.

Update the system:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

## 3. Install Docker

```bash
ssh focuswall@focus-wall.local
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
exit  # log out and back in so group takes effect
```

Verify:

```bash
ssh focuswall@focus-wall.local
docker run --rm hello-world
```

## 4. Deploy the server

Two ways to get the server running on the Pi. Use the runner path (4a) if the repo is private — that's what this project is built around. Fall back to the manual path (4b) if you don't want CI involved, or to sanity-check Docker on the Pi before wiring up the runner.

### 4a. Automated deploy via self-hosted runner (recommended)

**The repo must be private for this.** GitHub is explicit that self-hosted runners on public repos are a known attack vector — anyone who opens a PR can get their workflow code executed on the runner, which here is your physical Pi. If you ever make the repo public, remove the runner first.

1. On GitHub: repo → **Settings → Actions → Runners → New self-hosted runner** → OS **Linux**, Architecture **ARM64**.
2. GitHub generates the exact download/config commands with a fresh, short-lived registration token — copy them from the page and run them verbatim over SSH (don't reuse a token from an old session or paste one from this doc; it'll be expired):

   ```bash
   ssh focuswall@focus-wall.local
   mkdir ~/actions-runner && cd ~/actions-runner
   # paste GitHub's curl + tar commands here, then:
   ./config.sh --url https://github.com/<you>/<repo> --token <TOKEN> --labels focus-wall-pi
   ```
3. Install it as a service so it survives reboots — same `restart: unless-stopped` philosophy as the Docker container:

   ```bash
   sudo ./svc.sh install
   sudo ./svc.sh start
   sudo ./svc.sh status   # confirm it's running
   ```
4. Activate the workflow: the repo ships an inert sample at `.github/workflows/deploy.yml.example` (GitHub ignores non-`.yml` files, so it never runs until you rename it). Copy it to `.github/workflows/deploy.yml` — or paste the fuller contents from `IMPLEMENTATION.md` § "Phase 2 — containerize" — then push to `main` from your workstation.
5. Watch it run: repo → **Actions** tab. The job checks the repo out into the runner's own work directory and runs `docker compose up -d --build` right there — no registry involved.
6. If you're using any of the optional secret-backed channels — Echo Show, Discord, or the Slack panel — add each token as a **GitHub Actions repository secret** (repo → **Settings → Secrets and variables → Actions → New repository secret**). `deploy.yml`'s deploy step injects them as env vars (`${{ secrets.* }}`), and `docker-compose.yml` interpolates them into the container; they're masked in logs. The full set (`DISCORD_WEBHOOK_URL`, `VOICEMONKEY_TOKEN`/`VOICEMONKEY_DEVICE`, `SLACK_WS0_*`/`SLACK_WS1_*`) is listed in `docker-compose.yml`, and each channel's turn-on steps are in `ECHO_SETUP_CHECKLIST.md`, `DISCORD_SETUP_CHECKLIST.md`, and `SLACK_SETUP_CHECKLIST.md`. Any secret left unset just disables that one channel — none are required for the wall itself.

   *Local/manual alternative:* instead of GitHub secrets you can drop the same `KEY=value` lines in a gitignored `.env` beside `docker-compose.yml` on the runner (`~/actions-runner/_work/<repo>/<repo>/.env`); the workflow's `clean: false` checkout preserves it across deploys.

From here, every `git push` to `main` redeploys automatically — no more SSH-and-pull.

### 4b. Manual deploy (fallback / first bring-up)

```bash
ssh focuswall@focus-wall.local
git clone <your-repo-url> ~/focus-wall
cd ~/focus-wall
docker compose up -d
docker compose logs -f focus-wall  # ctrl-c when you see "Now listening on..."
```

### Verify (either path)

```bash
curl http://focus-wall.local:5050/healthz
# should print: ok
```

## 5. Kiosk mode

Goal: Pi boots → autologin → desktop loads → Chromium opens fullscreen on the dashboard → no cursor → no screen blanking → survives reboot.

Bookworm uses Wayland with the **labwc** or **wayfire** window manager. The default for the Pi 5 is `labwc`. Check yours:

```bash
echo "$XDG_SESSION_TYPE"
# wayland
```

### 5a. Enable autologin to desktop

```bash
sudo raspi-config
# System Options → Boot / Auto Login → Desktop Autologin → OK → Finish → reboot
```

### 5b. Install supporting packages

```bash
sudo apt install -y chromium-browser
```

(Usually already present on the full desktop image.) Don't bother with `unclutter` — it's X11-only and does nothing under Bookworm's Wayland session. The dashboard hides the cursor itself when loaded with the `?kiosk=1` URL parameter.

### 5c. Create the kiosk autostart

For **labwc** (Pi 5 default on Bookworm), create `~/.config/labwc/autostart`:

```bash
mkdir -p ~/.config/labwc
nano ~/.config/labwc/autostart
```

Contents:

```bash
# Screen blanking is disabled via raspi-config (step 5d) — nothing needed here.
# Cursor hiding is handled by the dashboard's ?kiosk=1 parameter (unclutter is
# X11-only and does nothing on Wayland).

# Wait for the server to be reachable, then launch Chromium kiosk.
# The outer loop relaunches Chromium whenever it exits — labwc does not
# respawn dead children, and this is also what makes the nightly pkill
# restart (step 6) work.
( while true; do
    while ! curl -sf http://localhost:5050/healthz > /dev/null; do sleep 1; done
    chromium-browser \
      --kiosk \
      --noerrdialogs \
      --disable-infobars \
      --disable-translate \
      --no-first-run \
      --check-for-update-interval=31536000 \
      --app='http://localhost:5050/?kiosk=1'
    sleep 2  # avoid a tight respawn loop
  done
) &
```

Save and `chmod +x ~/.config/labwc/autostart`.

For **wayfire** (older or alternative), create `~/.config/wayfire.ini`:

```ini
[autostart]
chromium = sh -c 'while true; do while ! curl -sf http://localhost:5050/healthz; do sleep 1; done; chromium-browser --kiosk --noerrdialogs --disable-infobars --no-first-run --app="http://localhost:5050/?kiosk=1"; sleep 2; done'
screensaver = false
dpms = false
```

### 5d. Disable screen blanking system-wide

In **raspi-config**:

```bash
sudo raspi-config
# Display Options → Screen Blanking → No → Finish
```

For belt-and-suspenders, also disable via systemd:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### 5e. Test the kiosk

```bash
sudo reboot
```

Pi should boot, log in automatically, and present Chromium fullscreen on the dashboard within 30–45 seconds.

## 6. Nightly Chromium restart (optional, recommended)

Chromium leaks memory slowly. After 5–7 days of uptime it can get sluggish. A nightly restart fixes this.

The autostart from step 5c already runs Chromium inside a respawn loop — labwc/wayfire do not restart dead child processes on their own; the loop is what brings Chromium back. So the cron job only needs to kill it:

```bash
crontab -e
```

Add:

```
0 3 * * * pkill -f chromium-browser
```

Within a couple of seconds of the 3am kill, the loop relaunches a fresh Chromium pointed at the dashboard.

## 7. Network resilience

If your Wi-Fi is flaky, two helpers:

### Static IP via DHCP reservation

In your router, reserve an IP for the Pi's MAC. mDNS plus a stable IP means the Pi finds itself the same way every boot.

### Wi-Fi watchdog

```bash
sudo apt install -y watchdog
sudo nano /etc/watchdog.conf
```

Add:

```
ping = 192.168.1.1     # your router IP
interval = 30
retry-timeout = 60
```

Then:

```bash
sudo systemctl enable --now watchdog
```

If the Pi can't ping its router for 60s, it reboots.

## 8. Updates

**If you set up the runner (§4a):** nothing to do. Push to `main`; the Pi redeploys itself within a minute or so of the Actions job finishing.

**Manual path (§4b):**

```bash
ssh focuswall@focus-wall.local
cd ~/focus-wall
git pull
docker compose up -d --build
```

Chromium auto-reconnects to the SSE stream as soon as the new container is healthy, either way.

## 9. Optional: SSH key auth

Once everything is working, lock down SSH:

```bash
# From your workstation
ssh-copy-id focuswall@focus-wall.local

# On the Pi
sudo nano /etc/ssh/sshd_config
# Set:
#   PasswordAuthentication no
#   PubkeyAuthentication yes
sudo systemctl restart ssh
```

## 10. Backup strategy

For a side project, the SD card *is* the backup risk. Two options:

**Option A: re-flashable.** Treat the Pi as cattle. Keep this repo plus a one-line setup note ("flash, clone, docker compose up, set autologin") and accept that recovery means re-flashing. ~30 minutes.

**Option B: dd image to a file.** When everything's working:

```bash
# From your workstation
ssh focuswall@focus-wall.local 'sudo dd if=/dev/mmcblk0 bs=4M' | gzip > focus-wall-$(date +%F).img.gz
```

Restore with `gunzip` and Raspberry Pi Imager.

Option A is honest. Option B is over-engineered for this. Pick A.

## 11. Troubleshooting

| Symptom | First thing to check |
|---------|----------------------|
| Dashboard doesn't load | `docker compose logs focus-wall` on the Pi |
| Push to `main` doesn't deploy | GitHub repo's **Actions** tab for job status; on the Pi, `sudo ~/actions-runner/svc.sh status` to confirm the runner service is up |
| Chromium doesn't start at boot | `cat ~/.config/labwc/autostart` — does it exist and is it executable? |
| Cursor visible | Kiosk URL must include `?kiosk=1` — check the `--app=` line in the autostart |
| Screen blanks | Re-run `raspi-config` display options (step 5d), confirm systemd sleep targets are masked |
| `focus-wall.local` doesn't resolve | Confirm mDNS with `avahi-resolve -n focus-wall.local` (on Linux) or use the IP |
| SSE drops every minute | Check for a reverse proxy or VPN buffering responses; bypass it |
| Pi reboots randomly | Power supply — Pi 5 needs the 27W official supply, not a phone charger |
| Memory creeps over a week | Confirm cron Chromium restart fires; `journalctl -u cron` |
| Events arrive but dashboard is stale | Hard reload (Ctrl+Shift+R) — Chromium cached old assets |

## 12. Health-check from your workstation

A one-liner you can put in a `bin/` directory or alias:

```bash
ssh focuswall@focus-wall.local 'docker compose -f ~/focus-wall/docker-compose.yml ps && uptime'
```

## 13. Going from "working" to "wall-mounted"

The order that hurts the least:

1. **Test the dashboard on the bench** — Pi on the desk, monitor next to it, run a real Claude Code session for an hour. Iterate on visuals and event coverage.
2. **Decide cable strategy** — through-wall, raceway, or behind-monitor bundle (see HARDWARE.md).
3. **Power off, mount, route cables.** Mount the monitor first, then attach the Pi to the back.
4. **Power on.** It should self-recover into the dashboard.

If step 4 fails, your bench setup wasn't actually self-recovering — go back to step 1 and pull the power cord during testing until it does.

## Done

When the Pi survives an unannounced power cycle and shows the dashboard again with no keyboard, you're done with deployment. Phase 4 (polish against the real wall) and beyond are next.
