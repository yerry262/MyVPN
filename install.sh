#!/usr/bin/env bash
# MyVPN device installer — Linux & WSL.
# Requests membership in the home WireGuard mesh, waits for yerry's signed
# approval, then configures and starts the tunnel. Private keys never leave
# this device. See docs/superpowers/specs/2026-07-09-myvpn-design.md.
#
# Usage:
#   ./install.sh                 full flow (request -> poll -> configure)
#   ./install.sh --finish        resume polling after a timeout or reboot
#   ./install.sh --dry-run       generate keys + show the request, no PR, no system changes
#   ./install.sh --with-claude   ...also install Claude Code + always-on remote-control
#                                (combinable with the other flags; runs after the tunnel
#                                is up, or standalone if this device already joined)
#
# Env overrides (mainly for testing):
#   MYVPN_STATE_DIR, MYVPN_IFACE, MYVPN_NAME, MYVPN_ENDPOINT_TYPE (lan|ddns),
#   MYVPN_ALLOWED_IPS, MYVPN_NONINTERACTIVE=1, MYVPN_ACCEPT_NEW_SIGNER=1,
#   MYVPN_RC_NAME (remote-control session name, default = device name)
set -euo pipefail

REPO_SLUG="yerry262/MyVPN"
REPO_URL="https://github.com/${REPO_SLUG}.git"
MESH_CIDR="10.44.0.0/24"
MESH_PREFIX="10.44.0"
HUB_WG_IP="10.44.0.1"
LAN_ENDPOINT="192.168.4.228:51820"
DDNS_ENDPOINT="slconsultingllc.redirectme.net:51820"
SIG_NAMESPACE="myvpn"

STATE_DIR="${MYVPN_STATE_DIR:-$HOME/.myvpn}"
IFACE="${MYVPN_IFACE:-wg0}"
ALLOWED_IPS="${MYVPN_ALLOWED_IPS:-$MESH_CIDR}"
POLL_INTERVAL=30
POLL_TIMEOUT=$((2 * 60 * 60))

MODE="request"
WITH_CLAUDE=0
for arg in "$@"; do
  case "$arg" in
    --finish) MODE="finish" ;;
    --dry-run) MODE="dry-run" ;;
    --with-claude) WITH_CLAUDE=1 ;;
    *) echo "Unknown flag: $arg (expected --finish, --dry-run, --with-claude)" >&2; exit 2 ;;
  esac
done

log() { printf '\e[1;36m[myvpn]\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m[myvpn] ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

SUDO="sudo"
[ "$(id -u)" = 0 ] && SUDO=""

# --- dependencies (always latest available) ------------------------------
ensure_deps() {
  command -v apt-get >/dev/null || die "only apt-based distros are supported (Debian/Ubuntu/Raspbian/WSL)"
  local need=()
  for c in wg git jq curl; do command -v "$c" >/dev/null || need+=("$c"); done
  command -v gh >/dev/null || need+=(gh)
  command -v age >/dev/null || need+=(age)
  [ ${#need[@]} -eq 0 ] && { log "dependencies already present"; return; }

  log "installing: ${need[*]}"
  $SUDO apt-get update -qq
  local pkgs=()
  for c in "${need[@]}"; do
    case "$c" in
      wg) pkgs+=(wireguard-tools) ;;
      gh) ;; # handled below via GitHub's official apt repo
      *) pkgs+=("$c") ;;
    esac
  done
  [ ${#pkgs[@]} -gt 0 ] && $SUDO apt-get install -y "${pkgs[@]}"

  if ! command -v gh >/dev/null; then
    # official gh apt repo => always current, not the distro-frozen version
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
      $SUDO tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
      $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    $SUDO apt-get update -qq && $SUDO apt-get install -y gh
  fi
  command -v age >/dev/null || die "age failed to install (no apt candidate?) — install manually from https://github.com/FiloSottile/age/releases"
}

# --- repo checkout --------------------------------------------------------
ensure_repo() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$script_dir/devices.json" ]; then
    REPO_DIR="$script_dir"
    git -C "$REPO_DIR" fetch -q origin main
  else
    REPO_DIR="$STATE_DIR/repo"
    if [ -d "$REPO_DIR/.git" ]; then
      git -C "$REPO_DIR" fetch -q origin main
    else
      log "cloning $REPO_SLUG to $REPO_DIR"
      git clone -q "$REPO_URL" "$REPO_DIR"
    fi
  fi
}

# --- signer pinning (TOFU) -----------------------------------------------
pin_signer() {
  local repo_signers="$REPO_DIR/keys/allowed_signers"
  [ -f "$repo_signers" ] || die "keys/allowed_signers missing from repo"
  if [ -f "$STATE_DIR/allowed_signers" ]; then
    if ! cmp -s "$repo_signers" "$STATE_DIR/allowed_signers"; then
      [ "${MYVPN_ACCEPT_NEW_SIGNER:-}" = 1 ] ||
        die "SIGNER KEY CHANGED since first run — possible tampering. Verify with yerry, then re-run with MYVPN_ACCEPT_NEW_SIGNER=1"
      cp "$repo_signers" "$STATE_DIR/allowed_signers"
    fi
  else
    cp "$repo_signers" "$STATE_DIR/allowed_signers"
    log "pinned signer key (trust-on-first-use)"
  fi
}

# --- identity -------------------------------------------------------------
gather_identity() {
  if [ -f "$STATE_DIR/name" ]; then
    NAME="$(cat "$STATE_DIR/name")"
    log "resuming as '$NAME'"
    return
  fi
  NAME="${MYVPN_NAME:-}"
  ENDPOINT_TYPE="${MYVPN_ENDPOINT_TYPE:-}"
  if [ -z "$NAME" ]; then
    [ "${MYVPN_NONINTERACTIVE:-}" = 1 ] && die "MYVPN_NONINTERACTIVE=1 requires MYVPN_NAME"
    read -rp "Device name [$(hostname -s)]: " NAME
    NAME="${NAME:-$(hostname -s)}"
  fi
  [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || die "name must be lowercase alnum/hyphens: '$NAME'"
  if [ -z "$ENDPOINT_TYPE" ]; then
    [ "${MYVPN_NONINTERACTIVE:-}" = 1 ] && die "MYVPN_NONINTERACTIVE=1 requires MYVPN_ENDPOINT_TYPE"
    read -rp "Is this device stationary at home (lan) or roaming (ddns)? [ddns]: " ENDPOINT_TYPE
    ENDPOINT_TYPE="${ENDPOINT_TYPE:-ddns}"
  fi
  [[ "$ENDPOINT_TYPE" =~ ^(lan|ddns)$ ]] || die "endpoint type must be 'lan' or 'ddns'"
  echo "$NAME" > "$STATE_DIR/name"
  echo "$ENDPOINT_TYPE" > "$STATE_DIR/endpoint_type"
}

generate_keys() {
  if [ -f "$STATE_DIR/wg.key" ]; then
    log "reusing existing keys in $STATE_DIR"
  else
    (umask 077 && wg genkey > "$STATE_DIR/wg.key")
    wg pubkey < "$STATE_DIR/wg.key" > "$STATE_DIR/wg.pub"
    (umask 077 && age-keygen -o "$STATE_DIR/age.key" 2>/dev/null)
    grep -o 'age1.*' "$STATE_DIR/age.key" | head -1 > "$STATE_DIR/age.pub"
    log "generated WireGuard + age keypairs (private keys stay on this device)"
  fi
  WG_PUB="$(cat "$STATE_DIR/wg.pub")"
  AGE_RECIPIENT="$(cat "$STATE_DIR/age.pub")"
}

pick_ip() {
  if [ -f "$STATE_DIR/ip" ]; then WG_IP="$(cat "$STATE_DIR/ip")"; return; fi
  local used
  used="$( { git -C "$REPO_DIR" show origin/main:devices.json | jq -r '.devices[].wg_ip'
             for f in $(git -C "$REPO_DIR" ls-tree --name-only origin/main pending-peers/ approved-peers/ 2>/dev/null | grep '\.json$' || true); do
               git -C "$REPO_DIR" show "origin/main:$f" | jq -r '.wg_ip'
             done; } | sort -u)"
  local i
  for i in $(seq 2 254); do
    if ! grep -qx "$MESH_PREFIX.$i" <<< "$used"; then WG_IP="$MESH_PREFIX.$i"; break; fi
  done
  [ -n "${WG_IP:-}" ] || die "no free IP in $MESH_CIDR"
  echo "$WG_IP" > "$STATE_DIR/ip"
}

request_block() {
  # shellcheck disable=SC1091  # /etc/os-release is best-effort, for the os label only
  jq -n --arg name "$NAME" --arg ip "$WG_IP" --arg pub "$WG_PUB" \
        --arg age "$AGE_RECIPIENT" --arg ep "$(cat "$STATE_DIR/endpoint_type")" \
        --arg os "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-linux}")" \
        --arg ts "$(date -Iseconds)" \
        '{name:$name, wg_ip:$ip, wg_pubkey:$pub, age_recipient:$age, endpoint_type:$ep, os:$os, requested_at:$ts}'
}

open_pr() {
  local branch="join/$NAME"
  if git -C "$REPO_DIR" show "origin/main:approved-peers/$NAME.json" &>/dev/null; then
    log "already approved on main — skipping PR"; return
  fi
  if ! gh auth status &>/dev/null; then
    log "gh is not authenticated — no PR opened."
    log "Run 'gh auth login' and re-run, OR paste the request block above to yerry."
    exit 0
  fi
  local head_ref="$branch"
  local perm
  perm="$(gh repo view "$REPO_SLUG" --json viewerPermission -q .viewerPermission 2>/dev/null || echo NONE)"
  git -C "$REPO_DIR" checkout -q -B "$branch" origin/main
  mkdir -p "$REPO_DIR/pending-peers"
  request_block > "$REPO_DIR/pending-peers/$NAME.json"
  git -C "$REPO_DIR" add "pending-peers/$NAME.json"
  git -C "$REPO_DIR" -c user.name="myvpn-installer" -c user.email="myvpn@$NAME.local" \
    commit -q -m "Join request: $NAME ($WG_IP)"
  if [ "$perm" = "ADMIN" ] || [ "$perm" = "WRITE" ]; then
    git -C "$REPO_DIR" push -q -f origin "$branch"
  else
    gh repo fork "$REPO_SLUG" --remote --remote-name fork &>/dev/null || true
    git -C "$REPO_DIR" push -q -f fork "$branch"
    head_ref="$(gh api user -q .login):$branch"
  fi
  if gh pr view "$branch" --repo "$REPO_SLUG" &>/dev/null; then
    log "PR already open"
  else
    gh pr create --repo "$REPO_SLUG" --base main --head "$head_ref" \
      --title "Join request: $NAME ($WG_IP)" \
      --body "Automated join request from \`install.sh\`. Approve with \`./approve.sh $NAME\` on Legion." >/dev/null
    log "PR opened: join request for $NAME ($WG_IP)"
  fi
  git -C "$REPO_DIR" checkout -q origin/main -- devices.json 2>/dev/null || true
}

# --- approval poll + tunnel bring-up --------------------------------------
wait_for_approval() {
  log "waiting for yerry to approve (polling every ${POLL_INTERVAL}s, up to 2h)..."
  local waited=0
  while true; do
    git -C "$REPO_DIR" fetch -q origin main || true
    if git -C "$REPO_DIR" show "origin/main:approved-peers/$NAME.json" &>/dev/null; then
      log "approval found on main"
      return
    fi
    [ "$waited" -ge "$POLL_TIMEOUT" ] &&
      die "timed out after 2h — once approved, resume with: ./install.sh --finish"
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
  done
}

configure_tunnel() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  git -C "$REPO_DIR" show "origin/main:approved-peers/$NAME.json" > "$tmp/approved.json"
  git -C "$REPO_DIR" show "origin/main:approved-peers/$NAME.json.sig" > "$tmp/approved.json.sig"
  git -C "$REPO_DIR" show "origin/main:approved-peers/$NAME.psk.age" > "$tmp/psk.age"

  ssh-keygen -Y verify -f "$STATE_DIR/allowed_signers" -I "$SIG_NAMESPACE" \
    -n "$SIG_NAMESPACE" -s "$tmp/approved.json.sig" < "$tmp/approved.json" >/dev/null ||
    die "approval SIGNATURE INVALID — refusing to join. Tell yerry."
  log "approval signature verified against pinned signer key"

  local approved_ip approved_pub
  approved_ip="$(jq -r .wg_ip "$tmp/approved.json")"
  approved_pub="$(jq -r .wg_pubkey "$tmp/approved.json")"
  [ "$approved_pub" = "$WG_PUB" ] || die "approved pubkey doesn't match ours — was the request tampered with?"
  WG_IP="$approved_ip"

  local psk; psk="$(age -d -i "$STATE_DIR/age.key" "$tmp/psk.age")" ||
    die "PSK decryption failed"
  log "preshared key decrypted (post-quantum layer active)"

  local hub_pub endpoint
  hub_pub="$(git -C "$REPO_DIR" show origin/main:devices.json | jq -r '.devices[] | select(.role=="hub") | .wg_pubkey')"
  case "$(cat "$STATE_DIR/endpoint_type")" in
    lan) endpoint="$LAN_ENDPOINT" ;;
    *)   endpoint="$DDNS_ENDPOINT" ;;
  esac

  (umask 077 && cat > "$tmp/$IFACE.conf" <<EOF
[Interface]
Address = $WG_IP/24
PrivateKey = $(cat "$STATE_DIR/wg.key")

[Peer]
# spotifypi (hub)
PublicKey = $hub_pub
PresharedKey = $psk
Endpoint = $endpoint
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF
  )
  $SUDO install -m 600 -o root -g root "$tmp/$IFACE.conf" "/etc/wireguard/$IFACE.conf"

  if [ -d /run/systemd/system ]; then
    $SUDO systemctl enable --now "wg-quick@$IFACE" >/dev/null 2>&1 ||
      { $SUDO wg-quick down "$IFACE" >/dev/null 2>&1 || true; $SUDO wg-quick up "$IFACE"; }
  else
    $SUDO wg-quick up "$IFACE"  # non-systemd WSL: add to your startup yourself
  fi

  # the hub's sync timer runs every 2 min — allow for a full cycle plus slack
  log "waiting for first handshake (hub registers us within ~2 min)..."
  local tries=0
  until [ "$($SUDO wg show "$IFACE" latest-handshakes | awk '{print $2}')" -gt 0 ] 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 70 ] && die "no handshake after 3.5 min — check firewall/endpoint, then: sudo wg show $IFACE"
    sleep 3
  done
  ping -c 2 -W 3 "$HUB_WG_IP" >/dev/null || die "handshake OK but hub unreachable — routing issue?"

  shred -u "$STATE_DIR/age.key" 2>/dev/null || rm -f "$STATE_DIR/age.key"
  shred -u "$STATE_DIR/wg.key" 2>/dev/null || rm -f "$STATE_DIR/wg.key"

  log "SUCCESS — $NAME is on the mesh as $WG_IP (handshake + hub ping verified)"
  log "one-time private keys shredded; config lives in /etc/wireguard/$IFACE.conf"
}

# --- Claude Code + always-on remote-control (--with-claude) ----------------
setup_claude() {
  log "setting up Claude Code + remote-control autostart"
  local claude_bin="$HOME/.local/bin/claude"
  command -v claude >/dev/null && claude_bin="$(command -v claude)"
  if [ ! -x "$claude_bin" ]; then
    curl -fsSL https://claude.ai/install.sh | bash
    claude_bin="$HOME/.local/bin/claude"
    # shellcheck disable=SC2016  # literal $HOME/$PATH belongs in .bashrc unexpanded
    grep -q '\.local/bin' "$HOME/.bashrc" 2>/dev/null ||
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  fi

  if [ ! -f "$HOME/.claude/.credentials.json" ]; then
    if [ "${MYVPN_NONINTERACTIVE:-}" = 1 ]; then
      log "Claude needs a one-time interactive login: run 'claude', complete OAuth, then re-run ./install.sh --with-claude"
      return
    fi
    log "one-time interactive login needed — launching claude; finish the OAuth flow, then /exit"
    "$claude_bin" || true
    [ -f "$HOME/.claude/.credentials.json" ] ||
      { log "still not logged in — after logging in, re-run: ./install.sh --with-claude"; return; }
  fi

  # pre-accept workspace trust: the service can't answer the dialog (recipe gotcha #6)
  python3 - "$HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
path = os.path.join(home, ".claude.json")
data = {}
if os.path.exists(path):
    with open(path) as f: data = json.load(f)
data.setdefault("projects", {}).setdefault(home, {})["hasTrustDialogAccepted"] = True
with open(path, "w") as f: json.dump(data, f, indent=2)
PY

  local rc_name="${MYVPN_RC_NAME:-${NAME:-$(hostname -s)}}"
  local rc_cmd="$claude_bin remote-control --name $rc_name --permission-mode bypassPermissions"

  if grep -qi microsoft /proc/version 2>/dev/null; then
    # WSL: tmux daemon (systemd linger can't boot WSL or keep the VM alive — tank/euro pattern)
    command -v tmux >/dev/null || $SUDO apt-get install -y tmux
    cat > "$HOME/.local/bin/claude-rc-daemon.sh" <<EOF
#!/usr/bin/env bash
# supervises claude remote-control in tmux session 'rc'; keeps the WSL VM alive
cd "\$HOME"
while true; do
  tmux has-session -t rc 2>/dev/null || tmux new-session -d -s rc -c "\$HOME" "$rc_cmd"
  sleep 30
done
EOF
    chmod +x "$HOME/.local/bin/claude-rc-daemon.sh"
    pgrep -f claude-rc-daemon.sh >/dev/null ||
      nohup "$HOME/.local/bin/claude-rc-daemon.sh" >/dev/null 2>&1 &
    local startup="" vbs distro="${WSL_DISTRO_NAME:-Ubuntu}" d
    for d in /mnt/c/Users/*/AppData/Roaming/Microsoft/Windows/"Start Menu"/Programs/Startup; do
      [ -d "$d" ] && { startup="$d"; break; }
    done
    if [ -n "$startup" ] && [ -w "$startup" ]; then
      vbs="$startup/ClaudeRC.vbs"
      printf 'CreateObject("WScript.Shell").Run "wsl.exe -d %s -u %s -- %s/.local/bin/claude-rc-daemon.sh", 0\r\n' \
        "$distro" "$USER" "$HOME" > "$vbs"
      log "RC daemon running in tmux 'rc'; autostart VBS written to Windows Startup ($vbs)"
    else
      log "RC daemon running in tmux 'rc' — Windows Startup folder not writable; add autostart manually (see euro-laptop VBS pattern)"
    fi
  elif [ -d /run/systemd/system ]; then
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/claude-remote-control.service" <<EOF
[Unit]
Description=Claude Code Remote Control
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$rc_cmd
WorkingDirectory=$HOME
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    $SUDO loginctl enable-linger "$USER"
    systemctl --user daemon-reload
    systemctl --user enable --now claude-remote-control.service
    sleep 3
    if systemctl --user is-active --quiet claude-remote-control.service; then
      log "remote-control service active (session '$rc_name') — check the Claude app for it"
    else
      log "service not active yet — check: journalctl --user -u claude-remote-control -n 20"
    fi
  else
    log "no systemd and not WSL — start manually: $rc_cmd"
  fi
}

# --- main ------------------------------------------------------------------
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
ensure_deps
ensure_repo
pin_signer
gather_identity
generate_keys
pick_ip

if [ "$MODE" != "finish" ]; then
  echo
  log "join request (paste this to yerry if the PR path fails):"
  echo "----------------------------------------------------------------"
  request_block
  echo "----------------------------------------------------------------"
fi

case "$MODE" in
  dry-run) log "dry run — stopping before PR / system changes"; exit 0 ;;
  request) open_pr ;;
esac

# already on the mesh (e.g. re-run with --with-claude only)? skip the join
if [ -f "/etc/wireguard/$IFACE.conf" ] &&
   [ "$($SUDO wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')" -gt 0 ] 2>/dev/null; then
  log "already joined ($IFACE has a live handshake) — skipping join flow"
else
  wait_for_approval
  configure_tunnel
fi

[ "$WITH_CLAUDE" = 1 ] && setup_claude
log "all done"
