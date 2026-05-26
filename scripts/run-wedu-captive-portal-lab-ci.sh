#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROXMOX_HOST="${OPENPATH_WEDU_CI_PROXMOX_HOST:-whitelist-proxmox}"
WINDOWS_VMID="${OPENPATH_WEDU_CI_WINDOWS_VMID:-103}"
GATEWAY_VMID="${OPENPATH_WEDU_CI_GATEWAY_VMID:-121}"
WINDOWS_RUNNER_NAME="${OPENPATH_WEDU_CI_WINDOWS_RUNNER_NAME:-openpath-windows-103}"
GATEWAY_URL="${OPENPATH_WEDU_LAB_GATEWAY_URL:-http://10.77.0.1}"
EXPECTED_DNS="${OPENPATH_WEDU_LAB_EXPECTED_DNS:-10.77.0.1}"
EXPECTED_SUBNET="${OPENPATH_WEDU_LAB_EXPECTED_SUBNET:-10.77.0.0/24}"
DIRECT_TIMEOUT_SECONDS="${OPENPATH_WEDU_CI_DIRECT_TIMEOUT_SECONDS:-900}"
ARTIFACT_DIR="${OPENPATH_WEDU_CI_ARTIFACT_DIR:-.opencode/tmp/wedu-captive-portal-lab-ci/$(date -u +%Y%m%dT%H%M%SZ)}"
WINDOWS_REPO_ROOT="${OPENPATH_WEDU_CI_WINDOWS_REPO_ROOT:-C:\\Windows\\Temp\\openpath-wedu-ci}"
REMOTE_LOCK_DIR="${OPENPATH_WEDU_CI_LOCK_DIR:-/run/openpath-wedu-captive-portal-lab.lock}"
DELETE_SNAPSHOT_ON_SUCCESS="${OPENPATH_WEDU_CI_DELETE_SNAPSHOT_ON_SUCCESS:-1}"
DRY_RUN="${OPENPATH_WEDU_CI_DRY_RUN:-0}"

ARTIFACT_DIR="$(cd "$REPO_ROOT" && mkdir -p "$ARTIFACT_DIR" && cd "$ARTIFACT_DIR" && pwd)"
HTTP_SERVER_PID=""
HTTP_SERVER_LOG="$ARTIFACT_DIR/overlay-http.log"
LOCK_OWNER="${GITHUB_RUN_ID:-local}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SNAPSHOT_NAME=""
SNAPSHOT_CREATED=0
RUNNER_SERVICES_STOPPED=0
ORIGINAL_NET0=""
ORIGINAL_BOOT=""
RUN_STATUS=0
CLEANUP_FAILED=0

log() {
  printf '%s\n' "$*"
}

warn() {
  printf '::warning::%s\n' "$*" >&2
}

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ssh_proxmox() {
  ssh "$PROXMOX_HOST" "$@"
}

extract_first_usable_ipv4() {
  python3 -c '
import json, sys
payload = json.load(sys.stdin)
interfaces = payload if isinstance(payload, list) else payload.get("result", payload.get("data", []))
for interface in interfaces:
    for address in interface.get("ip-addresses", []):
        ip = address.get("ip-address", "")
        kind = str(address.get("ip-address-type", "")).lower()
        if kind in ("", "ipv4") and ip.count(".") == 3 and ip != "127.0.0.1" and not ip.startswith("169.254."):
            print(ip)
            raise SystemExit(0)
raise SystemExit(1)
'
}

require_guest_exec_success() {
  python3 -c '
import json, sys
payload = json.load(sys.stdin)
if payload.get("exited") != 1 or payload.get("exitcode") != 0:
    sys.stderr.write(payload.get("err-data") or payload.get("out-data") or str(payload))
    raise SystemExit(1)
print(payload.get("out-data", ""), end="")
'
}

run_windows_ps() {
  local timeout_seconds="$1"
  local script="$2"
  local encoded
  local output
  encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
  output="$(
    ssh_proxmox qm guest exec "$WINDOWS_VMID" --timeout "$timeout_seconds" -- \
      powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$encoded"
  )"
  printf '%s' "$output" | require_guest_exec_success
}

wait_windows_qga() {
  local attempts="${1:-90}"
  for _ in $(seq 1 "$attempts"); do
    if ssh_proxmox qm agent "$WINDOWS_VMID" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

acquire_remote_lock() {
  local quoted_owner
  quoted_owner="$(printf '%q' "$LOCK_OWNER")"
  ssh_proxmox bash -lc "
    set -euo pipefail
    if mkdir '$REMOTE_LOCK_DIR'; then
      printf '%s\n' $quoted_owner > '$REMOTE_LOCK_DIR/owner'
      exit 0
    fi
    printf 'WEDU lab lock is already held by: ' >&2
    cat '$REMOTE_LOCK_DIR/owner' >&2 2>/dev/null || true
    exit 1
  "
}

release_remote_lock() {
  local quoted_owner
  quoted_owner="$(printf '%q' "$LOCK_OWNER")"
  ssh_proxmox bash -lc "
    set -euo pipefail
    if [ -f '$REMOTE_LOCK_DIR/owner' ] && [ \"\$(cat '$REMOTE_LOCK_DIR/owner')\" = $quoted_owner ]; then
      rm -rf '$REMOTE_LOCK_DIR'
    fi
  " || warn "Failed to release WEDU lab lock"
}

get_openpath_runner_state() {
  GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" gh api "repos/${GITHUB_REPOSITORY:-balejosg/Openpath}/actions/runners" \
    --jq ".runners[] | select(.name == \"$WINDOWS_RUNNER_NAME\") | \"\\(.status)/busy=\\(.busy)\""
}

assert_openpath_runner_idle() {
  local state
  state="$(get_openpath_runner_state || true)"
  if [ "$state" != "online/busy=false" ]; then
    fail "Expected $WINDOWS_RUNNER_NAME to be online/busy=false before WEDU lab, got: ${state:-missing}"
  fi
}

wait_for_openpath_runner_online() {
  local state
  for attempt in $(seq 1 24); do
    state="$(get_openpath_runner_state || true)"
    log "runner_state attempt=$attempt $WINDOWS_RUNNER_NAME=${state:-missing}"
    if [ "$state" = "online/busy=false" ]; then
      return 0
    fi
    sleep 10
  done
  return 1
}

stop_all_action_runner_services() {
  local script
  script='
$ErrorActionPreference = "Stop"
$services = @(Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue)
foreach ($service in $services) {
  if ($service.Status -ne "Stopped") {
    Stop-Service -Name $service.Name -Force
    $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(45))
  }
}
$services = @(Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue)
$services | Select-Object Name, Status | ConvertTo-Json -Compress
'
  run_windows_ps 120 "$script"
  RUNNER_SERVICES_STOPPED=1
}

start_all_action_runner_services() {
  local script
  script='
$ErrorActionPreference = "Stop"
$services = @(Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue)
foreach ($service in $services) {
  if ($service.Status -ne "Running") {
    Start-Service -Name $service.Name
    $service.WaitForStatus("Running", [TimeSpan]::FromSeconds(45))
  }
}
$services = @(Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue)
$services | Select-Object Name, Status | ConvertTo-Json -Compress
'
  run_windows_ps 120 "$script"
}

cleanup_windows_repo_root() {
  local ps_root
  ps_root="$WINDOWS_REPO_ROOT"
  run_windows_ps 120 "
\$ErrorActionPreference = 'Continue'
Remove-Item -LiteralPath '$ps_root' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'C:\Windows\Temp\openpath-wedu-ci.zip' -Force -ErrorAction SilentlyContinue
" >/dev/null || warn "Failed to clean temporary Windows checkout"
}

reset_gateway_captive() {
  local mode
  local output
  output="$(
    ssh_proxmox qm guest exec "$GATEWAY_VMID" -- bash -lc \
      'TOKEN=$(cat /opt/wedu-captive-portal/control-token); curl -fsS -H "X-Lab-Token: $TOKEN" http://10.77.0.1/lab/reset >/dev/null; cat /run/wedu-lab-firewall-mode'
  )"
  printf '%s' "$output" >"$ARTIFACT_DIR/gateway-reset.json"
  mode="$(printf '%s' "$output" | require_guest_exec_success | tr -d '\r\n')"
  [ "$mode" = "captive" ] || fail "Gateway reset did not leave firewall in captive mode: $mode"
}

read_gateway_token() {
  local output
  output="$(ssh_proxmox qm guest exec "$GATEWAY_VMID" -- bash -lc 'cat /opt/wedu-captive-portal/control-token')"
  printf '%s' "$output" | require_guest_exec_success
}

start_overlay_server() {
  local archive="$1"
  local guest_ip="$2"
  local host_ip
  local port
  host_ip="$(ip route get "$guest_ip" | sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p' | head -n 1)"
  [ -n "$host_ip" ] || fail "Unable to detect controller source IP for guest $guest_ip"
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')"
  (cd "$ARTIFACT_DIR" && python3 -m http.server "$port" --bind "$host_ip" >"$HTTP_SERVER_LOG" 2>&1) &
  HTTP_SERVER_PID="$!"
  for _ in $(seq 1 20); do
    if curl -fsS "http://$host_ip:$port/$(basename "$archive")" >/dev/null; then
      printf 'http://%s:%s/%s\n' "$host_ip" "$port" "$(basename "$archive")"
      return 0
    fi
    sleep 0.5
  done
  fail "Local checkout archive HTTP server did not become ready"
}

stop_overlay_server() {
  if [ -n "$HTTP_SERVER_PID" ] && kill -0 "$HTTP_SERVER_PID" >/dev/null 2>&1; then
    kill "$HTTP_SERVER_PID" >/dev/null 2>&1 || true
    wait "$HTTP_SERVER_PID" >/dev/null 2>&1 || true
  fi
  HTTP_SERVER_PID=""
}

prepare_current_checkout_on_windows() {
  local head_sha
  local archive
  local guest_json
  local guest_ip
  local archive_url
  head_sha="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
  archive="$ARTIFACT_DIR/openpath-wedu-ci-$head_sha.zip"
  git -C "$REPO_ROOT" archive --format=zip --output "$archive" HEAD
  guest_json="$(ssh_proxmox qm guest cmd "$WINDOWS_VMID" network-get-interfaces)"
  guest_ip="$(printf '%s' "$guest_json" | extract_first_usable_ipv4)"
  archive_url="$(start_overlay_server "$archive" "$guest_ip")"
  run_windows_ps 300 "
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$repoRoot = '$WINDOWS_REPO_ROOT'
\$zipPath = 'C:\Windows\Temp\openpath-wedu-ci.zip'
Remove-Item -LiteralPath \$repoRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath \$zipPath -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri '$archive_url' -OutFile \$zipPath -UseBasicParsing
New-Item -ItemType Directory -Path \$repoRoot -Force | Out-Null
Expand-Archive -LiteralPath \$zipPath -DestinationPath \$repoRoot -Force
if (-not (Test-Path -LiteralPath (Join-Path \$repoRoot 'tests\e2e\ci\run-windows-captive-portal-wedu-lab.ps1'))) {
  throw 'WEDU lab harness missing from prepared checkout.'
}
"
  stop_overlay_server
}

capture_vm_config() {
  ORIGINAL_NET0="$(ssh_proxmox qm config "$WINDOWS_VMID" | sed -n 's/^net0: //p')"
  ORIGINAL_BOOT="$(ssh_proxmox qm config "$WINDOWS_VMID" | sed -n 's/^boot: //p')"
  [ -n "$ORIGINAL_NET0" ] || fail "Unable to read VM $WINDOWS_VMID net0"
  [ -n "$ORIGINAL_BOOT" ] || ORIGINAL_BOOT='order=sata0'
}

move_windows_vm_to_lab() {
  local lab_net0
  SNAPSHOT_NAME="pre-wedu-lab-ci-$(date -u +%Y%m%dT%H%M%SZ)"
  log "snapshot=$SNAPSHOT_NAME"
  ssh_proxmox qm shutdown "$WINDOWS_VMID" --timeout 120 || ssh_proxmox qm stop "$WINDOWS_VMID"
  ssh_proxmox qm snapshot "$WINDOWS_VMID" "$SNAPSHOT_NAME" --description "Before WEDU captive portal CI lab"
  SNAPSHOT_CREATED=1
  lab_net0="$(printf '%s' "$ORIGINAL_NET0" | sed -E 's/bridge=[^,]+/bridge=vmbr10/')"
  if ! printf '%s' "$lab_net0" | grep -q 'bridge=vmbr10'; then
    lab_net0="$lab_net0,bridge=vmbr10"
  fi
  ssh_proxmox qm set "$WINDOWS_VMID" --net0 "$lab_net0"
  ssh_proxmox qm set "$WINDOWS_VMID" --boot order=sata0
  ssh_proxmox qm start "$WINDOWS_VMID"
  wait_windows_qga 90 || fail "QGA did not become ready after moving VM $WINDOWS_VMID to vmbr10"
}

configure_windows_lab_network() {
  run_windows_ps 180 "
\$ErrorActionPreference = 'Stop'
\$adapter = Get-NetAdapter | Where-Object { \$_.Status -ne 'Disabled' } | Sort-Object ifIndex | Select-Object -First 1
if (-not \$adapter) { throw 'No enabled network adapter found.' }
Set-NetIPInterface -InterfaceIndex \$adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceIndex \$adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
Get-NetIPAddress -InterfaceIndex \$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { \$_.PrefixOrigin -ne 'Dhcp' } |
  Remove-NetIPAddress -Confirm:\$false -ErrorAction SilentlyContinue
ipconfig /release \$adapter.Name | Out-Null
ipconfig /renew \$adapter.Name | Out-Null
\$ip = @(Get-NetIPAddress -InterfaceIndex \$adapter.ifIndex -AddressFamily IPv4 | Where-Object { \$_.IPAddress -like '10.77.0.*' })
\$dns = @(Get-DnsClientServerAddress -InterfaceIndex \$adapter.ifIndex -AddressFamily IPv4).ServerAddresses
if (\$ip.Count -lt 1) { throw 'Windows runner did not receive a WEDU lab IPv4 address.' }
if (-not (\$dns -contains '$EXPECTED_DNS')) { throw 'Windows runner is not using WEDU lab DNS $EXPECTED_DNS.' }
[pscustomobject]@{ adapter = \$adapter.Name; ip = @(\$ip.IPAddress); dns = @(\$dns) } | ConvertTo-Json -Compress
" | tee "$ARTIFACT_DIR/windows-lab-network.json" >/dev/null
}

run_wedu_direct_diagnostic() {
  local token
  token="$(read_gateway_token)"
  [ -n "$token" ] || fail "Unable to read WEDU lab gateway token"
  (
    cd "$REPO_ROOT"
    OPENPATH_WEDU_LAB_GATEWAY_TOKEN="$token" \
      OPENPATH_WEDU_LAB_GATEWAY_URL="$GATEWAY_URL" \
      OPENPATH_WEDU_LAB_EXPECTED_DNS="$EXPECTED_DNS" \
      OPENPATH_WEDU_LAB_EXPECTED_SUBNET="$EXPECTED_SUBNET" \
      npm run diagnostics:windows:direct -- \
        --mode captive-portal-wedu-lab \
        --runner-repo-root "$WINDOWS_REPO_ROOT" \
        --artifact-dir "$ARTIFACT_DIR" \
        --timeout-seconds "$DIRECT_TIMEOUT_SECONDS"
  )
}

restore_windows_vm() {
  if [ "$SNAPSHOT_CREATED" -eq 1 ]; then
    if ssh_proxmox qm status "$WINDOWS_VMID" | grep -q 'status: running'; then
      ssh_proxmox qm stop "$WINDOWS_VMID" || true
    fi
    ssh_proxmox qm rollback "$WINDOWS_VMID" "$SNAPSHOT_NAME"
    ssh_proxmox qm set "$WINDOWS_VMID" --net0 "$ORIGINAL_NET0"
    ssh_proxmox qm set "$WINDOWS_VMID" --boot "$ORIGINAL_BOOT"
    ssh_proxmox qm start "$WINDOWS_VMID"
    wait_windows_qga 90 || return 1
  fi

  if [ "$RUNNER_SERVICES_STOPPED" -eq 1 ] || [ "$SNAPSHOT_CREATED" -eq 1 ]; then
    start_all_action_runner_services >/dev/null
    cleanup_windows_repo_root
    wait_for_openpath_runner_online || return 1
  fi

  if [ "$SNAPSHOT_CREATED" -eq 1 ] && [ "$DELETE_SNAPSHOT_ON_SUCCESS" = "1" ]; then
    ssh_proxmox qm delsnapshot "$WINDOWS_VMID" "$SNAPSHOT_NAME" || warn "Failed to delete snapshot $SNAPSHOT_NAME"
  fi
}

cleanup() {
  RUN_STATUS=$?
  set +e
  stop_overlay_server
  if [ "$SNAPSHOT_CREATED" -eq 1 ] || [ "$RUNNER_SERVICES_STOPPED" -eq 1 ]; then
    restore_windows_vm || CLEANUP_FAILED=1
  fi
  reset_gateway_captive || CLEANUP_FAILED=1
  release_remote_lock
  if [ "$CLEANUP_FAILED" -ne 0 ]; then
    exit 1
  fi
  exit "$RUN_STATUS"
}

main() {
  if [ "$DRY_RUN" = "1" ]; then
    log "dry-run: WEDU captive portal lab CI would mutate VM $WINDOWS_VMID through $PROXMOX_HOST"
    return 0
  fi

  for cmd in ssh git python3 npm node iconv base64 gh ip curl; do
    require_cmd "$cmd"
  done
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -n "$GH_TOKEN" ] || fail "GH_TOKEN or GITHUB_TOKEN is required for runner state checks"

  trap cleanup EXIT
  acquire_remote_lock
  assert_openpath_runner_idle
  wait_windows_qga 12 || fail "QGA is not ready before WEDU lab"
  capture_vm_config
  stop_all_action_runner_services >/dev/null
  prepare_current_checkout_on_windows
  move_windows_vm_to_lab
  configure_windows_lab_network
  stop_all_action_runner_services >/dev/null
  reset_gateway_captive
  run_wedu_direct_diagnostic
}

main "$@"
