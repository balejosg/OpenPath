#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

IMAGE_TAG="${OPENPATH_E2E_IMAGE_TAG:-openpath-e2e:latest}"
CONTAINER_NAME="${OPENPATH_E2E_CONTAINER_NAME:-e2e-test-$$}"
INSTALLER_ONLY=0

_context_dir=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --installer-only)
            INSTALLER_ONLY=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

cleanup() {
    # Best-effort cleanup
    if [ -n "${CONTAINER_NAME:-}" ]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if [ -n "${_context_dir:-}" ] && [ -d "$_context_dir" ]; then
        rm -rf "$_context_dir" || true
    fi
}

debug_container() {
    echo ""
    echo "Debug information..."
    docker ps -a || true
    echo ""
    echo "Systemd status (e2e-tests.service):"
    docker exec "$CONTAINER_NAME" systemctl status e2e-tests.service --no-pager 2>/dev/null || true
    echo ""
    echo "Systemd properties (e2e-tests.service):"
    docker exec "$CONTAINER_NAME" systemctl show e2e-tests.service \
        -p ActiveState -p SubState -p Result -p ExecMainStatus -p ExecMainCode -p ExecMainPID \
        --no-pager 2>/dev/null || true
    echo ""
    echo "Systemd journal tail (e2e-tests.service):"
    docker exec "$CONTAINER_NAME" journalctl -u e2e-tests.service --no-pager -n 400 2>/dev/null || true
}

on_error() {
    local rc=$?
    echo ""
    echo "Linux E2E failed (exit code: $rc)"
    debug_container
    exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

require_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "Missing required file: $path" >&2
        exit 1
    fi
}

require_dir() {
    local path="$1"
    if [ ! -d "$path" ]; then
        echo "Missing required directory: $path" >&2
        exit 1
    fi
}

create_minimal_context() {
    local tmp
    tmp="$(mktemp -d -t openpath-e2e-context.XXXXXXXX)"

    mkdir -p "$tmp/linux" "$tmp/runtime" "$tmp/tests/e2e" "$tmp/firefox-extension" "$tmp/windows"

    # Core Linux agent + E2E runner scripts
    cp -a "$PROJECT_ROOT/linux/." "$tmp/linux/"
    cp -a "$PROJECT_ROOT/runtime/." "$tmp/runtime/"
    cp -a "$PROJECT_ROOT/tests/e2e/." "$tmp/tests/e2e/"

    # Keep Windows tree so pre-install validation does not warn
    cp -a "$PROJECT_ROOT/windows/." "$tmp/windows/"

    # Extension runtime assets validated by pre-install-validation.sh
    require_file "$PROJECT_ROOT/firefox-extension/manifest.json"
    require_dir "$PROJECT_ROOT/firefox-extension/dist"
    require_dir "$PROJECT_ROOT/firefox-extension/popup"
    require_dir "$PROJECT_ROOT/firefox-extension/blocked"
    require_dir "$PROJECT_ROOT/firefox-extension/native"
    require_dir "$PROJECT_ROOT/firefox-extension/icons"

    mkdir -p "$tmp/firefox-extension/dist"
    cp -a "$PROJECT_ROOT/firefox-extension/manifest.json" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/dist/." "$tmp/firefox-extension/dist/"
    cp -a "$PROJECT_ROOT/firefox-extension/popup" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/blocked" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/native" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/icons" "$tmp/firefox-extension/"

    require_file "$PROJECT_ROOT/VERSION"
    require_file "$PROJECT_ROOT/runtime/browser-policy-spec.json"
    cp -a "$PROJECT_ROOT/VERSION" "$tmp/"

    echo "$tmp"
}

wait_for_oneshot_service() {
    local max_iters="$1" # number of polls
    local sleep_sec="$2"

    for ((i = 1; i <= max_iters; i++)); do
        local exit_ts
        exit_ts=$(docker exec "$CONTAINER_NAME" systemctl show e2e-tests.service --property=ExecMainExitTimestampMonotonic --value 2>/dev/null || true)
        if [ -n "$exit_ts" ] && [ "$exit_ts" != "0" ]; then
            echo "  Service completed"
            return 0
        fi

        if [ "$((i % 12))" = "0" ]; then
            local active_state
            local sub_state
            active_state=$(docker exec "$CONTAINER_NAME" systemctl show e2e-tests.service --property=ActiveState --value 2>/dev/null || true)
            sub_state=$(docker exec "$CONTAINER_NAME" systemctl show e2e-tests.service --property=SubState --value 2>/dev/null || true)
            echo "  [$i/$max_iters] Tests still running (${i}*${sleep_sec}s = $((i * sleep_sec))s elapsed)... (state=${active_state:-unknown}/${sub_state:-unknown})"
        fi
        sleep "$sleep_sec"
    done

    return 1
}

is_routable_dns_ip() {
    local dns="$1"

    [[ "$dns" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    case "$dns" in
        0.*|127.*|169.254.*|224.*|225.*|226.*|227.*|228.*|229.*|23[0-9].*|24[0-9].*|25[0-5].*)
            return 1
            ;;
    esac

    return 0
}

dns_discard_reason() {
    local dns="$1"

    if ! [[ "$dns" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        printf '%s\n' "not an IPv4 address"
        return 0
    fi

    printf '%s\n' "not routable for container DNS"
}

log_dns_decision() {
    local status="$1"
    local dns="$2"
    local reason="${3:-}"

    case "$status" in
        Accepted)
            echo "Accepted DNS server for E2E container: ${dns}" >&2
            ;;
        Discarded)
            echo "Discarded DNS server for E2E container: ${dns} (${reason})" >&2
            ;;
    esac
}

log_resolv_conf_dns_candidates() {
    local dns
    local found_candidate=0

    while IFS= read -r dns; do
        dns="${dns%%#*}"
        dns="$(printf '%s' "$dns" | awk '$1 == "nameserver" { print $2 }')"
        [ -n "$dns" ] || continue
        found_candidate=1
        echo "DNS candidate from /etc/resolv.conf: ${dns}" >&2
    done < /etc/resolv.conf

    if [ "$found_candidate" -eq 0 ]; then
        echo "DNS candidate from /etc/resolv.conf: none" >&2
    fi
}

collect_docker_dns_args() {
    local raw_dns
    local dns
    local reason

    log_resolv_conf_dns_candidates
    if [ -n "${OPENPATH_E2E_DOCKER_DNS:-}" ]; then
        echo "OPENPATH_E2E_DOCKER_DNS is set; using explicit E2E container DNS" >&2
        raw_dns="${OPENPATH_E2E_DOCKER_DNS//,/ }"
        for dns in $raw_dns; do
            if ! is_routable_dns_ip "$dns"; then
                reason="$(dns_discard_reason "$dns")"
                log_dns_decision "Discarded" "$dns" "$reason"
                continue
            fi
            log_dns_decision "Accepted" "$dns"
            printf '%s\n%s\n' "--dns" "$dns"
        done
        return 0
    fi

    while IFS= read -r dns; do
        dns="${dns%%#*}"
        dns="$(printf '%s' "$dns" | awk '$1 == "nameserver" { print $2 }')"
        [ -n "$dns" ] || continue
        if ! is_routable_dns_ip "$dns"; then
            reason="$(dns_discard_reason "$dns")"
            log_dns_decision "Discarded" "$dns" "$reason"
            continue
        fi
        log_dns_decision "Accepted" "$dns"
        printf '%s\n%s\n' "--dns" "$dns"
    done < /etc/resolv.conf
}

run_whitelist_update_test() {
    echo ""
    echo "Testing whitelist update mechanism (openpath-update.sh)..."

    docker exec "$CONTAINER_NAME" bash -c '
        set -euo pipefail

        fixture_dir="/tmp/openpath-whitelist-fixture"
        token="test-update-token"
        test_dir="$fixture_dir/w/$token"
        test_file="$test_dir/whitelist.txt"
        rm -rf "$fixture_dir"
        mkdir -p "$test_dir"
        cat > "$test_file" << EOF
## WHITELIST
google.com
github.com
newdomain.example.com
example.org
example.net

## BLOCKED-SUBDOMAINS
ads.example.com
EOF

        python3 -m http.server 18082 --bind 127.0.0.1 --directory "$fixture_dir" >/tmp/openpath-whitelist-fixture.log 2>&1 &
        server_pid=$!
        trap "kill $server_pid >/dev/null 2>&1 || true" EXIT

        for _ in $(seq 1 20); do
            if curl -fsS "http://127.0.0.1:18082/w/$token/whitelist.txt" >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done

        mkdir -p /etc/openpath
        printf "http://127.0.0.1:18082\n" > /etc/openpath/api-url.conf
        printf "linux-e2e-update-room\n" > /etc/openpath/classroom.conf
        printf "linux-e2e-update-room-id\n" > /etc/openpath/classroom-id.conf

        conf="/etc/openpath/whitelist-url.conf"
        backup="${conf}.bak"
        if [ -f "$conf" ]; then
            cp -f "$conf" "$backup"
        fi

        echo "http://127.0.0.1:18082/w/$token/whitelist.txt" > "$conf"

        /usr/local/bin/openpath-update.sh

        if ! grep -q "newdomain.example.com" /var/lib/openpath/whitelist.txt; then
            echo "Updated whitelist does not contain expected domain"
            exit 1
        fi

        # Restore config
        if [ -f "$backup" ]; then
            mv -f "$backup" "$conf"
        fi
    '

    echo "Whitelist update test completed"
}

run_agent_self_update_test() {
    echo ""
    echo "Testing agent self-update mechanism (openpath-self-update.sh)..."

    docker exec "$CONTAINER_NAME" bash -lc '
        set -euo pipefail

        workdir="/tmp/openpath-agent-self-update"
        release_dir="$workdir/release"
        build_log="$workdir/build.log"
        server_log="$workdir/http.log"
        update_log="$workdir/update.log"
        mkdir -p /etc/openpath
        if [ ! -s /etc/openpath/api-url.conf ]; then
            printf "http://127.0.0.1:18080\n" > /etc/openpath/api-url.conf
        fi
        if [ ! -s /etc/openpath/whitelist-url.conf ]; then
            printf "http://127.0.0.1/w/self-update-test-token/whitelist.txt\n" > /etc/openpath/whitelist-url.conf
        fi
        if [ ! -s /etc/openpath/classroom.conf ]; then
            printf "self-update-test-classroom\n" > /etc/openpath/classroom.conf
        fi
        if [ ! -s /etc/openpath/classroom-id.conf ]; then
            printf "self-update-test-classroom-id\n" > /etc/openpath/classroom-id.conf
        fi
        current_conf="$(cat /etc/openpath/whitelist-url.conf)"
        current_version="$(cat /usr/local/lib/openpath/VERSION 2>/dev/null || cat /openpath/VERSION 2>/dev/null || echo 4.1.0)"

        target_version="$(CURRENT_VERSION="$current_version" python3 - <<'"'"'PY'"'"'
import os
import re

raw = os.environ.get("CURRENT_VERSION", "4.1.0")
parts = [int(p) for p in re.findall(r"\d+", raw)[:3]]
while len(parts) < 3:
    parts.append(0)
parts[0] += 1
print(f"{parts[0]}.{parts[1]}.{parts[2]}")
PY
)"

        rm -rf "$workdir"
        mkdir -p "$release_dir/api/agent/linux/packages"

        cd /openpath
        ./linux/scripts/build/build-deb.sh "$current_version" 1 >"$build_log" 2>&1
        ./linux/scripts/build/build-deb.sh "$target_version" 1 >>"$build_log" 2>&1

        current_deb_name="openpath-dnsmasq_${current_version}-1_amd64.deb"
        deb_name="openpath-dnsmasq_${target_version}-1_amd64.deb"
        cp "build/$current_deb_name" "$release_dir/api/agent/linux/packages/$current_version"
        cp "build/$deb_name" "$release_dir/$deb_name"

        cat > "$release_dir/latest.json" <<EOF
{
  "success": true,
  "version": "${target_version}",
  "downloadPath": "/$deb_name",
  "minSupportedVersion": "0.0.0",
  "minDirectUpgradeVersion": "0.0.0",
  "bridgeVersions": []
}
EOF

        python3 -m http.server 18080 --bind 127.0.0.1 --directory "$release_dir" >"$server_log" 2>&1 &
        server_pid=$!
        trap "kill \$server_pid >/dev/null 2>&1 || true" EXIT
        for _ in $(seq 1 20); do
            if curl -fsS "http://127.0.0.1:18080/latest.json" >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done

        if ! OPENPATH_SELF_UPDATE_API="http://127.0.0.1:18080/latest.json" /usr/local/bin/openpath-self-update.sh >"$update_log" 2>&1; then
            echo "Self-update command failed"
            echo "--- update log ---"
            cat "$update_log"
            echo "--- build log ---"
            cat "$build_log"
            echo "--- server log ---"
            cat "$server_log"
            exit 1
        fi

        if ! dpkg -s openpath-dnsmasq 2>/dev/null | grep -q "Version: ${target_version}-1"; then
            echo "Self-update did not install package version ${target_version}-1"
            cat "$update_log"
            exit 1
        fi

        if [ "$(cat /usr/local/lib/openpath/VERSION)" != "$target_version" ]; then
            echo "Self-update did not update /usr/local/lib/openpath/VERSION to ${target_version}"
            cat "$update_log"
            exit 1
        fi

        if [ "$(cat /etc/openpath/whitelist-url.conf)" != "$current_conf" ]; then
            echo "Self-update did not preserve whitelist-url.conf"
            cat "$update_log"
            exit 1
        fi

        if [ ! -x /usr/local/bin/openpath-self-update.sh ]; then
            echo "Self-update removed the installed self-update command"
            cat "$update_log"
            exit 1
        fi
    '

    echo "Agent self-update test completed"
}

run_agent_bridge_and_rollback_test() {
    echo ""
    echo "Testing agent bridge upgrade and rollback mechanism..."

    docker exec "$CONTAINER_NAME" bash -lc '
        set -euo pipefail

        workdir="/tmp/openpath-agent-bridge-rollback"
        release_dir="$workdir/release"
        server_script="$workdir/server.py"
        server_log="$workdir/http.log"
        update_log="$workdir/update.log"
        build_log="$workdir/build.log"
        machine_token="test-machine-token"
        current_version="$(cat /usr/local/lib/openpath/VERSION 2>/dev/null || cat /openpath/VERSION 2>/dev/null || echo 4.1.0)"

        mapfile -t versions < <(CURRENT_VERSION="$current_version" python3 - <<'"'"'PY'"'"'
import os
import re

raw = os.environ.get("CURRENT_VERSION", "4.1.0")
parts = [int(p) for p in re.findall(r"\d+", raw)[:3]]
while len(parts) < 3:
    parts.append(0)

bridge = parts[:]
bridge[2] += 1

target = parts[:]
target[2] += 2

print(f"{bridge[0]}.{bridge[1]}.{bridge[2]}")
print(f"{target[0]}.{target[1]}.{target[2]}")
PY
)

        rollback_version="$current_version"
        bridge_version="${versions[0]}"
        target_version="${versions[1]}"

        rm -rf "$workdir" /var/lib/openpath/packages
        mkdir -p "$release_dir"

        cd /openpath
        ./linux/scripts/build/build-deb.sh "$rollback_version" 1 >>"$build_log" 2>&1
        ./linux/scripts/build/build-deb.sh "$bridge_version" 1 >>"$build_log" 2>&1
        ./linux/scripts/build/build-deb.sh "$target_version" 1 >>"$build_log" 2>&1

        target_build_dir="/openpath/build/openpath-dnsmasq_${target_version}-1_amd64"
        TARGET_POSTINST="$target_build_dir/DEBIAN/postinst" python3 - <<'"'"'PY'"'"'
import os
from pathlib import Path

path = Path(os.environ["TARGET_POSTINST"])
content = path.read_text()
needle = "\nexit 0\n"
replacement = "\n# Force rollback path during Linux E2E\necho \"Forced failure during Linux E2E\" >&2\nexit 1\n"
if needle not in content:
    raise SystemExit("postinst did not contain the expected final exit 0")
path.write_text(content.replace(needle, replacement, 1))
PY
        chmod 755 "$target_build_dir/DEBIAN/postinst"
        dpkg-deb --build --root-owner-group "$target_build_dir" >/dev/null

        rollback_deb="openpath-dnsmasq_${rollback_version}-1_amd64.deb"
        bridge_deb="openpath-dnsmasq_${bridge_version}-1_amd64.deb"
        target_deb="openpath-dnsmasq_${target_version}-1_amd64.deb"

        cp "/openpath/build/$rollback_deb" "$release_dir/$rollback_deb"
        cp "/openpath/build/$bridge_deb" "$release_dir/$bridge_deb"
        cp "/openpath/build/$target_deb" "$release_dir/$target_deb"

        cat > "$server_script" <<PY
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import json

RELEASE_DIR = Path(${release_dir@Q})
EXPECTED_TOKEN = ${machine_token@Q}
TARGET_VERSION = ${target_version@Q}
BRIDGE_VERSION = ${bridge_version@Q}

class Handler(BaseHTTPRequestHandler):
    def _write_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _write_file(self, path):
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.debian.binary-package")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        auth_header = self.headers.get("Authorization")
        if auth_header != f"Bearer {EXPECTED_TOKEN}":
            self._write_json(401, {"success": False, "error": "Unauthorized"})
            return

        parsed = urlparse(self.path)
        if parsed.path == "/api/agent/linux/manifest":
            self._write_json(200, {
                "success": True,
                "version": TARGET_VERSION,
                "downloadPath": f"/api/agent/linux/packages/{TARGET_VERSION}",
                "minSupportedVersion": "0.0.0",
                "minDirectUpgradeVersion": BRIDGE_VERSION,
                "bridgeVersions": [BRIDGE_VERSION],
            })
            return

        if parsed.path.startswith("/api/agent/linux/packages/"):
            version = parsed.path.rsplit("/", 1)[-1]
            package_path = RELEASE_DIR / f"openpath-dnsmasq_{version}-1_amd64.deb"
            if not package_path.exists():
                self._write_json(404, {"success": False, "error": "Package not found"})
                return
            self._write_file(package_path)
            return

        self._write_json(404, {"success": False, "error": "Not found"})

    def log_message(self, format, *args):
        pass

HTTPServer(("127.0.0.1", 18081), Handler).serve_forever()
PY

        python3 "$server_script" >"$server_log" 2>&1 &
        server_pid=$!
        trap "kill \$server_pid >/dev/null 2>&1 || true" EXIT
        sleep 1

        printf "http://127.0.0.1:18081\n" > /etc/openpath/api-url.conf
        printf "http://127.0.0.1/w/%s/whitelist.txt\n" "$machine_token" > /etc/openpath/whitelist-url.conf

        set +e
        /usr/local/bin/openpath-self-update.sh >"$update_log" 2>&1
        update_rc=$?
        set -e

        if [ "$update_rc" -eq 0 ]; then
            echo "Bridge rollback scenario unexpectedly succeeded"
            cat "$update_log"
            exit 1
        fi

        if ! grep -q "Attempting rollback to OpenPath v${bridge_version}" "$update_log"; then
            echo "Rollback log did not mention bridge version ${bridge_version}"
            cat "$update_log"
            exit 1
        fi

        if ! dpkg -s openpath-dnsmasq 2>/dev/null | grep -q "Version: ${bridge_version}-1"; then
            echo "Rollback did not restore bridge package version ${bridge_version}-1"
            cat "$update_log"
            exit 1
        fi

        if [ "$(cat /usr/local/lib/openpath/VERSION)" != "$bridge_version" ]; then
            echo "Rollback did not restore /usr/local/lib/openpath/VERSION to ${bridge_version}"
            cat "$update_log"
            exit 1
        fi

        if [ ! -f "/var/lib/openpath/packages/$rollback_deb" ]; then
            echo "Rollback cache is missing the original package $rollback_deb"
            exit 1
        fi

        if [ ! -f "/var/lib/openpath/packages/$bridge_deb" ]; then
            echo "Rollback cache is missing the bridge package $bridge_deb"
            exit 1
        fi

        if [ ! -f "/var/lib/openpath/packages/$target_deb" ]; then
            echo "Rollback cache is missing the failed target package $target_deb"
            exit 1
        fi

        if ! systemctl is-active --quiet dnsmasq; then
            echo "dnsmasq is not active after rollback"
            cat "$update_log"
            exit 1
        fi
    '

    echo "Agent bridge upgrade and rollback test completed"
}

verify_linux_uninstall() {
    echo ""
    echo "Verifying Linux uninstall removes installed state..."

    docker exec "$CONTAINER_NAME" bash -lc '
        set -euo pipefail

        /usr/local/lib/openpath/uninstall.sh --auto-yes

        if [ -e /etc/dnsmasq.d/openpath.conf ]; then
            echo "/etc/dnsmasq.d/openpath.conf still exists after uninstall"
            exit 1
        fi

        if [ -e /usr/local/bin/openpath-update.sh ]; then
            echo "/usr/local/bin/openpath-update.sh still exists after uninstall"
            exit 1
        fi

        if [ -d /usr/local/lib/openpath ]; then
            echo "/usr/local/lib/openpath still exists after uninstall"
            exit 1
        fi
    '

    echo "Linux uninstall test completed"
}

main() {
    echo "Building systemd-enabled E2E test Docker image (minimal context)..."

    _context_dir="$(create_minimal_context)"

    docker build -t "$IMAGE_TAG" -f "$_context_dir/tests/e2e/Dockerfile" "$_context_dir"

    echo ""
    echo "Starting systemd container..."

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    mapfile -t docker_dns_args < <(collect_docker_dns_args)
    if [ "${#docker_dns_args[@]}" -gt 0 ]; then
        echo "Using runner DNS for E2E container: ${docker_dns_args[*]}"
    else
        if [ -n "${OPENPATH_E2E_DOCKER_DNS:-}" ]; then
            echo "OPENPATH_E2E_DOCKER_DNS is set but no accepted servers were found; Docker default DNS will be used"
        else
            echo "OPENPATH_E2E_DOCKER_DNS is not set; Docker default DNS will be used"
        fi
        echo "Using Docker default DNS for E2E container"
    fi

    docker run -d --name "$CONTAINER_NAME" \
        --privileged \
        --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "${docker_dns_args[@]}" \
        -e CI=true \
        -e OPENPATH_INSTALLER_CONTRACT_MODE="$INSTALLER_ONLY" \
        "$IMAGE_TAG"

    echo "Waiting for systemd to boot..."
    sleep 5

    echo "Waiting for e2e-tests.service to complete..."
    if ! wait_for_oneshot_service 96 5; then
        echo "Timed out waiting for e2e-tests.service to finish"
        debug_container
        exit 1
    fi

    echo ""
    echo "Test output:"
    docker exec "$CONTAINER_NAME" journalctl -u e2e-tests.service --no-pager -n 200 || true

    echo ""
    echo "Checking service result..."
    result=$(docker exec "$CONTAINER_NAME" systemctl show e2e-tests.service --property=Result --value 2>/dev/null || echo "failed")
    echo "Service Result: $result"

    if [ "$result" != "success" ]; then
        echo "E2E tests failed (result: $result)"
        debug_container
        exit 1
    fi

    if [ "$INSTALLER_ONLY" = "1" ]; then
        verify_linux_uninstall
        echo ""
        echo "Linux installer contract passed"
        return 0
    fi

    run_whitelist_update_test
    run_agent_self_update_test
    run_agent_bridge_and_rollback_test
    verify_linux_uninstall

    echo ""
    echo "Linux E2E tests passed"
}

main "$@"
