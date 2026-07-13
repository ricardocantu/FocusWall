# Hardware

Bill of materials, prices in USD as of mid-2026, and notes on the physical install.

## Three tiers

| Tier | Total | Use when |
|------|-------|----------|
| Budget | ~$120 | You have an old monitor in a closet |
| Recommended | ~$200 | Building it properly the first time |
| Premium | ~$320 | You want it to look intentional |

Prices are ballpark and vary by reseller (Adafruit, PiShop, CanaKit, Amazon).

## Recommended build

| # | Part | Notes | Price |
|---|------|-------|-------|
| 1 | Raspberry Pi 5 (4GB) | 8GB is overkill for this workload | $80 |
| 2 | Official Pi 5 27W USB-C power supply | Don't skimp — Pi 5 with HDMI active pulls more than a Pi 4 | $12 |
| 3 | Active-cooled case (e.g. Argon NEO 5, FLIRC Pi 5) | Passive cases throttle on 24/7 loads | $25 |
| 4 | SanDisk Extreme 64GB microSD A2 | A2 rating matters for boot time | $14 |
| 5 | 14" portable monitor, 1920×1080, IPS, HDMI | Look for "USB-C powered" so one cable does video+power | $90 |
| 6 | Low-profile VESA 75/100 wall mount | Tilting type, ~$15 | $15 |
| 7 | 1m or 2m HDMI cable (depending on mount distance) | Cheap is fine | $8 |
| 8 | Velcro cable management strips | Hides the Pi behind the monitor | $5 |

**Subtotal: ~$249.** Drops to ~$200 if you skip the case (use a basic one ~$10) and find the monitor on sale.

## Budget build

If you have an HDMI monitor sitting around:

| # | Part | Notes | Price |
|---|------|-------|-------|
| 1 | Raspberry Pi 4 Model B (2GB) | Works fine, slightly slower boot | $45 |
| 2 | Official Pi 4 power supply | | $10 |
| 3 | Basic case with fan | | $10 |
| 4 | 32GB microSD | | $10 |
| 5 | HDMI cable | | $8 |
| 6 | Existing monitor | $0 | |
| 7 | Mount or stand | Hardware store or print one | $20 |

**Subtotal: ~$103.**

## Premium build

If you want it to disappear into the wall:

| # | Part | Notes | Price |
|---|------|-------|-------|
| 1 | Raspberry Pi 5 (4GB) | | $80 |
| 2 | Pi 5 power supply | | $12 |
| 3 | Argon NEO 5 case | Aluminium, passively cooled, looks the part | $25 |
| 4 | 128GB SanDisk Extreme | More room for logs/SQLite if you grow | $20 |
| 5 | 15.6" frameless touch monitor (e.g. Eviciv, ASUS ZenScreen) | Frameless looks much better wall-mounted | $160 |
| 6 | VESA mount, slim profile | Hold-on-display arm style | $30 |
| 7 | Right-angle HDMI cable | Lets the cable hide flush | $10 |
| 8 | Cable raceway / cord cover (paintable) | If you can't fish the cable through the wall | $15 |

**Subtotal: ~$352.** Worth it if the wall is in a high-visibility spot — kitchen, hallway, office wall someone might see.

## Optional Echo Show announcements (Phase 6a)

**No additional hardware required if you already own an Echo Show.** This add-on uses a third-party webhook bridge (Voice Monkey) to make the Echo speak when Claude needs you. See `ECHO_SHOW.md` for the setup walkthrough.

If you *don't* own an Echo Show and are considering buying one purely for this:

- Don't. A second small portable monitor in the other room is a better use of $90.
- The Echo Show makes sense as an add-on, not the primary surface — voice is intrusive and ephemeral, while the wall display is always there to glance at.

## On choosing a monitor

Three things actually matter for a wall display:

1. **Power input.** USB-C-powered means one cable to the wall. HDMI-only monitors need a separate power brick — manageable but uglier. If you go USB-C: confirm the Pi 5 can power it, or use a USB-C PD power supply that splits to the monitor + Pi.

2. **Size.** 14" is the sweet spot — big enough to read from across a room, small enough to not dominate a wall. 11" is too small unless within 6 feet. 17" starts to feel like a TV.

3. **Glare.** Matte panel only. Glossy reflects the room and ruins the across-the-room readability the project is built around.

4. **Mount.** Almost any 14"+ portable monitor has VESA 75 holes. Check before buying.

## Cable strategy

Two cables minimum: video (HDMI from Pi to monitor) and power (one for the Pi, one for the monitor unless USB-C combined).

Options for hiding cables:

- **Best:** fish through the wall. Requires a hole behind the monitor and another at outlet height. Looks invisible when done.
- **Good:** paintable cord raceway. Sticks to the wall, holds the cables, gets painted wall color. Visible if you look but not distracting.
- **Acceptable:** velcro the Pi to the back of the monitor and run a single cable bundle down. Slightly bulky but everything is one parcel.

## Mounting

A VESA 75 or 100 plate is the standard. Tilting mounts let you angle the screen down toward viewing position (useful when mounted above eye level). Avoid full-articulating arms — they're overkill and add cost.

For drywall, use the toggle bolts that come with the mount. Don't use the plastic anchors — those are for picture frames.

## Power planning

The full setup needs two outlets behind the monitor — one for the monitor, one for the Pi — unless your monitor is USB-C powered and you use a single PD supply.

Quietest option: a small UPS so power blips don't reboot the Pi. CyberPower CP425SLG (~$50) is plenty for this load. Optional but nice if your building has rough power.

## Where to buy

US sources, in rough order of preference:

- **Adafruit** — Pi 5, accessories. Stock is reliable.
- **PiShop.us** — same, sometimes cheaper.
- **Amazon** — monitors, mounts, cables. Avoid third-party Pi sellers; counterfeits exist.
- **Micro Center** (in-store) — if you have one nearby, often cheapest on Pis.

## Total time investment

Once parts arrive:

- Unboxing and bench testing: ~30 min
- OS flash and first boot: ~30 min (see DEPLOYMENT.md)
- Wall mount and cable routing: 1–2 hours
- Full software setup if following DEPLOYMENT.md cleanly: ~1 hour

So budget half a day for the hardware side once everything is in hand.
