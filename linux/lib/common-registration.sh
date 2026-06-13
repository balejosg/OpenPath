#!/bin/bash
################################################################################
# common-registration.sh - Machine registration and health reporting helpers
################################################################################

build_machine_registration_payload() {
    local reported_hostname="$1"
    local classroom_name="$2"
    local classroom_id="$3"
    local version="$4"

    HN="$reported_hostname" CNAME="$classroom_name" CID="$classroom_id" VER="$version" python3 -c '
import json, os

payload = {
    "hostname": os.environ.get("HN", ""),
    "version": os.environ.get("VER", "unknown"),
}

classroom_id = os.environ.get("CID", "")
classroom_name = os.environ.get("CNAME", "")
if classroom_id:
    payload["classroomId"] = classroom_id
elif classroom_name:
    payload["classroomName"] = classroom_name

print(json.dumps(payload))
'
}

parse_machine_registration_response() {
    local response="$1"
    local parsed_response
    local parsed_lines=()

    parsed_response=$(printf '%s' "$response" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if data.get("success") is not True:
    sys.exit(1)

whitelist_url = data.get("whitelistUrl")
if not isinstance(whitelist_url, str) or not whitelist_url:
    sys.exit(1)

def as_text(value):
    return value if isinstance(value, str) else ""

print(whitelist_url)
print(as_text(data.get("classroomName")))
print(as_text(data.get("classroomId")))
print(as_text(data.get("machineHostname")))
') || {
        # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
        TOKENIZED_URL=""
        # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
        REGISTERED_CLASSROOM_NAME=""
        # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
        REGISTERED_CLASSROOM_ID=""
        # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
        REGISTERED_MACHINE_NAME=""
        return 1
    }

    mapfile -t parsed_lines <<< "$parsed_response"
    # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
    TOKENIZED_URL="${parsed_lines[0]:-}"
    # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
    REGISTERED_CLASSROOM_NAME="${parsed_lines[1]:-}"
    # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
    REGISTERED_CLASSROOM_ID="${parsed_lines[2]:-}"
    # shellcheck disable=SC2034  # Global outputs consumed by callers after register_machine
    REGISTERED_MACHINE_NAME="${parsed_lines[3]:-}"

    [ -n "$TOKENIZED_URL" ]
}

# Args: $1=reported_hostname $2=classroom_name $3=classroom_id $4=version $5=api_url $6=auth_token
# Sets globals consumed by callers after register_machine.
register_machine() {
    local reported_hostname="$1"
    local classroom_name="$2"
    local classroom_id="$3"
    local version="$4"
    local api_url="$5"
    local auth_token="$6"

    local payload
    payload=$(build_machine_registration_payload "$reported_hostname" "$classroom_name" "$classroom_id" "$version")

    local curl_stderr
    curl_stderr=$(mktemp "${TMPDIR:-/tmp}/openpath-register.XXXXXX")

    if REGISTER_RESPONSE=$(curl -sS -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $auth_token" \
            -d "$payload" \
            "$api_url/api/machines/register" 2>"$curl_stderr"); then
        rm -f "$curl_stderr"
    else
        local curl_status=$?
        local curl_error
        curl_error=$(tr '\n\r' ' ' < "$curl_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
        rm -f "$curl_stderr"

        REGISTER_RESPONSE="curl failed (exit $curl_status)"
        if [ -n "$curl_error" ]; then
            REGISTER_RESPONSE="$REGISTER_RESPONSE: $curl_error"
        fi
        return 1
    fi

    parse_machine_registration_response "$REGISTER_RESPONSE"
}

send_health_report_to_api() {
    local status="$1"
    local actions="$2"
    local dnsmasq_running="${3:-false}"
    local dns_resolving="${4:-false}"
    local fail_count="${5:-0}"
    local version="${6:-${VERSION:-unknown}}"
    # Optional enforcement telemetry (positional so deployed 6-arg callers still
    # work). firewall_state: active|inactive|"" (unknown). whitelist_age_hours:
    # number or "" (unknown). Empty values are omitted from the payload so the
    # server records null ("not reported"), never a false enforcement-down.
    local firewall_state="${7:-}"
    local whitelist_age_hours="${8:-}"

    if [ ! -f "$HEALTH_API_URL_CONF" ]; then
        log_debug "[HEALTH] No health API configured (create $HEALTH_API_URL_CONF)"
        return 0
    fi

    local api_url
    api_url=$(cat "$HEALTH_API_URL_CONF" 2>/dev/null)
    if [ -z "$api_url" ]; then
        log_warn "[HEALTH] Health API URL file is empty: $HEALTH_API_URL_CONF"
        return 0
    fi

    local auth_token=""
    auth_token=$(get_machine_token_from_whitelist_url_file 2>/dev/null || true)
    if [ -z "$auth_token" ] && [ -f "$HEALTH_API_SECRET_CONF" ]; then
        auth_token=$(cat "$HEALTH_API_SECRET_CONF" 2>/dev/null)
    fi

    local hostname
    hostname=$(get_registered_machine_name)

    local payload
    # Canonical field names (v1.3+): agentVersion and platform are added alongside
    # the legacy version field so old API versions also accept the payload.
    payload=$(HN="$hostname" ST="$status" DR="$dnsmasq_running" DRE="$dns_resolving" \
        FC="$fail_count" AC="$actions" VER="$version" FW="$firewall_state" WA="$whitelist_age_hours" python3 -c '
import json, os
dr = os.environ["DR"] == "true"
dre = os.environ["DRE"] == "true"
report = {
    "hostname": os.environ["HN"],
    "status": os.environ["ST"],
    "dnsmasqRunning": dr,
    "dnsResolving": dre,
    "dnsState": dre,
    "failCount": int(os.environ["FC"]),
    "actions": os.environ["AC"],
    "version": os.environ["VER"],
    "agentVersion": os.environ["VER"],
    "platform": "linux",
}
fw = os.environ.get("FW", "")
if fw in ("active", "inactive"):
    report["firewallState"] = fw == "active"
wa = os.environ.get("WA", "")
if wa != "":
    try:
        report["whitelistAgeHours"] = float(wa)
    except ValueError:
        pass
print(json.dumps({"json": report}))')

    if [ -n "$auth_token" ]; then
        timeout 5 curl -s -X POST "$api_url/trpc/healthReports.submit" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $auth_token" \
            -d "$payload" >/dev/null 2>&1 &
    else
        timeout 5 curl -s -X POST "$api_url/trpc/healthReports.submit" \
            -H "Content-Type: application/json" \
            -d "$payload" >/dev/null 2>&1 &
    fi

    return 0
}
