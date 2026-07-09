#!/usr/bin/env bash
# MyVPN approval tool — run on Legion only (needs the signer private key).
# Validates a pending join request, merges its PR, mints + encrypts the PSK,
# signs the approval, and pushes it to main for the pi + device to pick up.
#
# Usage: ./approve.sh <device-name | PR-number>
set -euo pipefail

REPO_SLUG="yerry262/MyVPN"
SIGNER="${MYVPN_SIGNER:-$HOME/CLAUDE_CORNER/wireguard/myvpn-signer}"
SIG_NAMESPACE="myvpn"

log() { printf '\e[1;35m[approve]\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m[approve] ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: ./approve.sh <device-name | PR-number>"
[ -f "$SIGNER" ] || die "signer key not found at $SIGNER — is this Legion?"
for c in gh wg age jq ssh-keygen; do command -v "$c" >/dev/null || die "missing: $c"; done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# --- resolve the PR --------------------------------------------------------
if [[ "$1" =~ ^[0-9]+$ ]]; then
  PR="$1"
else
  PR="$(gh pr list --repo "$REPO_SLUG" --state open --json number,files \
    -q ".[] | select(.files[].path == \"pending-peers/$1.json\") | .number" | head -1)"
  [ -n "$PR" ] || die "no open PR adds pending-peers/$1.json"
fi

# --- validate: exactly one added file, in pending-peers/ -------------------
mapfile -t FILES < <(gh pr view "$PR" --repo "$REPO_SLUG" --json files -q '.files[].path')
[ ${#FILES[@]} -eq 1 ] || die "PR #$PR touches ${#FILES[@]} files — a join request must add exactly one"
[[ "${FILES[0]}" =~ ^pending-peers/[a-z0-9][a-z0-9-]{1,30}\.json$ ]] ||
  die "PR #$PR touches '${FILES[0]}' — not a valid pending-peers file"
NAME="$(basename "${FILES[0]}" .json)"

HEAD_SHA="$(gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid -q .headRefOid)"
REQ_JSON="$(gh api "repos/$REPO_SLUG/contents/${FILES[0]}?ref=$HEAD_SHA" -q .content | base64 -d)"

# --- validate request contents ---------------------------------------------
jq -e . <<< "$REQ_JSON" >/dev/null || die "request is not valid JSON"
WG_IP="$(jq -r .wg_ip <<< "$REQ_JSON")"
WG_PUB="$(jq -r .wg_pubkey <<< "$REQ_JSON")"
AGE_RECIPIENT="$(jq -r .age_recipient <<< "$REQ_JSON")"
[ "$(jq -r .name <<< "$REQ_JSON")" = "$NAME" ] || die "name in JSON doesn't match filename"
[[ "$WG_IP" =~ ^10\.44\.0\.([2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$ ]] || die "bad wg_ip: $WG_IP"
[[ "$WG_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "bad wg_pubkey format"
[[ "$AGE_RECIPIENT" =~ ^age1[a-z0-9]+$ ]] || die "bad age_recipient format"

git fetch -q origin main
if git show origin/main:devices.json | jq -e --arg ip "$WG_IP" --arg pub "$WG_PUB" \
     '.devices[] | select(.wg_ip == $ip or .wg_pubkey == $pub)' >/dev/null; then
  gh pr comment "$PR" --repo "$REPO_SLUG" --body "IP/key conflict with an existing device — re-run install.sh to pick a fresh IP." >/dev/null
  die "conflict: $WG_IP or that pubkey is already registered (commented on PR #$PR)"
fi

log "PR #$PR: $NAME requests $WG_IP — merging"
gh pr merge "$PR" --repo "$REPO_SLUG" --squash --delete-branch >/dev/null
git fetch -q origin main && git checkout -q main && git pull -q --ff-only origin main

# --- mint PSK (dual-recipient: device + pi), sign, register ----------------
PI_RECIPIENT="$(cat keys/pi-age.pub)"
mkdir -p approved-peers
jq --arg ts "$(date -Iseconds)" '. + {approved_at: $ts}' <<< "$REQ_JSON" > "approved-peers/$NAME.json"
wg genpsk | age -r "$AGE_RECIPIENT" -r "$PI_RECIPIENT" -o "approved-peers/$NAME.psk.age"
ssh-keygen -Y sign -f "$SIGNER" -n "$SIG_NAMESPACE" "approved-peers/$NAME.json" 2>/dev/null
jq --argjson dev "$(jq '{name, wg_ip, wg_pubkey, endpoint_type} + {role:"spoke", added:(.requested_at[:10])}' "approved-peers/$NAME.json")" \
  '.devices += [$dev] | .devices |= sort_by(.wg_ip | split(".") | map(tonumber))' devices.json > devices.json.tmp
mv devices.json.tmp devices.json
git rm -q "pending-peers/$NAME.json"

git add "approved-peers/$NAME.json" "approved-peers/$NAME.json.sig" "approved-peers/$NAME.psk.age" devices.json
git commit -q -m "Approve $NAME ($WG_IP)

Signed approval + dual-recipient PSK. Pi will hot-add within ~2 min.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -q origin main

log "APPROVED: $NAME as $WG_IP"
log "pi will register it within ~2 min; the device's installer finishes on its own"
log "reminder: update wireguard/README.md, CLAUDE.md and memory (or let the join-our-vpn skill do it)"
