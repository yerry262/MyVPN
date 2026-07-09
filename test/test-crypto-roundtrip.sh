#!/usr/bin/env bash
# Crypto round-trip tests with throwaway keys — no network, no real secrets.
# 1. ssh-keygen -Y sign/verify incl. tamper-must-fail
# 2. dual-recipient age encrypt, decrypt with each recipient
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- signature round-trip ---------------------------------------------------
ssh-keygen -t ed25519 -f signer -N '' -q
echo "myvpn namespaces=\"myvpn\" $(cut -d' ' -f1,2 < signer.pub) test" > allowed_signers
echo '{"name":"testdev","wg_ip":"10.44.0.99"}' > sample.json

ssh-keygen -Y sign -f signer -n myvpn sample.json 2>/dev/null
ssh-keygen -Y verify -f allowed_signers -I myvpn -n myvpn -s sample.json.sig \
  < sample.json >/dev/null || fail "valid signature did not verify"
echo "PASS: valid signature verifies"

echo '{"name":"testdev","wg_ip":"10.44.0.1"}' > tampered.json
if ssh-keygen -Y verify -f allowed_signers -I myvpn -n myvpn -s sample.json.sig \
     < tampered.json >/dev/null 2>&1; then
  fail "tampered content verified — signature scheme broken"
fi
echo "PASS: tampered content refused"

ssh-keygen -t ed25519 -f rogue -N '' -q
ssh-keygen -Y sign -f rogue -n myvpn tampered.json 2>/dev/null
if ssh-keygen -Y verify -f allowed_signers -I myvpn -n myvpn -s tampered.json.sig \
     < tampered.json >/dev/null 2>&1; then
  fail "rogue-key signature verified — pinning broken"
fi
echo "PASS: rogue signer refused"

# --- dual-recipient age round-trip -------------------------------------------
age-keygen -o dev.key 2>/dev/null
age-keygen -o hub.key 2>/dev/null
DEV_R="$(grep -o 'age1.*' dev.key | head -1)"
HUB_R="$(grep -o 'age1.*' hub.key | head -1)"

PSK="$(head -c 32 /dev/urandom | base64)"
printf '%s' "$PSK" | age -r "$DEV_R" -r "$HUB_R" -o psk.age

[ "$(age -d -i dev.key psk.age)" = "$PSK" ] || fail "device recipient cannot decrypt"
echo "PASS: device recipient decrypts"
[ "$(age -d -i hub.key psk.age)" = "$PSK" ] || fail "hub recipient cannot decrypt"
echo "PASS: hub recipient decrypts"

age-keygen -o stranger.key 2>/dev/null
if age -d -i stranger.key psk.age >/dev/null 2>&1; then
  fail "non-recipient decrypted the PSK"
fi
echo "PASS: non-recipient refused"

echo "ALL CRYPTO ROUND-TRIP TESTS PASSED"
