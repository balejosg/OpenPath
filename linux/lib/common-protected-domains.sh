#!/bin/bash

################################################################################
# common-protected-domains.sh - Protected control-plane and browser-system domain helpers
################################################################################

get_openpath_firefox_system_domains() {
    cat <<'EOF'
aus5.mozilla.org
firefox.settings.services.mozilla.com
firefox-settings-attachments.cdn.mozilla.net
content-signature-2.cdn.mozilla.net
download.mozilla.org
download.cdn.mozilla.net
archive.mozilla.org
ftp.mozilla.org
safebrowsing.googleapis.com
addons.mozilla.org
versioncheck.addons.mozilla.org
services.addons.mozilla.org
ciscobinary.openh264.org
redirector.gvt1.com
clients2.googleusercontent.com
EOF
}

append_unique_openpath_domain() {
    local domain="$1"

    [ -z "$domain" ] && return 0

    local normalized
    normalized=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/[[:space:]]//g; s/^\.*//; s/\.*$//')
    if ! is_openpath_domain_format "$normalized"; then
        return 0
    fi

    local existing
    for existing in "${OPENPATH_PROTECTED_DOMAINS[@]}"; do
        if [ "$existing" = "$normalized" ]; then
            return 0
        fi
    done

    OPENPATH_PROTECTED_DOMAINS+=("$normalized")
}

get_openpath_captive_portal_probe_domains() {
    cat <<'EOF'
detectportal.firefox.com
connectivity-check.ubuntu.com
captive.apple.com
www.msftconnecttest.com
clients3.google.com
EOF
}

get_openpath_os_system_domains() {
    cat <<'EOF'
ntp.ubuntu.com
time.google.com
pool.ntp.org
security.ubuntu.com
archive.ubuntu.com
changelogs.ubuntu.com
EOF
}

refresh_openpath_protected_domains() {
    OPENPATH_PROTECTED_DOMAINS=()
    OPENPATH_PROTECTED_DOMAINS_READY=0

    local domain
    for domain in \
        raw.githubusercontent.com \
        github.com \
        githubusercontent.com \
        api.github.com \
        release-assets.githubusercontent.com \
        objects.githubusercontent.com \
        sourceforge.net \
        downloads.sourceforge.net; do
        append_unique_openpath_domain "$domain"
    done

    while IFS= read -r domain; do
        append_unique_openpath_domain "$domain"
    done < <(get_openpath_captive_portal_probe_domains)

    while IFS= read -r domain; do
        append_unique_openpath_domain "$domain"
    done < <(get_openpath_os_system_domains)

    while IFS= read -r domain; do
        append_unique_openpath_domain "$domain"
    done < <(get_openpath_firefox_system_domains)

    local whitelist_url=""
    if [ -f "$WHITELIST_URL_CONF" ]; then
        whitelist_url=$(tr -d '\r\n' < "$WHITELIST_URL_CONF" 2>/dev/null || true)
    elif [ -n "${WHITELIST_URL:-}" ]; then
        whitelist_url="$WHITELIST_URL"
    elif [ -n "${DEFAULT_WHITELIST_URL:-}" ]; then
        whitelist_url="$DEFAULT_WHITELIST_URL"
    fi
    append_unique_openpath_domain "$(get_url_host "$whitelist_url")"

    local api_url=""
    if [ -f "$ETC_CONFIG_DIR/api-url.conf" ]; then
        api_url=$(tr -d '\r\n' < "$ETC_CONFIG_DIR/api-url.conf" 2>/dev/null || true)
    fi
    append_unique_openpath_domain "$(get_url_host "$api_url")"

    local health_api_url=""
    if [ -f "$HEALTH_API_URL_CONF" ]; then
        health_api_url=$(tr -d '\r\n' < "$HEALTH_API_URL_CONF" 2>/dev/null || true)
    fi
    append_unique_openpath_domain "$(get_url_host "$health_api_url")"

    OPENPATH_PROTECTED_DOMAINS_READY=1
}

ensure_openpath_protected_domains() {
    if [ "${OPENPATH_PROTECTED_DOMAINS_READY:-0}" -ne 1 ]; then
        refresh_openpath_protected_domains
    fi
}

get_openpath_protected_domains() {
    refresh_openpath_protected_domains

    printf '%s\n' "${OPENPATH_PROTECTED_DOMAINS[@]}"
}

is_openpath_protected_domain() {
    local candidate="$1"
    [ -z "$candidate" ] && return 1

    local normalized
    normalized=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/[[:space:]]//g; s/^\.*//; s/\.*$//')

    ensure_openpath_protected_domains

    local protected
    for protected in "${OPENPATH_PROTECTED_DOMAINS[@]}"; do
        [ -z "$protected" ] && continue
        if [ "$protected" = "$normalized" ]; then
            return 0
        fi
    done

    return 1
}

get_blocked_path_host() {
    local rule="$1"
    [ -z "$rule" ] && return 1

    local candidate="$rule"
    candidate="${candidate#*://}"

    while [[ "$candidate" == \** ]]; do
        candidate="${candidate#\*}"
    done
    while [[ "$candidate" == .* ]]; do
        candidate="${candidate#.}"
    done

    [ -z "$candidate" ] && return 1
    [[ "$candidate" == /* ]] && return 1

    local host="${candidate%%/*}"
    host="${host%%\?*}"
    host="${host%%\#*}"
    host="${host%%:*}"
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | sed 's/[[:space:]]//g; s/^\.*//; s/\.*$//')

    if is_openpath_domain_format "$host"; then
        printf '%s\n' "$host"
        return 0
    fi

    return 1
}

protect_control_plane_rules() {
    refresh_openpath_protected_domains

    local -A protected_domain_lookup=()
    local -A whitelist_lookup=()

    local protected_domain
    for protected_domain in "${OPENPATH_PROTECTED_DOMAINS[@]}"; do
        [ -z "$protected_domain" ] && continue
        protected_domain_lookup["$protected_domain"]=1
    done

    local domain
    for domain in "${WHITELIST_DOMAINS[@]}"; do
        [ -n "$domain" ] && whitelist_lookup["$domain"]=1
    done

    for protected_domain in "${OPENPATH_PROTECTED_DOMAINS[@]}"; do
        [ -z "$protected_domain" ] && continue
        if [ -z "${whitelist_lookup[$protected_domain]+x}" ]; then
            WHITELIST_DOMAINS+=("$protected_domain")
            whitelist_lookup["$protected_domain"]=1
        fi
    done

    local filtered_subdomains=()
    local removed_subdomains=0
    local blocked_subdomain
    for blocked_subdomain in "${BLOCKED_SUBDOMAINS[@]}"; do
        if [ -n "${protected_domain_lookup[$blocked_subdomain]+x}" ]; then
            removed_subdomains=$((removed_subdomains + 1))
            continue
        fi
        filtered_subdomains+=("$blocked_subdomain")
    done
    BLOCKED_SUBDOMAINS=("${filtered_subdomains[@]}")

    local filtered_paths=()
    local removed_paths=0
    local blocked_path
    for blocked_path in "${BLOCKED_PATHS[@]}"; do
        local blocked_path_host=""
        blocked_path_host=$(get_blocked_path_host "$blocked_path" 2>/dev/null || true)
        if [ -n "$blocked_path_host" ] && [ -n "${protected_domain_lookup[$blocked_path_host]+x}" ]; then
            removed_paths=$((removed_paths + 1))
            continue
        fi
        filtered_paths+=("$blocked_path")
    done
    BLOCKED_PATHS=("${filtered_paths[@]}")

    if [ "$removed_subdomains" -gt 0 ] || [ "$removed_paths" -gt 0 ]; then
        log_warn "Removed ${removed_subdomains} blocked subdomains and ${removed_paths} blocked paths targeting protected always-allowed domains"
    fi
}
