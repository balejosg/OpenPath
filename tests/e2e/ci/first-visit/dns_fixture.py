#!/usr/bin/env python3
"""sslip.io DNS fixture for the first-visit lane (Phase 3A).

This resolver answers ``*.sslip.io`` A queries with the IPv4 address embedded
in the name (TTL 60) and forwards every other query to the lab resolver
(default 192.168.1.133) with a bounded timeout. It runs on the Proxmox host
(where UDP/53 is free) and is the product's configured upstream for the lab
guest (configure sets ``primaryDNS``/``secondaryDNS`` to the lab host address).

Phase 5.3 B5: on the lab path the fixture hosts never reach this resolver. The
product's AcrylicHosts renderer resolves any sslip.io whitelisted/learned name
with a static hosts entry built from the embedded IPv4
(``windows/lib/internal/AcrylicHostsModel.ps1::Get-AcrylicForwardRules``), and
Acrylic's domain affinity mask only forwards whitelisted/runtime-dependency
domains upstream. A dependency host therefore resolves only after the product
learns it (before learning the name is not in the mask and Acrylic answers
NXDOMAIN locally; after learning the static hosts entry answers first), and
``dns.jsonl`` holds no answer entries for the anchors. The fixture's roles are:
serving the harness's direct INFRA probe (``Resolve-DnsName -Server <lab>``)
and forwarding everything that is not a fixture hostname.

Usage:
  dns_fixture.py --state-dir DIR [--listen 0.0.0.0] [--port 53]
                 [--upstream 192.168.1.133] [--timeout 4]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import socket
import threading
import time

SSLP_IPV4 = re.compile(r"(?:^|\.)(\d{1,3}(?:[.-]\d{1,3}){3})\.sslip\.io$", re.IGNORECASE)


def parse_question_name(message: bytes) -> tuple[str, int]:
    if len(message) < 12:
        return "", -1
    offset = 12
    labels = []
    while offset < len(message):
        length = message[offset]
        if length == 0:
            offset += 1
            break
        if length > 63 or offset + 1 + length > len(message):
            return "", -1
        labels.append(message[offset + 1 : offset + 1 + length].decode("ascii", errors="replace"))
        offset += 1 + length
    if offset + 4 > len(message):
        return "", -1
    qtype = int.from_bytes(message[offset : offset + 2], "big")
    return ".".join(labels), qtype


def build_a_response(message: bytes, ip: str, ttl: int = 60) -> bytes:
    parts = ip.replace("-", ".").split(".")
    rdata = bytes(int(part) for part in parts)
    question_end = 12
    while message[question_end] != 0:
        question_end += 1 + message[question_end]
    question_end += 5  # null byte + qtype + qclass
    question = message[12:question_end]
    header = message[:2] + b"\x81\x80" + message[4:6] + b"\x00\x01\x00\x00\x00\x00"
    answer = (
        b"\xc0\x0c"
        + b"\x00\x01"
        + b"\x00\x01"
        + int(ttl).to_bytes(4, "big")
        + len(rdata).to_bytes(2, "big")
        + rdata
    )
    return header + question + answer


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=53)
    parser.add_argument("--upstream", default="192.168.1.133")
    parser.add_argument("--timeout", type=float, default=4.0)
    args = parser.parse_args()

    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    log_path = state_dir / "dns.jsonl"

    def log(entry: dict) -> None:
        entry["ts"] = time.time()
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.listen, args.port))
    print(json.dumps({"listening": f"{args.listen}:{args.port}", "upstream": args.upstream}), flush=True)

    while True:
        try:
            data, address = sock.recvfrom(2048)
        except OSError:
            break
        name, qtype = parse_question_name(data)
        match = SSLP_IPV4.search(name) if name else None
        if match and qtype == 1:
            ip = match.group(1).replace("-", ".")
            if len(ip.split(".")) == 4 and all(0 <= int(part) <= 255 for part in ip.split(".")):
                sock.sendto(build_a_response(data, ip), address)
                log({"name": name, "qtype": qtype, "action": "sslip-answer", "ip": ip, "client": address[0]})
                continue
        if not name:
            log({"action": "malformed", "client": address[0]})
            continue
        forward = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        forward.settimeout(args.timeout)
        try:
            forward.sendto(data, (args.upstream, 53))
            reply, _ = forward.recvfrom(4096)
            sock.sendto(reply, address)
            log({"name": name, "qtype": qtype, "action": "forward", "client": address[0]})
        except socket.timeout:
            log({"name": name, "qtype": qtype, "action": "forward-timeout", "client": address[0]})
            sock.sendto(data[:2] + b"\x81\x82" + data[4:], address)  # SERVFAIL
        except OSError as error:
            log({"name": name, "qtype": qtype, "action": "forward-error", "error": str(error)})
        finally:
            forward.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
