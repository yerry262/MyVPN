# MyVPN device installer — native Windows (PowerShell, run as Administrator).
# Same flow as install.sh: request -> yerry approves -> tunnel up with PSK.
# STATUS: UNTESTED on real Windows so far — WSL boxes should use install.sh instead.
#
# Usage:
#   .\install.ps1              full flow
#   .\install.ps1 -Finish      resume polling after approval
#   .\install.ps1 -DryRun      keys + request only, no PR, no system changes
param(
    [switch]$Finish,
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"

$RepoSlug   = "yerry262/MyVPN"
$RepoUrl    = "https://github.com/$RepoSlug.git"
$MeshPrefix = "10.44.0"
$HubWgIp    = "10.44.0.1"
$LanEndpoint  = "192.168.4.228:51820"
$DdnsEndpoint = "slconsultingllc.redirectme.net:51820"
$SigNamespace = "myvpn"
$StateDir = if ($env:MYVPN_STATE_DIR) { $env:MYVPN_STATE_DIR } else { "$env:USERPROFILE\.myvpn" }

function Log($msg) { Write-Host "[myvpn] $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "[myvpn] ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- dependencies (latest via winget) --------------------------------------
function Ensure-Deps {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Die "winget not found — update Windows / install App Installer" }
    foreach ($pkg in @(
        @{ id = "WireGuard.WireGuard"; probe = "C:\Program Files\WireGuard\wg.exe" },
        @{ id = "Git.Git";             probe = "git" },
        @{ id = "GitHub.cli";          probe = "gh" },
        @{ id = "FiloSottile.age";     probe = "age" }
    )) {
        $present = if ($pkg.probe -like "*\*") { Test-Path $pkg.probe } else { [bool](Get-Command $pkg.probe -ErrorAction SilentlyContinue) }
        if (-not $present) {
            Log "installing $($pkg.id)"
            winget install --id $pkg.id -e --accept-source-agreements --accept-package-agreements | Out-Null
        }
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $script:Wg = "C:\Program Files\WireGuard\wg.exe"
    if (-not (Test-Path $Wg)) { Die "wg.exe not found after install" }
}

function Ensure-Repo {
    $script:RepoDir = "$StateDir\repo"
    if (Test-Path "$RepoDir\.git") { git -C $RepoDir fetch -q origin main }
    else { Log "cloning $RepoSlug"; git clone -q $RepoUrl $RepoDir }
}

function Pin-Signer {
    $repoSigners = "$RepoDir\keys\allowed_signers"
    $pin = "$StateDir\allowed_signers"
    if (Test-Path $pin) {
        if ((Get-FileHash $pin).Hash -ne (Get-FileHash $repoSigners).Hash) {
            if ($env:MYVPN_ACCEPT_NEW_SIGNER -ne "1") { Die "SIGNER KEY CHANGED since first run — verify with yerry, then set MYVPN_ACCEPT_NEW_SIGNER=1" }
            Copy-Item $repoSigners $pin -Force
        }
    } else { Copy-Item $repoSigners $pin; Log "pinned signer key (trust-on-first-use)" }
}

function Gather-Identity {
    if (Test-Path "$StateDir\name") { $script:Name = Get-Content "$StateDir\name"; Log "resuming as '$Name'"; return }
    $script:Name = if ($env:MYVPN_NAME) { $env:MYVPN_NAME } else { Read-Host "Device name [$env:COMPUTERNAME]" }
    if (-not $Name) { $script:Name = $env:COMPUTERNAME.ToLower() }
    $script:Name = $Name.ToLower()
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]{1,30}$') { Die "name must be lowercase alnum/hyphens" }
    $script:EndpointType = if ($env:MYVPN_ENDPOINT_TYPE) { $env:MYVPN_ENDPOINT_TYPE } else { Read-Host "stationary at home (lan) or roaming (ddns)? [ddns]" }
    if (-not $EndpointType) { $script:EndpointType = "ddns" }
    if ($EndpointType -notin @("lan", "ddns")) { Die "endpoint type must be lan or ddns" }
    Set-Content "$StateDir\name" $Name
    Set-Content "$StateDir\endpoint_type" $EndpointType
}

function Generate-Keys {
    if (-not (Test-Path "$StateDir\wg.key")) {
        (& $Wg genkey) | Set-Content "$StateDir\wg.key"
        Get-Content "$StateDir\wg.key" | & $Wg pubkey | Set-Content "$StateDir\wg.pub"
        age-keygen -o "$StateDir\age.key" 2>$null
        (Select-String -Path "$StateDir\age.key" -Pattern 'age1\S+').Matches[0].Value | Set-Content "$StateDir\age.pub"
        Log "generated WireGuard + age keypairs locally"
    }
    $script:WgPub = Get-Content "$StateDir\wg.pub"
    $script:AgeRecipient = Get-Content "$StateDir\age.pub"
}

function Pick-Ip {
    if (Test-Path "$StateDir\ip") { $script:WgIp = Get-Content "$StateDir\ip"; return }
    $used = @()
    $used += (git -C $RepoDir show origin/main:devices.json | ConvertFrom-Json).devices.wg_ip
    foreach ($dir in @("pending-peers", "approved-peers")) {
        foreach ($f in (git -C $RepoDir ls-tree --name-only origin/main "$dir/" 2>$null | Where-Object { $_ -like "*.json" })) {
            $used += (git -C $RepoDir show "origin/main:$f" | ConvertFrom-Json).wg_ip
        }
    }
    foreach ($i in 2..254) {
        if ("$MeshPrefix.$i" -notin $used) { $script:WgIp = "$MeshPrefix.$i"; break }
    }
    if (-not $WgIp) { Die "no free IP" }
    Set-Content "$StateDir\ip" $WgIp
}

function Request-Json {
    [ordered]@{
        name          = $Name
        wg_ip         = $WgIp
        wg_pubkey     = $WgPub
        age_recipient = $AgeRecipient
        endpoint_type = (Get-Content "$StateDir\endpoint_type")
        os            = "windows $([Environment]::OSVersion.Version)"
        requested_at  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
    } | ConvertTo-Json
}

function Open-PR {
    $branch = "join/$Name"
    git -C $RepoDir show "origin/main:approved-peers/$Name.json" 2>$null
    if ($LASTEXITCODE -eq 0) { Log "already approved — skipping PR"; return }
    gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) { Log "gh not authenticated — run 'gh auth login', or paste the request block to yerry"; exit 0 }
    git -C $RepoDir checkout -q -B $branch origin/main
    New-Item -ItemType Directory -Force "$RepoDir\pending-peers" | Out-Null
    Request-Json | Set-Content "$RepoDir\pending-peers\$Name.json"
    git -C $RepoDir add "pending-peers/$Name.json"
    git -C $RepoDir -c user.name=myvpn-installer -c user.email="myvpn@$Name.local" commit -q -m "Join request: $Name ($WgIp)"
    $perm = gh repo view $RepoSlug --json viewerPermission -q .viewerPermission 2>$null
    $headRef = $branch
    if ($perm -in @("ADMIN", "WRITE")) {
        git -C $RepoDir push -q -f origin $branch
    } else {
        gh repo fork $RepoSlug --remote --remote-name fork 2>$null
        git -C $RepoDir push -q -f fork $branch
        $headRef = "$(gh api user -q .login):$branch"
    }
    gh pr create --repo $RepoSlug --base main --head $headRef --title "Join request: $Name ($WgIp)" --body "Automated join request from install.ps1. Approve with ./approve.sh $Name on Legion." | Out-Null
    Log "PR opened: join request for $Name ($WgIp)"
}

function Wait-Approval {
    Log "waiting for approval (30s polls, up to 2h)..."
    $deadline = (Get-Date).AddHours(2)
    while ($true) {
        git -C $RepoDir fetch -q origin main 2>$null
        git -C $RepoDir show "origin/main:approved-peers/$Name.json" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Log "approval found"; return }
        if ((Get-Date) -gt $deadline) { Die "timed out — resume later with: .\install.ps1 -Finish" }
        Start-Sleep 30
    }
}

function Configure-Tunnel {
    $tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [guid]::NewGuid()) -Force
    git -C $RepoDir show "origin/main:approved-peers/$Name.json" | Set-Content "$tmp\approved.json" -NoNewline
    git -C $RepoDir show "origin/main:approved-peers/$Name.json.sig" | Set-Content "$tmp\approved.json.sig"
    git -C $RepoDir show "origin/main:approved-peers/$Name.psk.age" | Set-Content "$tmp\psk.age" -AsByteStream

    Get-Content "$tmp\approved.json" -Raw | ssh-keygen -Y verify -f "$StateDir\allowed_signers" -I $SigNamespace -n $SigNamespace -s "$tmp\approved.json.sig"
    if ($LASTEXITCODE -ne 0) { Die "approval SIGNATURE INVALID — refusing to join. Tell yerry." }
    Log "approval signature verified"

    $approved = Get-Content "$tmp\approved.json" | ConvertFrom-Json
    if ($approved.wg_pubkey -ne $WgPub) { Die "approved pubkey doesn't match ours" }
    $script:WgIp = $approved.wg_ip

    $psk = age -d -i "$StateDir\age.key" "$tmp\psk.age"
    if ($LASTEXITCODE -ne 0) { Die "PSK decryption failed" }
    Log "preshared key decrypted (post-quantum layer active)"

    $hubPub = ((git -C $RepoDir show origin/main:devices.json | ConvertFrom-Json).devices | Where-Object role -eq hub).wg_pubkey
    $endpoint = if ((Get-Content "$StateDir\endpoint_type") -eq "lan") { $LanEndpoint } else { $DdnsEndpoint }

    $conf = @"
[Interface]
Address = $WgIp/24
PrivateKey = $(Get-Content "$StateDir\wg.key")

[Peer]
# spotifypi (hub)
PublicKey = $hubPub
PresharedKey = $psk
Endpoint = $endpoint
AllowedIPs = $(if ($env:MYVPN_ALLOWED_IPS) { $env:MYVPN_ALLOWED_IPS } else { "10.44.0.0/24" })
PersistentKeepalive = 25
"@
    $confPath = "$StateDir\myvpn.conf"
    Set-Content $confPath $conf
    & "C:\Program Files\WireGuard\wireguard.exe" /installtunnelservice $confPath
    Start-Sleep 5
    if (-not (Test-Connection $HubWgIp -Count 2 -Quiet)) { Die "tunnel installed but hub unreachable — check 'wg show' / firewall" }

    Remove-Item "$StateDir\age.key", "$StateDir\wg.key" -Force
    Remove-Item $tmp -Recurse -Force
    Log "SUCCESS — $Name is on the mesh as $WgIp (hub ping verified)"
}

# --- main -------------------------------------------------------------------
New-Item -ItemType Directory -Force $StateDir | Out-Null
Ensure-Deps
Ensure-Repo
Pin-Signer
Gather-Identity
Generate-Keys
Pick-Ip

if (-not $Finish) {
    Log "join request (paste to yerry if the PR path fails):"
    Write-Host "----------------------------------------------------------------"
    Request-Json
    Write-Host "----------------------------------------------------------------"
}
if ($DryRun) { Log "dry run — stopping before PR / system changes"; exit 0 }
if (-not $Finish) { Open-PR }
Wait-Approval
Configure-Tunnel
