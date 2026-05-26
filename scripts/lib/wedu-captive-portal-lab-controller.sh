#!/usr/bin/env bash

function openpath_wedu_ssh_proxmox {
  local host="$1"
  shift

  local arg
  local quoted_arg
  local quoted_args=()
  for arg in "$@"; do
    printf -v quoted_arg %q "$arg"
    quoted_args+=("$quoted_arg")
  done
  ssh "$host" "${quoted_args[*]}"
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

function openpath_wedu_start_overlay_server {
  local artifact_dir="$1"
  local http_server_log="$2"
  local archive="$3"
  local guest_ip="$4"
  local host_ip
  local port

  OPENPATH_WEDU_OVERLAY_PID=""
  OPENPATH_WEDU_OVERLAY_URL=""

  host_ip="$(ip route get "$guest_ip" | sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p' | head -n 1)"
  if [ -z "$host_ip" ]; then
    printf 'Unable to detect controller source IP for guest %s\n' "$guest_ip" >&2
    return 1
  fi

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
