#!/bin/bash

################################################################################
# dns-firewall-contract.sh - single owner of the DNS-sinkhole <-> firewall
# fail-closed contract
#
# dnsmasq answers blocked/non-whitelisted lookups with the non-local sinkhole
# addresses (OPENPATH_DNS_SINKHOLE_IPV4/IPV6 -- canonical defaults registered
# in defaults.conf), and the firewall's sinkhole fast-fail REJECTs connections
# to exactly those addresses so a blocked domain fails instantly instead of
# black-holing at the default DROP. The IPv6 half is the dangerous half: the
# v6 sinkhole AAAA answer must be emitted IFF an active ip6tables firewall
# will RST it. An emitted-but-unreset AAAA makes a dual-stack client (Happy
# Eyeballs) commit to the dead v6 sinkhole for the full connect timeout (~90s
# per blocked sub-resource -- the page-observer canary bug class). Both the
# DNS config writers (dns-dnsmasq.sh) and the firewall v6 rule builder
# (firewall-rule-helpers.sh) consume ipv6_sinkhole_fail_closed below, so the
# two sides cannot diverge.
#
# Sourced unconditionally by common.sh, so every context that generates DNS
# config or applies firewall rules (installer, openpath-update, watchdog,
# CLI, postinst, captive-portal detector, and the bats harnesses) sees the
# same single copy. Function definitions only -- no source-time side effects.
################################################################################

# Parse an OpenPath boolean flag. Falsy: 0/false/no/off/disabled
# (case-insensitive). Unset or empty means the caller's default applies
# (callers pass "${FLAG:-1}" for default-ON flags -- note ':-' substitutes for
# the empty string too, so set-but-empty equals unset). Single owner of flag
# semantics for the contract predicates below and the firewall feature flags
# in firewall-rule-helpers.sh.
openpath_flag_enabled() {
    local value="${1:-1}"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        0 | false | no | off | disabled) return 1 ;;
        *) return 0 ;;
    esac
}

ipv6_firewall_enabled() { openpath_flag_enabled "${IPV6_FIREWALL_ENABLED:-1}"; }
ip6tables_available() { command -v ip6tables >/dev/null 2>&1; }

# IPv6 egress is filtered only when enabled AND ip6tables is usable; otherwise
# IPv6 is left to the (inert) dnsmasq v6 sinkhole, which is the pre-existing gap.
ipv6_firewall_active() { ipv6_firewall_enabled && ip6tables_available; }

# Blocked domains resolve to a non-local sinkhole IP that the default DROP then
# black-holes, so a browser hangs the full TCP connect timeout (~90s) on every
# blocked sub-resource of an allowed page. When enabled, the firewall sends a
# TCP reset for connections to the sinkhole IP (instant "connection refused")
# and the DNS layer drops the v6 sinkhole answer when no IPv6 firewall can
# reset it. SECURITY: the reset is scoped to the (already obviously-fake,
# non-routable) sinkhole IP only, so it reveals nothing about which real
# destinations are filtered (those still hit the silent DROP), never permits
# egress, and keeps the non-local sinkhole. On by default (validated on the
# firefox-esr student-policy lane + staging canary). Set
# OPENPATH_SINKHOLE_FAST_FAIL=0 to opt out.
sinkhole_fast_fail_enabled() { openpath_flag_enabled "${SINKHOLE_FAST_FAIL:-1}"; }

# THE contract predicate: true when an active IPv6 firewall will RST
# connections to the v6 sinkhole. Consumed by BOTH sides of the contract:
#   - dns-dnsmasq.sh (_dns_emit_blocked_aaaa_sinkhole): under fast-fail, emit
#     the v6 sinkhole AAAA answer only when this is true;
#   - firewall-rule-helpers.sh (apply_ipv6_firewall): append the v6 sinkhole
#     REJECT (TCP RST + UDP port-unreachable) rules exactly when this is true.
# "DNS omits the AAAA sinkhole" and "the firewall RSTs the v6 sinkhole" can
# therefore never disagree. The full truth table is pinned by
# tests/firewall-bypass.bats ("agree in every flag cell").
ipv6_sinkhole_fail_closed() {
    sinkhole_fast_fail_enabled && ipv6_firewall_active
}
