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

# Normalize an effective flag value (defaults.conf style 1/0 plus operator
# overrides true/false/yes/no/on/off) to the canonical posture strings
# "true"/"false". Anything else (including empty/unset) yields "" so the
# caller omits the key entirely — the server must record "not reported",
# never a guessed value.
normalize_posture_bool() {
    local raw="${1:-}"
    case "${raw,,}" in
        1|true|yes|on) echo "true" ;;
        0|false|no|off) echo "false" ;;
        *) echo "" ;;
    esac
}

health_report_fail_streak_file() {
    echo "${VAR_STATE_DIR:-/var/lib/openpath}/health-report-fail-streak"
}

# Prints the persisted consecutive-delivery-failure count (0 when the file is
# missing or holds anything but a plain non-negative integer).
read_health_report_fail_streak() {
    local streak_file value
    streak_file=$(health_report_fail_streak_file)
    value=$(cat "$streak_file" 2>/dev/null || true)
    case "$value" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$value" ;;
    esac
}

# Synchronous delivery worker: POSTs the payload, then records the outcome.
# Run it in the background from send_health_report_to_api — non-blocking for
# the caller, but no longer silent: failures are logged and counted.
# Args: $1=api_url $2=auth_token (may be empty) $3=payload
deliver_health_report_payload() {
    local api_url="$1"
    local auth_token="$2"
    local payload="$3"

    local http_code="000"
    local curl_exit=0
    if [ -n "$auth_token" ]; then
        http_code=$(timeout 5 curl -s -o /dev/null -w '%{http_code}' -X POST \
            "$api_url/trpc/healthReports.submit" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $auth_token" \
            -d "$payload" 2>/dev/null) && curl_exit=0 || curl_exit=$?
    else
        http_code=$(timeout 5 curl -s -o /dev/null -w '%{http_code}' -X POST \
            "$api_url/trpc/healthReports.submit" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null) && curl_exit=0 || curl_exit=$?
    fi

    local streak_file
    streak_file=$(health_report_fail_streak_file)
    mkdir -p "$(dirname "$streak_file")" 2>/dev/null || true

    if [ "$curl_exit" -eq 0 ] && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "0" > "$streak_file" 2>/dev/null || true
        return 0
    fi

    local streak
    streak=$(read_health_report_fail_streak)
    streak=$((streak + 1))
    echo "$streak" > "$streak_file" 2>/dev/null || true
    log_warn "[HEALTH] Report delivery failed (curl_exit=$curl_exit http=$http_code streak=$streak)"
    return 1
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

    # Optional Firefox managed-extension registration state (positional so
    # deployed 8-arg callers still work). Empty registered/target values omit
    # the firefoxRegistration object entirely.
    local firefox_registered_count="${9:-}"
    local firefox_target_count="${10:-}"
    local firefox_last_checked_at="${11:-}"

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

    # Effective flag posture. The variables are set by defaults.conf, which
    # common.sh sources before this library; empty/unrecognized values are
    # omitted from the payload (absent = "not reported").
    local posture_ipv6 posture_sff posture_scoped posture_ase
    posture_ipv6=$(normalize_posture_bool "${IPV6_FIREWALL_ENABLED:-}")
    posture_sff=$(normalize_posture_bool "${SINKHOLE_FAST_FAIL:-}")
    posture_scoped=$(normalize_posture_bool "${CAPTIVE_PORTAL_SCOPED_PASSTHROUGH_ENABLED:-}")
    posture_ase=$(normalize_posture_bool "${ALLOW_SET_EGRESS_ENABLED:-}")

    local fail_streak
    fail_streak=$(read_health_report_fail_streak)

    local payload
    # Canonical field names (v1.3+): agentVersion and platform are added alongside
    # the legacy version field so old API versions also accept the payload.
    payload=$(HN="$hostname" ST="$status" DR="$dnsmasq_running" DRE="$dns_resolving" \
        FC="$fail_count" AC="$actions" VER="$version" FW="$firewall_state" WA="$whitelist_age_hours" \
        CFG_IPV6="$posture_ipv6" CFG_SFF="$posture_sff" CFG_SCOPED="$posture_scoped" \
        CFG_ASE="$posture_ase" CFG_R1918="${RFC1918_EGRESS_MODE:-}" CFG_FMODE="${FAILURE_MODE:-}" \
        FS="$fail_streak" \
        FRR="$firefox_registered_count" FRT="$firefox_target_count" FRA="$firefox_last_checked_at" python3 -c '
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
frr = os.environ.get("FRR", "")
frt = os.environ.get("FRT", "")
fra = os.environ.get("FRA", "")
if frr != "" and frt != "":
    try:
        registration = {"registered": int(frr), "targetCount": int(frt)}
        if fra != "":
            registration["lastCheckedAt"] = fra
        report["firefoxRegistration"] = registration
    except ValueError:
        pass
# Allowlisted effective flag posture (canonical key order; absent keys omitted).
posture = {}
for key, env in (
    ("ipv6FirewallEnabled", "CFG_IPV6"),
    ("sinkholeFastFail", "CFG_SFF"),
    ("captivePortalScopedPassthrough", "CFG_SCOPED"),
):
    value = os.environ.get(env, "")
    if value in ("true", "false"):
        posture[key] = value
mode = os.environ.get("CFG_R1918", "").strip().lower()
if mode:
    posture["rfc1918EgressMode"] = mode
ase = os.environ.get("CFG_ASE", "")
if ase in ("true", "false"):
    posture["allowSetEgressEnabled"] = ase
fmode = os.environ.get("CFG_FMODE", "").strip().lower()
if fmode:
    posture["failureMode"] = fmode
if posture:
    report["configPosture"] = posture
fs = os.environ.get("FS", "")
if fs.isdigit() and int(fs) > 0:
    report["healthReportFailStreak"] = int(fs)
print(json.dumps({"json": report}))')

    # Non-blocking but non-silent: the backgrounded worker captures the HTTP
    # outcome, logs failures, and maintains the fail-streak counter.
    deliver_health_report_payload "$api_url" "$auth_token" "$payload" &

    return 0
}

# Prints "registered_count<TAB>target_count<TAB>verified_at" parsed from the
# Firefox extension ready marker written by verify_firefox_extension_registered
# (linux/lib/firefox-activation-plan.sh). Prints nothing when the marker is
# absent or incomplete so callers omit firefoxRegistration from the health
# payload entirely ("not reported", never a false registration-down).
read_firefox_registration_state() {
    local marker_path="${FIREFOX_EXTENSION_READY_FILE:-${VAR_STATE_DIR:-/var/lib/openpath}/firefox-extension-ready}"

    [ -f "$marker_path" ] || return 0

    awk -F= '
        $1 == "registered_count" { registered = $2 }
        $1 == "target_count" { target = $2 }
        $1 == "verified_at" { verified = $2 }
        END {
            if (registered ~ /^[0-9]+$/ && target ~ /^[0-9]+$/) {
                printf "%s\t%s\t%s\n", registered, target, verified
            }
        }
    ' "$marker_path" 2>/dev/null || true
}
