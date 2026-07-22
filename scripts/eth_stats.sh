#!/usr/bin/env bash
# Pull live stats from the Ethereum node box over its stable WireGuard IP
# (10.44.0.4) so this keeps working whether we're on the LAN or off it, and
# doesn't break when the LAN DHCP lease changes (see machine_ethereum_node memory).
# Geth RPC (:8545) vhost-checks the hostname, so we hit the IP with "Host: localhost".
# Prysm beacon API (:3500) and metrics (:8080) are LAN-open as of 2026-07-08.
set -euo pipefail

NODE_IP=10.44.0.4

rpc() {
  curl -s -m 5 -X POST -H 'Content-Type: application/json' -H 'Host: localhost' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":[],\"id\":1}" \
    "http://$NODE_IP:8545" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"])'
}

echo "== Geth (execution) =="
echo "client:   $(rpc web3_clientVersion)"
echo "syncing:  $(rpc eth_syncing)"
block_hex=$(rpc eth_blockNumber)
echo "block:    $((block_hex)) ($block_hex)"
peers_hex=$(rpc net_peerCount)
echo "peers:    $((peers_hex))"
gas_hex=$(rpc eth_gasPrice)
echo "gasPrice: $(python3 -c "print(f'{int('$gas_hex',16)/1e9:.3f} gwei')")"

echo
echo "== Prysm beacon =="
curl -s -m 5 "http://$NODE_IP:3500/eth/v1/node/version" | python3 -c 'import sys,json;print("version:  ", json.load(sys.stdin)["data"]["version"])'
curl -s -m 5 "http://$NODE_IP:3500/eth/v1/node/syncing" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print("head slot: %s  sync_distance: %s  syncing: %s  el_offline: %s" % (d["head_slot"], d["sync_distance"], d["is_syncing"], d["el_offline"]))'
curl -s -m 5 "http://$NODE_IP:3500/eth/v1/node/peer_count" | python3 -c 'import sys,json;print("peers:    ", json.load(sys.stdin)["data"]["connected"], "connected")'
h=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$NODE_IP:3500/eth/v1/node/health")
echo "health:   HTTP $h $([ "$h" = 200 ] && echo '(OK)' || echo '(206=syncing, other=NOT OK)')"
