#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/wedu-captive-portal-lab-controller.sh"

PROXMOX_HOST="${OPENPATH_WEDU_CI_PROXMOX_HOST:-whitelist-proxmox}"
WINDOWS_VMID="${OPENPATH_WEDU_CI_WINDOWS_VMID:-103}"
CLIENT_VMID="${OPENPATH_WEDU_CI_LINUX_CLIENT_VMID:-104}"
GATEWAY_VMID="${OPENPATH_WEDU_CI_GATEWAY_VMID:-121}"
GATEWAY_URL="${OPENPATH_WEDU_LAB_GATEWAY_URL:-http://10.77.0.1}"
EXPECTED_DNS="${OPENPATH_WEDU_LAB_EXPECTED_DNS:-10.77.0.1}"
REMOTE_LOCK_DIR="${OPENPATH_WEDU_CI_LOCK_DIR:-/run/openpath-wedu-captive-portal-lab.lock}"
ARTIFACT_DIR="${OPENPATH_WEDU_CI_ARTIFACT_DIR:-.opencode/tmp/wedu-linux-client-smoke/$(date -u +%Y%m%dT%H%M%SZ)}"
DELETE_SNAPSHOT_ON_SUCCESS="${OPENPATH_WEDU_CI_DELETE_SNAPSHOT_ON_SUCCESS:-1}"
DRY_RUN="${OPENPATH_WEDU_CI_DRY_RUN:-0}"
LOCK_OWNER="${GITHUB_RUN_ID:-local}-linux-client-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SNAPSHOT_NAME=""
SNAPSHOT_CREATED=0
ORIGINAL_NET0=""
ORIGINAL_BOOT=""
PREVIOUS_GATEWAY_MODE=""
RUN_STATUS=0
CLEANUP_FAILED=0

ARTIFACT_DIR="$(cd "$REPO_ROOT" && mkdir -p "$ARTIFACT_DIR" && cd "$ARTIFACT_DIR" && pwd)"

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

warn() {
  printf '::warning::%s\n' "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ssh_proxmox() {
  openpath_wedu_ssh_proxmox "$PROXMOX_HOST" "$@"
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

guest_exec() {
  local vmid="$1"
  local script="$2"
  local output
  output="$(ssh_proxmox qm guest exec "$vmid" -- bash -lc "$script")"
  printf '%s' "$output" | require_guest_exec_success
}

wait_qga() {
  local vmid="$1"
  for _ in $(seq 1 24); do
    if ssh_proxmox qm agent "$vmid" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

read_gateway_mode() {
  guest_exec "$GATEWAY_VMID" 'cat /run/wedu-lab-firewall-mode 2>/dev/null || printf unknown' | tr -d '\r\n'
}

set_gateway_mode() {
  local path="$1"
  guest_exec "$GATEWAY_VMID" "TOKEN=\$(cat /opt/wedu-captive-portal/control-token); curl -fsS -H \"X-Lab-Token: \$TOKEN\" '$GATEWAY_URL$path' >/dev/null; cat /run/wedu-lab-firewall-mode"
}

assert_vm_103_not_attached_to_vmbr10() {
  local net0
  net0="$(ssh_proxmox qm config "$WINDOWS_VMID" | sed -n 's/^net0: //p')"
  if printf '%s' "$net0" | grep -q 'bridge=vmbr10'; then
    fail "VM 103 is already attached to vmbr10; refusing optional VM 104 smoke"
  fi
}

capture_client_config() {
  ORIGINAL_NET0="$(ssh_proxmox qm config "$CLIENT_VMID" | sed -n 's/^net0: //p')"
  ORIGINAL_BOOT="$(ssh_proxmox qm config "$CLIENT_VMID" | sed -n 's/^boot: //p')"
  [ -n "$ORIGINAL_NET0" ] || fail "Unable to read VM $CLIENT_VMID net0"
  [ -n "$ORIGINAL_BOOT" ] || ORIGINAL_BOOT='order=sata0'
}

move_client_to_lab() {
  local lab_net0
  SNAPSHOT_NAME="pre-wedu-linux-client-smoke-$(date -u +%Y%m%dT%H%M%SZ)"
  ssh_proxmox qm shutdown "$CLIENT_VMID" --timeout 120 || ssh_proxmox qm stop "$CLIENT_VMID"
  ssh_proxmox qm snapshot "$CLIENT_VMID" "$SNAPSHOT_NAME" --description "Before WEDU Linux client smoke"
  SNAPSHOT_CREATED=1
  lab_net0="$(printf '%s' "$ORIGINAL_NET0" | sed -E 's/bridge=[^,]+/bridge=vmbr10/')"
  if ! printf '%s' "$lab_net0" | grep -q 'bridge=vmbr10'; then
    lab_net0="$lab_net0,bridge=vmbr10"
  fi
  ssh_proxmox qm set "$CLIENT_VMID" --net0 "$lab_net0"
  ssh_proxmox qm set "$CLIENT_VMID" --boot "$ORIGINAL_BOOT"
  ssh_proxmox qm start "$CLIENT_VMID"
  wait_qga "$CLIENT_VMID" || fail "QGA did not become ready after moving VM $CLIENT_VMID to vmbr10"
}

assert_client_network() {
  guest_exec "$CLIENT_VMID" "
set -euo pipefail
dhclient -r || true
dhclient || true
ip -4 addr
ip -4 addr | grep -q '10\.77\.0\.'
grep -R \"nameserver $EXPECTED_DNS\" /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null
" >"$ARTIFACT_DIR/linux-client-network.txt"
}

assert_pre_auth_interception() {
  guest_exec "$CLIENT_VMID" "curl -fsS --max-time 10 http://example.com/ | grep -q 'WEDU lab captive portal'"
}

assert_post_auth_navigation() {
  set_gateway_mode /lab/authenticated >/dev/null
  guest_exec "$CLIENT_VMID" "curl -fsS --max-time 20 http://example.com/ >/dev/null"
}

write_smoke_artifact() {
  local status="$1"
  python3 - "$ARTIFACT_DIR/linux-client-smoke.json" "$status" "$PREVIOUS_GATEWAY_MODE" "$CLIENT_VMID" "$WINDOWS_VMID" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, status, previous_mode, client_vmid, windows_vmid = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "status": status,
            "mode": "linux-client-smoke",
            "clientVmId": int(client_vmid),
            "guardedWindowsVmId": int(windows_vmid),
            "previousGatewayMode": previous_mode,
            "checkedAt": datetime.now(timezone.utc).isoformat(),
        },
        handle,
        sort_keys=True,
    )
    handle.write("\n")
PY
}

restore_client() {
  if [ "$SNAPSHOT_CREATED" -eq 1 ]; then
    if ssh_proxmox qm status "$CLIENT_VMID" | grep -q 'status: running'; then
      ssh_proxmox qm stop "$CLIENT_VMID" || true
    fi
    ssh_proxmox qm rollback "$CLIENT_VMID" "$SNAPSHOT_NAME"
    ssh_proxmox qm set "$CLIENT_VMID" --net0 "$ORIGINAL_NET0"
    ssh_proxmox qm set "$CLIENT_VMID" --boot "$ORIGINAL_BOOT"
    ssh_proxmox qm start "$CLIENT_VMID"
    wait_qga "$CLIENT_VMID" || return 1
    if [ "$DELETE_SNAPSHOT_ON_SUCCESS" = "1" ]; then
      ssh_proxmox qm delsnapshot "$CLIENT_VMID" "$SNAPSHOT_NAME" || warn "Failed to delete snapshot $SNAPSHOT_NAME"
    fi
  fi
}

cleanup() {
  RUN_STATUS=$?
  set +e
  restore_client || CLEANUP_FAILED=1
  if [ "$PREVIOUS_GATEWAY_MODE" = "authenticated" ]; then
    set_gateway_mode /lab/authenticated >/dev/null || CLEANUP_FAILED=1
  else
    set_gateway_mode /lab/reset >/dev/null || CLEANUP_FAILED=1
  fi
  openpath_wedu_release_remote_lock "$PROXMOX_HOST" "$REMOTE_LOCK_DIR" "$LOCK_OWNER" ||
    warn "Failed to release WEDU Linux client smoke lock"
  if [ "$CLEANUP_FAILED" -ne 0 ]; then
    exit 1
  fi
  exit "$RUN_STATUS"
}

main() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'dry-run: WEDU Linux client smoke would mutate VM 104 through %s\n' "$PROXMOX_HOST"
    return 0
  fi

  for cmd in ssh python3; do
    require_cmd "$cmd"
  done

  trap cleanup EXIT
  openpath_wedu_acquire_remote_lock "$PROXMOX_HOST" "$REMOTE_LOCK_DIR" "$LOCK_OWNER" "linux-client-smoke"
  assert_vm_103_not_attached_to_vmbr10
  wait_qga "$GATEWAY_VMID" || fail "Gateway VM $GATEWAY_VMID QGA is not ready"
  PREVIOUS_GATEWAY_MODE="$(read_gateway_mode)"
  set_gateway_mode /lab/reset >/dev/null
  capture_client_config
  move_client_to_lab
  assert_client_network
  assert_pre_auth_interception
  assert_post_auth_navigation
  write_smoke_artifact ok
}

main "$@"
