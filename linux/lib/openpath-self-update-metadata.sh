#!/bin/bash

################################################################################
# openpath-self-update-metadata.sh - Manifest, version, and cache metadata
################################################################################

# shellcheck disable=SC2034  # Shared self-update globals are declared in the entrypoint.

parse_json_string_field() {
    local response="$1"
    local field_name="$2"
    printf '%s\n' "$response" | grep -oP "\"${field_name}\":\\s*\"\\K[^\"]+" | head -1 || true
}

parse_json_string_array_field() {
    local response="$1"
    local field_name="$2"
    local array_block=""

    array_block=$(printf '%s' "$response" | tr '\n' ' ' | sed -nE "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\\[([^]]*)\\].*/\\1/p")
    if [ -z "$array_block" ]; then
        return 0
    fi

    printf '%s\n' "$array_block" | grep -oP '"\K[^"]+' || true
}

extract_url_origin() {
    local url="$1"
    printf '%s\n' "$url" | sed -nE 's#^(https?://[^/]+).*$#\1#p'
}

# Returns 0 when the download URL's origin (scheme://host[:port]) equals the
# configured API origin. Used to reject a manifest downloadPath that points at a
# different origin than the API we authenticated to (the direct .deb fetch is
# not gpg-verified, unlike APT installs).
download_url_matches_configured_origin() {
    local download_url="$1"
    local configured_origin="$2"

    [ -n "$configured_origin" ] || return 1

    local download_origin
    download_origin=$(extract_url_origin "$download_url")
    [ -n "$download_origin" ] || return 1

    [ "${download_origin%/}" = "${configured_origin%/}" ]
}

get_configured_api_base_url() {
    if [ ! -r "$API_URL_CONF" ]; then
        return 1
    fi

    local api_url
    api_url=$(tr -d '\r\n' < "$API_URL_CONF" 2>/dev/null || true)
    if [ -z "$api_url" ]; then
        return 1
    fi

    printf '%s\n' "${api_url%/}"
}

build_absolute_download_url() {
    local origin="$1"
    local candidate="$2"

    if [[ "$candidate" =~ ^https?:// ]]; then
        printf '%s\n' "$candidate"
    elif [[ "$candidate" == /* ]]; then
        printf '%s\n' "${origin}${candidate}"
    elif [ -n "$origin" ]; then
        printf '%s\n' "${origin}/${candidate}"
    else
        return 1
    fi
}

refresh_update_metadata() {
    local manifest_url="${OPENPATH_SELF_UPDATE_API:-}"
    local manifest_token="${OPENPATH_SELF_UPDATE_API_TOKEN:-}"
    local auth_header=""
    local response=""
    local origin=""
    local api_base=""
    local machine_token=""
    local managed_manifest_requested=0

    if [ -n "$manifest_token" ]; then
        auth_header="Authorization: Bearer ${manifest_token}"
    fi

    if [ -z "$manifest_url" ]; then
        api_base=$(get_configured_api_base_url || true)
        machine_token=$(get_machine_token_from_whitelist_url_file || true)
        if [ -n "$api_base" ] && [ -n "$machine_token" ]; then
            manifest_url="${api_base}${LINUX_AGENT_MANIFEST_PATH}"
            if [ -z "$auth_header" ]; then
                auth_header="Authorization: Bearer ${machine_token}"
            fi
            origin="$api_base"
            managed_manifest_requested=1
        fi
    else
        origin=$(extract_url_origin "$manifest_url")
        managed_manifest_requested=1
    fi

    if [ -z "$manifest_url" ]; then
        manifest_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
        origin="https://github.com"
    fi

    if [ -n "$auth_header" ]; then
        response=$(curl -sS --connect-timeout 10 --max-time 30 -H "$auth_header" "$manifest_url" 2>/dev/null)
    else
        response=$(curl -sS --connect-timeout 10 --max-time 30 "$manifest_url" 2>/dev/null)
    fi

    if [ -z "$response" ]; then
        log_error "Cannot reach update manifest"
        return 1
    fi

    local manifest_version=""
    local manifest_download_path=""
    manifest_version=$(parse_json_string_field "$response" "version")
    manifest_download_path=$(parse_json_string_field "$response" "downloadPath")

    if [ -n "$manifest_version" ] && [ -n "$manifest_download_path" ]; then
        UPDATE_SOURCE="api-manifest"
        LATEST_VERSION="$manifest_version"
        DOWNLOAD_AUTH_HEADER="$auth_header"
        UPDATE_API_BASE_URL="$origin"
        DOWNLOAD_URL=$(build_absolute_download_url "$origin" "$manifest_download_path") || {
            log_error "Cannot resolve Linux agent download URL from API manifest"
            return 1
        }

        # Cross-origin guard: the manifest's downloadPath may be an absolute URL
        # to ANY origin. The .deb fetched here is NOT gpg-verified (only APT
        # installs are), so following a download to an attacker-chosen origin
        # would install an unverified package. Require the resolved download
        # origin to match the configured API origin; reject otherwise. Full
        # provenance still needs a server-provided signed digest (see sha256
        # verification in download_url_to_file).
        if ! download_url_matches_configured_origin "$DOWNLOAD_URL" "$origin"; then
            log_error "Refusing cross-origin agent download: $(extract_url_origin "$DOWNLOAD_URL") != ${origin}"
            return 1
        fi

        MANIFEST_SHA256=$(parse_json_string_field "$response" "sha256")
        MIN_SUPPORTED_VERSION=$(parse_json_string_field "$response" "minSupportedVersion")
        MIN_DIRECT_UPGRADE_VERSION=$(parse_json_string_field "$response" "minDirectUpgradeVersion")
        mapfile -t BRIDGE_VERSIONS < <(parse_json_string_array_field "$response" "bridgeVersions" | sort -uV)
        [ -z "$MIN_SUPPORTED_VERSION" ] && MIN_SUPPORTED_VERSION="0.0.0"
        [ -z "$MIN_DIRECT_UPGRADE_VERSION" ] && MIN_DIRECT_UPGRADE_VERSION="0.0.0"
        return 0
    fi

    if [ "$managed_manifest_requested" -eq 1 ]; then
        log_warn "Managed Linux update manifest was unavailable or incomplete; falling back to GitHub releases"
        manifest_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
        origin="https://github.com"
        auth_header=""

        response=$(curl -sS --connect-timeout 10 --max-time 30 "$manifest_url" 2>/dev/null)
        if [ -z "$response" ]; then
            log_error "Cannot reach fallback GitHub release metadata"
            return 1
        fi
    fi

    local github_tag=""
    local github_download_url=""
    github_tag=$(parse_json_string_field "$response" "tag_name")
    github_download_url=$(printf '%s\n' "$response" | grep -oP '"browser_download_url":\s*"\K[^"]+\.deb' | head -1)

    if [ -z "$github_tag" ]; then
        log_error "Cannot parse latest release tag"
        return 1
    fi

    if [ -z "$github_download_url" ]; then
        log_error "No .deb package found in latest release"
        return 1
    fi

    UPDATE_SOURCE="github-release"
    LATEST_VERSION="${github_tag#v}"
    DOWNLOAD_URL="$github_download_url"
    DOWNLOAD_AUTH_HEADER=""
    UPDATE_API_BASE_URL=""
    BRIDGE_VERSIONS=()
    MANIFEST_SHA256=""
    MIN_SUPPORTED_VERSION="0.0.0"
    MIN_DIRECT_UPGRADE_VERSION="0.0.0"
}

compare_versions() {
    local v1="$1" v2="$2"

    if [ "$v1" = "$v2" ]; then
        return 0
    fi

    local higher
    higher=$(printf '%s\n%s' "$v1" "$v2" | sort -V | tail -1)

    if [ "$higher" = "$v1" ]; then
        return 1
    fi

    return 2
}

read_installed_version() {
    if [ -r "$INSTALL_DIR/VERSION" ]; then
        tr -d '\r\n' < "$INSTALL_DIR/VERSION"
        return 0
    fi

    printf '%s\n' "$CURRENT_VERSION"
}

cached_package_path_for_version() {
    local version="$1"
    printf '%s\n' "$PACKAGE_CACHE_DIR/openpath-dnsmasq_${version}-1_amd64.deb"
}

build_managed_package_url_for_version() {
    local version="$1"

    if [ "$UPDATE_SOURCE" != "api-manifest" ] || [ -z "$UPDATE_API_BASE_URL" ]; then
        return 1
    fi

    printf '%s/api/agent/linux/packages/%s\n' "${UPDATE_API_BASE_URL%/}" "$version"
}

resolve_update_sequence() {
    local current_version="$1"
    local target_version="$2"
    local bridge_version=""
    local filtered_bridges=()

    UPDATE_SEQUENCE=()

    for bridge_version in "${BRIDGE_VERSIONS[@]}"; do
        local cmp_current=0
        local cmp_target=0

        [ -n "$bridge_version" ] || continue

        compare_versions "$bridge_version" "$current_version" || cmp_current=$?
        if [ "$cmp_current" -ne 1 ]; then
            continue
        fi

        compare_versions "$bridge_version" "$target_version" || cmp_target=$?
        if [ "$cmp_target" -eq 1 ]; then
            continue
        fi

        filtered_bridges+=("$bridge_version")
    done

    if [ "${#filtered_bridges[@]}" -gt 0 ]; then
        mapfile -t UPDATE_SEQUENCE < <(printf '%s\n' "${filtered_bridges[@]}" | sort -uV)
    fi

    if [ "${#UPDATE_SEQUENCE[@]}" -eq 0 ]; then
        UPDATE_SEQUENCE=("$target_version")
        return 0
    fi

    local last_index=$(( ${#UPDATE_SEQUENCE[@]} - 1 ))
    if [ "${UPDATE_SEQUENCE[$last_index]}" != "$target_version" ]; then
        UPDATE_SEQUENCE+=("$target_version")
    fi
}
