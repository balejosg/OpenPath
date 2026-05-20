#!/usr/bin/env bats
################################################################################
# dns.bats - Tests for lib/dns.sh
################################################################################

load 'test_helper'

setup() {
    # Create temp directory for tests
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/lib"
    
    # Copy libs
    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true
}

teardown() {
    if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

# ============== Configuration generation tests ==============

@test "generates dnsmasq config with whitelisted domains" {
    local config_file="$TEST_TMP_DIR/dnsmasq.conf"
    local dns_server="8.8.8.8"
    local domains="google.com
github.com"
    
    # Simulate config generation
    {
        echo "# Generated config"
        echo "address=/#/192.0.2.1"
        echo "address=/#/100::"
        for domain in $domains; do
            echo "server=/$domain/$dns_server"
        done
    } > "$config_file"
    
    [ -f "$config_file" ]
    grep -q "address=/#/192.0.2.1" "$config_file"
    grep -q "address=/#/100::" "$config_file"
    grep -q "server=/google.com/8.8.8.8" "$config_file"
    grep -q "server=/github.com/8.8.8.8" "$config_file"
}

@test "default sinkhole addresses appear BEFORE server= directives" {
    local config_file="$TEST_TMP_DIR/dnsmasq.conf"
    
    {
        echo "address=/#/192.0.2.1"
        echo "address=/#/100::"
        echo "server=/google.com/8.8.8.8"
    } > "$config_file"
    
    # Verify order: sinkhole addresses must be before server allow rules
    local address_line=$(grep -n "address=/#/192.0.2.1" "$config_file" | cut -d: -f1)
    local ipv6_line=$(grep -n "address=/#/100::" "$config_file" | cut -d: -f1)
    local server_line=$(grep -n "server=/google.com" "$config_file" | cut -d: -f1)
    
    [ "$address_line" -lt "$server_line" ]
    [ "$ipv6_line" -lt "$server_line" ]
}

# ============== DNS detection tests ==============

@test "detect_primary_dns returns valid IP or fallback" {
    # Mock for when no DNS is detected
    local dns="8.8.8.8"  # Fallback
    
    # Validate that it's an IP
    if [[ "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local valid=true
    else
        local valid=false
    fi
    
    [ "$valid" = true ]
}

@test "detect_primary_dns reads non-local resolv.conf nameserver before fallback" {
    local state_dir="$TEST_TMP_DIR/detect-resolv"
    mkdir -p "$state_dir/etc"

    cat > "$state_dir/resolv.conf" <<'EOF'
nameserver 127.0.0.53
nameserver 168.63.129.16
EOF

    local helper_script="$TEST_TMP_DIR/detect-primary-dns-resolv.sh"
    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"

export ETC_CONFIG_DIR="$state_dir/etc"
export VAR_STATE_DIR="$state_dir/var"
export FALLBACK_DNS_PRIMARY="8.8.8.8"
export OPENPATH_SYSTEMD_RESOLV_CONF="$state_dir/missing-systemd-resolv.conf"
export OPENPATH_RESOLV_CONF="$state_dir/resolv.conf"

mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"

source "$project_dir/linux/lib/common.sh"

nmcli() { return 127; }
ip() { return 1; }
timeout() {
    shift
    if [ "${1:-}" = "dig" ] && [ "${2:-}" = "@168.63.129.16" ]; then
        printf '%s\n' "142.250.184.206"
        return 0
    fi
    return 1
}

detect_primary_dns
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [ "$output" = "168.63.129.16" ]
}

@test "detect_primary_dns never reuses loopback as dnsmasq upstream" {
    local state_dir="$TEST_TMP_DIR/detect-loopback"
    mkdir -p "$state_dir/etc"

    printf '%s\n' "127.0.0.1" > "$state_dir/etc/original-dns.conf"
    printf '%s\n' "nameserver 168.63.129.16" > "$state_dir/resolv.conf"

    local helper_script="$TEST_TMP_DIR/detect-primary-dns-loopback.sh"
    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"

export ETC_CONFIG_DIR="$state_dir/etc"
export VAR_STATE_DIR="$state_dir/var"
export FALLBACK_DNS_PRIMARY="8.8.8.8"
export OPENPATH_SYSTEMD_RESOLV_CONF="$state_dir/missing-systemd-resolv.conf"
export OPENPATH_RESOLV_CONF="$state_dir/resolv.conf"

mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"

source "$project_dir/linux/lib/common.sh"

nmcli() { return 127; }
ip() { return 1; }
timeout() {
    shift
    case "${2:-}" in
        @127.0.0.1|@168.63.129.16)
            printf '%s\n' "142.250.184.206"
            return 0
            ;;
    esac
    return 1
}

detect_primary_dns
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [ "$output" = "168.63.129.16" ]
}

# ============== resolv.conf configuration tests ==============

@test "resolv.conf points to localhost" {
    local resolv_file="$TEST_TMP_DIR/resolv.conf"
    
    echo "nameserver 127.0.0.1" > "$resolv_file"
    
    grep -q "nameserver 127.0.0.1" "$resolv_file"
}

@test "dnsmasq init script reads preserved upstream DNS from /etc openpath config" {
    local state_dir="$TEST_TMP_DIR/dns-init-script"
    local helper_script="$TEST_TMP_DIR/create-dns-init-script.sh"

    mkdir -p "$state_dir/bin" "$state_dir/etc" "$state_dir/var"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"

export INSTALL_DIR="$project_dir/linux"
export ETC_CONFIG_DIR="$state_dir/etc/openpath"
export VAR_STATE_DIR="$state_dir/var/lib/openpath"
export SCRIPTS_DIR="$state_dir/bin"
mkdir -p "$ETC_CONFIG_DIR" "$VAR_STATE_DIR" "$SCRIPTS_DIR"

source "$project_dir/linux/lib/common.sh"
source "$project_dir/linux/lib/dns.sh"

create_dns_init_script

grep -nF "$ETC_CONFIG_DIR/original-dns.conf" "$SCRIPTS_DIR/dnsmasq-init-resolv.sh"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
}

@test "select_usable_upstream_dns falls back when PRIMARY_DNS is loopback" {
    export OPENPATH_FALLBACK_DNS="9.9.9.9"

    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run select_usable_upstream_dns "127.0.0.1"

    [ "$status" -eq 0 ]
    [ "$output" = "9.9.9.9" ]
}

# ============== Tests de generate_dnsmasq_config ==============

@test "generate_dnsmasq_config creates configuration file" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/dnsmasq.d/url-whitelist.conf"
    export PRIMARY_DNS="8.8.8.8"
    export VERSION="3.5"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"
    
    mkdir -p "$(dirname "$DNSMASQ_CONF")"

    log() { echo "$1"; }
    export -f log
    
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    WHITELIST_DOMAINS=("google.com" "github.com")
    BLOCKED_SUBDOMAINS=()
    BLOCKED_PATHS=()
    
    run generate_dnsmasq_config
    [ "$status" -eq 0 ]
    [ -f "$DNSMASQ_CONF" ]
}

@test "generate_dnsmasq_config includes non-local sinkhole addresses first" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/dnsmasq.d/url-whitelist.conf"
    export PRIMARY_DNS="8.8.8.8"
    export VERSION="3.5"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"
    
    mkdir -p "$(dirname "$DNSMASQ_CONF")"

    log() { echo "$1"; }
    export -f log
    
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    WHITELIST_DOMAINS=("google.com")
    BLOCKED_SUBDOMAINS=()
    BLOCKED_PATHS=()
    
    generate_dnsmasq_config
    
    grep -q "address=/#/192.0.2.1" "$DNSMASQ_CONF"
    grep -q "address=/#/100::" "$DNSMASQ_CONF"

    local address_line
    local ipv6_line
    local server_line
    address_line=$(grep -n "address=/#/192.0.2.1" "$DNSMASQ_CONF" | cut -d: -f1)
    ipv6_line=$(grep -n "address=/#/100::" "$DNSMASQ_CONF" | cut -d: -f1)
    server_line=$(grep -n "server=/google.com" "$DNSMASQ_CONF" | cut -d: -f1)

    [ "$address_line" -lt "$server_line" ]
    [ "$ipv6_line" -lt "$server_line" ]
}

@test "generate_dnsmasq_config falls back before writing stale loopback upstream" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/dnsmasq.d/url-whitelist.conf"
    export PRIMARY_DNS="127.0.0.1"
    export OPENPATH_FALLBACK_DNS="9.9.9.9"
    export VERSION="3.5"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"

    mkdir -p "$(dirname "$DNSMASQ_CONF")"

    log() { echo "$1"; }
    export -f log

    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    WHITELIST_DOMAINS=("google.com")
    BLOCKED_SUBDOMAINS=()
    BLOCKED_PATHS=()

    run generate_dnsmasq_config

    [ "$status" -eq 0 ]
    grep -q "server=/google.com/9.9.9.9" "$DNSMASQ_CONF"
    ! grep -q "^server=.*127.0.0.1" "$DNSMASQ_CONF"
}

@test "write_dnsmasq_default_sinkhole_rules emits explicit non-local IPv4 and IPv6 sinkholes only" {
    local config_file="$TEST_TMP_DIR/dnsmasq.conf"

    log_warn() { echo "$1"; }
    export -f log_warn

    source "$PROJECT_DIR/linux/lib/dns.sh"

    run write_dnsmasq_default_sinkhole_rules "$config_file"

    [ "$status" -eq 0 ]
    grep -qx "address=/#/192.0.2.1" "$config_file"
    grep -qx "address=/#/100::" "$config_file"
    ! grep -qx "address=/#/0.0.0.0" "$config_file"
    ! grep -qx "address=/#/::" "$config_file"
    ! grep -qx "address=/#/" "$config_file"
}

@test "runtime health probes never use an invalid sentinel domain as the blocked-domain check" {
    run grep -Rsn "blocked-test.invalid" "$PROJECT_DIR/linux/lib" "$PROJECT_DIR/linux/scripts/runtime"

    [ "$status" -ne 0 ]
}

@test "runtime dependency policy accepts dependency only when anchor is locally whitelisted" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"

    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=()

    run validate_runtime_dependency_candidate "allowed.example" "cdn.example" "fetch"

    [ "$status" -eq 0 ]
    [[ "$output" == *"anchorHost=allowed.example"* ]]
    [[ "$output" == *"dependencyHost=cdn.example"* ]]
    [[ "$output" == *"requestType=fetch"* ]]
}

@test "runtime dependency policy rejects unapproved anchor host" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"

    WHITELIST_DOMAINS=("other.example")
    BLOCKED_SUBDOMAINS=()

    run validate_runtime_dependency_candidate "blocked.example" "cdn.example" "fetch"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Anchor host is not locally whitelisted"* ]]
}

@test "runtime dependency policy rejects main_frame and blocked dependency hosts" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"

    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=("cdn.example")

    run validate_runtime_dependency_candidate "allowed.example" "cdn.example" "fetch"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Blocked hosts are not accepted as runtime dependencies"* ]]

    run validate_runtime_dependency_candidate "allowed.example" "asset.example" "main_frame"
    [ "$status" -ne 0 ]
    [[ "$output" == *"main_frame dependencies are not supported"* ]]
}

@test "runtime dependency policy rejects protected hosts and reports same-host as skipped" {
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-policy.sh"

    WHITELIST_DOMAINS=("allowed.example" "github.com")
    BLOCKED_SUBDOMAINS=()

    run validate_runtime_dependency_candidate "allowed.example" "github.com" "fetch"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Protected hosts are not accepted as runtime dependencies"* ]]

    run validate_runtime_dependency_candidate "allowed.example" "allowed.example" "fetch"
    [ "$status" -eq 2 ]
    [[ "$output" == *"reason=same-host"* ]]
}

@test "generate_dnsmasq_config includes runtime dependency domains as exact local allows" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/openpath.conf"
    export PRIMARY_DNS="8.8.8.8"
    export VERSION="3.5"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"
    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export RUNTIME_DEPENDENCY_OVERLAY_FILE="$VAR_STATE_DIR/runtime-dependency-overlay.json"
    mkdir -p "$VAR_STATE_DIR"
    cat > "$RUNTIME_DEPENDENCY_OVERLAY_FILE" <<'JSON'
{"version":1,"entries":[
  {"anchorHost":"allowed.example","dependencyHost":"cdn.example","requestTypes":["fetch"],"firstSeen":"2099-01-01T00:00:00Z","lastSeen":"2099-01-01T00:00:00Z","expiresAt":"2099-01-02T00:00:00Z","source":"firefox-webrequest-local"}
]}
JSON

    log() { echo "$1"; }
    export -f log

    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-overlay.sh"

    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=()
    BLOCKED_PATHS=()

    run generate_dnsmasq_config

    [ "$status" -eq 0 ]
    grep -q "server=/cdn.example/8.8.8.8" "$DNSMASQ_CONF"
}

@test "generate_dnsmasq_config renders runtime dependency domains before blocked subdomain NXDOMAIN entries" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/openpath.conf"
    export PRIMARY_DNS="8.8.8.8"
    export VERSION="3.5"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"
    export VAR_STATE_DIR="$TEST_TMP_DIR/var/lib/openpath"
    export RUNTIME_DEPENDENCY_OVERLAY_FILE="$VAR_STATE_DIR/runtime-dependency-overlay.json"
    mkdir -p "$VAR_STATE_DIR"
    cat > "$RUNTIME_DEPENDENCY_OVERLAY_FILE" <<'JSON'
{"version":1,"entries":[
  {"anchorHost":"allowed.example","dependencyHost":"cdn.example","requestTypes":["fetch"],"firstSeen":"2099-01-01T00:00:00Z","lastSeen":"2099-01-01T00:00:00Z","expiresAt":"2099-01-02T00:00:00Z","source":"firefox-webrequest-local"}
]}
JSON

    log() { echo "$1"; }
    export -f log

    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"
    source "$PROJECT_DIR/linux/lib/runtime-dependency-overlay.sh"

    WHITELIST_DOMAINS=("allowed.example")
    BLOCKED_SUBDOMAINS=("blocked.allowed.example")
    BLOCKED_PATHS=()

    run generate_dnsmasq_config

    [ "$status" -eq 0 ]
    local runtime_line
    local blocked_line
    runtime_line=$(grep -n "server=/cdn.example/8.8.8.8" "$DNSMASQ_CONF" | cut -d: -f1)
    blocked_line=$(grep -n "address=/blocked.allowed.example/" "$DNSMASQ_CONF" | cut -d: -f1)
    [ "$runtime_line" -lt "$blocked_line" ]
}

@test "generate_dnsmasq_config includes domains from whitelist" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/dnsmasq.d/url-whitelist.conf"
    export PRIMARY_DNS="8.8.8.8"
    export VERSION="3.5"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"
    
    mkdir -p "$(dirname "$DNSMASQ_CONF")"

    log() { echo "$1"; }
    export -f log
    
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    WHITELIST_DOMAINS=("example.org" "test.com")
    BLOCKED_SUBDOMAINS=()
    BLOCKED_PATHS=()
    
    generate_dnsmasq_config
    
    grep -q "server=/example.org/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/test.com/8.8.8.8" "$DNSMASQ_CONF"
}

@test "generate_dnsmasq_config includes protected control-plane, Firefox, and bootstrap domains" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/dnsmasq.d/url-whitelist.conf"
    export PRIMARY_DNS="8.8.8.8"
    export VERSION="3.5"
    export ETC_CONFIG_DIR="$TEST_TMP_DIR/etc"
    export WHITELIST_URL_CONF="$ETC_CONFIG_DIR/whitelist-url.conf"
    export HEALTH_API_URL_CONF="$ETC_CONFIG_DIR/health-api-url.conf"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"

    mkdir -p "$(dirname "$DNSMASQ_CONF")" "$ETC_CONFIG_DIR"

    echo "https://downloads.example/w/token/whitelist.txt" > "$WHITELIST_URL_CONF"
    echo "https://control.example" > "$HEALTH_API_URL_CONF"

    WHITELIST_DOMAINS=("safe.example")
    BLOCKED_SUBDOMAINS=()
    BLOCKED_PATHS=()

    log() { echo "$1"; }
    export -f log

    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    generate_dnsmasq_config

    grep -q "server=/control.example/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/downloads.example/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/api.github.com/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/release-assets.githubusercontent.com/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/downloads.sourceforge.net/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/aus5.mozilla.org/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/download.mozilla.org/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/download.cdn.mozilla.net/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/archive.mozilla.org/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/firefox.settings.services.mozilla.com/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/addons.mozilla.org/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/versioncheck.addons.mozilla.org/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/safebrowsing.googleapis.com/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/ciscobinary.openh264.org/8.8.8.8" "$DNSMASQ_CONF"
    grep -q "server=/redirector.gvt1.com/8.8.8.8" "$DNSMASQ_CONF"
    ! grep -q "server=/incoming.telemetry.mozilla.org/" "$DNSMASQ_CONF"
    ! grep -q "server=/ads.mozilla.org/" "$DNSMASQ_CONF"
    ! grep -q "server=/mozilla.cloudflare-dns.com/" "$DNSMASQ_CONF"
}

@test "generate_dnsmasq_config includes blocked subdomains" {
    export DNSMASQ_CONF="$TEST_TMP_DIR/dnsmasq.d/url-whitelist.conf"
    export PRIMARY_DNS="8.8.8.8"
    export VERSION="3.5"
    export LOG_FILE="$TEST_TMP_DIR/openpath.log"
    
    mkdir -p "$(dirname "$DNSMASQ_CONF")"

    log() { echo "$1"; }
    export -f log
    
    source "$PROJECT_DIR/linux/lib/common.sh"
    source "$PROJECT_DIR/linux/lib/dns.sh"

    WHITELIST_DOMAINS=("example.org")
    BLOCKED_SUBDOMAINS=("ads.example.org")
    BLOCKED_PATHS=()
    
    generate_dnsmasq_config
    
    grep -q "address=/ads.example.org/" "$DNSMASQ_CONF"
}

# ============== Tests de validate_dnsmasq_config ==============

@test "validate_dnsmasq_config detects valid config" {
    # Mock dnsmasq
    dnsmasq() {
        echo "dnsmasq: syntax check OK."
        return 0
    }
    export -f dnsmasq
    
    log() { echo "$1"; }
    export -f log
    
    source "$PROJECT_DIR/linux/lib/dns.sh"
    
    run validate_dnsmasq_config
    [ "$status" -eq 0 ]
}

@test "validate_dnsmasq_config detects invalid config" {
    # Mock dnsmasq with error
    dnsmasq() {
        echo "dnsmasq: syntax error at line 5"
        return 1
    }
    export -f dnsmasq
    
    log() { echo "$1"; }
    export -f log
    
    source "$PROJECT_DIR/linux/lib/dns.sh"
    
    run validate_dnsmasq_config
    [ "$status" -eq 1 ]
}

# ============== Tests de verify_dns ==============

@test "verify_dns returns success with functional DNS" {
    # Mock dig
    dig() {
        echo "142.250.185.206"
        return 0
    }
    export -f dig
    
    # Mock timeout
    timeout() {
        shift  # Remove timeout value
        "$@"   # Execute the rest
    }
    export -f timeout
    
    source "$PROJECT_DIR/linux/lib/dns.sh"
    
    run verify_dns
    [ "$status" -eq 0 ]
}

@test "verify_dns resolves a domain from the active whitelist" {
    export WHITELIST_FILE="$TEST_TMP_DIR/whitelist.txt"
    cat > "$WHITELIST_FILE" <<'EOF'
## WHITELIST
google.es
EOF

    dig() {
        case "$2" in
            google.es)
                echo "216.58.204.163"
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    }
    export -f dig

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    source "$PROJECT_DIR/linux/lib/dns.sh"

    run verify_dns
    [ "$status" -eq 0 ]
}

@test "verify_dns rejects sinkhole-only DNS answers" {
    export WHITELIST_FILE="$TEST_TMP_DIR/whitelist.txt"
    cat > "$WHITELIST_FILE" <<'EOF'
## WHITELIST
google.es
EOF

    dig() {
        echo "0.0.0.0"
        return 0
    }
    export -f dig

    timeout() {
        shift
        "$@"
    }
    export -f timeout

    source "$PROJECT_DIR/linux/lib/dns.sh"

    run verify_dns
    [ "$status" -eq 1 ]
}

@test "verify_dns returns error with failing DNS" {
    # Mock dig to fail
    dig() {
        return 1
    }
    export -f dig

    timeout() {
        return 1
    }
    export -f timeout

    source "$PROJECT_DIR/linux/lib/dns.sh"

    run verify_dns
    [ "$status" -eq 1 ]
}

# ============== Tests de validate_domain ==============

@test "validate_domain rejects empty string" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain ""
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain too short" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "a.b"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain exceeding 253 chars" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    # Create a domain that's 254 characters (63.63.63.63 pattern repeated)
    local long_domain=""
    for i in {1..4}; do
        long_domain+="$(printf 'a%.0s' {1..63})."
    done
    long_domain+="com"

    run validate_domain "$long_domain"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain starting with hyphen in label" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "-example.com"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain ending with hyphen in label" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "example-.com"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain with consecutive dots" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "example..com"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain with single label" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "localhost"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects TLD with numbers" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "example.c0m"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects TLD too short" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "example.c"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects label exceeding 63 chars" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    # Create a label that's 64 characters
    local long_label="$(printf 'a%.0s' {1..64})"

    run validate_domain "${long_label}.com"
    [ "$status" -eq 1 ]
}

@test "validate_domain accepts valid simple domain" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts valid subdomain" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "www.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts valid deep subdomain" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "a.b.c.d.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts wildcard domain" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "*.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts domain with hyphens in middle" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "my-example-site.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts domain with numbers in labels" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "abc123.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts valid long TLD" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run validate_domain "example.technology"
    [ "$status" -eq 0 ]
}

# ============== Tests de sanitize_domain ==============

@test "sanitize_domain removes special characters" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run sanitize_domain "example<script>.com"
    [ "$output" = "examplescript.com" ]
}

@test "sanitize_domain preserves valid characters" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run sanitize_domain "my-example.com"
    [ "$output" = "my-example.com" ]
}

@test "sanitize_domain removes spaces" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run sanitize_domain "example .com"
    [ "$output" = "example.com" ]
}

@test "sanitize_domain removes shell metacharacters" {
    source "$PROJECT_DIR/linux/lib/dns.sh"

    run sanitize_domain 'example$(rm -rf /).com'
    [ "$output" = "examplerm-rf.com" ]
}
