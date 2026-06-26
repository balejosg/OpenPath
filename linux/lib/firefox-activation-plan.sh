#!/bin/bash

# firefox-activation-plan.sh - Firefox profile activation and registration helpers

resolve_firefox_activation_user() {
    if [ -n "${OPENPATH_FIREFOX_PROFILE_USER:-}" ]; then
        printf '%s\n' "$OPENPATH_FIREFOX_PROFILE_USER"
        return 0
    fi

    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi

    id -un 2>/dev/null || printf '%s\n' "root"
}

resolve_firefox_activation_home() {
    local activation_user="$1"
    local passwd_file="${OPENPATH_PASSWD_FILE:-/etc/passwd}"
    local home_dir=""

    if [ -n "${OPENPATH_FIREFOX_PROFILE_HOME:-}" ]; then
        printf '%s\n' "$OPENPATH_FIREFOX_PROFILE_HOME"
        return 0
    fi

    if [ -n "$activation_user" ] && [ -r "$passwd_file" ]; then
        home_dir="$(awk -F: -v user="$activation_user" '$1 == user { print $6; exit }' "$passwd_file" || true)"
    fi

    if [ -n "$activation_user" ] && command -v getent >/dev/null 2>&1; then
        home_dir="${home_dir:-$(getent passwd "$activation_user" | cut -d: -f6 || true)}"
    fi

    if [ -z "$home_dir" ]; then
        home_dir="${HOME:-}"
    fi

    [ -n "$home_dir" ] || return 1
    printf '%s\n' "$home_dir"
}

resolve_firefox_activation_profile_dir() {
    local profile_home="$1"
    local firefox_root="$profile_home/.mozilla/firefox"
    local profiles_ini="$firefox_root/profiles.ini"
    local profile_dir=""

    if [ -n "${OPENPATH_FIREFOX_PROFILE_DIR:-}" ]; then
        printf '%s\n' "$OPENPATH_FIREFOX_PROFILE_DIR"
        return 0
    fi

    if [ -f "$profiles_ini" ]; then
        profile_dir="$(
            python3 - "$firefox_root" "$profiles_ini" <<'PY' 2>/dev/null || true
import configparser
import sys
from pathlib import Path

root = Path(sys.argv[1])
profiles_ini = Path(sys.argv[2])
parser = configparser.RawConfigParser()
parser.read(profiles_ini, encoding="utf-8")

def resolve_profile_path(path_value: str, is_relative: str) -> str:
    path = root / path_value if is_relative != "0" else Path(path_value)
    return str(path)

for section in parser.sections():
    if not section.startswith("Install"):
        continue
    default_path = parser.get(section, "Default", fallback="").strip()
    locked = parser.get(section, "Locked", fallback="").strip()
    if default_path and locked == "1":
        print(resolve_profile_path(default_path, "1"))
        raise SystemExit(0)

sections = [section for section in parser.sections() if section.lower().startswith("profile")]
selected = None
for section in sections:
    if parser.get(section, "Default", fallback="") == "1":
        selected = section
        break
if selected is None and sections:
    selected = sections[0]

if selected:
    profile_path = parser.get(selected, "Path", fallback="").strip()
    is_relative = parser.get(selected, "IsRelative", fallback="1").strip()
    if profile_path:
        print(resolve_profile_path(profile_path, is_relative))
PY
        )"
    fi

    if [ -n "$profile_dir" ]; then
        printf '%s\n' "$profile_dir"
        return 0
    fi

    printf '%s\n' "$firefox_root/openpath.default"
    return 0
}

resolve_firefox_profile_paths_from_ini() {
    local firefox_root="$1"
    local profiles_ini="$firefox_root/profiles.ini"

    [ -f "$profiles_ini" ] || return 1
    python3 - "$firefox_root" "$profiles_ini" <<'PY' 2>/dev/null || true
import configparser
import sys
from pathlib import Path

root = Path(sys.argv[1])
profiles_ini = Path(sys.argv[2])
parser = configparser.RawConfigParser()
parser.read(profiles_ini, encoding="utf-8")

seen = set()
for section in parser.sections():
    if not section.lower().startswith("profile"):
        continue
    profile_path = parser.get(section, "Path", fallback="").strip()
    if not profile_path:
        continue
    is_relative = parser.get(section, "IsRelative", fallback="1").strip()
    resolved = root / profile_path if is_relative != "0" else Path(profile_path)
    text = str(resolved)
    if text in seen:
        continue
    seen.add(text)
    print(text)
PY
}

enumerate_firefox_activation_targets() {
    local passwd_file="${OPENPATH_PASSWD_FILE:-/etc/passwd}"
    local user=""
    local uid=""
    local home_dir=""
    local shell=""
    local firefox_root=""
    local profile_dir=""
    local found_profile=false

    if [ -n "${OPENPATH_FIREFOX_PROFILE_USER:-}" ] \
        || [ -n "${OPENPATH_FIREFOX_PROFILE_HOME:-}" ] \
        || [ -n "${OPENPATH_FIREFOX_PROFILE_DIR:-}" ]; then
        user="$(resolve_firefox_activation_user)"
        home_dir="$(resolve_firefox_activation_home "$user")" || return 1
        profile_dir="$(ensure_firefox_activation_profile "$user" "$home_dir")" || return 1
        printf '%s\t%s\t%s\n' "$user" "$home_dir" "$profile_dir"
        return 0
    fi

    [ -r "$passwd_file" ] || return 1
    while IFS=: read -r user _ uid _ _ home_dir shell; do
        [ -n "$user" ] || continue
        [ -n "$home_dir" ] || continue
        [ -d "$home_dir" ] || continue
        found_profile=false

        for firefox_root in \
            "$home_dir/.mozilla/firefox" \
            "$home_dir/snap/firefox/common/.mozilla/firefox"; do
            while IFS= read -r profile_dir; do
                [ -n "$profile_dir" ] || continue
                found_profile=true
                printf '%s\t%s\t%s\n' "$user" "$home_dir" "$profile_dir"
            done < <(resolve_firefox_profile_paths_from_ini "$firefox_root")
        done

        if [ "$found_profile" = false ]; then
            case "$shell" in
                */nologin|*/false)
                    continue
                    ;;
            esac
            if [ "$user" = "root" ]; then
                continue
            fi
            if ! [[ "$uid" =~ ^[0-9]+$ ]] || [ "$uid" -lt 1000 ]; then
                continue
            fi
            profile_dir="$(ensure_firefox_activation_profile "$user" "$home_dir")" || return 1
            printf '%s\t%s\t%s\n' "$user" "$home_dir" "$profile_dir"
        fi
    done < "$passwd_file"
}

ensure_firefox_activation_profile() {
    local activation_user="$1"
    local profile_home="$2"
    local firefox_root="$profile_home/.mozilla/firefox"
    local profiles_ini="$firefox_root/profiles.ini"
    local profile_dir=""
    local current_user=""

    profile_dir="$(resolve_firefox_activation_profile_dir "$profile_home")" || return 1
    current_user="$(id -un 2>/dev/null || true)"

    if [ "$(id -u)" -eq 0 ] \
        && [ -n "$activation_user" ] \
        && [ "$activation_user" != "root" ] \
        && [ "$activation_user" != "$current_user" ] \
        && id "$activation_user" >/dev/null 2>&1 \
        && command -v runuser >/dev/null 2>&1; then
        runuser -u "$activation_user" -- env HOME="$profile_home" mkdir -p "$profile_dir" || return 1
        if [ ! -f "$profiles_ini" ]; then
            runuser -u "$activation_user" -- env HOME="$profile_home" sh -c '
                mkdir -p "$(dirname "$1")"
                cat > "$1" <<EOF
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=openpath
IsRelative=1
Path=openpath.default
Default=1
EOF
            ' sh "$profiles_ini" || true
        fi
    elif [ "$(id -u)" -eq 0 ] \
        && [ -n "$activation_user" ] \
        && [ "$activation_user" != "root" ] \
        && [ "$activation_user" != "$current_user" ] \
        && id "$activation_user" >/dev/null 2>&1 \
        && command -v sudo >/dev/null 2>&1; then
        sudo -H -u "$activation_user" env HOME="$profile_home" mkdir -p "$profile_dir" || return 1
        if [ ! -f "$profiles_ini" ]; then
            sudo -H -u "$activation_user" env HOME="$profile_home" sh -c '
                mkdir -p "$(dirname "$1")"
                cat > "$1" <<EOF
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=openpath
IsRelative=1
Path=openpath.default
Default=1
EOF
            ' sh "$profiles_ini" || true
        fi
    else
        mkdir -p "$profile_dir" || return 1
        if [ ! -f "$profiles_ini" ] && [ "$profile_dir" = "$firefox_root/openpath.default" ]; then
            mkdir -p "$firefox_root"
            cat > "$profiles_ini" <<'EOF'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=openpath
IsRelative=1
Path=openpath.default
Default=1
EOF
        fi
    fi

    printf '%s\n' "$profile_dir"
}

detect_firefox_extension_registration_in_profile() {
    local profile_dir="$1"
    local extension_id="$2"

    python3 - "$profile_dir" "$extension_id" <<'PY'
import json
import sys
from pathlib import Path

profile = Path(sys.argv[1])
extension_id = sys.argv[2]

def describe_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    return str(value)

def extensions_json_addon_state(path: Path):
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    addons = payload.get("addons")
    if not isinstance(addons, list):
        return None
    for addon in addons:
        if not isinstance(addon, dict) or addon.get("id") != extension_id:
            continue
        reasons = []
        if addon.get("active") is False:
            reasons.append("active=false")
        if addon.get("userDisabled") is True:
            reasons.append("userDisabled=true")
        if addon.get("signedState") == -1:
            reasons.append("signedState=-1")
        if addon.get("location"):
            reasons.append(f"location={describe_value(addon.get('location'))}")
        return reasons
    return None

if profile.is_dir():
    addon_reasons = extensions_json_addon_state(profile / "extensions.json")
    if addon_reasons is not None:
        if any(reason in addon_reasons for reason in ("active=false", "userDisabled=true", "signedState=-1")):
            print(f"extensions.json-disabled\t{profile}\t{';'.join(addon_reasons)}")
            raise SystemExit(1)
        print(f"extensions.json\t{profile}")
        raise SystemExit(0)

raise SystemExit(1)
PY
}

detect_firefox_extension_registration() {
    local profile_home="$1"
    local extension_id="$2"
    local firefox_root=""
    local profile=""

    for firefox_root in \
        "$profile_home/.mozilla/firefox" \
        "$profile_home/snap/firefox/common/.mozilla/firefox"; do
        [ -d "$firefox_root" ] || continue
        for profile in "$firefox_root"/*; do
            [ -d "$profile" ] || continue
            detect_firefox_extension_registration_in_profile "$profile" "$extension_id" && return 0
        done
    done

    return 1
}

firefox_profile_has_extension_registration() {
    local profile_home="$1"
    local extension_id="$2"

    detect_firefox_extension_registration "$profile_home" "$extension_id" >/dev/null
}

log_firefox_registration_probe() {
    local probe_attempt="$1"
    local activation_user="$2"
    local profile_home="$3"
    local probe_exit_status="$4"
    local registration_source="$5"
    local registration_profile="$6"

    log \
        "Firefox registration probe_attempt=$probe_attempt activation_user=$activation_user profile_home=$profile_home probe_exit_status=$probe_exit_status registration_source=$registration_source registration_profile=$registration_profile"
}

# The ambient DISPLAY/XAUTHORITY belong to whoever started the install -- the
# desktop session owner (== the sudo invoker, or the current user for a
# self-install). They are only usable when the activation probe runs AS that same
# user. For any OTHER user the foreign display cannot be opened ("cannot open
# display: :0") and Firefox exits before it installs the force_installed managed
# extension, so registration is missing for every profile except the session
# owner's (registered=1 target_count=N).
firefox_activation_probe_owns_ambient_display() {
    local activation_user="$1"
    local current_user="$2"

    [ -n "$activation_user" ] || return 1
    [ "$activation_user" = "$current_user" ] && return 0
    [ -n "${SUDO_USER:-}" ] && [ "$activation_user" = "$SUDO_USER" ] && return 0
    return 1
}

# Decide how the activation probe should launch Firefox for a target user.
# Prints either:
#   gui\t<XAUTHORITY-or-empty>\t<DISPLAY>   -- use the ambient X session
#   headless                                -- run with --headless (no X needed)
firefox_activation_probe_display_plan() {
    local activation_user="$1"
    local current_user="$2"
    local profile_home="$3"
    local xauthority_path="$profile_home/.Xauthority"
    local x11_socket="${OPENPATH_X11_SOCKET:-/tmp/.X11-unix/X0}"
    local probe_xauthority=""
    local probe_display=""

    if firefox_activation_probe_owns_ambient_display "$activation_user" "$current_user"; then
        if [ -n "${XAUTHORITY:-}" ]; then
            probe_xauthority="$XAUTHORITY"
        elif [ -f "$xauthority_path" ]; then
            probe_xauthority="$xauthority_path"
        fi

        if [ -n "${DISPLAY:-}" ]; then
            probe_display="$DISPLAY"
        elif [ -S "$x11_socket" ] && [ -n "$probe_xauthority" ]; then
            probe_display=":0"
        fi
    fi

    if [ -n "$probe_display" ]; then
        printf 'gui\t%s\t%s\n' "$probe_xauthority" "$probe_display"
    else
        printf 'headless\n'
    fi
}

run_firefox_activation_probe() {
    local firefox_binary="$1"
    local activation_user="$2"
    local profile_home="$3"
    local activation_profile="${4:-}"
    local screenshot_path="${TMPDIR:-/tmp}/openpath-firefox-extension-activation.${activation_user:-unknown}.png"
    local current_user=""

    force_browser_close || true
    current_user="$(id -un 2>/dev/null || true)"
    if [ -z "$activation_profile" ]; then
        activation_profile="$(ensure_firefox_activation_profile "$activation_user" "$profile_home")" || return 1
    else
        mkdir -p "$activation_profile" || return 1
    fi

    local display_env=()
    local firefox_args=()
    local probe_plan=""
    local probe_mode=""
    local probe_xauthority=""
    local probe_display=""

    probe_plan="$(firefox_activation_probe_display_plan "$activation_user" "$current_user" "$profile_home")"
    IFS=$'\t' read -r probe_mode probe_xauthority probe_display <<< "$probe_plan"

    if [ "$probe_mode" = "gui" ]; then
        [ -n "$probe_xauthority" ] && display_env+=("XAUTHORITY=$probe_xauthority")
        display_env+=("DISPLAY=$probe_display")
        firefox_args=("--profile" "$activation_profile" "about:blank")
    else
        firefox_args=("--headless" "--profile" "$activation_profile" "--screenshot" "$screenshot_path" "about:blank")
    fi

    if [ "$(id -u)" -eq 0 ] \
        && [ -n "$activation_user" ] \
        && [ "$activation_user" != "root" ] \
        && [ "$activation_user" != "$current_user" ] \
        && id "$activation_user" >/dev/null 2>&1 \
        && command -v runuser >/dev/null 2>&1; then
        runuser -u "$activation_user" -- \
            env HOME="$profile_home" "${display_env[@]}" \
            timeout --kill-after=5s "${FIREFOX_ACTIVATION_PROBE_TIMEOUT_SECONDS}s" "$firefox_binary" "${firefox_args[@]}" \
            >/dev/null 2>&1
        return $?
    fi

    if [ "$(id -u)" -eq 0 ] \
        && [ -n "$activation_user" ] \
        && [ "$activation_user" != "root" ] \
        && [ "$activation_user" != "$current_user" ] \
        && id "$activation_user" >/dev/null 2>&1 \
        && command -v sudo >/dev/null 2>&1; then
        sudo -H -u "$activation_user" \
            env HOME="$profile_home" "${display_env[@]}" \
            timeout --kill-after=5s "${FIREFOX_ACTIVATION_PROBE_TIMEOUT_SECONDS}s" "$firefox_binary" "${firefox_args[@]}" \
            >/dev/null 2>&1
        return $?
    fi

    env HOME="$profile_home" "${display_env[@]}" timeout --kill-after=5s "${FIREFOX_ACTIVATION_PROBE_TIMEOUT_SECONDS}s" "$firefox_binary" "${firefox_args[@]}" \
        >/dev/null 2>&1
}

write_firefox_extension_ready_marker() {
    local target_count="$1"
    local registered_count="$2"
    shift 2
    local marker_path="${FIREFOX_EXTENSION_READY_FILE:-$VAR_STATE_DIR/firefox-extension-ready}"

    mkdir -p "$(dirname "$marker_path")"
    {
        printf 'extension_id=%s\n' "$FIREFOX_EXTENSION_ID"
        printf 'target_count=%s\n' "$target_count"
        printf 'registered_count=%s\n' "$registered_count"
        printf 'verified_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '%s\n' "$@"
    } > "$marker_path"
    chmod 600 "$marker_path" 2>/dev/null || true
}

verify_firefox_extension_registered() {
    local firefox_binary=""
    local activation_user=""
    local profile_home=""
    local deadline=0
    local activation_status=0
    local activation_attempts=0
    local marker_path="${FIREFOX_EXTENSION_READY_FILE:-$VAR_STATE_DIR/firefox-extension-ready}"
    local registration_info=""
    local registration_source="missing"
    local registration_profile=""
    local targets=()
    local target=""
    local profile_dir=""
    local target_count=0
    local registered_count=0
    local target_lines=()
    local missing_targets=()
    local disabled_targets=()
    local last_registration_reason=""

    rm -f "$marker_path" 2>/dev/null || true

    firefox_binary="$(resolve_firefox_binary_path)" || {
        log_error "Firefox executable not found after browser setup"
        return 1
    }
    mapfile -t targets < <(enumerate_firefox_activation_targets)
    target_count="${#targets[@]}"
    if [ "$target_count" -eq 0 ]; then
        activation_user="$(resolve_firefox_activation_user)"
        profile_home="$(resolve_firefox_activation_home "$activation_user")" || {
            log_error "No Firefox activation targets found for extension verification"
            return 1
        }
        profile_dir="$(ensure_firefox_activation_profile "$activation_user" "$profile_home")" || {
            log_error "No Firefox activation targets found for extension verification"
            return 1
        }
        targets+=("$activation_user"$'\t'"$profile_home"$'\t'"$profile_dir")
        target_count=1
    fi

    for target in "${targets[@]}"; do
        IFS=$'\t' read -r activation_user profile_home profile_dir <<< "$target"
        deadline=$((SECONDS + FIREFOX_EXTENSION_REGISTRATION_TIMEOUT_SECONDS))
        activation_attempts=0
        registration_source="missing"
        registration_profile=""
        last_registration_reason=""

        while [ "$SECONDS" -le "$deadline" ] || [ "$activation_attempts" -lt "$FIREFOX_EXTENSION_REGISTRATION_MIN_PROBES" ]; do
            registration_info="$(detect_firefox_extension_registration_in_profile "$profile_dir" "$FIREFOX_EXTENSION_ID" 2>/dev/null || true)"
            if [ -n "$registration_info" ]; then
                registration_source="${registration_info%%$'\t'*}"
                registration_profile="${registration_info#*$'\t'}"
                registration_profile="${registration_profile%%$'\t'*}"
                if [ "$registration_source" = "extensions.json-disabled" ]; then
                    last_registration_reason="${registration_info#*$'\t'}"
                    last_registration_reason="${last_registration_reason#*$'\t'}"
                    log_firefox_registration_probe "$activation_attempts" "$activation_user" "$profile_home" 1 "$registration_source" "$registration_profile reason=$last_registration_reason"
                else
                    log_firefox_registration_probe "$activation_attempts" "$activation_user" "$profile_home" 0 "$registration_source" "$registration_profile"
                    break
                fi
            fi

            activation_attempts=$((activation_attempts + 1))
            if run_firefox_activation_probe "$firefox_binary" "$activation_user" "$profile_home" "$profile_dir"; then
                activation_status=0
            else
                activation_status=$?
            fi

            registration_source="missing"
            registration_profile=""
            registration_info="$(detect_firefox_extension_registration_in_profile "$profile_dir" "$FIREFOX_EXTENSION_ID" 2>/dev/null || true)"
            if [ -n "$registration_info" ]; then
                registration_source="${registration_info%%$'\t'*}"
                registration_profile="${registration_info#*$'\t'}"
                registration_profile="${registration_profile%%$'\t'*}"
                if [ "$registration_source" = "extensions.json-disabled" ]; then
                    last_registration_reason="${registration_info#*$'\t'}"
                    last_registration_reason="${last_registration_reason#*$'\t'}"
                fi
            fi
            if [ "$registration_source" = "extensions.json-disabled" ]; then
                log_firefox_registration_probe "$activation_attempts" "$activation_user" "$profile_home" 1 "$registration_source" "$profile_dir reason=$last_registration_reason"
            else
                log_firefox_registration_probe "$activation_attempts" "$activation_user" "$profile_home" "$activation_status" "$registration_source" "$profile_dir"
            fi

            if [ "$registration_source" != "missing" ] && [ "$registration_source" != "extensions.json-disabled" ]; then
                break
            fi

            if [ "$activation_status" -ne 0 ] \
                && [ "$SECONDS" -gt "$deadline" ] \
                && [ "$activation_attempts" -ge "$FIREFOX_EXTENSION_REGISTRATION_MIN_PROBES" ]; then
                break
            fi

            sleep 1
        done

        if [ "$registration_source" != "missing" ] && [ "$registration_source" != "extensions.json-disabled" ]; then
            registered_count=$((registered_count + 1))
            target_lines+=("profile=$activation_user|$profile_home|$profile_dir|registered|$registration_source")
        elif [ "$registration_source" = "extensions.json-disabled" ]; then
            target_lines+=("profile=$activation_user|$profile_home|$profile_dir|disabled|$registration_source;$last_registration_reason")
            disabled_targets+=("$activation_user|$profile_home|$profile_dir|$last_registration_reason")
        else
            target_lines+=("profile=$activation_user|$profile_home|$profile_dir|missing|missing")
            missing_targets+=("$activation_user|$profile_home|$profile_dir")
        fi
    done

    write_firefox_extension_ready_marker "$target_count" "$registered_count" "${target_lines[@]}"
    log "Firefox managed extension registration targets: registered=$registered_count target_count=$target_count"
    if [ "$registered_count" -eq "$target_count" ]; then
        return 0
    fi

    if [ "${OPENPATH_ALLOW_DEFERRED_FIREFOX_REGISTRATION:-0}" = "1" ] \
        && [ "${#disabled_targets[@]}" -eq 0 ]; then
        log "Firefox managed extension registration deferred: registered=$registered_count target_count=$target_count"
        return 0
    fi

    log_error \
        "Firefox did not register active managed extension for all profiles: $FIREFOX_EXTENSION_ID registered=$registered_count target_count=$target_count missing=${missing_targets[*]} disabled=${disabled_targets[*]}"
    return 1
}
