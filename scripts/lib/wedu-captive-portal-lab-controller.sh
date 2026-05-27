#!/usr/bin/env bash

function openpath_wedu_ssh_proxmox {
  local host="$1"
  shift

  local arg
  local quoted_arg
  local quoted_args=()
  local ssh_options=(
    -o StrictHostKeyChecking=accept-new
  )
  if [ -n "${OPENPATH_WEDU_CI_SSH_KEY_PATH:-}" ]; then
    ssh_options+=(
      -i "$OPENPATH_WEDU_CI_SSH_KEY_PATH"
      -o IdentitiesOnly=yes
    )
  fi
  for arg in "$@"; do
    printf -v quoted_arg %q "$arg"
    quoted_args+=("$quoted_arg")
  done
  ssh "${ssh_options[@]}" "$host" "${quoted_args[*]}"
}

function openpath_wedu_create_tracked_checkout_archive {
  local root="$1"
  local archive="$2"

  python3 - "$root" "$archive" <<'PY'
import os
import subprocess
import sys
import zipfile

root, archive = sys.argv[1], sys.argv[2]
tracked = subprocess.check_output(['git', '-C', root, 'ls-files', '-z'])
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
    for raw_name in tracked.split(b'\0'):
        if not raw_name:
            continue
        name = raw_name.decode()
        bundle.write(os.path.join(root, name), name)
PY
}

function openpath_wedu_acquire_remote_lock {
  local proxmox_host="$1"
  local lock_dir="$2"
  local owner="$3"
  local mode="$4"
  local ttl_seconds="${OPENPATH_WEDU_CI_LOCK_TTL_SECONDS:-7200}"
  local force_stale_lock="${OPENPATH_WEDU_CI_FORCE_STALE_LOCK:-0}"
  local github_run_id="${GITHUB_RUN_ID:-local}"
  local repo_sha="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || printf 'unknown')}"

  openpath_wedu_ssh_proxmox "$proxmox_host" bash -s -- \
    "$lock_dir" "$owner" "$mode" "$ttl_seconds" "$force_stale_lock" "$github_run_id" "$repo_sha" <<'REMOTE'
set -euo pipefail

lock_dir="$1"
owner="$2"
mode="$3"
ttl_seconds="$4"
force_stale_lock="$5"
github_run_id="$6"
repo_sha="$7"
metadata_path="$lock_dir/wedu-lock-metadata.json"

write_lock_metadata() {
  mkdir -p "$lock_dir"
  python3 - "$metadata_path" "$owner" "$mode" "$github_run_id" "$repo_sha" <<'PY'
import json
import os
import socket
import sys
import time

path, owner, mode, github_run_id, repo_sha = sys.argv[1:]
payload = {
    "owner": owner,
    "mode": mode,
    "startedEpoch": int(time.time()),
    "githubRunId": github_run_id,
    "repoSha": repo_sha,
    "host": socket.gethostname(),
    "pid": os.getpid(),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
PY
  printf '%s\n' "$owner" > "$lock_dir/owner"
}

lock_age_seconds() {
  python3 - "$metadata_path" <<'PY'
import json
import sys
import time

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
    print(max(0, int(time.time()) - int(payload.get("startedEpoch", 0))))
except Exception:
    print(999999999)
PY
}

if mkdir "$lock_dir" 2>/dev/null; then
  write_lock_metadata
  exit 0
fi

age="$(lock_age_seconds)"
if [ "$age" -gt "$ttl_seconds" ]; then
  if [ "$force_stale_lock" = "1" ]; then
    rm -rf "$lock_dir"
    mkdir "$lock_dir"
    write_lock_metadata
    exit 0
  fi
  printf 'stale WEDU lab lock at %s age=%ss ttl=%ss; set OPENPATH_WEDU_CI_FORCE_STALE_LOCK=1 to replace it\n' "$lock_dir" "$age" "$ttl_seconds" >&2
  cat "$metadata_path" >&2 2>/dev/null || true
  exit 1
fi

printf 'WEDU lab lock is already held at %s\n' "$lock_dir" >&2
cat "$metadata_path" >&2 2>/dev/null || cat "$lock_dir/owner" >&2 2>/dev/null || true
exit 1
REMOTE
}

function openpath_wedu_release_remote_lock {
  local proxmox_host="$1"
  local lock_dir="$2"
  local owner="$3"

  openpath_wedu_ssh_proxmox "$proxmox_host" bash -s -- "$lock_dir" "$owner" <<'REMOTE'
set -euo pipefail

lock_dir="$1"
owner="$2"
metadata_path="$lock_dir/wedu-lock-metadata.json"

actual_owner=""
if [ -f "$metadata_path" ]; then
  actual_owner="$(python3 - "$metadata_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(json.load(handle).get("owner", ""))
except Exception:
    print("")
PY
)"
elif [ -f "$lock_dir/owner" ]; then
  actual_owner="$(cat "$lock_dir/owner")"
fi

if [ "$actual_owner" = "$owner" ]; then
  rm -rf "$lock_dir"
fi
REMOTE
}

function openpath_wedu_start_overlay_server {
  local artifact_dir="$1"
  local http_server_log="$2"
  local archive="$3"
  local guest_ip="$4"
  local host_ip
  local attempts="${OPENPATH_WEDU_OVERLAY_START_ATTEMPTS:-3}"
  local attempt
  local port

  OPENPATH_WEDU_OVERLAY_PID=""
  OPENPATH_WEDU_OVERLAY_URL=""

  host_ip="$(ip route get "$guest_ip" | sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p' | head -n 1)"
  if [ -z "$host_ip" ]; then
    printf 'Unable to detect controller source IP for guest %s\n' "$guest_ip" >&2
    return 1
  fi

  for attempt in $(seq 1 "$attempts"); do
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')"
    (cd "$artifact_dir" && python3 -m http.server "$port" --bind "$host_ip" >"$http_server_log" 2>&1) &
    OPENPATH_WEDU_OVERLAY_PID="$!"

    for _ in $(seq 1 20); do
      if curl -fsS "http://$host_ip:$port/$(basename "$archive")" >/dev/null; then
        # shellcheck disable=SC2034 # read by the sourced caller.
        OPENPATH_WEDU_OVERLAY_URL="http://$host_ip:$port/$(basename "$archive")"
        return 0
      fi
      sleep 0.5
    done

    openpath_wedu_stop_overlay_server "$OPENPATH_WEDU_OVERLAY_PID"
    OPENPATH_WEDU_OVERLAY_PID=""
    printf 'Local checkout archive HTTP server attempt %s/%s did not become ready\n' "$attempt" "$attempts" >&2
  done

  printf 'Local checkout archive HTTP server did not become ready\n' >&2
  return 1
}

function openpath_wedu_stop_overlay_server {
  local http_server_pid="${1:-}"

  if [ -n "$http_server_pid" ] && kill -0 "$http_server_pid" >/dev/null 2>&1; then
    kill "$http_server_pid" >/dev/null 2>&1 || true
    wait "$http_server_pid" >/dev/null 2>&1 || true
  fi
}
