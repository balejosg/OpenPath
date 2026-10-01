#!/usr/bin/env bash
# Phase 3A G3 lab lock (runs on the Proxmox host through the CI transport).
#
# Protocol:
#   * owner + created + heartbeat files;
#   * a lock is stale only when its HEARTBEAT is older than the TTL (never by
#     the age of `created`);
#   * a live lock is waited for (bounded wait) instead of being stolen;
#   * every replacement is recorded with the previous owner in
#     <lock_dir>.replacements.log.
#
# Usage:
#   proxmox-lab-lock.sh acquire <lock_dir> <owner> <ttl_seconds> <wait_seconds>
#   proxmox-lab-lock.sh renew   <lock_dir> <owner>
#   proxmox-lab-lock.sh release <lock_dir> <owner>
#   proxmox-lab-lock.sh status  <lock_dir>
set -u

command="$1"
lock_dir="$2"

case "$command" in
  acquire)
    owner="$3"
    ttl="${4:-1800}"
    wait_seconds="${5:-900}"
    now=$(date +%s)
    deadline=$((now + wait_seconds))
    while :; do
      if [ -d "$lock_dir" ]; then
        current_owner=$(cat "$lock_dir/owner" 2>/dev/null || echo '')
        heartbeat=$(cat "$lock_dir/heartbeat" 2>/dev/null || cat "$lock_dir/created" 2>/dev/null || echo 0)
        if [ "$current_owner" = "$owner" ]; then
          date +%s > "$lock_dir/heartbeat"
          echo acquired
          exit 0
        fi
        age=$((now - heartbeat))
        if [ "$age" -gt "$ttl" ]; then
          printf '%s previous-owner=%s new-owner=%s age=%ss\n' "$(date -u +%FT%TZ)" "$current_owner" "$owner" "$age" >> "$lock_dir.replacements.log" 2>/dev/null || true
          rm -rf "$lock_dir"
        fi
      fi
      if mkdir "$lock_dir" 2>/dev/null; then
        date +%s > "$lock_dir/created"
        date +%s > "$lock_dir/heartbeat"
        printf '%s' "$owner" > "$lock_dir/owner"
        echo acquired
        exit 0
      fi
      now=$(date +%s)
      if [ "$now" -ge "$deadline" ]; then
        echo busy
        exit 0
      fi
      sleep 10
    done
    ;;
  renew)
    owner="$3"
    if [ -f "$lock_dir/owner" ] && [ "$(cat "$lock_dir/owner")" = "$owner" ]; then
      date +%s > "$lock_dir/heartbeat"
      echo renewed
    else
      echo not-owner
    fi
    ;;
  release)
    owner="$3"
    if [ -f "$lock_dir/owner" ] && [ "$(cat "$lock_dir/owner")" = "$owner" ]; then
      rm -rf "$lock_dir"
      echo released
    else
      echo not-owner
    fi
    ;;
  status)
    if [ -d "$lock_dir" ]; then
      printf 'owner=%s created=%s heartbeat=%s\n' \
        "$(cat "$lock_dir/owner" 2>/dev/null || echo '')" \
        "$(cat "$lock_dir/created" 2>/dev/null || echo '')" \
        "$(cat "$lock_dir/heartbeat" 2>/dev/null || echo '')"
    else
      echo free
    fi
    ;;
  *)
    echo "unknown command: $command" >&2
    exit 2
    ;;
esac
