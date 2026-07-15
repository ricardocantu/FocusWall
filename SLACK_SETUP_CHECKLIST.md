# Slack unread panel — turn-on checklist

The wall's Slack panel reads *your own* unread badge via Slack's internal
`client.counts`, using a browser **session token** (`xoxc-…`) + the `d` cookie
per workspace. Only counts leave Slack — never message content. LAN-only.

> **Optional feature.** The Slack panel is not required to run the wall — leave
> these secrets unset and it stays hidden, with nothing else affected.
>
> Note: `client.counts` is undocumented and not an officially supported Slack
> integration, so treat this as a best-effort extra. The token also expires when
> you fully sign out / change your password (weeks–months) — re-grab it when the
> panel shows `?`.

## 1. Grab the token + cookie (once per workspace)

1. Open the workspace in Slack **web** (`app.slack.com`) in a browser, signed in.
2. Open DevTools → **Network**. Filter for `client.counts` (or any `api/` call).
3. Click a request → **Payload/Form Data**: copy the `token` value (starts `xoxc-`).
4. → **Headers → Request Headers → Cookie**: copy the value of the `d=` cookie
   (the long `d=xoxd-…` segment — just the value after `d=`, up to the `;`).

## 2. Add GitHub Actions secrets

Repo → Settings → Secrets and variables → Actions → **New repository secret**:

| Secret | Value |
|---|---|
| `SLACK_WS0_LABEL`  | A short name, e.g. `Acme` |
| `SLACK_WS0_TOKEN`  | the `xoxc-…` token |
| `SLACK_WS0_COOKIE` | the `d` cookie value (`xoxd-…`) |

For a second workspace, repeat with `SLACK_WS1_*`. Leave a slot's secrets unset
to disable it.

## 3. Deploy + verify

- Push to `main` (or re-run the deploy workflow) so the Pi redeploys with the
  secrets.
- On the wall (`/wall`), the Slack panel appears on the hero — one labeled block
  per workspace, with a presence dot and per-category unread rows (Mentions /
  Channels / DMs / Threads). A block shows `⚠ reconnect` if its token expired.
- Sanity check from any LAN machine:
  `curl -s http://focus-wall.local:5050/slack/state | jq .`
