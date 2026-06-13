#!/bin/bash

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

################################################################################
# openpath-firewall-restore.sh - Early-boot firewall restore (fail-closed)
#
# Boot fail-open fix: nothing restored /etc/iptables/rules.v4 at boot (there is
# no netfilter-persistent dependency), so for the ~2 min until the first
# openpath-update.sh ran, OUTPUT policy was ACCEPT and IP-literal egress was
# free. This oneshot runs before the network comes up (see the systemd unit in
# services.sh) and:
#   1. Recreates the allow-set ipsets BEFORE restore, because rules.v4
#      references them and iptables-restore rejects a ruleset that names a
#      missing set (see ensure_allow_dst_ipset / save_doh_block_ipset_state).
#   2. Restores the saved v4 (and v6) rules.
#   3. If no saved ruleset exists (first boot, or a wiped state), installs a
#      FAIL-CLOSED seed: default-deny OUTPUT except loopback, the DHCP client,
#      and DNS to 127.0.0.1. The box stays closed until activate_firewall
#      repopulates the allow set; first-boot legitimate traffic simply waits for
#      dnsmasq to come up. Fail-closed is the secure default.
################################################################################

set -o pipefail

OPENPATH_IPTABLES_RULES_V4="${OPENPATH_IPTABLES_RULES_V4:-/etc/iptables/rules.v4}"
OPENPATH_IPTABLES_RULES_V6="${OPENPATH_IPTABLES_RULES_V6:-/etc/iptables/rules.v6}"
OPENPATH_IPSET_STATE_FILE="${OPENPATH_IPSET_STATE_FILE:-/etc/iptables/openpath-ipsets.v4}"
OPENPATH_ALLOW_DST_IPSET="${OPENPATH_ALLOW_DST_IPSET:-openpath-allow-dst}"
OPENPATH_ALLOW_DST_IPSET6="${OPENPATH_ALLOW_DST_IPSET6:-openpath-allow-dst6}"
OPENPATH_ALLOW_SET_TIMEOUT="${OPENPATH_ALLOW_SET_TIMEOUT:-300}"

_fwr_log() {
    if command -v logger >/dev/null 2>&1; then
        logger -t openpath-firewall-restore "$1" 2>/dev/null || true
    fi
    echo "[openpath-firewall-restore] $1"
}

# Recreate the ipsets that rules.v4 references so iptables-restore does not
# reject the match-set rules. Empty sets are correct: dnsmasq/activate_firewall
# repopulate them. The persisted DoH block set is restored from its own file.
openpath_firewall_restore_ensure_ipsets() {
    command -v ipset >/dev/null 2>&1 || return 0

    ipset create "$OPENPATH_ALLOW_DST_IPSET" hash:ip timeout "$OPENPATH_ALLOW_SET_TIMEOUT" -exist 2>/dev/null || true
    ipset create "$OPENPATH_ALLOW_DST_IPSET6" hash:ip family inet6 timeout "$OPENPATH_ALLOW_SET_TIMEOUT" -exist 2>/dev/null || true

    if [ -f "$OPENPATH_IPSET_STATE_FILE" ]; then
        ipset restore -exist < "$OPENPATH_IPSET_STATE_FILE" 2>/dev/null || true
    fi
}

# Fail-closed seed used only when no saved ruleset exists. Default-deny OUTPUT
# except loopback, DHCP client (so the box can still get an address), and DNS to
# the local sinkhole. Everything else waits for activate_firewall.
openpath_firewall_restore_seed_fail_closed() {
    command -v iptables >/dev/null 2>&1 || return 1

    iptables -F OUTPUT 2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -p udp -d 127.0.0.1 --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -p tcp -d 127.0.0.1 --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -j DROP 2>/dev/null || true
    iptables -P OUTPUT DROP 2>/dev/null || true

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -F OUTPUT 2>/dev/null || true
        ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
        ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        ip6tables -A OUTPUT -p ipv6-icmp -j ACCEPT 2>/dev/null || true
        ip6tables -A OUTPUT -p udp --dport 546:547 -j ACCEPT 2>/dev/null || true
        ip6tables -A OUTPUT -j DROP 2>/dev/null || true
        ip6tables -P OUTPUT DROP 2>/dev/null || true
    fi

    return 0
}

openpath_firewall_restore_main() {
    openpath_firewall_restore_ensure_ipsets

    if [ -f "$OPENPATH_IPTABLES_RULES_V4" ] && command -v iptables-restore >/dev/null 2>&1; then
        if iptables-restore < "$OPENPATH_IPTABLES_RULES_V4" 2>/dev/null; then
            _fwr_log "Restored IPv4 rules from $OPENPATH_IPTABLES_RULES_V4"
        else
            _fwr_log "iptables-restore failed - applying fail-closed seed"
            openpath_firewall_restore_seed_fail_closed
            return 0
        fi

        if [ -f "$OPENPATH_IPTABLES_RULES_V6" ] && command -v ip6tables-restore >/dev/null 2>&1; then
            if ip6tables-restore < "$OPENPATH_IPTABLES_RULES_V6" 2>/dev/null; then
                _fwr_log "Restored IPv6 rules from $OPENPATH_IPTABLES_RULES_V6"
            else
                _fwr_log "ip6tables-restore failed (continuing on v4-only)"
            fi
        fi
        return 0
    fi

    _fwr_log "No saved ruleset at $OPENPATH_IPTABLES_RULES_V4 - applying fail-closed seed"
    openpath_firewall_restore_seed_fail_closed
}

if [ "${OPENPATH_FIREWALL_RESTORE_SOURCE_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

openpath_firewall_restore_main "$@"
