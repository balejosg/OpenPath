#!/bin/bash

################################################################################
# openpath-self-update-package.sh - Package caching, install, and rollback
################################################################################

cleanup_update_workspace() {
    rm -rf "$DOWNLOAD_DIR" "$BACKUP_DIR"
}

verify_deb_package() {
    local deb_file="$1"
    dpkg-deb --info "$deb_file" >/dev/null 2>&1
}

download_url_to_file() {
    local source_url="$1"
    local destination_file="$2"

    mkdir -p "$(dirname "$destination_file")"

    if [ -n "$DOWNLOAD_AUTH_HEADER" ]; then
        if ! curl -sS -L --connect-timeout 15 --max-time 120 -H "$DOWNLOAD_AUTH_HEADER" -o "$destination_file" "$source_url"; then
            log_error "Download failed: $source_url" >&2
            return 1
        fi
    else
        if ! curl -sS -L --connect-timeout 15 --max-time 120 -o "$destination_file" "$source_url"; then
            log_error "Download failed: $source_url" >&2
            return 1
        fi
    fi

    if ! verify_deb_package "$destination_file"; then
        log_error "Downloaded file is not a valid .deb package" >&2
        rm -f "$destination_file"
        return 1
    fi

    return 0
}

ensure_cached_package_for_version() {
    local version="$1"
    local cached_file=""
    local source_url=""

    cached_file=$(cached_package_path_for_version "$version")
    if [ -f "$cached_file" ] && verify_deb_package "$cached_file"; then
        printf '%s\n' "$cached_file"
        return 0
    fi

    rm -f "$cached_file"

    if [ "$version" = "$LATEST_VERSION" ]; then
        source_url="$DOWNLOAD_URL"
    else
        source_url=$(build_managed_package_url_for_version "$version" || true)
    fi

    if [ -z "$source_url" ]; then
        return 1
    fi

    log "Caching OpenPath package v${version}..." >&2
    download_url_to_file "$source_url" "$cached_file" || return 1
    printf '%s\n' "$cached_file"
}

install_deb_package_file() {
    local deb_file="$1"
    local target_version="$2"
    local action_label="${3:-update}"

    log "Installing OpenPath v${target_version} (${action_label})..."
    if dpkg -i "$deb_file" 2>&1; then
        log "✓ Package installed successfully"
    else
        log_warn "dpkg reported issues, running apt-get -f install..."
        if ! apt_install_with_retry "package repair" apt-get -f install -y 2>&1; then
            log_error "Package repair failed after dpkg -i"
            return 1
        fi
    fi

    if ! dpkg -s openpath-dnsmasq 2>/dev/null | grep -q '^Status: install ok installed'; then
        log_error "Updated package is not fully installed"
        return 1
    fi

    return 0
}

restart_updated_services() {
    log "Restarting services..."
    systemctl daemon-reload
    systemctl restart dnsmasq 2>/dev/null || true
    systemctl restart openpath-dnsmasq.timer 2>/dev/null || true
    systemctl restart dnsmasq-watchdog.timer 2>/dev/null || true
    systemctl restart openpath-sse-listener.service 2>/dev/null || true
    systemctl restart captive-portal-detector.service 2>/dev/null || true
}

verify_updated_installation() {
    local expected_version="$1"
    local installed_version=""

    installed_version=$(read_installed_version)
    if [ "$installed_version" != "$expected_version" ]; then
        log_error "Installed version mismatch after update: expected v${expected_version}, found v${installed_version}"
        return 1
    fi

    if ! dpkg -s openpath-dnsmasq 2>/dev/null | grep -q '^Status: install ok installed'; then
        log_error "OpenPath package is not fully installed after update"
        return 1
    fi

    for _ in $(seq 1 10); do
        if systemctl is-active --quiet dnsmasq; then
            return 0
        fi
        sleep 1
    done

    log_error "dnsmasq did not become active after installing v${expected_version}"
    return 1
}

backup_config() {
    log "Backing up configuration..."
    mkdir -p "$BACKUP_DIR"

    for f in "${PRESERVE_FILES[@]}"; do
        if [ -f "$f" ]; then
            local relative="${f#/}"
            mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
            cp -p "$f" "$BACKUP_DIR/$relative"
            log_debug "  Backed up: $f"
        fi
    done
}

restore_config() {
    log "Restoring configuration..."

    for f in "${PRESERVE_FILES[@]}"; do
        local relative="${f#/}"
        local backup="$BACKUP_DIR/$relative"
        if [ -f "$backup" ]; then
            mkdir -p "$(dirname "$f")"
            cp -p "$backup" "$f"
            log_debug "  Restored: $f"
        fi
    done
}

stop_active_services_for_update() {
    log "Stopping active services before update..."

    systemctl stop openpath-sse-listener.service 2>/dev/null || true
    systemctl stop captive-portal-detector.service 2>/dev/null || true
    systemctl stop openpath-dnsmasq.timer 2>/dev/null || true
    systemctl stop dnsmasq-watchdog.timer 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true

    if command -v pkill >/dev/null 2>&1; then
        pkill -x dnsmasq 2>/dev/null || true
    fi

    if command -v fuser >/dev/null 2>&1; then
        fuser -k 53/udp 2>/dev/null || true
        fuser -k 53/tcp 2>/dev/null || true
    fi

    sleep 1
}

finalize_updated_package() {
    local target_version="$1"

    restore_config

    if should_require_openpath_request_setup; then
        require_openpath_request_setup_complete "post-update verification" || return 1
    fi

    if [ -f "/usr/local/bin/dnsmasq-watchdog.sh" ]; then
        source /usr/local/lib/openpath/lib/common.sh 2>/dev/null || true
        rm -f "/var/lib/openpath/integrity.sha256"
        log "Integrity hashes will be regenerated on next watchdog run"
    fi

    restart_updated_services
    /usr/local/bin/openpath-update.sh 2>/dev/null &
    if should_require_openpath_request_setup; then
        require_openpath_request_setup_complete "post-update verification" || return 1
    fi
    verify_updated_installation "$target_version"
}

attempt_agent_package_rollback() {
    local previous_version="$1"
    local rollback_package=""

    rollback_package=$(ensure_cached_package_for_version "$previous_version" || true)
    if [ -z "$rollback_package" ] || [ ! -f "$rollback_package" ]; then
        log_error "Rollback package for v${previous_version} is unavailable"
        return 1
    fi

    log_warn "Attempting rollback to OpenPath v${previous_version}..."
    if ! install_deb_package_file "$rollback_package" "$previous_version" "rollback"; then
        log_error "Rollback package installation failed"
        return 1
    fi

    if ! finalize_updated_package "$previous_version"; then
        log_error "Rollback completed but health checks still failed"
        return 1
    fi

    cleanup_update_workspace
    log_warn "Rollback to v${previous_version} completed"
    return 0
}

install_update() {
    local new_version="$1"
    local previous_version="$2"
    local target_package=""

    target_package=$(ensure_cached_package_for_version "$new_version" || true)
    if [ -z "$target_package" ] || [ ! -f "$target_package" ]; then
        log_error "Unable to cache target package for v${new_version}"
        return 1
    fi

    if [ "$previous_version" != "$new_version" ]; then
        if ! ensure_cached_package_for_version "$previous_version" >/dev/null 2>&1; then
            if [ "$UPDATE_SOURCE" = "api-manifest" ]; then
                log_error "Unable to cache rollback package for current version v${previous_version}"
                return 1
            fi
            log_warn "Rollback package for v${previous_version} is unavailable; continuing without versioned rollback"
        fi
    fi

    log "Package ready: $(du -h "$target_package" | cut -f1)"

    backup_config
    stop_active_services_for_update

    if ! install_deb_package_file "$target_package" "$new_version" "update"; then
        if [ "$previous_version" != "$new_version" ]; then
            log_warn "Install failed; attempting rollback to v${previous_version}"
            attempt_agent_package_rollback "$previous_version" || true
        fi
        return 1
    fi

    if ! finalize_updated_package "$new_version"; then
        if [ "$previous_version" != "$new_version" ]; then
            log_warn "Health checks failed after update; attempting rollback to v${previous_version}"
            attempt_agent_package_rollback "$previous_version" || true
        fi
        return 1
    fi

    cleanup_update_workspace

    log "✓ OpenPath updated to v${new_version}"
    echo ""
    echo "✓ Update completed: v${previous_version} → v${new_version}"
    echo "  Services have been restarted automatically."
}
