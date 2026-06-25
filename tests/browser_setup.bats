#!/usr/bin/env bats
################################################################################
# browser_setup.bats - Tests for the Linux browser setup helper
################################################################################

load 'test_helper'

write_mock_id() {
    local bin_dir="$1"

    cat > "$bin_dir/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
    echo 0
    exit 0
fi

/usr/bin/id "$@"
EOF
    chmod +x "$bin_dir/id"
}

write_timeout_requires_kill_after() {
    local bin_dir="$1"
    local calls_file="$2"

    cat > "$bin_dir/timeout" <<EOF
#!/bin/bash
echo "\$*" >> "$calls_file"
case " \$* " in
    *" --kill-after=5s "*)
        shift
        shift
        exec "\$@"
        ;;
    *)
        echo "timeout missing --kill-after=5s" >&2
        exit 99
        ;;
esac
EOF
    chmod +x "$bin_dir/timeout"
}

write_timeout_runs_probe_then_times_out() {
    local bin_dir="$1"
    local calls_file="$2"

    cat > "$bin_dir/timeout" <<EOF
#!/bin/bash
echo "\$*" >> "$calls_file"
case " \$* " in
    *" --kill-after=5s "*)
        shift
        shift
        "\$@" || true
        exit 124
        ;;
    *)
        echo "timeout missing --kill-after=5s" >&2
        exit 99
        ;;
esac
EOF
    chmod +x "$bin_dir/timeout"
}

write_timeout_first_probe_exceeds_deadline_then_registers() {
    local bin_dir="$1"
    local calls_file="$2"

    cat > "$bin_dir/timeout" <<EOF
#!/bin/bash
echo "\$*" >> "$calls_file"
case " \$* " in
    *" --kill-after=5s "*)
        shift
        shift
        count_file="\${HOME:-}/.mozilla/firefox/openpath-test-timeout-count"
        mkdir -p "\$(dirname "\$count_file")"
        run_count=0
        if [ -f "\$count_file" ]; then
            run_count=\$(cat "\$count_file" 2>/dev/null || echo 0)
        fi
        run_count=\$((run_count + 1))
        echo "\$run_count" > "\$count_file"
        if [ "\$run_count" -eq 1 ]; then
            OPENPATH_FAKE_FIREFOX_MODE=policy-only "\$@" || true
            sleep 2
            exit 124
        fi
        "\$@" || true
        exit 124
        ;;
    *)
        echo "timeout missing --kill-after=5s" >&2
        exit 99
        ;;
esac
EOF
    chmod +x "$bin_dir/timeout"
}

write_fake_common_sh() {
    local target="$1"

    cat > "$target" <<'EOF'
#!/bin/bash
set -euo pipefail

export INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/openpath}"
export SCRIPTS_DIR="${SCRIPTS_DIR:-/usr/local/bin}"
ETC_CONFIG_DIR="${ETC_CONFIG_DIR:-/etc/openpath}"
VAR_STATE_DIR="${VAR_STATE_DIR:-/tmp/openpath-browser-setup-test-state-$$}"
LOG_FILE="${LOG_FILE:-/var/log/openpath.log}"
export FIREFOX_POLICIES="${FIREFOX_POLICIES:-/etc/firefox/policies/policies.json}"
export FIREFOX_EXTENSIONS_ROOT="${FIREFOX_EXTENSIONS_ROOT:-/usr/share/mozilla/extensions}"
export WHITELIST_URL_CONF="${WHITELIST_URL_CONF:-$ETC_CONFIG_DIR/whitelist-url.conf}"

log() { echo "$1"; }
log_error() { echo "$1" >&2; }

read_single_line_file() {
    local file="$1"
    [ -r "$file" ] || return 1
    tr -d '\r\n' < "$file"
}

is_tokenized_whitelist_url() {
    local url="$1"
    [[ "$url" =~ /w/[^/]+/whitelist\.txt($|[?#].*) ]]
}

is_openpath_request_setup_complete() {
    local api_url=""
    local whitelist_url=""
    local classroom=""
    local classroom_id=""
    api_url=$(read_single_line_file "$ETC_CONFIG_DIR/api-url.conf" || true)
    whitelist_url=$(read_single_line_file "$WHITELIST_URL_CONF" || true)
    classroom=$(read_single_line_file "$ETC_CONFIG_DIR/classroom.conf" || true)
    classroom_id=$(read_single_line_file "$ETC_CONFIG_DIR/classroom-id.conf" || true)

    [ -n "$api_url" ] || return 1
    [ -n "$whitelist_url" ] && is_tokenized_whitelist_url "$whitelist_url" || return 1
    [ -n "$classroom" ] || [ -n "$classroom_id" ]
}

describe_openpath_request_setup_missing() {
    echo "request setup incomplete"
}

require_openpath_request_setup_complete() {
    if is_openpath_request_setup_complete; then
        return 0
    fi
    echo "request setup incomplete" >&2
    return 1
}
EOF
}

@test "firefox activation plan enumerates existing normal and snap profiles" {
    local passwd_file="$TEST_TMP_DIR/passwd"
    local alice_home="$TEST_TMP_DIR/home/alice"
    local bob_home="$TEST_TMP_DIR/home/bob"

    mkdir -p "$alice_home/.mozilla/firefox/first.default" "$alice_home/.mozilla/firefox/second.default"
    mkdir -p "$bob_home/snap/firefox/common/.mozilla/firefox/snap.default"
    cat > "$alice_home/.mozilla/firefox/profiles.ini" <<'EOF'
[Profile0]
Name=first
IsRelative=1
Path=first.default

[Profile1]
Name=second
IsRelative=1
Path=second.default
EOF
    cat > "$bob_home/snap/firefox/common/.mozilla/firefox/profiles.ini" <<'EOF'
[Profile0]
Name=snap
IsRelative=1
Path=snap.default
EOF
    printf 'alice:x:1001:1001::%s:/bin/bash\nbob:x:1002:1002::%s:/bin/bash\n' "$alice_home" "$bob_home" > "$passwd_file"

    run env OPENPATH_PASSWD_FILE="$passwd_file" bash -c \
        'source "$1"; enumerate_firefox_activation_targets' bash "$PROJECT_DIR/linux/lib/firefox-activation-plan.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *$'alice\t'"$alice_home"$'\t'"$alice_home/.mozilla/firefox/first.default"* ]]
    [[ "$output" == *$'alice\t'"$alice_home"$'\t'"$alice_home/.mozilla/firefox/second.default"* ]]
    [[ "$output" == *$'bob\t'"$bob_home"$'\t'"$bob_home/snap/firefox/common/.mozilla/firefox/snap.default"* ]]
}

@test "firefox activation plan creates fallback profile only for interactive users" {
    local passwd_file="$TEST_TMP_DIR/passwd"
    local alice_home="$TEST_TMP_DIR/home/alice"
    local daemon_home="$TEST_TMP_DIR/home/daemon"
    local service_home="$TEST_TMP_DIR/home/service"

    mkdir -p "$alice_home" "$daemon_home" "$service_home"
    printf 'root:x:0:0::/root:/bin/bash\ndaemon:x:1:1::%s:/usr/sbin/nologin\nservice:x:999:999::%s:/bin/bash\nalice:x:1001:1001::%s:/bin/bash\n' \
        "$daemon_home" "$service_home" "$alice_home" > "$passwd_file"

    run env OPENPATH_PASSWD_FILE="$passwd_file" bash -c \
        'source "$1"; enumerate_firefox_activation_targets' bash "$PROJECT_DIR/linux/lib/firefox-activation-plan.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == $'alice\t'"$alice_home"$'\t'"$alice_home/.mozilla/firefox/openpath.default" ]]
    [[ "$output" != *"daemon"* ]]
    [[ "$output" != *"service"* ]]
    [[ "$output" != *$'root\t'* ]]
}

@test "firefox activation plan profile override limits target verification" {
    local passwd_file="$TEST_TMP_DIR/passwd"
    local home_dir="$TEST_TMP_DIR/home/alice"
    local override_profile="$TEST_TMP_DIR/custom/profile"

    mkdir -p "$home_dir"
    printf 'alice:x:1001:1001::%s:/bin/bash\n' "$home_dir" > "$passwd_file"

    run env \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FIREFOX_PROFILE_USER="alice" \
        OPENPATH_FIREFOX_PROFILE_HOME="$home_dir" \
        OPENPATH_FIREFOX_PROFILE_DIR="$override_profile" \
        bash -c 'source "$1"; enumerate_firefox_activation_targets' bash "$PROJECT_DIR/linux/lib/firefox-activation-plan.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == $'alice\t'"$home_dir"$'\t'"$override_profile" ]]
}

write_fake_browser_sh() {
    local target="$1"
    local calls_file="$2"
    local firefox_dir="$3"
    local ext_root="$4"
    local policies_file="$5"
    local mode="$6"

    cat > "$target" <<EOF
#!/bin/bash

install_firefox_esr() {
    echo "install_firefox_esr" >> "$calls_file"
    mkdir -p "$firefox_dir"
    cat > "$firefox_dir/firefox" <<'FIREFOX'
#!/bin/bash
profile_root="\${HOME:-}/.mozilla/firefox/openpath-test.default"
explicit_profile=0
selected_install_profile=""
profiles_ini_path="\${HOME:-}/.mozilla/firefox/profiles.ini"
if [ -f "\$profiles_ini_path" ]; then
    selected_install_profile="\$(python3 - "\$profiles_ini_path" <<'PY' 2>/dev/null || true
import configparser
import sys
from pathlib import Path

profiles_ini = Path(sys.argv[1])
parser = configparser.RawConfigParser()
parser.read(profiles_ini, encoding="utf-8")

for section in parser.sections():
    if not section.startswith("Install"):
        continue
    default = parser.get(section, "Default", fallback="").strip()
    locked = parser.get(section, "Locked", fallback="").strip()
    if default and locked == "1":
        print((profiles_ini.parent / default).resolve())
        raise SystemExit(0)

raise SystemExit(1)
PY
)"
fi
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --profile|-profile|--Profile|-Profile)
            if [ -n "\${2:-}" ]; then
                profile_root="\$2"
                explicit_profile=1
                shift 2
                continue
            fi
            ;;
    esac
    shift
done
if [ "\$explicit_profile" -eq 0 ] && [ -n "\$selected_install_profile" ]; then
    profile_root="\$selected_install_profile"
fi
mkdir -p "\$profile_root"
count_file="\${HOME:-}/.mozilla/firefox/openpath-test-run-count"
mkdir -p "\$(dirname "\$count_file")"
run_count=0
if [ -f "\$count_file" ]; then
    run_count=\$(cat "\$count_file" 2>/dev/null || echo 0)
fi
run_count=\$((run_count + 1))
echo "\$run_count" > "\$count_file"
case "\${OPENPATH_FAKE_FIREFOX_MODE:-success}" in
    policy-only|missing-firefox)
        ;;
    snap-registration)
        snap_profile_root="\${HOME:-}/snap/firefox/common/.mozilla/firefox/openpath-test.default"
        mkdir -p "\$snap_profile_root"
        cat > "\$snap_profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
        ;;
    delayed-registration)
        if [ "\$run_count" -ge 2 ]; then
            cat > "\$profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
        fi
        ;;
    third-registration)
        if [ "\$run_count" -ge 3 ]; then
            cat > "\$profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
        fi
        ;;
    requires-profile-registration)
        if [ "\$explicit_profile" -eq 1 ]; then
            cat > "\$profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
        fi
        ;;
    missing-second-profile)
        case "\$profile_root" in
            *second.default)
                ;;
            *)
                cat > "\$profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
                ;;
        esac
        ;;
    disabled-extension)
        cat > "\$profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","active":false,"userDisabled":true,"signedState":-1,"location":"app-system-share","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
        ;;
    install-profile-registration)
        if [ -n "\$selected_install_profile" ] && [ "\$profile_root" = "\$selected_install_profile" ]; then
            cat > "\$profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
        fi
        ;;
    *)
        cat > "\$profile_root/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
        ;;
esac
exit 0
FIREFOX
    chmod +x "$firefox_dir/firefox"
    return 0
}

install_browser_integrations() {
    local ext_source="$1"
    local release_source="$2"
    shift 2
    echo "install_browser_integrations:\$ext_source|\$release_source|\$*" >> "$calls_file"

    if [ "$mode" = "missing-native" ]; then
        if [[ " \$* " == *" --native-host-best-effort "* ]]; then
            return 0
        fi
        echo "native host missing" >&2
        return 1
    fi

    if [[ " \$* " == *" --native-host "* ]]; then
        local native_manifest_dir="\${FIREFOX_NATIVE_HOST_DIR:-$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts}"
        local native_script_dir="\${OPENPATH_NATIVE_HOST_INSTALL_DIR:-$TEST_TMP_DIR/local/lib/openpath}"
        mkdir -p "\$native_manifest_dir" "\$native_script_dir"
        cat > "\$native_manifest_dir/whitelist_native_host.json" <<'JSON'
{"name":"whitelist_native_host","path":"/usr/local/lib/openpath/openpath-native-host.py","type":"stdio","allowed_extensions":["openpath-block-monitor@openpath"]}
JSON
        echo '#!/usr/bin/env python3' > "\$native_script_dir/openpath-native-host.py"
        chmod +x "\$native_script_dir/openpath-native-host.py"
    fi

    if [ "$mode" = "success" ]; then
        local app_id="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
        local ext_dir="$ext_root/\$app_id/openpath-block-monitor@openpath"
        mkdir -p "\$ext_dir"
        touch "\$ext_dir/manifest.json"
        mkdir -p "\$(dirname "$policies_file")"
        cat > "$policies_file" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed","install_url":"https://control.example/api/extensions/firefox/openpath.xpi"}}}}
JSON
    elif [ "$mode" = "managed-api" ]; then
        mkdir -p "\$(dirname "$policies_file")"
        cat > "$policies_file" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed","install_url":"https://control.example/api/extensions/firefox/openpath.xpi"}}}}
JSON
    elif [ "$mode" = "policy-only" ]; then
        mkdir -p "\$(dirname "$policies_file")"
        cat > "$policies_file" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed","install_url":"https://control.example/api/extensions/firefox/openpath.xpi"}}}}
JSON
    fi

    return 0
}

apply_search_engine_policies() {
    echo "apply_search_engine_policies" >> "$calls_file"
    return 0
}

detect_firefox_dir() {
    if [ "$mode" = "missing-firefox" ]; then
        return 1
    fi

    echo "$firefox_dir"
    return 0
}

force_browser_close() {
    return 0
}

get_firefox_extensions_root() {
    echo "$ext_root"
}

get_firefox_native_host_dir() {
    echo "\${FIREFOX_NATIVE_HOST_DIR:-$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts}"
}

get_native_host_install_dir() {
    echo "\${OPENPATH_NATIVE_HOST_INSTALL_DIR:-$TEST_TMP_DIR/local/lib/openpath}"
}

run_browser_json_helper() {
    python3 "$PROJECT_DIR/linux/libexec/browser-json.py" "\$@"
}
EOF
}

@test "firefox activation plan rejects disabled or unsigned profile registration" {
    local profile_dir="$TEST_TMP_DIR/profile"

    mkdir -p "$profile_dir"
    cat > "$profile_dir/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","active":false,"userDisabled":true,"signedState":-1,"location":"app-system-share","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON

    run bash -c 'source "$1"; detect_firefox_extension_registration_in_profile "$2" "openpath-block-monitor@openpath"' \
        bash "$PROJECT_DIR/linux/lib/firefox-activation-plan.sh" "$profile_dir"

    [ "$status" -eq 1 ]
    [[ "$output" == *"extensions.json-disabled"* ]]
    [[ "$output" == *"active=false"* ]]
    [[ "$output" == *"userDisabled=true"* ]]
    [[ "$output" == *"signedState=-1"* ]]
}

@test "firefox activation plan rejects disabled registration even when prefs has uuid" {
    local profile_dir="$TEST_TMP_DIR/profile"

    mkdir -p "$profile_dir"
    cat > "$profile_dir/extensions.json" <<'JSON'
{"addons":[{"id":"openpath-block-monitor@openpath","active":false,"userDisabled":true,"signedState":-1,"location":"app-system-share","rootURI":"moz-extension://openpath-test-uuid/"}]}
JSON
    cat > "$profile_dir/prefs.js" <<'PREFS'
user_pref("extensions.webextensions.uuids", "{\"openpath-block-monitor@openpath\":\"openpath-test-uuid\"}");
PREFS

    run bash -c 'source "$1"; detect_firefox_extension_registration_in_profile "$2" "openpath-block-monitor@openpath"' \
        bash "$PROJECT_DIR/linux/lib/firefox-activation-plan.sh" "$profile_dir"

    [ "$status" -eq 1 ]
    [[ "$output" == *"extensions.json-disabled"* ]]
    [[ "$output" == *"active=false"* ]]
    [[ "$output" == *"userDisabled=true"* ]]
    [[ "$output" == *"signedState=-1"* ]]
}

@test "firefox activation plan rejects prefs-only registration without active addon state" {
    local profile_dir="$TEST_TMP_DIR/profile"

    mkdir -p "$profile_dir"
    cat > "$profile_dir/prefs.js" <<'PREFS'
user_pref("extensions.webextensions.uuids", "{\"openpath-block-monitor@openpath\":\"openpath-test-uuid\"}");
PREFS

    run bash -c 'source "$1"; detect_firefox_extension_registration_in_profile "$2" "openpath-block-monitor@openpath"' \
        bash "$PROJECT_DIR/linux/lib/firefox-activation-plan.sh" "$profile_dir"

    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "browser request readiness facts reject policy-only firefox setup" {
    local policies_file="$TEST_TMP_DIR/firefox-policies.json"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    mkdir -p "$(dirname "$policies_file")" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    cat > "$policies_file" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed","install_url":"https://control.example/api/extensions/firefox/openpath.xpi"}}}}
JSON

    export ETC_CONFIG_DIR="$etc_dir"
    export WHITELIST_URL_CONF="$etc_dir/whitelist-url.conf"
    export FIREFOX_POLICIES="$policies_file"
    export FIREFOX_EXTENSION_ID="openpath-block-monitor@openpath"

    read_single_line_file() {
        local file="$1"
        [ -r "$file" ] || return 1
        tr -d '\r\n' < "$file"
    }
    log() { echo "$1"; }
    log_error() { echo "$1" >&2; }
    detect_firefox_dir() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr"; }
    resolve_firefox_extensions_root_dir() { echo "$TEST_TMP_DIR/share/mozilla/extensions"; }
    resolve_firefox_binary_path() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"; }
    verify_firefox_extension_registered() { return 1; }
    get_firefox_native_host_dir() { echo "$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts"; }
    get_native_host_install_dir() { echo "$TEST_TMP_DIR/local/lib/openpath"; }
    run_browser_json_helper() {
        python3 "$PROJECT_DIR/linux/libexec/browser-json.py" "$@"
    }

    mkdir -p "$TEST_TMP_DIR/usr/lib/firefox-esr" "$TEST_TMP_DIR/share/mozilla/extensions" "$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts" "$TEST_TMP_DIR/local/lib/openpath"
    touch "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"
    touch "$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts/whitelist_native_host.json"
    touch "$TEST_TMP_DIR/local/lib/openpath/openpath-native-host.py"

    source "$PROJECT_DIR/linux/lib/browser-request-readiness.sh"

    run collect_openpath_browser_request_readiness
    [ "$status" -eq 1 ]
    [[ "$output" == *"ready=false"* ]]
    [[ "$output" != *"fact.firefox_policy=ready"* ]]
    [[ "$output" == *"fact.firefox_registration=missing"* ]]
    [[ "$output" == *"failure_reason=firefox_registration_missing"* ]]
}

@test "browser request readiness facts require linux native host proof" {
    local policies_file="$TEST_TMP_DIR/firefox-policies.json"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local app_id="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
    mkdir -p "$(dirname "$policies_file")" "$etc_dir" "$ext_root/$app_id/openpath-block-monitor@openpath" "$TEST_TMP_DIR/usr/lib/firefox-esr"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    touch "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"
    touch "$ext_root/$app_id/openpath-block-monitor@openpath/manifest.json"
    cat > "$policies_file" <<'JSON'
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed"}}}}
JSON

    export ETC_CONFIG_DIR="$etc_dir"
    export WHITELIST_URL_CONF="$etc_dir/whitelist-url.conf"
    export FIREFOX_POLICIES="$policies_file"
    export FIREFOX_EXTENSION_ID="openpath-block-monitor@openpath"

    read_single_line_file() {
        local file="$1"
        [ -r "$file" ] || return 1
        tr -d '\r\n' < "$file"
    }
    log() { echo "$1"; }
    log_error() { echo "$1" >&2; }
    detect_firefox_dir() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr"; }
    resolve_firefox_extensions_root_dir() { echo "$ext_root"; }
    resolve_firefox_binary_path() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"; }
    verify_firefox_extension_registered() { return 0; }
    get_firefox_native_host_dir() { echo "$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts"; }
    get_native_host_install_dir() { echo "$TEST_TMP_DIR/local/lib/openpath"; }
    run_browser_json_helper() {
        python3 "$PROJECT_DIR/linux/libexec/browser-json.py" "$@"
    }

    source "$PROJECT_DIR/linux/lib/browser-request-readiness.sh"

    run collect_openpath_browser_request_readiness
    [ "$status" -eq 1 ]
    [[ "$output" == *"fact.firefox_registration=ready"* ]]
    [[ "$output" == *"fact.firefox_native_host=missing"* ]]
    [[ "$output" == *"failure_reason=firefox_native_host_missing"* ]]
}

@test "browser request readiness accepts local Firefox policy install entry payload" {
    local policies_file="$TEST_TMP_DIR/firefox-policies.json"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local app_id="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
    local ext_dir="$ext_root/$app_id/openpath-block-monitor@openpath"
    mkdir -p "$(dirname "$policies_file")" "$etc_dir" "$ext_dir" "$TEST_TMP_DIR/usr/lib/firefox-esr"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    touch "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"
    touch "$ext_dir/manifest.json"
    cat > "$policies_file" <<JSON
{"policies":{"ExtensionSettings":{"openpath-block-monitor@openpath":{"installation_mode":"force_installed"}},"Extensions":{"Install":["$ext_dir"],"Locked":["openpath-block-monitor@openpath"]}}}
JSON

    export ETC_CONFIG_DIR="$etc_dir"
    export WHITELIST_URL_CONF="$etc_dir/whitelist-url.conf"
    export FIREFOX_POLICIES="$policies_file"
    export FIREFOX_EXTENSION_ID="openpath-block-monitor@openpath"

    read_single_line_file() {
        local file="$1"
        [ -r "$file" ] || return 1
        tr -d '\r\n' < "$file"
    }
    log() { echo "$1"; }
    log_error() { echo "$1" >&2; }
    detect_firefox_dir() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr"; }
    resolve_firefox_extensions_root_dir() { echo "$TEST_TMP_DIR/missing-extension-root"; }
    resolve_firefox_binary_path() { echo "$TEST_TMP_DIR/usr/lib/firefox-esr/firefox"; }
    verify_firefox_extension_registered() { return 0; }
    get_firefox_native_host_dir() { echo "$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts"; }
    get_native_host_install_dir() { echo "$TEST_TMP_DIR/local/lib/openpath"; }
    run_browser_json_helper() {
        python3 "$PROJECT_DIR/linux/libexec/browser-json.py" "$@"
    }

    mkdir -p "$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts" "$TEST_TMP_DIR/local/lib/openpath"
    touch "$TEST_TMP_DIR/lib/mozilla/native-messaging-hosts/whitelist_native_host.json"
    touch "$TEST_TMP_DIR/local/lib/openpath/openpath-native-host.py"
    chmod +x "$TEST_TMP_DIR/local/lib/openpath/openpath-native-host.py"

    source "$PROJECT_DIR/linux/lib/browser-request-readiness.sh"

    run collect_openpath_browser_request_readiness
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready=true"* ]]
    [[ "$output" == *"fact.firefox_payload=ready"* ]]
    [[ "$output" == *"fact.firefox_registration=ready"* ]]
    [[ "$output" == *"fact.firefox_native_host=ready"* ]]
}

@test "verify_firefox_extension_payload resolves the extensions root without a caller-provided resolver" {
    # Reproduces the install path (browser.sh sources browser-request-readiness.sh
    # WITHOUT openpath-browser-setup.sh), where resolve_firefox_extensions_root_dir
    # is not pre-defined. The lib must resolve the unpacked extensions root itself,
    # otherwise the staged extension is reported as a missing payload.
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local app_id="{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
    local ext_dir="$ext_root/$app_id/openpath-block-monitor@openpath"
    mkdir -p "$ext_dir"
    touch "$ext_dir/manifest.json"

    export FIREFOX_EXTENSIONS_ROOT="$ext_root"
    export FIREFOX_EXTENSION_ID="openpath-block-monitor@openpath"
    log() { echo "$1"; }
    log_error() { echo "$1" >&2; }

    # Deliberately do NOT define resolve_firefox_extensions_root_dir (no mock):
    # this is exactly the unmocked install context that regressed.
    source "$PROJECT_DIR/linux/lib/browser-request-readiness.sh"

    run verify_firefox_extension_payload
    [ "$status" -eq 0 ]
}

@test "openpath-browser-setup installs firefox integrations without applying Firefox browser policies" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    rm -rf "$TEST_TMP_DIR/home" "$fake_install" "$fake_scripts" "$firefox_dir" "$ext_root" "$(dirname "$policies_file")"
    rm -rf "$TEST_TMP_DIR/home" "$fake_install" "$fake_scripts" "$firefox_dir" "$ext_root" "$(dirname "$policies_file")"
    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "success"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]

    run cat "$calls_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_firefox_esr"* ]]
    [[ "$output" == *"install_browser_integrations:"* ]]
    [[ "$output" == *"--native-host"* ]]
    [[ "$output" == *"--firefox-required"* ]]
    [[ "$output" == *"--chromium-best-effort"* ]]
    [[ "$output" == *"--native-host-required"* ]]
    [[ "$output" != *"apply_search_engine_policies"* ]]
}

@test "source installer no longer labels a browser policy application step" {
    run grep -nF 'Aplicando politicas de navegadores' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -ne 0 ]
}

@test "openpath-browser-setup fails before installing integrations when request setup is incomplete" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "success"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"request setup"* ]]
    if [ -f "$calls_file" ]; then
        run grep -n "install_browser_integrations" "$calls_file"
        [ "$status" -ne 0 ]
    fi
}

@test "openpath-browser-setup can install only Firefox before request setup exists" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "success"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh" --install-firefox-only

    [ "$status" -eq 0 ]
    run cat "$calls_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_firefox_esr"* ]]
    [[ "$output" != *"install_browser_integrations:"* ]]
    [[ "$output" != *"apply_search_engine_policies"* ]]
}

@test "openpath-browser-setup accepts managed api firefox policy payload" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="managed-api" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
}

@test "openpath-browser-setup fails when policy exists but firefox never registers extension" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local expected_activation_user=""

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    expected_activation_user="$(id -un)"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "policy-only"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="policy-only" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Firefox did not register active managed extension"* ]]
    [[ "$output" == *"probe_attempt=1"* ]]
    [[ "$output" == *"activation_user=$expected_activation_user"* ]]
    [[ "$output" == *"profile_home=$TEST_TMP_DIR/home"* ]]
    [[ "$output" == *"registration_source=missing"* ]]
}

@test "openpath-browser-setup can defer missing firefox registration for headless canaries" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "policy-only"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_ALLOW_DEFERRED_FIREFOX_REGISTRATION="1" \
        OPENPATH_FAKE_FIREFOX_MODE="policy-only" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox managed extension registration deferred"* ]]
    grep -F 'registered_count=0' "$ready_file"
    grep -F '|missing|missing' "$ready_file"
}

@test "openpath-browser-setup never defers disabled unsigned firefox registration" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_ALLOW_DEFERRED_FIREFOX_REGISTRATION="1" \
        OPENPATH_FAKE_FIREFOX_MODE="disabled-extension" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Firefox did not register active managed extension"* ]]
    [[ "$output" == *"extensions.json-disabled"* ]]
    grep -F "|disabled|extensions.json-disabled;active=false;userDisabled=true;signedState=-1;location=app-system-share" "$ready_file"
}

@test "openpath-browser-setup fails when firefox registers disabled unsigned extension" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="disabled-extension" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Firefox did not register active managed extension"* ]]
    [[ "$output" == *"extensions.json-disabled"* ]]
    [[ "$output" == *"active=false"* ]]
    [[ "$output" == *"userDisabled=true"* ]]
    [[ "$output" == *"signedState=-1"* ]]
    grep -F "profile=" "$ready_file"
    grep -F "|disabled|extensions.json-disabled;active=false;userDisabled=true;signedState=-1;location=app-system-share" "$ready_file"
}

@test "openpath-browser-setup activates firefox with a persistent profile path" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local expected_profile="$TEST_TMP_DIR/home/.mozilla/firefox/openpath.default"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="requires-profile-registration" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
    [ -f "$expected_profile/extensions.json" ]
}

@test "openpath-browser-setup follows Firefox install default profile instead of forcing openpath.default" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local firefox_home="$TEST_TMP_DIR/home"
    local firefox_root="$firefox_home/.mozilla/firefox"
    local install_profile="$firefox_root/default-release"
    local openpath_profile="$firefox_root/openpath.default"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir" "$firefox_root"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    cat > "$firefox_root/profiles.ini" <<'EOF'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=default-release
IsRelative=1
Path=default-release

[InstallTESTHASH]
Default=default-release
Locked=1
EOF
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$firefox_home" \
        OPENPATH_FAKE_FIREFOX_MODE="install-profile-registration" \
        OPENPATH_FIREFOX_PROFILE_HOME="$firefox_home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
    [ -f "$install_profile/extensions.json" ]
    [ ! -f "$openpath_profile/extensions.json" ]
}

@test "openpath-browser-setup retries firefox activation while waiting for managed extension registration" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="delayed-registration" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="3" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
    [[ "$output" == *"registration_source=extensions.json"* ]]
    [ "$(cat "$TEST_TMP_DIR/home/.mozilla/firefox/openpath-test-run-count")" -ge 2 ]
}

@test "openpath-browser-setup hard-kills firefox activation probes after timeout" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local timeout_calls_file="$TEST_TMP_DIR/timeout.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_timeout_requires_kill_after "$bin_dir" "$timeout_calls_file"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="delayed-registration" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="3" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    grep -F -- '--kill-after=5s' "$timeout_calls_file"
    grep -F -- ' 60s ' "$timeout_calls_file"
}

@test "openpath-browser-setup accepts registration written before activation probe timeout" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local timeout_calls_file="$TEST_TMP_DIR/timeout.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/class""room-id.conf"
    write_mock_id "$bin_dir"
    write_timeout_runs_probe_then_times_out "$bin_dir" "$timeout_calls_file"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="success" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="3" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
    grep -F -- '--kill-after=5s' "$timeout_calls_file"
}

@test "openpath-browser-setup retries when first activation timeout exceeds registration deadline" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local timeout_calls_file="$TEST_TMP_DIR/timeout.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/class""room-id.conf"
    write_mock_id "$bin_dir"
    write_timeout_first_probe_exceeds_deadline_then_registers "$bin_dir" "$timeout_calls_file"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="delayed-registration" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
    [ "$(wc -l < "$timeout_calls_file")" -ge 2 ]
}

@test "openpath-browser-setup allows a third firefox activation probe for slow managed extension registration" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/class""room-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FAKE_FIREFOX_MODE="third-registration" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
    [ "$(cat "$TEST_TMP_DIR/home/.mozilla/firefox/openpath-test-run-count")" -ge 3 ]
}

@test "openpath-browser-setup accepts registration written under snap firefox profile root" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local firefox_home="$TEST_TMP_DIR/home"
    local snap_root="$firefox_home/snap/firefox/common/.mozilla/firefox"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir" "$snap_root/openpath-test.default"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    cat > "$snap_root/profiles.ini" <<'EOF'
[Profile0]
Name=snap
IsRelative=1
Path=openpath-test.default
EOF
    printf 'student:x:1001:1001::%s:/bin/bash\n' "$firefox_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$firefox_home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FAKE_FIREFOX_MODE="snap-registration" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Firefox browser setup is ready"* ]]
}

@test "openpath-browser-setup requires native host for firefox managed blocking" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "missing-native"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"native host missing"* ]]
    [[ "$output" == *"Failed to configure Firefox browser integrations"* ]]
}

@test "openpath-browser-setup fails when firefox integration is still missing after reconciliation" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "missing-firefox"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/home" \
        OPENPATH_FIREFOX_PROFILE_HOME="$TEST_TMP_DIR/home" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 1 ]
}

@test "openpath-browser-setup activates all passwd homes and all firefox profiles" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local alice_home="$TEST_TMP_DIR/home/alice"
    local bob_home="$TEST_TMP_DIR/home/bob"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    mkdir -p "$alice_home/.mozilla/firefox/first.default" "$alice_home/.mozilla/firefox/second.default"
    mkdir -p "$bob_home/snap/firefox/common/.mozilla/firefox/snap.default"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    cat > "$alice_home/.mozilla/firefox/profiles.ini" <<'EOF'
[Profile0]
Name=first
IsRelative=1
Path=first.default

[Profile1]
Name=second
IsRelative=1
Path=second.default
EOF
    cat > "$bob_home/snap/firefox/common/.mozilla/firefox/profiles.ini" <<'EOF'
[Profile0]
Name=snap
IsRelative=1
Path=snap.default
EOF
    printf 'alice:x:1001:1001::%s:/bin/bash\nbob:x:1002:1002::%s:/bin/bash\n' "$alice_home" "$bob_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/root-home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FAKE_FIREFOX_MODE="success" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [ -f "$alice_home/.mozilla/firefox/first.default/extensions.json" ]
    [ -f "$alice_home/.mozilla/firefox/second.default/extensions.json" ]
    [ -f "$bob_home/snap/firefox/common/.mozilla/firefox/snap.default/extensions.json" ]
    grep -F 'extension_id=openpath-block-monitor@openpath' "$ready_file"
    grep -F 'target_count=3' "$ready_file"
    grep -F 'registered_count=3' "$ready_file"
}

@test "openpath-browser-setup fails and lists missing profile registration" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local alice_home="$TEST_TMP_DIR/home/alice"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    mkdir -p "$alice_home/.mozilla/firefox/first.default" "$alice_home/.mozilla/firefox/second.default"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    cat > "$alice_home/.mozilla/firefox/profiles.ini" <<'EOF'
[Profile0]
Name=first
IsRelative=1
Path=first.default

[Profile1]
Name=second
IsRelative=1
Path=second.default
EOF
    printf 'alice:x:1001:1001::%s:/bin/bash\n' "$alice_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/root-home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FAKE_FIREFOX_MODE="missing-second-profile" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"registered=1 target_count=2"* ]]
    [[ "$output" == *"alice|$alice_home|$alice_home/.mozilla/firefox/second.default"* ]]
}

@test "openpath-browser-setup creates openpath.default for passwd user without firefox profile" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local alice_home="$TEST_TMP_DIR/home/alice"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir" "$alice_home"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    printf 'alice:x:1001:1001::%s:/bin/bash\n' "$alice_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/root-home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FAKE_FIREFOX_MODE="success" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [ -f "$alice_home/.mozilla/firefox/profiles.ini" ]
    [ -f "$alice_home/.mozilla/firefox/openpath.default/extensions.json" ]
}

@test "openpath-browser-setup does not create fallback profiles for system users" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local daemon_home="$TEST_TMP_DIR/usr/sbin"
    local alice_home="$TEST_TMP_DIR/home/alice"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir" "$daemon_home" "$alice_home"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    printf 'daemon:x:1:1::%s:/usr/sbin/nologin\nalice:x:1001:1001::%s:/bin/bash\n' "$daemon_home" "$alice_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/root-home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FAKE_FIREFOX_MODE="success" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [ ! -e "$daemon_home/.mozilla/firefox/openpath.default/extensions.json" ]
    [ -f "$alice_home/.mozilla/firefox/openpath.default/extensions.json" ]
    grep -F 'target_count=1' "$ready_file"
}

@test "openpath-browser-setup does not create fallback profile for root" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local root_home="$TEST_TMP_DIR/root"
    local alice_home="$TEST_TMP_DIR/home/alice"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir" "$root_home" "$alice_home"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    printf 'root:x:0:0::%s:/bin/bash\nalice:x:1001:1001::%s:/bin/bash\n' "$root_home" "$alice_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$root_home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FAKE_FIREFOX_MODE="success" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [ ! -e "$root_home/.mozilla/firefox/openpath.default/extensions.json" ]
    [ -f "$alice_home/.mozilla/firefox/openpath.default/extensions.json" ]
    grep -F 'target_count=1' "$ready_file"
}

@test "openpath-browser-setup creates root fallback only when no user targets exist" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local root_home="$TEST_TMP_DIR/root"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir" "$root_home"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    printf 'root:x:0:0::%s:/bin/bash\n' "$root_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    cat > "$bin_dir/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
    echo 0
    exit 0
fi
if [ "${1:-}" = "-un" ]; then
    echo root
    exit 0
fi
/usr/bin/id "$@"
EOF
    chmod +x "$bin_dir/id"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$root_home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FAKE_FIREFOX_MODE="success" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [ -f "$root_home/.mozilla/firefox/openpath.default/extensions.json" ]
    grep -F 'target_count=1' "$ready_file"
    grep -F "profile=root|$root_home|$root_home/.mozilla/firefox/openpath.default|registered|extensions.json" "$ready_file"
}

@test "openpath-browser-setup profile overrides limit verification to one target" {
    local fake_install="$TEST_TMP_DIR/install"
    local fake_scripts="$TEST_TMP_DIR/scripts"
    local firefox_dir="$TEST_TMP_DIR/usr/lib/firefox-esr"
    local ext_root="$TEST_TMP_DIR/share/mozilla/extensions"
    local policies_file="$TEST_TMP_DIR/etc/firefox/policies/policies.json"
    local ready_file="$TEST_TMP_DIR/state/firefox-extension-ready"
    local calls_file="$TEST_TMP_DIR/browser-setup.calls"
    local bin_dir="$TEST_TMP_DIR/bin"
    local etc_dir="$TEST_TMP_DIR/etc/openpath"
    local passwd_file="$TEST_TMP_DIR/passwd"
    local alice_home="$TEST_TMP_DIR/home/alice"
    local bob_home="$TEST_TMP_DIR/home/bob"

    mkdir -p "$fake_install/lib" "$fake_scripts" "$ext_root" "$bin_dir" "$etc_dir"
    mkdir -p "$alice_home/.mozilla/firefox/first.default" "$bob_home/.mozilla/firefox/bob.default"
    printf '%s' 'https://control.example' > "$etc_dir/api-url.conf"
    printf '%s' 'https://control.example/w/token123/whitelist.txt' > "$etc_dir/whitelist-url.conf"
    printf '%s' 'cls_123' > "$etc_dir/classroom-id.conf"
    printf 'alice:x:1001:1001::%s:/bin/bash\nbob:x:1002:1002::%s:/bin/bash\n' "$alice_home" "$bob_home" > "$passwd_file"
    write_mock_id "$bin_dir"
    write_fake_common_sh "$fake_install/lib/common.sh"
    write_fake_browser_sh "$fake_install/lib/browser.sh" "$calls_file" "$firefox_dir" "$ext_root" "$policies_file" "managed-api"

    run env \
        PATH="$bin_dir:$PATH" \
        HOME="$TEST_TMP_DIR/root-home" \
        OPENPATH_PASSWD_FILE="$passwd_file" \
        OPENPATH_FIREFOX_PROFILE_USER="alice" \
        OPENPATH_FIREFOX_PROFILE_HOME="$alice_home" \
        OPENPATH_FIREFOX_PROFILE_DIR="$alice_home/.mozilla/firefox/first.default" \
        OPENPATH_FAKE_FIREFOX_MODE="success" \
        OPENPATH_FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS="1" \
        FIREFOX_EXTENSION_READY_FILE="$ready_file" \
        INSTALL_DIR="$fake_install" \
        SCRIPTS_DIR="$fake_scripts" \
        ETC_CONFIG_DIR="$etc_dir" \
        FIREFOX_POLICIES="$policies_file" \
        FIREFOX_EXTENSIONS_ROOT="$ext_root" \
        bash "$PROJECT_DIR/linux/scripts/runtime/openpath-browser-setup.sh"

    [ "$status" -eq 0 ]
    [ -f "$alice_home/.mozilla/firefox/first.default/extensions.json" ]
    [ ! -f "$bob_home/.mozilla/firefox/bob.default/extensions.json" ]
    grep -F 'target_count=1' "$ready_file"
    grep -F 'registered_count=1' "$ready_file"
}
