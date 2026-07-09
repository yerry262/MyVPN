# MyVPN — Self-Service WireGuard Mesh Onboarding

**Date:** 2026-07-09
**Repo:** `yerry262/MyVPN` (public)
**Status:** Approved by yerry (conversation, 2026-07-09)

## Goal

One command on a new device (Linux, WSL, or Windows) requests membership in the home
WireGuard mesh (`10.44.0.0/24`); one PR merge + signed approval by yerry admits it.
The hub (spotifypi) registers approved peers automatically by pulling from GitHub —
nobody SSHes anywhere during a routine join. The post-quantum PresharedKey layer is
preserved for every self-service join.

## Trust model

- **Admission gate = yerry's merge + a cryptographic signature from Legion.**
  A dedicated ed25519 SSH signing key (`myvpn-signer`) lives at
  `~/CLAUDE_CORNER/wireguard/myvpn-signer` on Legion and never enters the repo.
- The pi verifies every approval against a **pinned copy** of the signer public key at
  `/etc/myvpn/allowed_signers`, delivered once over SSH — *not* read from the repo.
  A compromised GitHub account can open PRs but cannot mint a valid signature, so the
  pi ignores it. GitHub is transport, not trust.
- Devices verify the same signature against `keys/allowed_signers` pinned at first
  run (TOFU); a later change of signer aborts with a loud warning.
- **Public repo exposes only public-safe data:** hostnames, mesh IPs, WireGuard
  public keys, age recipients and ciphertexts, the signer public key, and the DDNS
  hostname (already public DNS). Private keys, PSK plaintext, and the signer private
  key never touch the repo.
- Only yerry has write access; branch protection requires a PR to `main` with
  `enforce_admins=false` so `approve.sh` (run as yerry) can push approval commits
  directly — the approval *is* the review.

## The loop

1. **Device** runs `install.sh` (Linux/WSL) or `install.ps1` (Windows):
   installs latest deps, generates a WireGuard keypair **and** a single-use age
   keypair locally (private keys never leave the device), picks the next free
   `10.44.0.X` from the registry, opens a PR adding
   `pending-peers/<name>.json` `{name, wg_ip, wg_pubkey, age_recipient,
   endpoint_type, os, requested_at}`, always prints the same block as a
   copy-paste fallback string, then polls `origin/main` for approval.
2. **Yerry approves** on Legion: `./approve.sh <name|PR#>`. It validates the request
   (exactly one new pending file, IP free, key formats sane), merges the PR, runs
   `wg genpsk`, encrypts the PSK with `age -r <device> -r <pi>` (dual recipient —
   both tunnel ends can decrypt the same public ciphertext), signs the approval
   record with `ssh-keygen -Y sign -n myvpn`, appends the device to `devices.json`,
   deletes the pending file, and pushes
   `approved-peers/<name>.{json,sig,psk.age}` to `main`.
3. **Pi auto-registers**: `myvpn-sync.timer` (every 2 min) fetches `origin/main`
   read-only (no GitHub credentials on the pi), and for each approved peer not yet
   live: verifies the signature against the pinned key, decrypts the PSK with
   `/etc/myvpn/age.key`, hot-adds via `wg set wg0 peer <pub> preshared-key …
   allowed-ips 10.44.0.X/32` (never restarts `wg-quick@wg0` — live tunnels are
   untouched), and appends a marked `[Peer]` block to `/etc/wireguard/wg0.conf`
   for reboot persistence. Add-only: revocation stays manual.
4. **Device finishes itself**: its poll sees the approval, verifies the signature,
   decrypts the PSK, writes `/etc/wireguard/wg0.conf` with `PresharedKey`, enables
   `wg-quick@wg0`, confirms a handshake and pings the hub, then shreds the one-time
   age private key.

## Repo layout

```
install.sh          device installer, Linux + WSL (self-clones to ~/.myvpn/repo if curl'd)
install.ps1         device installer, native Windows (winget; UNTESTED until a Windows box runs it)
approve.sh          Legion-only approval tool
devices.json        public registry: name, wg_ip, wg_pubkey, role, endpoint_type, added
keys/allowed_signers   signer public key (devices TOFU-pin; pi's pin is delivered via SSH)
keys/pi-age.pub        pi's age recipient (written after hub bootstrap)
pending-peers/      open join requests (one JSON per device; removed on approval)
approved-peers/     <name>.json + <name>.json.sig + <name>.psk.age
hub/install-hub.sh  one-time pi bootstrap (age key, pinned signer, clone, systemd units)
hub/myvpn-sync.sh   the pull-verify-apply loop
hub/myvpn-sync.{service,timer}
test/test-crypto-roundtrip.sh   sig + dual-recipient age round-trips, tamper must fail
docs/superpowers/specs/         this document
```

## Device installer details

- **Latest versions:** `apt-get update` then `wireguard-tools`/`git`/`jq` from apt,
  `gh` from GitHub's official apt repo, `age` from apt (fallback: latest GitHub
  release binary). Windows: `winget install`/`upgrade` for WireGuard, Git,
  GitHub.cli, FiloSottile.age.
- **Endpoint choice:** stationary-at-home → `192.168.4.228:51820` (LAN);
  roaming → `slconsultingllc.redirectme.net:51820` (DDNS).
- **IP allocation:** lowest free host in `10.44.0.0/24` scanning `devices.json`,
  `approved-peers/`, and `pending-peers/`. Races are resolved at approval time:
  `approve.sh` rejects a conflicting request with a PR comment; the device re-runs.
- **PR flow:** requires `gh auth login` with any GitHub account (public repo).
  Direct branch when the account has push access, fork otherwise.
  No `gh` auth → the fallback string is the deliverable; exit cleanly with instructions.
- **Testability:** env overrides `MYVPN_STATE_DIR`, `MYVPN_IFACE`, `MYVPN_NAME`,
  `MYVPN_ENDPOINT_TYPE`, `MYVPN_ALLOWED_IPS`, `MYVPN_NONINTERACTIVE`; modes
  `--dry-run` (no PR) and `--finish` (resume polling after timeout/reboot).
- Poll every 30 s, give up after 2 h with a `--finish` resume hint.

## Error handling

- Bad/unsigned approval on the pi → skip + loud journal log; never applied.
- Malformed pending JSON → `approve.sh` refuses before merge.
- Pi offline at merge → next timer tick catches up (eventual consistency).
- CGNAT/firewalled device → outbound-only UDP + `PersistentKeepalive = 25`, as today.
- Signer pubkey changed vs pin → device aborts, tells yerry to investigate.

## Existing devices

The five current mesh members (pi .1 hub, legion .2, tank .3, ethereum-node .4,
euro-laptop .5) are seeded into `devices.json` as-is and are **not** migrated —
their configs and PSKs are untouched.

## Out of scope (deliberate)

- Automated revocation / key rotation (manual: `wg set wg0 peer <pub> remove` + conf edit on pi).
- iOS/Android (QR flow stays in the `join-our-vpn` skill).
- Any change to existing device configs.

## Follow-ups outside this repo

- Update `~/CLAUDE_CORNER/wireguard/README.md`, `~/CLAUDE_CORNER/CLAUDE.md`,
  the `join-our-vpn` skill (route Linux/WSL/Windows joins through MyVPN), and memory.
