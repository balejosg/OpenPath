#!/bin/bash
################################################################################
# apt.sh - Resilient APT helpers shared by installer, runtime, and CI
################################################################################

openpath_default_apt_mirrors() {
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    case "$arch" in
        arm64|armhf|riscv64|ppc64el|s390x)
            printf '%s\n' "http://ports.ubuntu.com/ubuntu-ports"
            ;;
        *)
            printf '%s\n' "http://azure.archive.ubuntu.com/ubuntu http://archive.ubuntu.com/ubuntu http://mirrors.edge.kernel.org/ubuntu"
            ;;
    esac
}

OPENPATH_APT_MIRRORS="${OPENPATH_APT_MIRRORS:-$(openpath_default_apt_mirrors)}"
OPENPATH_APT_RETRIES="${OPENPATH_APT_RETRIES:-2}"
OPENPATH_APT_UPDATE_TIMEOUT_SECONDS="${OPENPATH_APT_UPDATE_TIMEOUT_SECONDS:-45}"
OPENPATH_APT_INSTALL_TIMEOUT_SECONDS="${OPENPATH_APT_INSTALL_TIMEOUT_SECONDS:-300}"
OPENPATH_APT_CONNECT_TIMEOUT_SECONDS="${OPENPATH_APT_CONNECT_TIMEOUT_SECONDS:-10}"
OPENPATH_APT_CONF_FILE="${OPENPATH_APT_CONF_FILE:-/etc/apt/apt.conf.d/80openpath-network-retries}"

openpath_apt_attempts() {
    case "$OPENPATH_APT_RETRIES" in
        ''|*[!0-9]*|0)
            printf '%s\n' 2
            ;;
        *)
            printf '%s\n' "$OPENPATH_APT_RETRIES"
            ;;
    esac
}

reset_apt_package_indexes() {
    apt-get clean >/dev/null 2>&1 || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    mkdir -p /var/lib/apt/lists/partial 2>/dev/null || true
}

configure_apt_resilience() {
    mkdir -p "$(dirname "$OPENPATH_APT_CONF_FILE")" 2>/dev/null || return 0

    cat > "$OPENPATH_APT_CONF_FILE" 2>/dev/null <<EOF || true
Acquire::Retries "$(openpath_apt_attempts)";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "$OPENPATH_APT_CONNECT_TIMEOUT_SECONDS";
Acquire::https::Timeout "$OPENPATH_APT_CONNECT_TIMEOUT_SECONDS";
APT::Get::Assume-Yes "true";
DPkg::Lock::Timeout "120";
EOF
}

rewrite_ubuntu_sources_for_mirror() {
    local mirror="${1%/}"
    local source_file

    [ -n "$mirror" ] || return 0

    for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$source_file" ] || continue
        [ -w "$source_file" ] || continue
        sed -i -E \
            -e "s#https?://([a-z]{2}\\.)?archive\\.ubuntu\\.com/ubuntu/?#${mirror}#g" \
            -e "s#https?://azure\\.archive\\.ubuntu\\.com/ubuntu/?#${mirror}#g" \
            -e "s#https?://security\\.ubuntu\\.com/ubuntu/?#${mirror}#g" \
            -e "s#https?://mirrors\\.edge\\.kernel\\.org/ubuntu/?#${mirror}#g" \
            -e "s#https?://ports\\.ubuntu\\.com/ubuntu-ports/?#${mirror}#g" \
            "$source_file"
    done
}

run_apt_command_with_timeout() {
    local timeout_seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "$@"
        return $?
    fi

    "$@"
}

openpath_apt_update_output_failed() {
    local output_file="$1"

    grep -Eqi \
        'Failed to fetch|Some index files failed to download|Temporary failure resolving|Could not connect|Connection timed out|Could not resolve|Hash Sum mismatch|Network is unreachable' \
        "$output_file"
}

apt_update_with_retry() {
    local attempt
    local mirror
    local max_attempts
    local output_file

    max_attempts="$(openpath_apt_attempts)"
    configure_apt_resilience

    for mirror in $OPENPATH_APT_MIRRORS; do
        rewrite_ubuntu_sources_for_mirror "$mirror"

        for attempt in $(seq 1 "$max_attempts"); do
            reset_apt_package_indexes

            output_file="$(mktemp)"
            if run_apt_command_with_timeout "$OPENPATH_APT_UPDATE_TIMEOUT_SECONDS" apt-get update -qq >"$output_file" 2>&1; then
                if ! openpath_apt_update_output_failed "$output_file"; then
                    rm -f "$output_file"
                    return 0
                fi
            fi

            [ -s "$output_file" ] && cat "$output_file"
            rm -f "$output_file"

            if [ "$attempt" -lt "$max_attempts" ]; then
                echo "  ! apt-get update failed with ${mirror} (attempt ${attempt}/${max_attempts}); retrying..."
                sleep "$attempt"
            fi
        done

        echo "  ! apt-get update could not use ${mirror}; trying next mirror..."
    done

    echo "  x apt-get update failed after all configured mirrors"
    return 1
}

apt_install_with_retry() {
    local package_group="$1"
    shift

    local apt_output_file
    local attempt
    local max_attempts

    max_attempts="$(openpath_apt_attempts)"
    configure_apt_resilience

    if ! apt_update_with_retry; then
        return 1
    fi

    for attempt in $(seq 1 "$max_attempts"); do
        apt_output_file="$(mktemp)"
        if run_apt_command_with_timeout "$OPENPATH_APT_INSTALL_TIMEOUT_SECONDS" "$@" >"$apt_output_file" 2>&1; then
            rm -f "$apt_output_file"
            return 0
        fi

        [ -s "$apt_output_file" ] && cat "$apt_output_file"
        rm -f "$apt_output_file"

        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "  ! Installation of ${package_group} failed (attempt ${attempt}/${max_attempts}); refreshing indexes..."
            apt_update_with_retry || true
            sleep "$attempt"
        fi
    done

    echo "  x Installation of ${package_group} failed after ${max_attempts} attempts"
    return 1
}
