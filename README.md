# MyVPN

Self-service onboarding for a self-hosted WireGuard mesh (`10.44.0.0/24`).
One command on the new device requests membership; one merged PR + signed
approval admits it; the hub registers it automatically. Post-quantum
PresharedKey layer included on every join.

## Join (Linux / WSL)

```bash
git clone https://github.com/yerry262/MyVPN && cd MyVPN && ./install.sh
```

or without cloning first:

```bash
curl -fsSL https://raw.githubusercontent.com/yerry262/MyVPN/main/install.sh | bash
```

The script installs its own dependencies (latest `wireguard-tools`, `gh` from
GitHub's official apt repo, `age`), generates keys **locally** (private keys
never leave the device), opens a join-request PR, prints a copy-paste fallback
block, then waits. Once the PR is approved it verifies the signed approval,
decrypts its preshared key, brings the tunnel up, and confirms a handshake +
hub ping on its own.

Flags:

| Flag | Meaning |
|---|---|
| `--finish` | resume waiting after a timeout or reboot |
| `--dry-run` | generate keys + show the request; no PR, no system changes |
| `--with-claude` | also install Claude Code + an always-on `claude remote-control` session (systemd service, or tmux daemon + Windows-Startup VBS on WSL) |

## Join (native Windows)

```powershell
git clone https://github.com/yerry262/MyVPN; cd MyVPN; .\install.ps1   # as Administrator
```

> **UNTESTED** so far on real Windows — WSL boxes should use `install.sh`.

## Approve (Legion only)

```bash
./approve.sh <device-name | PR#>
```

Validates the request, merges the PR, mints a PSK encrypted to *both* the
device and the hub (`age`, dual recipient), signs the approval with the
`myvpn-signer` key, and pushes to `main`. The hub picks it up within ~2 min.

## How trust works

- **Merging a PR is not what admits a device — the signature is.** The hub
  only applies approvals signed by the `myvpn-signer` key (which lives on
  Legion, never in this repo), verified against a copy pinned on the hub over
  SSH at bootstrap. A compromised GitHub account can open PRs; it cannot sign.
- Everything in this repo is public-safe: hostnames, mesh IPs, WireGuard
  *public* keys, age ciphertexts, the signer *public* key. Private keys and
  PSK plaintext never touch the repo.
- **No GitHub secrets, variables, or deploy keys are needed — by design.**
  The hub pulls read-only; devices authenticate as any GitHub account just to
  open a PR; approvals are minted on Legion. There is nothing here to leak.

## Layout

```
install.sh / install.ps1   device installers (self-contained, install own deps)
approve.sh                 Legion-side approval (needs the signer private key)
devices.json               public registry of mesh members
keys/allowed_signers       signer public key (devices pin on first use)
keys/pi-age.pub            hub's age recipient
pending-peers/             open join requests (one JSON each; removed on approval)
approved-peers/            signed approvals: <name>.json + .json.sig + .psk.age
hub/                       hub bootstrap + sync script + systemd units
test/                      crypto round-trip tests (also run in CI)
docs/superpowers/specs/    design doc
```

## Hub bootstrap (once, already done for spotifypi)

```bash
scp keys/allowed_signers hub/install-hub.sh <hub>:/tmp/
ssh <hub> 'sudo bash /tmp/install-hub.sh /tmp/allowed_signers'
# commit the printed age recipient as keys/pi-age.pub
```

Revocation is deliberately manual: `sudo wg set wg0 peer <pubkey> remove` on
the hub + delete its `[Peer]` block from `/etc/wireguard/wg0.conf` and its
files from `approved-peers/` + `devices.json`.
