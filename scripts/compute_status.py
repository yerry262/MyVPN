#!/usr/bin/env python3
"""Turn `wg show wg0 dump` output into a public status.json.

Reads `wg show wg0 dump` from stdin, cross-references pubkeys against
devices.json, and prints [{"name": ..., "online": bool}, ...] to stdout.
No IPs, endpoints, or timestamps are included in the output — those never
leave the hub.

Usage: wg show wg0 dump | compute_status.py devices.json [--now UNIX_TS]
"""
import argparse
import json
import sys
import time

ONLINE_THRESHOLD_SECONDS = 180


def parse_wg_dump(dump_text):
    """Map wg_pubkey -> latest_handshake (unix ts, 0 if never) from `wg show wg0 dump`.

    Dump format: first line is the interface (private key, pubkey, port,
    fwmark) — skip it. Each following line is a peer:
    pubkey  psk  endpoint  allowed-ips  latest-handshake  rx  tx  keepalive
    """
    handshake_by_pubkey = {}
    lines = dump_text.strip("\n").split("\n")
    for line in lines[1:]:  # skip the interface line
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 5:
            continue
        pubkey, _psk, _endpoint, _allowed_ips, latest_handshake = fields[:5]
        handshake_by_pubkey[pubkey] = int(latest_handshake)
    return handshake_by_pubkey


def compute_status(devices, handshake_by_pubkey, now):
    status = []
    for device in devices:
        if device.get("role") == "hub":
            # The hub never appears as a peer in its own `wg show` dump —
            # peers are other devices connecting to it, not itself. This
            # script only runs when the hub's wg0 is up, so it's online
            # by definition whenever this ran at all.
            online = True
        else:
            handshake = handshake_by_pubkey.get(device["wg_pubkey"], 0)
            online = handshake > 0 and (now - handshake) < ONLINE_THRESHOLD_SECONDS
        status.append({"name": device["name"], "online": online})
    return status


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("devices_json")
    parser.add_argument("--now", type=int, default=None, help="override current unix time, for testing")
    args = parser.parse_args()

    dump_text = sys.stdin.read()
    with open(args.devices_json) as f:
        devices = json.load(f)["devices"]

    now = args.now if args.now is not None else int(time.time())
    handshake_by_pubkey = parse_wg_dump(dump_text)
    status = compute_status(devices, handshake_by_pubkey, now)
    json.dump(status, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
