#!/usr/bin/env bash
# Unit test for scripts/compute_status.py against a saved sample `wg show
# wg0 dump` output — deterministic, no live mesh access needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/devices.json" <<'EOF'
{
  "devices": [
    {"name": "spotifypi", "role": "hub", "wg_pubkey": "HUB0"},
    {"name": "legion", "wg_pubkey": "AAAA"},
    {"name": "tank", "wg_pubkey": "BBBB"},
    {"name": "stale-device", "wg_pubkey": "CCCC"},
    {"name": "never-connected", "wg_pubkey": "DDDD"}
  ]
}
EOF

# fixed "now" for determinism: 1000000000
# spotifypi: hub, has NO peer entry in its own dump (peers are others
#   connecting to it, not itself) -> must still report online=true
# legion: handshake 60s ago -> online
# tank:   handshake 170s ago -> online (just under 180s threshold)
# stale-device: handshake 300s ago -> offline
# never-connected: handshake 0 (never) -> offline
# unregistered peer (EEEE) present in dump but not in devices.json -> ignored
cat > "$tmp/dump.txt" <<EOF
privkey	pubkey	51820	off
AAAA	psk	1.2.3.4:51820	10.44.0.2/32	999999940	100	200	25
BBBB	psk	1.2.3.4:51820	10.44.0.3/32	999999830	100	200	25
CCCC	psk	1.2.3.4:51820	10.44.0.4/32	999999700	100	200	25
DDDD	psk	1.2.3.4:51820	10.44.0.5/32	0	0	0	25
EEEE	psk	1.2.3.4:51820	10.44.0.99/32	1000000000	100	200	25
EOF

actual="$(python3 "$REPO_DIR/scripts/compute_status.py" "$tmp/devices.json" --now 1000000000 < "$tmp/dump.txt")"
expected='[
  {
    "name": "spotifypi",
    "online": true
  },
  {
    "name": "legion",
    "online": true
  },
  {
    "name": "tank",
    "online": true
  },
  {
    "name": "stale-device",
    "online": false
  },
  {
    "name": "never-connected",
    "online": false
  }
]'

if [ "$actual" = "$expected" ]; then
  echo "PASS: compute_status.py"
else
  echo "FAIL: compute_status.py"
  echo "--- expected ---"; echo "$expected"
  echo "--- actual ---"; echo "$actual"
  exit 1
fi
