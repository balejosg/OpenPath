#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

IMAGE_TAG="${OPENPATH_STUDENT_E2E_IMAGE_TAG:-openpath-student-e2e:latest}"
CONTAINER_NAME="${OPENPATH_STUDENT_E2E_CONTAINER_NAME:-student-policy-test-$$}"
API_PORT="${OPENPATH_STUDENT_API_PORT:-3101}"
FIXTURE_PORT="${OPENPATH_STUDENT_FIXTURE_PORT:-18081}"
MACHINE_NAME="${OPENPATH_STUDENT_MACHINE_NAME:-linux-student-e2e}"
ARTIFACTS_DIR="${OPENPATH_STUDENT_ARTIFACTS_DIR:-$PROJECT_ROOT/tests/e2e/artifacts/linux-student-policy}"
STUDENT_HOST_SUFFIX="${OPENPATH_STUDENT_HOST_SUFFIX:-127.0.0.1.sslip.io}"
STUDENT_SCENARIO_GROUP="${OPENPATH_STUDENT_SCENARIO_GROUP:-}"
# Sinkhole fast-fail is ON by default (defaults.conf SINKHOLE_FAST_FAIL=1), so the
# lane installs the agent with NO override and asserts that a blocked domain
# fast-fails (firewall RST) instead of black-holing ~90s -- exercising the real
# shipped default. Set OPENPATH_STUDENT_SINKHOLE_FAST_FAIL=0 to install the opt-out
# (override OPENPATH_SINKHOLE_FAST_FAIL=0) and skip the fast-fail assertions.
STUDENT_SINKHOLE_FAST_FAIL="${OPENPATH_STUDENT_SINKHOLE_FAST_FAIL:-1}"

API_PID=""
FIXTURE_PID=""
_context_dir=""
_started_test_db=false
TIMINGS_TSV="$ARTIFACTS_DIR/linux-student-policy-timings.tsv"
TIMINGS_JSON="$ARTIFACTS_DIR/linux-student-policy-timings.json"
FIREFOX_XPI_HASH_PATH="$ARTIFACTS_DIR/firefox-xpi-sha256.txt"
CURRENT_TIMING_NAME=""
CURRENT_TIMING_STARTED_AT=""
CURRENT_TIMING_STARTED_NS=""
STUDENT_USE_MANAGED_FIREFOX_EXTENSION=false

write_timing_evidence() {
    if [[ ! -s "$TIMINGS_TSV" ]]; then
        return 0
    fi

    mkdir -p "$ARTIFACTS_DIR"
    python3 - "$TIMINGS_TSV" "$TIMINGS_JSON" <<'PY'
import json
import sys

tsv_path, json_path = sys.argv[1:3]
timings = []

with open(tsv_path, 'r', encoding='utf-8') as fh:
    for raw_line in fh:
        line = raw_line.rstrip('\n')
        if not line:
            continue
        name, status, started_at, ended_at, duration_ms, duration_seconds, error = line.split('\t', 6)
        timings.append({
            'name': name,
            'status': status,
            'startedAt': started_at,
            'endedAt': ended_at,
            'durationMs': int(duration_ms),
            'durationSeconds': float(duration_seconds),
            'error': error or None,
        })

with open(json_path, 'w', encoding='utf-8') as fh:
    json.dump(timings, fh, indent=2)
    fh.write('\n')
PY
}

start_timing_phase() {
    CURRENT_TIMING_NAME="$1"
    CURRENT_TIMING_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    CURRENT_TIMING_STARTED_NS="$(date +%s%N)"
}

finish_timing_phase() {
    local status="${1:-success}"
    local error_message="${2:-}"

    if [[ -z "$CURRENT_TIMING_NAME" ]]; then
        return 0
    fi

    local phase_name="$CURRENT_TIMING_NAME"
    local started_at="$CURRENT_TIMING_STARTED_AT"
    local started_ns="$CURRENT_TIMING_STARTED_NS"
    CURRENT_TIMING_NAME=""
    CURRENT_TIMING_STARTED_AT=""
    CURRENT_TIMING_STARTED_NS=""

    local ended_at
    local ended_ns
    local duration_ms
    local duration_seconds
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ended_ns="$(date +%s%N)"
    duration_ms=$(((ended_ns - started_ns) / 1000000))
    # Force C locale so awk's printf uses a '.' decimal separator regardless of
    # the host locale; otherwise a comma-decimal locale (e.g. es_ES) yields
    # "3,319", which the timings aggregator's float() parse rejects.
    duration_seconds="$(LC_ALL=C awk -v ms="$duration_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
    error_message="${error_message//$'\t'/ }"
    error_message="${error_message//$'\n'/ }"

    mkdir -p "$ARTIFACTS_DIR"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$phase_name" \
        "$status" \
        "$started_at" \
        "$ended_at" \
        "$duration_ms" \
        "$duration_seconds" \
        "$error_message" >>"$TIMINGS_TSV"
    write_timing_evidence
}

run_timed_step() {
    local phase_name="$1"
    shift

    start_timing_phase "$phase_name"
    "$@"
    finish_timing_phase success ""
}

publish_github_step_summary() {
    local mode="${1:-success}"

    if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
        return 0
    fi

    {
        echo ""
        echo "## Linux Student Policy Diagnostics"
        echo ""
        echo "Status: $mode"
        echo "Scenario group: ${STUDENT_SCENARIO_GROUP:-full}"
        echo ""
        echo "Artifacts: linux-student-policy-timings.json, firefox-xpi-sha256.txt, linux-auto-allow-boundary.json, linux-runtime-dependency-apply.json, linux-dns-readiness.err.log, and linux-firefox-readiness.err.log are uploaded with this job when present."
        echo ""
        echo "## Linux Student Policy Timing"
        echo ""
        echo "| Phase | Status | Seconds |"
        echo "| --- | --- | ---: |"
        if [[ -s "$TIMINGS_TSV" ]]; then
            while IFS=$'\t' read -r phase_name phase_status _started_at _ended_at _duration_ms duration_seconds _error_message; do
                echo "| $phase_name | $phase_status | $duration_seconds |"
            done <"$TIMINGS_TSV"
        else
            echo "| none | not-recorded | 0 |"
        fi

        echo ""
        echo "### Readiness failures"

        local readiness_files=(
            "$ARTIFACTS_DIR/linux-dns-readiness.err.log"
            "$ARTIFACTS_DIR/linux-firefox-readiness.err.log"
        )
        local found_readiness_failure=false
        local readiness_file
        for readiness_file in "${readiness_files[@]}"; do
            if [[ -s "$readiness_file" ]]; then
                found_readiness_failure=true
                echo ""
                echo "#### $(basename "$readiness_file")"
                echo '```'
                sed -n '1,80p' "$readiness_file"
                echo '```'
            fi
        done

        if [[ "$found_readiness_failure" == false ]]; then
            echo ""
            echo "No readiness failures captured."
        fi

        echo ""
        echo "### Auto-allow boundary"
        if [[ -s "$ARTIFACTS_DIR/linux-auto-allow-boundary.json" ]]; then
            python3 - "$ARTIFACTS_DIR/linux-auto-allow-boundary.json" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    artifact = json.load(fh)

boundary = artifact.get('failureBoundary') or {}
result = 'success' if artifact.get('success') is True else 'failure'
print(f"- Result: `{result}`")
print(f"- Boundary: `{boundary.get('id', 'unknown')}`")
print(f"- Message: {boundary.get('message', 'n/a')}")
PY
        else
            echo ""
            echo "linux-auto-allow-boundary.json: missing"
        fi
    } >>"$GITHUB_STEP_SUMMARY"
}

cleanup() {
    if [[ -n "$FIXTURE_PID" ]]; then
        kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    fi

    if [[ -n "$API_PID" ]]; then
        kill "$API_PID" >/dev/null 2>&1 || true
    fi

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    if [[ "$_started_test_db" == true ]]; then
        docker compose -f "$PROJECT_ROOT/docker-compose.test.yml" down -v >/dev/null 2>&1 || true
    fi

    if [[ -n "$_context_dir" && -d "$_context_dir" ]]; then
        rm -rf "$_context_dir" || true
    fi
}

debug_state() {
    echo ""
    echo "Linux student-policy debug information..."
    echo ""
    echo "Docker containers:"
    docker ps -a || true
    echo ""
    echo "Container system status:"
    docker exec "$CONTAINER_NAME" systemctl is-system-running --wait 2>/dev/null || true
    echo ""
    echo "openpath-sse-listener.service status:"
    docker exec "$CONTAINER_NAME" systemctl status openpath-sse-listener.service --no-pager 2>/dev/null || true
    echo ""
    echo "openpath-update.service status:"
    docker exec "$CONTAINER_NAME" systemctl status openpath-update.service --no-pager 2>/dev/null || true
    echo ""
    echo "Linux OpenPath log tail:"
    docker exec "$CONTAINER_NAME" bash -lc 'tail -n 200 /var/log/openpath.log 2>/dev/null || true' || true
    echo ""
    echo "Whitelist snapshot:"
    docker exec "$CONTAINER_NAME" bash -lc 'cat /var/lib/openpath/whitelist.txt 2>/dev/null || true' || true
    echo ""
    echo "DNS listener snapshot:"
    docker exec "$CONTAINER_NAME" bash -lc 'ss -H -lunt 2>/dev/null | grep ":53" || true' || true
    echo ""
    echo "resolv.conf snapshot:"
    docker exec "$CONTAINER_NAME" bash -lc 'cat /etc/resolv.conf 2>/dev/null || true' || true
    echo ""
    echo "DNS readiness probes:"
    docker exec \
        -e OPENPATH_STUDENT_HOST_SUFFIX="$OPENPATH_STUDENT_HOST_SUFFIX" \
        "$CONTAINER_NAME" \
        bash -lc 'for host in raw.githubusercontent.com github.com "blocked.${OPENPATH_STUDENT_HOST_SUFFIX}"; do echo "== $host =="; dig @127.0.0.1 "$host" +short +time=3 +tries=1 2>&1 || true; done' || true
    echo ""
    echo "Firefox native host snapshot:"
    docker exec "$CONTAINER_NAME" bash -lc 'ls -l /openpath/firefox-extension/openpath-firefox-extension.xpi /usr/local/lib/openpath/openpath-native-host.py /usr/local/bin/openpath-native-host.py /usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json /root/.mozilla/native-messaging-hosts/whitelist_native_host.json 2>/dev/null || true' || true
    echo ""
    echo "Firefox native host manifest snapshot:"
    docker exec "$CONTAINER_NAME" bash -lc 'for manifest in /usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json /root/.mozilla/native-messaging-hosts/whitelist_native_host.json; do echo "== $manifest =="; cat "$manifest" 2>/dev/null || true; done' || true
}

on_error() {
    local rc=$?
    echo ""
    echo "Linux student-policy runner failed (exit code: $rc)"
    finish_timing_phase failure "${BASH_COMMAND:-unknown}" || true
    debug_state | tee "$ARTIFACTS_DIR/linux-student-policy-debug-state.log"
    publish_github_step_summary "failure" || true
    exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 1
    fi
}

require_file() {
    local file_path="$1"
    if [[ ! -f "$file_path" ]]; then
        echo "Missing required file: $file_path" >&2
        exit 1
    fi
}

require_dir() {
    local dir_path="$1"
    if [[ ! -d "$dir_path" ]]; then
        echo "Missing required directory: $dir_path" >&2
        exit 1
    fi
}

is_port_in_use() {
    local port="$1"
    python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(('127.0.0.1', port))
except OSError:
    sys.exit(0)
finally:
    sock.close()

sys.exit(1)
PY
}

get_free_port() {
    python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(('127.0.0.1', 0))
print(sock.getsockname()[1])
sock.close()
PY
}

wait_for_postgres() {
    local attempts=30
    local sleep_seconds=1

    for ((i = 1; i <= attempts; i += 1)); do
        if docker exec openpath-test-db pg_isready -U openpath -d openpath_test >/dev/null 2>&1 &&
            docker exec openpath-test-db psql -U openpath -d openpath_test -tAc 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep "$sleep_seconds"
    done

    echo "Test PostgreSQL did not become ready in time" >&2
    exit 1
}

wait_for_http() {
    local url="$1"
    local host_header="${2:-}"
    local attempts="${3:-30}"

    for ((i = 1; i <= attempts; i += 1)); do
        if [[ -n "$host_header" ]]; then
            if curl -fsS -H "Host: $host_header" "$url" >/dev/null 2>&1; then
                return 0
            fi
        else
            if curl -fsS "$url" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 1
    done

    echo "Timed out waiting for HTTP endpoint: $url" >&2
    exit 1
}

wait_for_container_http() {
    local url="$1"
    local host_header="${2:-}"
    local attempts="${3:-30}"

    for ((i = 1; i <= attempts; i += 1)); do
        if [[ -n "$host_header" ]]; then
            if docker exec "$CONTAINER_NAME" curl -fsS -H "Host: $host_header" "$url" >/dev/null 2>&1; then
                return 0
            fi
        else
            if docker exec "$CONTAINER_NAME" curl -fsS "$url" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 1
    done

    echo "Timed out waiting for container HTTP endpoint: $url" >&2
    exit 1
}

wait_for_systemd() {
    local attempts=40

    for ((i = 1; i <= attempts; i += 1)); do
        local state
        state=$(docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null || true)
        if [[ "$state" == "running" || "$state" == "degraded" ]]; then
            return 0
        fi
        sleep 1
    done

    echo "Timed out waiting for systemd inside $CONTAINER_NAME" >&2
    exit 1
}

reserve_runtime_ports() {
    if is_port_in_use "$API_PORT"; then
        API_PORT="$(get_free_port)"
    fi

    if is_port_in_use "$FIXTURE_PORT"; then
        FIXTURE_PORT="$(get_free_port)"
    fi
}

create_context() {
    local tmp
    tmp="$(mktemp -d -t openpath-student-e2e-context.XXXXXXXX)"

    mkdir -p "$tmp/linux" "$tmp/runtime" "$tmp/windows" "$tmp/tests/e2e" "$tmp/tests/selenium" "$tmp/firefox-extension"

    cp -a "$PROJECT_ROOT/linux/." "$tmp/linux/"
    cp -a "$PROJECT_ROOT/runtime/." "$tmp/runtime/"
    cp -a "$PROJECT_ROOT/windows/." "$tmp/windows/"
    cp -a "$PROJECT_ROOT/tests/e2e/." "$tmp/tests/e2e/"
    cp -a "$PROJECT_ROOT/tests/selenium/." "$tmp/tests/selenium/"

    require_file "$PROJECT_ROOT/firefox-extension/manifest.json"
    require_dir "$PROJECT_ROOT/firefox-extension/_locales"
    require_dir "$PROJECT_ROOT/firefox-extension/dist"
    require_dir "$PROJECT_ROOT/firefox-extension/popup"
    require_dir "$PROJECT_ROOT/firefox-extension/blocked"
    require_dir "$PROJECT_ROOT/firefox-extension/native"
    require_dir "$PROJECT_ROOT/firefox-extension/icons"

    cp -a "$PROJECT_ROOT/firefox-extension/manifest.json" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/_locales" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/dist" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/popup" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/blocked" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/native" "$tmp/firefox-extension/"
    cp -a "$PROJECT_ROOT/firefox-extension/icons" "$tmp/firefox-extension/"

    require_file "$PROJECT_ROOT/VERSION"
    require_file "$PROJECT_ROOT/runtime/browser-policy-spec.json"
    require_file "$PROJECT_ROOT/tests/e2e/Dockerfile.student"

    cp -a "$PROJECT_ROOT/VERSION" "$tmp/"
    cp -a "$PROJECT_ROOT/tests/e2e/Dockerfile.student" "$tmp/Dockerfile.student"

    echo "$tmp"
}

start_test_db() {
    echo "Starting test PostgreSQL..."
    docker compose -f "$PROJECT_ROOT/docker-compose.test.yml" down -v >/dev/null 2>&1 || true
    docker compose -f "$PROJECT_ROOT/docker-compose.test.yml" up -d
    _started_test_db=true
    wait_for_postgres
}

initialize_test_database() {
    echo "Initializing E2E test database..."
    (
        cd "$PROJECT_ROOT"
        DB_HOST=localhost \
        DB_PORT=5433 \
        DB_NAME=openpath_test \
        DB_USER=openpath \
        DB_PASSWORD=openpath_test \
        npm run db:setup:e2e --workspace=@openpath/api
    )
}

prepare_workspace() {
    echo "Building shared and Firefox extension workspaces..."
    (
        cd "$PROJECT_ROOT"
        npm run build --workspace=@openpath/shared
        npm run build:cached --workspace=@openpath/firefox-extension
        prepare_firefox_release_artifacts
    )
}

prepare_firefox_release_artifacts() {
    echo "Packaging Firefox release artifacts for the Linux student-policy API..."
    local extension_dir="$PROJECT_ROOT/firefox-extension"
    local manifest_path="$extension_dir/manifest.json"
    local version
    local built_xpi_path
    local release_root="$extension_dir/build/firefox-release"
    local payload_hash
    local release_xpi_path="$release_root/openpath-firefox-extension.xpi"

    payload_hash="$(node "$extension_dir/firefox-release-payload-hash.mjs")"
    if [[ -s "$release_root/metadata.json" && -s "$release_xpi_path" ]]; then
        node "$extension_dir/verify-firefox-release-artifacts.mjs" \
            --release-dir "$release_root" \
            --payload-hash "$payload_hash"
        mkdir -p "$ARTIFACTS_DIR"
        sha256sum "$release_xpi_path" >"$FIREFOX_XPI_HASH_PATH"
        echo "Using existing signed Firefox release artifact: $release_xpi_path"
        STUDENT_USE_MANAGED_FIREFOX_EXTENSION=true
        return 0
    fi

    echo "Signed Firefox release artifacts not present; Linux student-policy Selenium will load the unsigned XPI directly and keep native-host readiness checks." >&2
    STUDENT_USE_MANAGED_FIREFOX_EXTENSION=false
    version="$(
        node -e 'const fs = require("node:fs"); const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(manifest.version);' \
            "$manifest_path"
    )"
    built_xpi_path="$extension_dir/monitor-bloqueos-red-$version.xpi"

    rm -f "$built_xpi_path"
    "$extension_dir/build-xpi.sh"
    require_file "$built_xpi_path"
    mkdir -p "$ARTIFACTS_DIR"
    local xpi_sha256
    xpi_sha256="$(sha256sum "$built_xpi_path" | awk '{print $1}')"
    printf '%s  %s\n' "$xpi_sha256" "$built_xpi_path" >"$FIREFOX_XPI_HASH_PATH"
    echo "Firefox XPI hash sha256=$xpi_sha256 path=$built_xpi_path"
}

resolve_student_host_suffix() {
    export OPENPATH_STUDENT_HOST_SUFFIX="$STUDENT_HOST_SUFFIX"
}

start_api_server() {
    local data_dir="$ARTIFACTS_DIR/api-data"
    mkdir -p "$data_dir"

    echo "Starting API on host port $API_PORT..."
    (
        cd "$PROJECT_ROOT"
        NODE_ENV=test \
        JWT_SECRET=openpath-student-policy-secret \
        SHARED_SECRET=openpath-student-policy-shared \
        DB_HOST=localhost \
        DB_PORT=5433 \
        DB_NAME=openpath_test \
        DB_USER=openpath \
        DB_PASSWORD=openpath_test \
        PORT="$API_PORT" \
        DATA_DIR="$data_dir" \
        PUBLIC_URL="http://host.docker.internal:$API_PORT" \
        OPENPATH_FIREFOX_RELEASE_ROOT="$PROJECT_ROOT/firefox-extension/build/firefox-release" \
        node --import tsx api/src/server.ts >"$ARTIFACTS_DIR/api.log" 2>&1
    ) &
    API_PID=$!
    wait_for_http "http://127.0.0.1:$API_PORT/trpc/healthcheck.ready"
}

bootstrap_scenario() {
    local scenario_label="${1:-Linux Student Policy}"
    echo "Bootstrapping student-policy scenario..."
    local raw_json="$ARTIFACTS_DIR/student-scenario.raw.json"
    local final_json="$ARTIFACTS_DIR/student-scenario.json"

    (
        cd "$PROJECT_ROOT"
        OPENPATH_STUDENT_HOST_SUFFIX="$OPENPATH_STUDENT_HOST_SUFFIX" \
        node --import tsx tests/e2e/student-flow/backend-harness.ts bootstrap \
            --api-url "http://127.0.0.1:$API_PORT" \
            --scenario-name "$scenario_label" \
            --machine-hostname "$MACHINE_NAME" \
            >"$raw_json"
    )

    python3 - "$raw_json" "$final_json" "$API_PORT" <<'PY'
import json
import sys

raw_path, final_path, api_port = sys.argv[1:4]
with open(raw_path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)

payload['apiUrl'] = f'http://host.docker.internal:{api_port}'

with open(final_path, 'w', encoding='utf-8') as fh:
    json.dump(payload, fh, indent=2)
    fh.write('\n')
PY
}

seed_initial_baseline_policy() {
    echo "Seeding initial Linux student-policy baseline..."
    local scenario_path="$ARTIFACTS_DIR/student-scenario.json"
    local api_url="http://127.0.0.1:$API_PORT"
    local teacher_token
    local restricted_group_id
    local alternate_group_id
    teacher_token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["auth"]["teacher"]["accessToken"])' "$scenario_path")"
    restricted_group_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["groups"]["restricted"]["id"])' "$scenario_path")"
    alternate_group_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["groups"]["alternate"]["id"])' "$scenario_path")"

    local baseline_hosts=()
    mapfile -t baseline_hosts < <(python3 - "$scenario_path" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    scenario = json.load(fh)

hosts = [
    scenario['fixtures']['portal'],
    scenario['fixtures']['cdnPortal'],
    scenario['fixtures']['site'],
    scenario['fixtures']['apiSite'],
    'host.docker.internal',
]

seen = set()
for host in hosts:
    if host and host not in seen:
        seen.add(host)
        print(host)
PY
)

    local group_id
    local host
    for group_id in "$restricted_group_id" "$alternate_group_id"; do
        for host in "${baseline_hosts[@]}"; do
            (
                cd "$PROJECT_ROOT"
                node --import tsx tests/e2e/student-flow/backend-harness.ts create-rule \
                    --api-url "$api_url" \
                    --access-token "$teacher_token" \
                    --group-id "$group_id" \
                    --type whitelist \
                    --value "$host" \
                    --comment "Initial Linux student-policy readiness baseline" >/dev/null
            )
        done
    done
}

build_image() {
    echo "Building Linux student-policy image..."
    _context_dir="$(create_context)"

    if docker buildx version >/dev/null 2>&1; then
        if docker buildx build \
            -f "$_context_dir/Dockerfile.student" \
            -t "$IMAGE_TAG" \
            --cache-from type=gha \
            --cache-to type=gha,mode=max \
            --load \
            "$_context_dir"; then
            return 0
        fi

        echo "Docker buildx cache build failed; falling back to plain docker build." >&2
    fi

    docker build -f "$_context_dir/Dockerfile.student" -t "$IMAGE_TAG" "$_context_dir"
}

start_container() {
    echo "Starting student-policy container..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --hostname "$MACHINE_NAME" \
        --privileged \
        --cgroupns=host \
        --tmpfs /run \
        --tmpfs /run/lock \
        --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --volume "$ARTIFACTS_DIR:/artifacts" \
        --add-host host.docker.internal:host-gateway \
        "$IMAGE_TAG" >/dev/null

    wait_for_systemd
}

start_container_fixture_server() {
    echo "Starting fixture server inside container on port $FIXTURE_PORT..."
    docker exec \
        -e OPENPATH_STUDENT_HOST_SUFFIX="$OPENPATH_STUDENT_HOST_SUFFIX" \
        "$CONTAINER_NAME" \
        bash -lc "cd /openpath/tests/selenium && nohup npx tsx /openpath/tests/e2e/student-flow/fixture-server.ts --host 0.0.0.0 --port '$FIXTURE_PORT' >/artifacts/fixture-server.json 2>/artifacts/fixture-server.log < /dev/null &"

    wait_for_container_http "http://127.0.0.1:$FIXTURE_PORT/ok" "portal.${OPENPATH_STUDENT_HOST_SUFFIX}:$FIXTURE_PORT"
}

configure_client() {
    local install_client="${1:-true}"

    # Fast-fail is ON by default now, so the standard install (no override) already
    # adds the sinkhole RST rule and gates the AAAA sinkhole -- the lane exercises
    # that real default. Only when opting OUT do we write an override BEFORE
    # install.sh: activate_firewall runs during install, and defaults.conf sources
    # /etc/openpath/overrides.conf before resolving SINKHOLE_FAST_FAIL.
    if [[ "$STUDENT_SINKHOLE_FAST_FAIL" == "0" || "$STUDENT_SINKHOLE_FAST_FAIL" == "false" ]]; then
        echo "Opting OUT of sinkhole fast-fail (OPENPATH_SINKHOLE_FAST_FAIL=0) via /etc/openpath/overrides.conf"
        docker exec "$CONTAINER_NAME" bash -lc 'mkdir -p /etc/openpath && printf "export OPENPATH_SINKHOLE_FAST_FAIL=0\n" > /etc/openpath/overrides.conf'
    fi

    if [[ "$install_client" == "true" ]]; then
        echo "Installing Linux OpenPath client in container..."
        docker exec "$CONTAINER_NAME" bash -lc 'rm -rf /openpath/linux/firefox-extension && cp -a /openpath/firefox-extension /openpath/linux/firefox-extension && cd /openpath && ./linux/install.sh --unattended --skip-firefox'
    else
        echo "Reconfiguring existing Linux OpenPath client in container..."
    fi

    local classroom_id
    local enrollment_token
    classroom_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["classroom"]["id"])' "$ARTIFACTS_DIR/student-scenario.json")
    enrollment_token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["auth"]["teacher"]["accessToken"])' "$ARTIFACTS_DIR/student-scenario.json")

    # Replace the placeholder bearer token with a real enrollment token tied to the classroom.
    enrollment_token=$(curl -fsS \
        -H "Authorization: Bearer $enrollment_token" \
        -X POST "http://127.0.0.1:$API_PORT/api/enroll/$classroom_id/ticket" | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["enrollmentToken"])')

    docker exec "$CONTAINER_NAME" bash -lc \
        "/usr/local/bin/openpath setup --api-url 'http://host.docker.internal:$API_PORT' --classroom-id '$classroom_id' --enrollment-token '$enrollment_token' --machine-name '$MACHINE_NAME'"

    if [[ "$STUDENT_USE_MANAGED_FIREFOX_EXTENSION" == "true" ]]; then
        docker exec "$CONTAINER_NAME" bash -lc '/usr/local/bin/openpath-browser-setup.sh'
    else
        docker exec "$CONTAINER_NAME" bash -lc '
set -euo pipefail
source /usr/local/lib/openpath/lib/common.sh
source /usr/local/lib/openpath/lib/browser.sh
install_browser_integrations \
    /openpath/firefox-extension \
    /openpath/firefox-extension/build/firefox-release \
    --native-host \
    --firefox-best-effort \
    --chromium-best-effort \
    --native-host-required
'
    fi
    docker exec "$CONTAINER_NAME" bash -lc '/usr/local/bin/openpath-update.sh'
    docker exec "$CONTAINER_NAME" bash -lc 'mkdir -p /root/.mozilla/native-messaging-hosts && cp /usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json /root/.mozilla/native-messaging-hosts/whitelist_native_host.json'

    local whitelist_url
    whitelist_url="$(docker exec "$CONTAINER_NAME" bash -lc 'cat /etc/openpath/whitelist-url.conf')"

    python3 - "$ARTIFACTS_DIR/student-scenario.json" "$whitelist_url" <<'PY'
import json
import re
import sys

scenario_path, whitelist_url = sys.argv[1:3]
match = re.search(r'/w/([^/]+)/', whitelist_url)
if match is None:
    raise SystemExit(f'Could not extract machine token from {whitelist_url}')

with open(scenario_path, 'r', encoding='utf-8') as fh:
    payload = json.load(fh)

payload['machine']['whitelistUrl'] = whitelist_url
payload['machine']['machineToken'] = match.group(1)

with open(scenario_path, 'w', encoding='utf-8') as fh:
    json.dump(payload, fh, indent=2)
    fh.write('\n')
PY
}

assert_linux_dns_policy_ready() {
    echo "Verifying Linux DNS policy readiness..."
    local readiness_log="$ARTIFACTS_DIR/linux-dns-readiness.err.log"
    rm -f "$readiness_log"

    if ! docker exec \
        -e OPENPATH_STUDENT_HOST_SUFFIX="$OPENPATH_STUDENT_HOST_SUFFIX" \
        "$CONTAINER_NAME" \
        bash -lc '
set -euo pipefail

dns_errors=()

if ! systemctl is-active --quiet dnsmasq; then
    dns_errors+=("dnsmasq service is not active after install/enroll/update")
fi

if ! ss -H -lunt 2>/dev/null | awk "\$5 ~ /:53$/ { found = 1 } END { exit found ? 0 : 1 }"; then
    dns_errors+=("dnsmasq is not listening on local port 53")
fi

if ! awk "\$1 == \"nameserver\" && \$2 == \"127.0.0.1\" { found = 1 } END { exit found ? 0 : 1 }" /etc/resolv.conf 2>/dev/null; then
    dns_errors+=("/etc/resolv.conf does not point at local dnsmasq")
fi

for probe_host in raw.githubusercontent.com github.com; do
    if ! probe_addresses="$(dig @127.0.0.1 "$probe_host" +short +time=3 +tries=1 2>&1)"; then
        dns_errors+=("$probe_host failed through local dnsmasq: $probe_addresses")
    elif [[ -z "$probe_addresses" ]]; then
        dns_errors+=("$probe_host returned no records through local dnsmasq")
    fi
done

blocked_probe_host="blocked.${OPENPATH_STUDENT_HOST_SUFFIX}"
blocked_fixture_ip="127.0.0.1"
blocked_addresses="$(dig @127.0.0.1 "$blocked_probe_host" +short +time=3 +tries=1 2>/dev/null || true)"
if [[ "$blocked_addresses" == *"$blocked_fixture_ip"* ]]; then
    dns_errors+=("$blocked_probe_host resolved to $blocked_fixture_ip through dnsmasq, expected default deny")
fi

if ((${#dns_errors[@]} > 0)); then
    printf "Linux DNS policy readiness failed before Selenium:\n" >&2
    printf " - %s\n" "${dns_errors[@]}" >&2
    exit 1
fi
' 2>"$readiness_log"; then
        cat "$readiness_log" >&2 || true
        return 1
    fi

    rm -f "$readiness_log"
}

# When sinkhole fast-fail is enabled the agent was installed with
# OPENPATH_SINKHOLE_FAST_FAIL=1, so a blocked domain must fail to connect
# *instantly* (firewall RST to the non-local sinkhole) instead of black-holing at
# the default DROP for the full TCP connect timeout (~90s). Measures the real curl
# latency to the blocked host through the installed dnsmasq + firewall and asserts
# it fast-fails (and is still blocked). Forces IPv4 because the container's v6
# sinkhole fast-fails at routing anyway; the v4 sinkhole is the universal hang.
# No-op when the opt-in flag is off (default lane unchanged).
assert_sinkhole_fast_fail() {
    if [[ "$STUDENT_SINKHOLE_FAST_FAIL" != "1" && "$STUDENT_SINKHOLE_FAST_FAIL" != "true" ]]; then
        return 0
    fi
    echo "Verifying sinkhole fast-fail latency for a blocked domain..."
    local log="$ARTIFACTS_DIR/linux-sinkhole-fast-fail.err.log"
    rm -f "$log"
    if ! docker exec \
        -e OPENPATH_STUDENT_HOST_SUFFIX="$OPENPATH_STUDENT_HOST_SUFFIX" \
        "$CONTAINER_NAME" \
        bash -lc '
set -uo pipefail
host="blocked.${OPENPATH_STUDENT_HOST_SUFFIX}"
threshold_ms=5000
echo "blocked host: $host"
echo "  A    -> $(dig @127.0.0.1 A "$host" +short +time=2 +tries=1 | head -1)"
echo "  AAAA -> $(dig @127.0.0.1 AAAA "$host" +short +time=2 +tries=1 | head -1)"
echo "  firewall RST rule: $(iptables -S OUTPUT 2>/dev/null | grep -c "REJECT --reject-with tcp-reset")"
( source /usr/local/lib/openpath/lib/defaults.conf 2>/dev/null; echo "  resolved SINKHOLE_FAST_FAIL=${SINKHOLE_FAST_FAIL:-UNSET}" )
echo "  sinkhole/deny rules:"; iptables -S OUTPUT 2>/dev/null | grep -E "192.0.2.1|OUTPUT -j (DROP|REJECT)" | sed "s/^/    /"
start=$(date +%s%N)
curl -4 -sS -o /dev/null --max-time 15 "https://$host/"
rc=$?
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
echo "  curl -4 https://$host/ -> rc=$rc elapsed=${elapsed_ms}ms"
if [ "$rc" -eq 0 ]; then
    echo "FAIL: blocked host was reachable (enforcement broken)" >&2
    exit 1
fi
if [ "$elapsed_ms" -lt "$threshold_ms" ]; then
    echo "PASS: blocked domain fast-failed in ${elapsed_ms}ms (< ${threshold_ms}ms)"
else
    echo "FAIL: blocked domain hung ${elapsed_ms}ms (>= ${threshold_ms}ms) - sinkhole RST not effective" >&2
    exit 1
fi
' 2>"$log"; then
        cat "$log" >&2 || true
        return 1
    fi
    rm -f "$log"
}

# Browser-level proof: in real headless Firefox, a blocked sub-resource of an
# allowed page must fail fast (onerror in ms) instead of black-holing for the
# browser's connect timeout (~90s) -- the actual student symptom. Drives the
# Firefox + selenium-webdriver already installed in the image. No-op when the
# opt-in flag is off.
assert_sinkhole_fast_fail_browser() {
    if [[ "$STUDENT_SINKHOLE_FAST_FAIL" != "1" && "$STUDENT_SINKHOLE_FAST_FAIL" != "true" ]]; then
        return 0
    fi
    echo "Verifying sinkhole fast-fail at the browser level (headless Firefox)..."
    local probe="$ARTIFACTS_DIR/sinkhole-fastfail-browser-probe.js"
    # host is passed to executeAsyncScript as arguments[0] (no string interpolation,
    # so the quoted heredoc needs no shell/JS escaping).
    cat > "$probe" <<'PROBEJS'
const { Builder } = require('/openpath/tests/selenium/node_modules/selenium-webdriver');
const firefox = require('/openpath/tests/selenium/node_modules/selenium-webdriver/firefox');
(async () => {
  const host = process.env.PROBE_HOST;
  const opts = new firefox.Options().addArguments('-headless');
  // Cap Firefox's own connect timeout so a regression (hang) ends in ~20s, not ~90s.
  opts.setPreference('network.http.connection-timeout', 20);
  opts.setPreference('network.http.connection-retry-timeout', 0);
  const driver = await new Builder().forBrowser('firefox').setFirefoxOptions(opts).build();
  try {
    await driver.manage().setTimeouts({ script: 100000 });
    await driver.get(process.env.PROBE_ORIGIN);
    const result = await driver.executeAsyncScript(
      'const cb = arguments[arguments.length - 1];' +
      'const url = "https://" + arguments[0] + "/probe.js?cache=" + Date.now();' +
      'const start = performance.now();' +
      'const s = document.createElement("script"); s.src = url;' +
      'let done = false;' +
      'const finish = (status) => { if (done) return; done = true; cb({ status, durationMs: Math.round(performance.now() - start) }); };' +
      's.onload = () => finish("ok"); s.onerror = () => finish("blocked");' +
      'setTimeout(() => finish("cap-90s"), 90000);' +
      'document.body.appendChild(s);',
      host
    );
    console.log('PROBE_RESULT ' + JSON.stringify(result));
  } finally { await driver.quit(); }
})().catch((e) => { console.error('PROBE_ERROR ' + (e && e.message)); process.exit(2); });
PROBEJS

    # Pipe the probe into the container (docker cp can fail to chown the
    # agent-managed resolv.conf mount on some daemons).
    docker exec -i "$CONTAINER_NAME" sh -c 'cat > /tmp/sinkhole-fastfail-browser-probe.js' < "$probe"
    local out
    if ! out=$(docker exec \
        -e PROBE_HOST="blocked.${OPENPATH_STUDENT_HOST_SUFFIX}" \
        -e PROBE_ORIGIN="http://127.0.0.1:${FIXTURE_PORT}/" \
        "$CONTAINER_NAME" node /tmp/sinkhole-fastfail-browser-probe.js 2>&1); then
        echo "$out" >&2
        echo "FAIL: browser probe errored" >&2
        return 1
    fi
    local json status duration
    json=$(printf '%s\n' "$out" | sed -n 's/^PROBE_RESULT //p' | tail -1)
    status=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)
    duration=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["durationMs"])' 2>/dev/null)
    echo "  browser blocked sub-resource: status=${status:-?} durationMs=${duration:-?}"
    if [[ "$status" == "ok" ]]; then
        echo "FAIL: blocked sub-resource loaded in the browser (enforcement broken)" >&2
        return 1
    fi
    if [[ -z "$duration" ]] || ((duration >= 6000)); then
        echo "FAIL: blocked sub-resource did not fast-fail in the browser (${duration:-?}ms >= 6000ms)" >&2
        return 1
    fi
    echo "PASS: browser blocked sub-resource fast-failed in ${duration}ms (< 6000ms)"
}

wait_for_linux_dns_policy_ready() {
    local max_attempts="${OPENPATH_LINUX_DNS_READINESS_ATTEMPTS:-12}"
    local delay_seconds="${OPENPATH_LINUX_DNS_READINESS_DELAY_SECONDS:-5}"
    local attempt=1
    local last_status=0

    if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || ((max_attempts < 1)); then
        max_attempts=12
    fi

    if ! [[ "$delay_seconds" =~ ^[0-9]+$ ]] || ((delay_seconds < 1)); then
        delay_seconds=5
    fi

    while ((attempt <= max_attempts)); do
        echo "Linux DNS policy readiness attempt $attempt/$max_attempts"
        if assert_linux_dns_policy_ready; then
            return 0
        fi

        last_status=$?
        if ((attempt < max_attempts)); then
            sleep "$delay_seconds"
        fi
        attempt=$((attempt + 1))
    done

    echo "Linux DNS policy readiness did not converge after $max_attempts attempts" >&2
    debug_state
    return "$last_status"
}

assert_linux_firefox_extension_ready() {
    echo "Verifying Linux Firefox extension readiness..."
    local readiness_log="$ARTIFACTS_DIR/linux-firefox-readiness.err.log"
    rm -f "$readiness_log"

    if ! docker exec "$CONTAINER_NAME" bash -lc '
set -euo pipefail

readiness_errors=()
xpi_path="/openpath/firefox-extension/openpath-firefox-extension.xpi"
system_manifest="/usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json"
root_manifest="/root/.mozilla/native-messaging-hosts/whitelist_native_host.json"

[[ -s "$xpi_path" ]] || readiness_errors+=("Firefox XPI missing or empty: $xpi_path")
[[ -s "$system_manifest" ]] || readiness_errors+=("system Firefox native host manifest missing: $system_manifest")
[[ -s "$root_manifest" ]] || readiness_errors+=("root Firefox native host manifest missing: $root_manifest")

if [[ -s "$root_manifest" ]]; then
    manifest_name="$(jq -r ".name // \"\"" "$root_manifest")"
    manifest_path="$(jq -r ".path // \"\"" "$root_manifest")"
    if [[ "$manifest_name" != "whitelist_native_host" ]]; then
        readiness_errors+=("root Firefox native host manifest has unexpected name: $manifest_name")
    fi
    if [[ -z "$manifest_path" ]]; then
        readiness_errors+=("root Firefox native host manifest has no path")
    elif [[ "$manifest_path" != /* ]]; then
        readiness_errors+=("root Firefox native host manifest path is not absolute: $manifest_path")
    elif ! [[ -x "$manifest_path" ]]; then
        readiness_errors+=("native host executable missing or not executable: $manifest_path")
    fi
    if ! jq -e ".allowed_extensions | index(\"openpath-block-monitor@openpath\")" "$root_manifest" >/dev/null; then
        readiness_errors+=("root Firefox native host manifest does not allow openpath-block-monitor@openpath")
    fi
fi

if ((${#readiness_errors[@]} > 0)); then
    printf "Linux Firefox extension readiness failed before Selenium:\n" >&2
    printf " - %s\n" "${readiness_errors[@]}" >&2
    exit 1
fi
' 2>"$readiness_log"; then
        cat "$readiness_log" >&2 || true
        return 1
    fi

    rm -f "$readiness_log"
}

run_student_suite() {
    local mode="${1:-sse}"
    local coverage_profile="${2:-full}"
    local group_label="${STUDENT_SCENARIO_GROUP:-full}"
    local docker_env_args=()
    if [[ "$STUDENT_USE_MANAGED_FIREFOX_EXTENSION" == "true" ]]; then
        docker_env_args+=(-e OPENPATH_SKIP_EXTENSION_BUNDLE=1)
    fi
    if [[ -n "$STUDENT_SCENARIO_GROUP" ]]; then
        docker_env_args+=(-e OPENPATH_STUDENT_SCENARIO_GROUP="$STUDENT_SCENARIO_GROUP")
    fi

    echo "Running Selenium student-policy suite inside container (mode: $mode, coverage profile: $coverage_profile, scenario group: $group_label)..."
    docker exec \
        -e OPENPATH_STUDENT_SCENARIO_FILE=/artifacts/student-scenario.json \
        -e OPENPATH_STUDENT_DIAGNOSTICS_DIR=/artifacts/selenium-diagnostics \
        -e OPENPATH_FIXTURE_PORT="$FIXTURE_PORT" \
        -e OPENPATH_STUDENT_HOST_SUFFIX="$OPENPATH_STUDENT_HOST_SUFFIX" \
        -e OPENPATH_EXTENSION_PATH=/openpath/firefox-extension/openpath-firefox-extension.xpi \
        -e OPENPATH_WHITELIST_PATH=/var/lib/openpath/whitelist.txt \
        -e OPENPATH_FORCE_UPDATE_COMMAND=/usr/local/bin/openpath-update.sh \
        -e OPENPATH_DISABLE_SSE_COMMAND='systemctl stop openpath-sse-listener.service' \
        -e OPENPATH_ENABLE_SSE_COMMAND='systemctl start openpath-sse-listener.service' \
        -e OPENPATH_STUDENT_MODE="$mode" \
        -e OPENPATH_STUDENT_COVERAGE_PROFILE="$coverage_profile" \
        -e CI=true \
        "${docker_env_args[@]}" \
        "$CONTAINER_NAME" \
        bash -lc 'cd /openpath/tests/selenium && npm run test:student-policy:ci'
}

main() {
    require_command curl
    require_command docker
    require_command node
    require_command npm
    require_command python3

    mkdir -p "$ARTIFACTS_DIR"
    # Start each run with fresh timing evidence; the TSV is append-only, so stale
    # rows from a prior run (e.g. one written under a different locale) would
    # otherwise be re-parsed by write_timing_evidence and break the aggregation.
    rm -f "$TIMINGS_TSV" "$TIMINGS_JSON"

    reserve_runtime_ports
    run_timed_step "Build workspaces" prepare_workspace
    resolve_student_host_suffix
    run_timed_step "Ensure test PostgreSQL" start_test_db
    run_timed_step "Initialize test database" initialize_test_database
    run_timed_step "Start API server" start_api_server
    run_timed_step "Bootstrap SSE scenario" bootstrap_scenario "Linux Student Policy SSE"
    run_timed_step "Seed SSE baseline policy" seed_initial_baseline_policy
    run_timed_step "Build Linux student-policy image" build_image
    run_timed_step "Start student-policy container" start_container
    run_timed_step "Start fixture server" start_container_fixture_server
    run_timed_step "Install/enroll/update client" configure_client true
    run_timed_step "Verify SSE DNS policy readiness" wait_for_linux_dns_policy_ready
    run_timed_step "Verify sinkhole fast-fail" assert_sinkhole_fast_fail
    run_timed_step "Verify sinkhole fast-fail (browser)" assert_sinkhole_fast_fail_browser
    run_timed_step "Verify SSE Firefox readiness" assert_linux_firefox_extension_ready
    run_timed_step "Run Selenium student suite (sse)" run_student_suite sse full
    run_timed_step "Bootstrap fallback scenario" bootstrap_scenario "Linux Student Policy Fallback"
    run_timed_step "Seed fallback baseline policy" seed_initial_baseline_policy
    run_timed_step "Reconfigure/update client" configure_client false
    run_timed_step "Verify fallback DNS policy readiness" wait_for_linux_dns_policy_ready
    run_timed_step "Verify fallback Firefox readiness" assert_linux_firefox_extension_ready
    run_timed_step "Run Selenium student suite (fallback, fallback-propagation)" run_student_suite fallback fallback-propagation

    publish_github_step_summary "success"
    echo "Linux student-policy runner completed successfully"
}

main "$@"
