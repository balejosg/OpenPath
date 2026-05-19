#!/bin/bash

get_runtime_dependency_queue_dir() {
    printf '%s\n' "${RUNTIME_DEPENDENCY_QUEUE_DIR:-${VAR_STATE_DIR:-/var/lib/openpath}/runtime-dependency-queue}"
}

get_runtime_dependency_rejected_dir() {
    printf '%s\n' "${RUNTIME_DEPENDENCY_REJECTED_DIR:-${VAR_STATE_DIR:-/var/lib/openpath}/runtime-dependency-rejected}"
}

get_runtime_dependency_queue_process_limit() {
    case "${OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PROCESS_LIMIT:-100}" in
        ''|*[!0-9]*|0)
            printf '%s\n' 100
            ;;
        *)
            printf '%s\n' "$OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PROCESS_LIMIT"
            ;;
    esac
}

ensure_runtime_dependency_queue_dir() {
    local queue_dir
    queue_dir="$(get_runtime_dependency_queue_dir)"
    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ ! -d "$queue_dir" ]; then
        printf 'runtime dependency queue is not configured: %s\n' "$queue_dir" >&2
        return 1
    fi
    mkdir -p "$queue_dir"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        chown root:root "$queue_dir" 2>/dev/null || true
        chmod 1733 "$queue_dir"
    fi
}

quarantine_runtime_dependency_queue_artifact() {
    local artifact="$1"
    local rejected_dir
    rejected_dir="$(get_runtime_dependency_rejected_dir)"
    mkdir -p "$rejected_dir"
    chown root:root "$rejected_dir" 2>/dev/null || true
    chmod 0700 "$rejected_dir" 2>/dev/null || true
    if ! mv -f -- "$artifact" "$rejected_dir/" 2>/dev/null; then
        rm -rf -- "$artifact" 2>/dev/null || true
    fi
}

write_runtime_dependency_queue_request() {
    local anchor_host="$1"
    local dependency_host="$2"
    local request_type="$3"
    local queue_dir
    local request_id
    local request_path
    queue_dir="$(get_runtime_dependency_queue_dir)"
    ensure_runtime_dependency_queue_dir
    request_id="$(date +%s%N)-$$-$RANDOM"
    request_path="$queue_dir/$request_id.json"
    umask 077
    printf '{"version":1,"queuedAt":"%s","anchorHost":"%s","dependencyHost":"%s","requestType":"%s","source":"firefox-webrequest-local"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$anchor_host" \
        "$dependency_host" \
        "$request_type" > "$request_path"
    printf '%s\n' "$request_path"
}

process_runtime_dependency_queue() {
    local queue_dir
    local request_batch
    local process_limit
    local queue_files=()
    local rejected_files=()
    local queue_file
    local update_status
    queue_dir="$(get_runtime_dependency_queue_dir)"
    ensure_runtime_dependency_queue_dir
    process_limit="$(get_runtime_dependency_queue_process_limit)"
    request_batch="$(mktemp)"

    while IFS= read -r -d '' queue_file; do
        queue_files+=("$queue_file")
        [ "${#queue_files[@]}" -ge "$process_limit" ] && break
    done < <(find "$queue_dir" -maxdepth 1 -type f -name '*.json' -size -4096c -print0 2>/dev/null | sort -z)

    while IFS= read -r -d '' queue_file; do
        rejected_files+=("$queue_file")
    done < <(find "$queue_dir" -maxdepth 1 -name '*.json' ! \( -type f -size -4096c \) -print0 2>/dev/null)

    for queue_file in "${rejected_files[@]}"; do
        quarantine_runtime_dependency_queue_artifact "$queue_file"
    done

    for queue_file in "${queue_files[@]}"; do
        cat "$queue_file" >> "$request_batch"
        printf '\n' >> "$request_batch"
    done

    if [ ! -s "$request_batch" ]; then
        rm -f "$request_batch"
        printf 'processed=0\nrejected=%s\nchanged=false\n' "${#rejected_files[@]}"
        return 0
    fi

    set +e
    update_runtime_dependency_overlay_from_requests "$request_batch"
    update_status=$?
    set -e
    if [ "$update_status" -eq 0 ] && [ "${#queue_files[@]}" -gt 0 ]; then
        rm -f "${queue_files[@]}"
    fi
    rm -f "$request_batch"
    return "$update_status"
}
