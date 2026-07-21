# Mesh Status Dashboard — Design

Date: 2026-07-20

## Goal

A public status dashboard on the `MyVPN` repo showing each registered mesh
device's rough online/offline state, with a matching entry point added to
the `Welcome` portfolio site. Public-repo-safe: no IPs, endpoints, or
timestamps are ever exposed — only device name + a boolean.

## Why this shape

`MyVPN`'s `devices.json` is static (only changes via merged join-request
PRs) — it has no live connectivity data. The only place live data exists is
`sudo wg show` on the hub (spotifypi), which is not reachable from the
public internet except through the WireGuard port itself. A GitHub Pages
static site can't poll that directly, so live status has to be produced
out-of-band and published somewhere the static frontend can fetch.

## Architecture

```
spotifypi (self-hosted GH Actions runner)
  --schedule (*/10 * * * *)-->  status-cron.yml
       runs `sudo wg show`, maps peers -> devices.json entries
       writes status.json: [{name, online}, ...]  (no IPs/timestamps)
       commits + pushes to the `status` branch

status branch (status.json only, orphan branch, bot commits)
       |
       | raw.githubusercontent.com fetch, client-side, every 30s
       v
GitHub Pages (main branch /site, deployed via deploy.yml)
  static HTML/CSS/JS dashboard — style "Minimal Elegant":
  dark gradient panel, name + glow bulb + status pill per device

Welcome repo (separate, existing static site)
  new big-link card (icon: pulsing mesh-node triangle) next to "Blood"
  links out to the deployed MyVPN Pages URL
```

## Components

**`status-cron.yml`** (new GH Actions workflow in `MyVPN/.github/workflows/`)
- Trigger: `schedule` (every 10 minutes) + `workflow_dispatch` only.
  **Never** `pull_request` / `pull_request_target` — this repo accepts
  join-request PRs from strangers; a self-hosted runner must never execute
  code from an untrusted PR. This is a hard security requirement, not a
  style choice.
- Runs on: `runs-on: [self-hosted, myvpn-hub]` — a runner registered on
  spotifypi, scoped by label so no other workflow in this repo can
  accidentally schedule onto it.
- Steps: `sudo wg show wg0 dump` (machine-readable) → parse peer pubkeys →
  match against `devices.json` `wg_pubkey` → for each device, `online =
  (now - latest_handshake) < 180s` → write `status.json` → commit + force
  push to the orphan `status` branch (kept separate from `main` so the
  10-minute bot commits don't clutter real history).
- Runs as whichever user already runs `myvpn-sync.timer` on the pi (same
  trust level — it already reads `wg show` output for the hub-sync job).

**`site/`** (new directory, plain HTML/CSS/JS, no build step needed — this
is a handful of DOM nodes and a fetch loop, a bundler would be overhead)
- `index.html` — page shell, "Minimal Elegant" style: dark gradient panel
  (`#151521` → `#0c0c13`), device rows with name, a small bulb (teal glow
  `#5eead4` when online, empty outline when offline), and a status pill.
- `app.js` — on load and every 30s: `fetch` `status.json` from
  `raw.githubusercontent.com/yerry262/MyVPN/status/status.json`
  (`cache: 'no-store'`), merge with `devices.json` (fetched once, from
  `main`) for the full device list (so a device with no recent cron data
  yet still appears, shown offline/unknown rather than silently missing),
  re-render rows. Shows a small "updated Xs ago" client-side timer based on
  fetch time (not exposing the actual handshake timestamp — this is just
  "when did *this browser* last successfully fetch").
- No inputs, no auth, no write paths — pure read-only display.

**`deploy.yml`** (new GH Actions workflow) — standard
`actions/deploy-pages` flow: on push to `main` affecting `site/**`, build
(no-op, just the static files) and deploy to GitHub Pages. Runs on a normal
GitHub-hosted runner (no mesh access needed for this one).

**Welcome repo change** — one new `<a class="big-link">` card in
`index.html`, positioned immediately after the existing "Blood Lab Results"
card, using the mesh-nodes-triangle icon (pulsing green node on hover,
matching the existing per-card hover-animation pattern already used for
Blood/Stream/etc.), linking to the deployed MyVPN Pages URL.

## Data flow / freshness

- Underlying data updates every ~10 minutes (cron cadence — GitHub Actions'
  practical minimum granularity; below that requires a genuinely
  low-latency service which isn't warranted for this use case).
- Frontend re-fetches every 30 seconds regardless, so a page left open
  always converges to the latest available snapshot promptly after a cron
  tick lands, without requiring a manual reload.
- A device is "online" if its last WireGuard handshake was under 3 minutes
  old at the moment the cron job ran (accounts for the mesh's
  `PersistentKeepalive = 25` without flapping on ordinary jitter).

## Error handling

- If `status.json` fetch fails (network blip, branch mid-push): keep
  showing the last successfully fetched snapshot, don't blank the page; log
  to console only.
- If a device in `devices.json` has no entry in `status.json` (e.g.
  brand-new, first cron tick hasn't run since it joined): render it as
  offline/unknown rather than omitting it — the registry is the source of
  truth for *which devices exist*, `status.json` only for *whether they're
  up*.
- If the self-hosted runner is offline (spotifypi down): the workflow run
  simply doesn't happen; `status.json` goes stale. The frontend's
  "updated Xs ago" indicator makes this visible without needing a separate
  alert — this is a personal dashboard, not a paged on-call system.

## Testing

- `status-cron.yml` logic (the `wg show` → `status.json` transform) as a
  small, standalone script (not inlined YAML) so it can be unit-tested
  against a saved sample `wg show wg0 dump` output — deterministic, no live
  mesh access needed for the test itself.
- Manual: `workflow_dispatch` the cron job once, confirm `status.json`
  lands on the `status` branch with the right shape.
- Manual: open the deployed Pages URL, confirm bulbs render correctly for
  at least one online and one offline (or unknown) device, confirm the 30s
  refresh actually re-fetches (watch Network tab).
- Manual: confirm the Welcome card renders and links correctly, hover
  animation matches sibling cards.

## Explicitly out of scope (YAGNI)

- No IPs, endpoints, or handshake timestamps ever exposed to the frontend.
- No auth/access control on the dashboard — it's intentionally minimal
  public info (device names already appear in the public `devices.json`;
  connectivity boolean adds little beyond that).
- No historical/uptime graphing — current-state only.
- No macOS support in `install.sh` — tracked as a separate, later task.
