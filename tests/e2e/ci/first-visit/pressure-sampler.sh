#!/usr/bin/env bash
# Phase 7 P1: Proxmox host pressure samples during a first-visit scene.
#
# Usage: pressure-sampler.sh <out-file> <vmid> <max-seconds>
#
# Writes one JSON line per second with the host PSI `some avg10` values
# (/proc/pressure/{cpu,io,memory}), the load average and the CPU percent of the
# VM's kvm process. The lane controller starts it right before the visit and
# stops it after the collect; the samples classify any >2 s guest gap as a host
# side stall instead of a product one.
set -u

out="${1:?out-file required}"
vmid="${2:-0}"
max_seconds="${3:-2400}"

: > "$out" 2>/dev/null || exit 1
end=$(( $(date +%s) + max_seconds ))

while [ "$(date +%s)" -lt "$end" ]; do
    t=$(date +%s%3N)
    cpu=$(awk '/^some/{print $2}' /proc/pressure/cpu 2>/dev/null | cut -d= -f2)
    io=$(awk '/^some/{print $2}' /proc/pressure/io 2>/dev/null | cut -d= -f2)
    memory=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | cut -d= -f2)
    load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null | tr ' ' ',')
    qemu=""
    if [ "$vmid" -gt 0 ]; then
        pid=$(ps -eo pid=,args= 2>/dev/null | awk -v vmid="$vmid" '/kvm/ && index($0, "-id " vmid " ") > 0 {print $1; exit}')
        if [ -n "$pid" ]; then
            qemu=$(ps -o pcpu= -p "$pid" 2>/dev/null | tr -d ' ')
        fi
    fi
    printf '{"t":%s,"cpuSome":%s,"ioSome":%s,"memorySome":%s,"load":"%s","qemuCpu":"%s"}\n' \
        "$t" "${cpu:-0}" "${io:-0}" "${memory:-0}" "${load:-}" "${qemu:-}"
    sleep 1
done
