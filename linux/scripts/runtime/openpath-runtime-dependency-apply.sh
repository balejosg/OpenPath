#!/bin/bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/openpath}"

# shellcheck source=/usr/local/lib/openpath/lib/common.sh
source "$INSTALL_DIR/lib/common.sh"
load_libraries

run_runtime_dependency_apply_locked() {
    if [ -f "$WHITELIST_FILE" ]; then
        parse_whitelist_sections "$WHITELIST_FILE"
    else
        log_warn "Runtime dependency apply skipped: whitelist file missing"
        return 0
    fi

    if declare -F process_runtime_dependency_queue >/dev/null 2>&1; then
        process_runtime_dependency_queue || log_warn "Runtime dependency queue processing failed"
    fi

    generate_dnsmasq_config
    if has_config_changed; then
        if restart_dnsmasq; then
            sha256sum "$DNSMASQ_CONF" | cut -d' ' -f1 > "$DNSMASQ_CONF_HASH"
            # Only a successful reload proves the current overlay content is
            # operative; the native host waits for this marker before `ready`.
            mark_runtime_dependency_overlay_applied
        fi
    else
        log_debug "Runtime dependency apply did not change dnsmasq config"
        # The effective DNS configuration is unchanged, so the current overlay
        # content is already operative and can be marked as applied.
        mark_runtime_dependency_overlay_applied
    fi
    flush_dns_cache || true
}

if declare -F with_openpath_lock >/dev/null 2>&1; then
    with_openpath_lock run_runtime_dependency_apply_locked
else
    run_runtime_dependency_apply_locked
fi
