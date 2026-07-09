# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

Self-service onboarding for yerry's home WireGuard mesh (`10.44.0.0/24`).
Devices open join-request PRs; `approve.sh` on Legion signs approvals; the
hub (spotifypi) pulls `main` every 2 min and hot-adds signed peers. Read
`docs/superpowers/specs/2026-07-09-myvpn-design.md` before structural changes.

## Hard rules

- **NEVER commit secrets.** Allowed in-repo: WireGuard *public* keys, age
  recipients/ciphertexts (`*.psk.age`), the signer *public* key. Forbidden:
  private keys, PSK plaintext, anything from `~/CLAUDE_CORNER/wireguard/`
  except `.pub` material.
- The signer private key is `~/CLAUDE_CORNER/wireguard/myvpn-signer` (Legion
  only). The hub's trust pin is `/etc/myvpn/allowed_signers` on the pi,
  delivered over SSH — changing the signer means re-pinning the pi over SSH,
  not just editing `keys/allowed_signers`.
- **Never restart `wg-quick@wg0` on the pi** — it drops every live tunnel.
  Hot-add only (`wg set` / `wg addconf`), which is what `hub/myvpn-sync.sh` does.
- `approve.sh` pushes directly to `main` (documented exception to the
  branch→PR workflow: the approval IS the review). Everything else goes
  branch → PR → merge per `~/CLAUDE_CORNER/CLAUDE.md`.
- Existing mesh members (see `devices.json`) were provisioned manually with
  PSKs held in `~/CLAUDE_CORNER/wireguard/` — never migrate or touch their
  configs from here.

## Testing

- `test/test-crypto-roundtrip.sh` — signature + dual-recipient age round-trips
  (throwaway keys, no network). Run it + `shellcheck ./*.sh hub/*.sh` before
  committing script changes.
- `install.sh --dry-run` with `MYVPN_STATE_DIR=$(mktemp -d)` exercises
  everything up to the PR without touching the system.
- `install.ps1` is UNTESTED on real Windows — flag any change to it as such.

## Related

- Mesh topology, keys, DDNS, UPnP: `~/CLAUDE_CORNER/wireguard/README.md`
- The `join-our-vpn` skill routes phone/QR joins (out of scope here) and
  registry updates after approvals.
