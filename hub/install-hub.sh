#!/bin/bash
# MyVPN hub bootstrap — run ONCE on spotifypi, as root:
#   sudo bash install-hub.sh /path/to/allowed_signers
# The allowed_signers file must be delivered over SSH (pinned trust root),
# never taken from the repo. Prints the pi's age recipient at the end —
# commit that to the repo as keys/pi-age.pub.
set -euo pipefail

REPO_URL=https://github.com/yerry262/MyVPN.git
REPO=/opt/myvpn/repo

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
[ -f "${1:-}" ] || { echo "usage: sudo bash install-hub.sh /path/to/allowed_signers"; exit 1; }

apt-get update -qq
apt-get install -y -qq age git jq >/dev/null

install -d -m 700 /etc/myvpn
install -m 600 "$1" /etc/myvpn/allowed_signers

if [ ! -f /etc/myvpn/age.key ]; then
  (umask 077 && age-keygen -o /etc/myvpn/age.key 2>/dev/null)
fi

if [ ! -d "$REPO/.git" ]; then
  install -d /opt/myvpn
  git clone -q "$REPO_URL" "$REPO"
fi

install -m 755 "$REPO/hub/myvpn-sync.sh" /usr/local/bin/myvpn-sync.sh
install -m 644 "$REPO/hub/myvpn-sync.service" /etc/systemd/system/myvpn-sync.service
install -m 644 "$REPO/hub/myvpn-sync.timer" /etc/systemd/system/myvpn-sync.timer
systemctl daemon-reload
systemctl enable --now myvpn-sync.timer

echo "hub bootstrap complete; timer:"
systemctl status myvpn-sync.timer --no-pager | head -5
echo
echo "PI AGE RECIPIENT (commit to repo as keys/pi-age.pub):"
grep -o 'age1.*' /etc/myvpn/age.key | head -1
