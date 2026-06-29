#!/bin/bash
################################################################################
# apt-bootstrap.sh - One-liner bootstrap for classroom mode (novice-friendly)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/apt-bootstrap.sh | sudo bash
#
# Optional flags:
#   --unstable      Use unstable track
#   --skip-setup    Install package only (skip classroom setup)
#   --api-url URL   Non-interactive setup input
#   --classroom N  Non-interactive setup input
#   --classroom-id C Use classroom-id with enrollment token flow
#   --token-file F  Read registration token from file
#   --token-stdin   Read registration token from stdin
#   --enrollment-token T  Classroom enrollment token
#   --package-version V Install an explicit openpath-dnsmasq version
################################################################################

set -euo pipefail

LEGACY_GITHUB_PAGES_APT_REPO_URL="https://balejosg.github.io/openpath/apt"
RAW_GITHUB_CONTENT_APT_REPO_URL="https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt"
APT_REPO_URL="${OPENPATH_APT_REPO_URL:-$RAW_GITHUB_CONTENT_APT_REPO_URL}"
if [ "${APT_REPO_URL%/}" = "$LEGACY_GITHUB_PAGES_APT_REPO_URL" ]; then
    APT_REPO_URL="$RAW_GITHUB_CONTENT_APT_REPO_URL"
fi
APT_SETUP_URL="$APT_REPO_URL/apt-setup.sh"
APT_SOURCES_PATH="${OPENPATH_APT_SOURCES_PATH:-/etc/apt/sources.list.d/openpath.list}"

TRACK="stable"
SKIP_SETUP=false
API_URL=""
CLASSROOM=""
CLASSROOM_ID=""
TOKEN_FILE=""
TOKEN_STDIN=false
ENROLLMENT_TOKEN=""
PACKAGE_VERSION=""
BROWSER_SETUP_SCRIPT="${OPENPATH_BROWSER_SETUP_SCRIPT:-/usr/local/bin/openpath-browser-setup.sh}"
OPENPATH_ETC_CONFIG_DIR="${OPENPATH_ETC_CONFIG_DIR:-/etc/openpath}"
OPENPATH_APT_MIRRORS="${OPENPATH_APT_MIRRORS:-http://azure.archive.ubuntu.com/ubuntu http://archive.ubuntu.com/ubuntu http://mirrors.edge.kernel.org/ubuntu}"
OPENPATH_APT_RETRIES="${OPENPATH_APT_RETRIES:-2}"
OPENPATH_APT_UPDATE_TIMEOUT_SECONDS="${OPENPATH_APT_UPDATE_TIMEOUT_SECONDS:-45}"
OPENPATH_APT_INSTALL_TIMEOUT_SECONDS="${OPENPATH_APT_INSTALL_TIMEOUT_SECONDS:-180}"
OPENPATH_APT_CONNECT_TIMEOUT_SECONDS="${OPENPATH_APT_CONNECT_TIMEOUT_SECONDS:-10}"
OPENPATH_APT_CONF_FILE="${OPENPATH_APT_CONF_FILE:-/etc/apt/apt.conf.d/80openpath-network-retries}"
OPENPATH_FIREFOX_APT_PREFERENCES_PATH="${OPENPATH_FIREFOX_APT_PREFERENCES_PATH:-/etc/apt/preferences.d/mozilla-firefox}"
VERBOSE=false

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        printf '%s\n' "$*"
    fi
}

show_progress() {
    local current="$1"
    local total="$2"
    local label="$3"
    local percent=$((current * 100 / total))

    if [ "$VERBOSE" = true ]; then
        printf '[%s/%s] %s\n' "$current" "$total" "$label"
        return 0
    fi

    if [ -t 1 ]; then
        local width=24
        local filled=$((percent * width / 100))
        local empty=$((width - filled))
        local bar
        bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
        printf '\r[%s] %3d%% %s/%s %s' "$bar" "$percent" "$current" "$total" "$label"
        if [ "$current" -eq "$total" ]; then
            printf '\n'
        fi
    else
        printf 'Progress %s/%s: %s\n' "$current" "$total" "$label"
    fi
}

run_maybe_verbose() {
    if [ "$VERBOSE" = true ]; then
        "$@"
        return $?
    fi

    local output_file
    output_file="$(mktemp)"
    if "$@" >"$output_file" 2>&1; then
        rm -f "$output_file"
        return 0
    fi

    [ -t 1 ] && printf '\n'
    cat "$output_file"
    rm -f "$output_file"
    return 1
}

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

configure_apt_resilience() {
    mkdir -p "$(dirname "$OPENPATH_APT_CONF_FILE")" 2>/dev/null || return 0

    cat > "$OPENPATH_APT_CONF_FILE" 2>/dev/null <<EOF || true
Acquire::Retries "$(openpath_apt_attempts)";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "$OPENPATH_APT_CONNECT_TIMEOUT_SECONDS";
Acquire::https::Timeout "$OPENPATH_APT_CONNECT_TIMEOUT_SECONDS";
Acquire::http::No-Cache "true";
Acquire::https::No-Cache "true";
Acquire::http::Max-Age "0";
Acquire::https::Max-Age "0";
APT::Get::Assume-Yes "true";
DPkg::Lock::Timeout "120";
EOF
}

reset_apt_package_indexes() {
    apt-get clean >/dev/null 2>&1 || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    mkdir -p /var/lib/apt/lists/partial 2>/dev/null || true
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

    echo "ERROR: apt-get update failed after all configured mirrors"
    return 1
}

apt_install_with_retry() {
    local package_group="$1"
    shift

    local attempt
    local max_attempts

    max_attempts="$(openpath_apt_attempts)"
    configure_apt_resilience

    if ! apt_update_with_retry; then
        return 1
    fi

    for attempt in $(seq 1 "$max_attempts"); do
        if run_apt_command_with_timeout "$OPENPATH_APT_INSTALL_TIMEOUT_SECONDS" "$@" >/dev/null; then
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "  ! Installation of ${package_group} failed (attempt ${attempt}/${max_attempts}); refreshing indexes..."
            apt_update_with_retry || true
            sleep "$attempt"
        fi
    done

    echo "ERROR: Installation of ${package_group} failed after ${max_attempts} attempts"
    return 1
}

remove_legacy_openpath_apt_source() {
    if [ -f "$APT_SOURCES_PATH" ] \
        && grep -Fq "$LEGACY_GITHUB_PAGES_APT_REPO_URL" "$APT_SOURCES_PATH"; then
        rm -f "$APT_SOURCES_PATH"
        log_verbose "  Removed legacy OpenPath APT source: $APT_SOURCES_PATH"
    fi
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --stable             Use stable track (default)"
    echo "  --unstable           Use unstable track"
    echo "  --skip-setup         Install package only (skip classroom setup)"
    echo "  --api-url URL        API URL for classroom setup"
    echo "  --classroom NAME     Classroom name for setup"
    echo "  --classroom-id ID    Classroom ID for enrollment token setup"
    echo "  --token-file FILE    Read registration token from file"
    echo "  --token-stdin        Read registration token from stdin"
    echo "  --enrollment-token T Classroom enrollment token"
    echo "  --package-version V  Install explicit openpath-dnsmasq version"
    echo "  --verbose            Show detailed installer output"
    echo "  --help               Show this help"
}

require_browser_setup_helper() {
    if [ ! -x "$BROWSER_SETUP_SCRIPT" ]; then
        echo "ERROR: Browser setup helper not found at $BROWSER_SETUP_SCRIPT"
        exit 1
    fi
}

bootstrap_dpkg_is_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q '^install ok installed$'
}

bootstrap_apt_candidate_version() {
    local pkg="$1"
    apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

bootstrap_apt_has_candidate() {
    local pkg="$1"
    local candidate
    candidate="$(bootstrap_apt_candidate_version "$pkg")"
    [ -n "$candidate" ] && [ "$candidate" != "(none)" ]
}

bootstrap_os_id() {
    if [ -n "${OPENPATH_BOOTSTRAP_OS_ID:-}" ]; then
        printf '%s\n' "$OPENPATH_BOOTSTRAP_OS_ID"
        return 0
    fi

    if [ -r /etc/os-release ]; then
        awk -F= '$1=="ID" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true
    fi
}

configure_ubuntu_firefox_apt_source() {
    if command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1; then
        mkdir -p /etc/apt/keyrings
        if curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
            | gpg --dearmor -o /etc/apt/keyrings/packages.mozilla.org.gpg; then
            cat > /etc/apt/sources.list.d/mozilla.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main
EOF
            mkdir -p "$(dirname "$OPENPATH_FIREFOX_APT_PREFERENCES_PATH")" 2>/dev/null || true
            cat > "$OPENPATH_FIREFOX_APT_PREFERENCES_PATH" 2>/dev/null <<'EOF' || true
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1001

Package: firefox
Pin: version 1:1snap*
Pin-Priority: -1
EOF
            return 0
        fi
        rm -f /etc/apt/keyrings/packages.mozilla.org.gpg
    fi

    if ! command -v add-apt-repository >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive run_maybe_verbose apt_install_with_retry "software-properties-common" \
            apt-get install -y software-properties-common || true
    fi

    if command -v add-apt-repository >/dev/null 2>&1; then
        add-apt-repository -y ppa:mozillateam/ppa >/dev/null 2>&1 || true

        mkdir -p "$(dirname "$OPENPATH_FIREFOX_APT_PREFERENCES_PATH")" 2>/dev/null || true
        cat > "$OPENPATH_FIREFOX_APT_PREFERENCES_PATH" 2>/dev/null <<'EOF' || true
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001

Package: firefox
Pin: version 1:1snap*
Pin-Priority: -1
EOF
    fi
}

run_firefox_package_preinstall() {
    show_progress 3 6 "Ensuring Firefox browser package"

    if bootstrap_dpkg_is_installed firefox-esr || bootstrap_dpkg_is_installed firefox; then
        log_verbose "  OK Firefox browser package already installed"
        return 0
    fi

    if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
        pkill -TERM -f firefox 2>/dev/null || true
        snap remove --purge firefox >/dev/null 2>&1 || snap remove firefox >/dev/null 2>&1 || true
    fi

    local os_id
    os_id="$(bootstrap_os_id)"
    if [ "$os_id" = "ubuntu" ]; then
        configure_ubuntu_firefox_apt_source
    fi

    if ! apt_update_with_retry; then
        echo "ERROR: APT package indexes could not be refreshed before Firefox installation."
        exit 1
    fi

    if bootstrap_apt_has_candidate firefox-esr; then
        if run_maybe_verbose apt_install_with_retry "firefox-esr" apt-get install -y firefox-esr; then
            log_verbose "  OK Firefox ESR package ready"
            return 0
        fi
    fi

    if bootstrap_apt_has_candidate firefox; then
        local firefox_candidate
        firefox_candidate="$(bootstrap_apt_candidate_version firefox)"
        if [ "$os_id" = "ubuntu" ] && printf '%s' "$firefox_candidate" | grep -qi 'snap'; then
            echo "ERROR: Firefox APT candidate appears to be the Ubuntu Snap wrapper ($firefox_candidate)."
            echo "  The OpenPath Firefox extension requires a deb-packaged Firefox."
            exit 1
        fi

        if run_maybe_verbose apt_install_with_retry "firefox" apt-get install -y firefox; then
            log_verbose "  OK Firefox package ready"
            return 0
        fi
    fi

    echo "ERROR: No installable Firefox APT package found."
    exit 1
}

run_browser_setup_helper() {
    show_progress 6 6 "Ensuring Firefox browser setup"

    require_browser_setup_helper

    if ! run_maybe_verbose "$BROWSER_SETUP_SCRIPT"; then
        echo "ERROR: Firefox browser setup did not complete successfully."
        exit 1
    fi

    log_verbose "  OK Firefox browser setup ready"
}

bootstrap_is_tokenized_whitelist_url() {
    local url="$1"
    [[ "$url" =~ /w/[^/]+/whitelist\.txt($|[?#].*) ]]
}

read_bootstrap_config_file() {
    local file="$1"
    [ -r "$file" ] || return 1
    tr -d '\r\n' < "$file"
}

describe_bootstrap_request_setup_missing() {
    local missing_items=()
    local api_url=""
    local whitelist_url=""
    local classroom=""
    local classroom_id=""

    api_url=$(read_bootstrap_config_file "$OPENPATH_ETC_CONFIG_DIR/api-url.conf" || true)
    whitelist_url=$(read_bootstrap_config_file "$OPENPATH_ETC_CONFIG_DIR/whitelist-url.conf" || true)
    classroom=$(read_bootstrap_config_file "$OPENPATH_ETC_CONFIG_DIR/classroom.conf" || true)
    classroom_id=$(read_bootstrap_config_file "$OPENPATH_ETC_CONFIG_DIR/classroom-id.conf" || true)

    [ -n "$api_url" ] || missing_items+=("api-url.conf")
    if [ -z "$whitelist_url" ]; then
        missing_items+=("whitelist-url.conf")
    elif ! bootstrap_is_tokenized_whitelist_url "$whitelist_url"; then
        missing_items+=("tokenized whitelist-url.conf")
    fi
    [ -n "$classroom" ] || [ -n "$classroom_id" ] || missing_items+=("classroom.conf or classroom-id.conf")

    if [ "${#missing_items[@]}" -eq 0 ]; then
        printf '%s\n' "none"
        return 0
    fi

    local IFS=", "
    printf '%s\n' "${missing_items[*]}"
}

require_bootstrap_request_setup_complete() {
    local missing_description=""

    missing_description=$(describe_bootstrap_request_setup_missing)
    if [ "$missing_description" = "none" ]; then
        return 0
    fi

    echo "ERROR: Classroom setup incomplete."
    echo "  Missing: $missing_description"
    echo "  Rerun a valid sudo openpath setup command before browser request setup."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stable)
            TRACK="stable"
            shift
            ;;
        --unstable)
            TRACK="unstable"
            shift
            ;;
        --skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        --api-url)
            API_URL="$2"
            shift 2
            ;;
        --classroom)
            CLASSROOM="$2"
            shift 2
            ;;
        --classroom-id)
            CLASSROOM_ID="$2"
            shift 2
            ;;
        --token-file)
            TOKEN_FILE="$2"
            shift 2
            ;;
        --token-stdin)
            TOKEN_STDIN=true
            shift
            ;;
        --enrollment-token)
            ENROLLMENT_TOKEN="$2"
            shift 2
            ;;
        --package-version)
            PACKAGE_VERSION="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [ "$VERBOSE" = true ]; then
    echo "=============================================="
    echo "  OpenPath Classroom Bootstrap"
    echo "=============================================="
    echo ""
else
    echo "Installing OpenPath..."
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (use sudo)"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get not found (Debian/Ubuntu required)"
    exit 1
fi

show_progress 1 6 "Installing bootstrap dependencies"
export DEBIAN_FRONTEND=noninteractive
remove_legacy_openpath_apt_source
run_maybe_verbose apt_install_with_retry "bootstrap dependencies" apt-get install -y -qq ca-certificates curl gnupg
log_verbose "  OK Dependencies ready"

show_progress 2 6 "Configuring OpenPath APT repository ($TRACK)"
setup_script="$(mktemp)"
trap 'rm -f "$setup_script"' EXIT
if [[ "$APT_SETUP_URL" == https://* ]]; then
    curl -fsSL --proto '=https' --tlsv1.2 "$APT_SETUP_URL" -o "$setup_script"
else
    curl -fsSL "$APT_SETUP_URL" -o "$setup_script"
fi
run_maybe_verbose bash "$setup_script" "--$TRACK"
log_verbose "  OK Repository configured"

run_firefox_package_preinstall

show_progress 4 6 "Validating and installing openpath-dnsmasq"
if ! apt-cache show openpath-dnsmasq >/dev/null 2>&1; then
    echo "ERROR: APT repository metadata does not advertise openpath-dnsmasq."
    if [ "$TRACK" = "stable" ] && apt-cache show whitelist-dnsmasq >/dev/null 2>&1; then
        echo "  The stable track is still serving the legacy whitelist-dnsmasq package."
    fi
    echo "  Retry after the selected track is republished."
    echo "  Temporary workaround (development builds only):"
    echo "    curl -fsSL $APT_REPO_URL/apt-bootstrap.sh | sudo bash -s -- --unstable"
    exit 1
fi

if [ -n "$PACKAGE_VERSION" ]; then
    PACKAGE_DEB_VERSION="${PACKAGE_VERSION}-1"
    if ! apt-cache show "openpath-dnsmasq=$PACKAGE_DEB_VERSION" >/dev/null 2>&1; then
        echo "ERROR: Requested openpath-dnsmasq version $PACKAGE_DEB_VERSION is not available on the $TRACK track."
        echo "  Refusing to install an implicit fallback package version."
        echo "  Publish the requested package first or update the enrollment manifest."
        exit 1
    fi
    run_maybe_verbose apt_install_with_retry "openpath-dnsmasq $PACKAGE_DEB_VERSION" \
        apt-get install -y "openpath-dnsmasq=$PACKAGE_DEB_VERSION"
else
    run_maybe_verbose apt_install_with_retry "openpath-dnsmasq" apt-get install -y openpath-dnsmasq
fi
log_verbose "  OK Package installed"

if [ "$SKIP_SETUP" = true ]; then
    show_progress 5 6 "Classroom setup skipped"
    log_verbose "Classroom setup skipped (--skip-setup)"
    show_progress 6 6 "Browser request setup skipped"
    echo "Run manually later: sudo openpath setup"
    exit 0
fi

if [ -n "$ENROLLMENT_TOKEN" ] && [ -z "$CLASSROOM_ID" ]; then
    echo "ERROR: --classroom-id is required when using --enrollment-token"
    exit 1
fi

if [ -n "$ENROLLMENT_TOKEN" ] && { [ -n "$TOKEN_FILE" ] || [ "$TOKEN_STDIN" = true ]; }; then
    echo "ERROR: --enrollment-token cannot be combined with --token-file or --token-stdin"
    exit 1
fi

show_progress 5 6 "Running classroom setup"
setup_cmd=(openpath setup)

if [ -n "$API_URL" ]; then
    setup_cmd+=(--api-url "$API_URL")
fi
if [ -n "$CLASSROOM" ]; then
    setup_cmd+=(--classroom "$CLASSROOM")
fi
if [ -n "$CLASSROOM_ID" ]; then
    setup_cmd+=(--classroom-id "$CLASSROOM_ID")
fi
if [ -n "$TOKEN_FILE" ]; then
    setup_cmd+=(--token-file "$TOKEN_FILE")
fi
if [ "$TOKEN_STDIN" = true ]; then
    setup_cmd+=(--token-stdin)
fi
if [ -n "$ENROLLMENT_TOKEN" ]; then
    setup_cmd+=(--enrollment-token "$ENROLLMENT_TOKEN")
fi

if ! run_maybe_verbose "${setup_cmd[@]}"; then
    echo ""
    echo "ERROR: Classroom setup failed."
    echo "  Generate a fresh enrollment command or rerun a valid setup command."
    echo ""
    exit 1
fi

require_bootstrap_request_setup_complete
run_browser_setup_helper

echo ""
echo "OK Classroom setup completed"
if [ "$VERBOSE" = true ]; then
    openpath status || true
    openpath health || true
fi
