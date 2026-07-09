#!/bin/bash
# MyVPN hub sync — runs on spotifypi via myvpn-sync.timer (root).
# Pulls the public repo, and for each signed approval not yet live:
# verify -> decrypt PSK -> hot-add peer -> persist. Add-only by design;
# NEVER restarts wg-quick@wg0 (that would drop every live tunnel).
set -euo pipefail

REPO=/opt/myvpn/repo
PIN=/etc/myvpn/allowed_signers   # pinned via SSH at bootstrap — NOT read from the repo
AGE_KEY=/etc/myvpn/age.key
WG_CONF=/etc/wireguard/wg0.conf
SIG_NAMESPACE=myvpn

log() { logger -t myvpn-sync "$*"; echo "[myvpn-sync] $*"; }

git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main   # guards against history rewrites

LIVE_PEERS="$(wg show wg0 peers)"

shopt -s nullglob
for f in "$REPO"/approved-peers/*.json; do
  name="$(basename "$f" .json)"
  pub="$(jq -r .wg_pubkey "$f")"
  ip="$(jq -r .wg_ip "$f")"

  grep -qxF "$pub" <<< "$LIVE_PEERS" && continue

  if ! ssh-keygen -Y verify -f "$PIN" -I "$SIG_NAMESPACE" -n "$SIG_NAMESPACE" \
       -s "$f.sig" < "$f" >/dev/null 2>&1; then
    log "REFUSED $name: signature invalid against pinned signer key"
    continue
  fi
  if ! psk="$(age -d -i "$AGE_KEY" "${f%.json}.psk.age" 2>/dev/null)"; then
    log "REFUSED $name: PSK decryption failed"
    continue
  fi
  if grep -q "AllowedIPs = $ip/32" "$WG_CONF"; then
    log "REFUSED $name: $ip already present in $WG_CONF under a different key"
    continue
  fi

  # hot-add (live tunnels untouched), then persist for reboots
  wg set wg0 peer "$pub" preshared-key <(printf '%s\n' "$psk") allowed-ips "$ip/32"
  {
    echo ""
    echo "# $name (added by myvpn-sync $(date -Iseconds))"
    echo "[Peer]"
    echo "PublicKey = $pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $ip/32"
  } >> "$WG_CONF"
  log "ADDED peer $name ($ip)"
done
