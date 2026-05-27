#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/wedu-captive-portal-lab-controller.sh"

PROXMOX_HOST="${OPENPATH_WEDU_CI_PROXMOX_HOST:-whitelist-proxmox}"
GATEWAY_VMID="${OPENPATH_WEDU_CI_GATEWAY_VMID:-121}"
GATEWAY_URL="${OPENPATH_WEDU_LAB_GATEWAY_URL:-http://10.77.0.1}"
REMOTE_LOCK_DIR="${OPENPATH_WEDU_CI_LOCK_DIR:-/run/openpath-wedu-captive-portal-lab.lock}"
ARTIFACT_DIR="${OPENPATH_WEDU_CI_ARTIFACT_DIR:-.opencode/tmp/wedu-gateway-healthcheck/$(date -u +%Y%m%dT%H%M%SZ)}"
DRY_RUN="${OPENPATH_WEDU_CI_DRY_RUN:-0}"
LOCK_OWNER="${GITHUB_RUN_ID:-local}-gateway-healthcheck-$(date -u +%Y%m%dT%H%M%SZ)-$$"
PREVIOUS_GATEWAY_MODE=""
RUN_STATUS=0
CLEANUP_FAILED=0

ARTIFACT_DIR="$(cd "$REPO_ROOT" && mkdir -p "$ARTIFACT_DIR" && cd "$ARTIFACT_DIR" && pwd)"

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
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

gateway_exec() {
  local script="$1"
  local output
  output="$(ssh_proxmox qm guest exec "$GATEWAY_VMID" -- bash -lc "$script")"
  printf '%s' "$output" | require_guest_exec_success
}

wait_gateway_qga() {
  for _ in $(seq 1 24); do
    if ssh_proxmox qm agent "$GATEWAY_VMID" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

read_gateway_mode() {
  gateway_exec 'cat /run/wedu-lab-firewall-mode 2>/dev/null || printf unknown' | tr -d '\r\n'
}

set_gateway_mode() {
  local path="$1"
  gateway_exec "TOKEN=\$(cat /opt/wedu-captive-portal/control-token); curl -fsS -H \"X-Lab-Token: \$TOKEN\" '$GATEWAY_URL$path' >/dev/null; cat /run/wedu-lab-firewall-mode"
}

write_healthcheck_artifact() {
  local status="$1"
  local mode_after_reset="$2"
  local portal_probe="$3"
  python3 - "$ARTIFACT_DIR/gateway-healthcheck.json" "$status" "$PREVIOUS_GATEWAY_MODE" "$mode_after_reset" "$portal_probe" "$GATEWAY_VMID" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, status, previous_mode, mode_after_reset, portal_probe, gateway_vmid = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "status": status,
            "previousGatewayMode": previous_mode,
            "modeAfterReset": mode_after_reset,
            "portalProbeContainsMarker": portal_probe == "true",
            "gatewayVmId": int(gateway_vmid),
            "checkedAt": datetime.now(timezone.utc).isoformat(),
        },
        handle,
        sort_keys=True,
    )
    handle.write("\n")
PY
}

cleanup() {
  RUN_STATUS=$?
  set +e
  if [ "$PREVIOUS_GATEWAY_MODE" = "authenticated" ]; then
    set_gateway_mode /lab/authenticated >/dev/null || CLEANUP_FAILED=1
  fi
  openpath_wedu_release_remote_lock "$PROXMOX_HOST" "$REMOTE_LOCK_DIR" "$LOCK_OWNER" ||
    printf '::warning::Failed to release WEDU gateway healthcheck lock\n' >&2
  if [ "$CLEANUP_FAILED" -ne 0 ]; then
    exit 1
  fi
  exit "$RUN_STATUS"
}

main() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'dry-run: WEDU gateway healthcheck would mutate gateway VM %s through %s\n' "$GATEWAY_VMID" "$PROXMOX_HOST"
    return 0
  fi

  for cmd in ssh python3 curl; do
    require_cmd "$cmd"
  done

  trap cleanup EXIT
  openpath_wedu_acquire_remote_lock "$PROXMOX_HOST" "$REMOTE_LOCK_DIR" "$LOCK_OWNER" "healthcheck"
  wait_gateway_qga || fail "Gateway VM $GATEWAY_VMID QGA is not ready"
  gateway_exec 'systemctl is-active --quiet wedu-captive-portal && systemctl is-active --quiet dnsmasq && systemctl is-active --quiet wedu-lab-firewall && systemctl is-active --quiet wedu-lab-network'
  gateway_exec "ip -4 addr show | grep -q '10\\.77\\.0\\.1/24'"
  PREVIOUS_GATEWAY_MODE="$(read_gateway_mode)"
  mode_after_reset="$(set_gateway_mode /lab/reset | tr -d '\r\n')"
  [ "$mode_after_reset" = "captive" ] || fail "Gateway reset did not enter captive mode: $mode_after_reset"
  portal_body="$(gateway_exec 'curl -fsS http://10.77.0.1/' || true)"
  if printf '%s' "$portal_body" | grep -q 'WEDU lab captive portal'; then
    write_healthcheck_artifact ok "$mode_after_reset" true
  else
    write_healthcheck_artifact failed "$mode_after_reset" false
    fail "Gateway captive portal body probe did not contain the expected marker"
  fi
}

main "$@"
