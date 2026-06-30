#!/usr/bin/env python3
"""
Native Messaging Host para Monitor de Bloqueos de Red

Este script actúa como puente entre la extensión de Firefox y el sistema
de whitelist. Recibe solicitudes de la extensión y ejecuta comandos del
sistema para verificar o añadir dominios.

Instalación:
  1. Copiar a /usr/local/bin/openpath-native-host.py
  2. Hacer ejecutable: chmod +x /usr/local/bin/openpath-native-host.py
  3. Registrar el manifest en Firefox

Protocolo:
  - Recibe: JSON con estructura {"action": "...", "domains": [...]}
  - Envía: JSON con estructura {"success": bool, "results": [...]}
"""

import sys
import json
import struct
import subprocess
import os
import re
import socket
import hashlib
import fcntl
import threading
import time
from pathlib import Path
from datetime import datetime, timezone

WHITELIST_CMD_CANDIDATES = ["/usr/local/bin/openpath", "/usr/local/bin/whitelist"]
MAX_DOMAINS = 50
MAX_PATH_RULES = 500
MAX_LOG_SIZE_MB = 5
BLOCKED_DNS_SENTINELS = {"0.0.0.0", "::", "192.0.2.1", "100::"}
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*m")
UPDATE_TRIGGER_LOCK = threading.Lock()
RUNTIME_DEPENDENCY_BATCH_LIMIT = 20
RUNTIME_DEPENDENCY_SOURCE = "firefox-webrequest-local"
RUNTIME_DEPENDENCY_HOST_RE = re.compile(
    r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"
)


def get_log_path():
    xdg_data = os.environ.get("XDG_DATA_HOME")
    if xdg_data:
        log_dir = Path(xdg_data) / "openpath"
    else:
        log_dir = Path.home() / ".local" / "share" / "openpath"

    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        return log_dir / "native-host.log"
    except (PermissionError, OSError):
        return Path("/tmp/openpath-native-host.log")


LOG_FILE = get_log_path()


def normalize_runtime_dependency_host(value):
    if not isinstance(value, str):
        return ""
    normalized = value.strip().strip(".").lower()
    if normalized.endswith(".local"):
        return ""
    if len(normalized) < 4 or len(normalized) > 253:
        return ""
    if not RUNTIME_DEPENDENCY_HOST_RE.match(normalized):
        return ""
    return normalized


def get_runtime_dependency_queue_dir():
    return Path(
        os.environ.get(
            "OPENPATH_RUNTIME_DEPENDENCY_QUEUE_DIR",
            "/var/lib/openpath/runtime-dependency-queue",
        )
    )


def format_utc_timestamp():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def write_runtime_dependency_request(entry):
    if not isinstance(entry, dict):
        return {
            "success": False,
            "action": "allow-local-runtime-dependency",
            "error": "Invalid runtime dependency payload",
        }

    anchor_host = normalize_runtime_dependency_host(entry.get("anchorHost"))
    dependency_host = normalize_runtime_dependency_host(entry.get("dependencyHost"))
    request_type = str(entry.get("requestType", "")).strip().lower()
    if not anchor_host or not dependency_host or not request_type:
        return {
            "success": False,
            "action": "allow-local-runtime-dependency",
            "error": "Invalid runtime dependency payload",
        }
    if request_type == "main_frame":
        return {
            "success": False,
            "action": "allow-local-runtime-dependency",
            "anchorHost": anchor_host,
            "dependencyHost": dependency_host,
            "requestType": request_type,
            "error": "main_frame dependencies are not supported",
        }

    queue_dir = get_runtime_dependency_queue_dir()
    if not queue_dir.is_dir():
        return {
            "success": False,
            "action": "allow-local-runtime-dependency",
            "anchorHost": anchor_host,
            "dependencyHost": dependency_host,
            "requestType": request_type,
            "error": "Queue directory not configured",
        }

    request_id = f"{int(time.time() * 1000)}-{os.getpid()}-{os.urandom(8).hex()}"
    request_path = queue_dir / f"{request_id}.json"
    payload = {
        "version": 1,
        "queuedAt": format_utc_timestamp(),
        "anchorHost": anchor_host,
        "dependencyHost": dependency_host,
        "requestType": request_type,
        "source": RUNTIME_DEPENDENCY_SOURCE,
    }
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(request_path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))
        handle.write("\n")

    return {
        "success": True,
        "action": "allow-local-runtime-dependency",
        "anchorHost": anchor_host,
        "dependencyHost": dependency_host,
        "requestType": request_type,
        "queued": True,
        "source": RUNTIME_DEPENDENCY_SOURCE,
    }


def rotate_log_if_needed():
    try:
        if (
            LOG_FILE.exists()
            and LOG_FILE.stat().st_size > MAX_LOG_SIZE_MB * 1024 * 1024
        ):
            backup = LOG_FILE.with_suffix(".log.old")
            if backup.exists():
                backup.unlink()
            LOG_FILE.rename(backup)
    except Exception:
        pass


def log_debug(message):
    try:
        with open(LOG_FILE, "a") as f:
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            f.write(f"[{timestamp}] {message}\n")
    except Exception:
        pass


def get_machine_token():
    whitelist_url_path = Path("/etc/openpath/whitelist-url.conf")

    try:
        whitelist_url = whitelist_url_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        return {
            "success": False,
            "action": "get-machine-token",
            "error": f"Could not read {whitelist_url_path}: {exc}",
        }

    match = re.search(r"/w/([^/]+)/", whitelist_url)
    if not match:
        return {
            "success": False,
            "action": "get-machine-token",
            "error": "Whitelist URL does not contain a machine token",
        }

    return {
        "success": True,
        "action": "get-machine-token",
        "token": match.group(1),
    }


def read_optional_text(path_str):
    path = Path(path_str)
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def get_native_config():
    api_url = read_optional_text("/etc/openpath/api-url.conf")
    whitelist_url = read_optional_text("/etc/openpath/whitelist-url.conf")
    machine_token = ""

    if whitelist_url:
        match = re.search(r"/w/([^/]+)/", whitelist_url)
        if match:
            machine_token = match.group(1)

    if not api_url:
        return {
            "success": False,
            "action": "get-config",
            "error": "API URL is not configured",
        }

    normalized_api_url = api_url.rstrip("/")
    return {
        "success": True,
        "action": "get-config",
        "apiUrl": normalized_api_url,
        "requestApiUrl": normalized_api_url,
        "fallbackApiUrls": [],
        "hostname": socket.gethostname(),
        "machineToken": machine_token,
        "whitelistUrl": whitelist_url,
    }


def read_message():
    """Lee un mensaje del stdin en formato Native Messaging"""
    raw_length = sys.stdin.buffer.read(4)
    if len(raw_length) == 0:
        return None

    message_length = struct.unpack("@I", raw_length)[0]

    # Límite de seguridad: max 1MB
    if message_length > 1024 * 1024:
        return None

    message = sys.stdin.buffer.read(message_length).decode("utf-8")
    return json.loads(message)


def send_message(message):
    """Envía un mensaje al stdout en formato Native Messaging"""
    encoded_message = json.dumps(message).encode("utf-8")
    encoded_length = struct.pack("@I", len(encoded_message))

    sys.stdout.buffer.write(encoded_length)
    sys.stdout.buffer.write(encoded_message)
    sys.stdout.buffer.flush()


def get_system_disabled_flag_path():
    env_path = os.environ.get("OPENPATH_SYSTEM_DISABLED_FLAG")
    if env_path:
        return Path(env_path)
    return Path("/var/lib/openpath/system-disabled.flag")


def get_whitelist_command_path():
    env_path = os.environ.get("OPENPATH_WHITELIST_CMD")
    if env_path:
        return env_path

    for candidate in WHITELIST_CMD_CANDIDATES:
        if os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate

    return None


def whitelist_marks_system_disabled(whitelist_file):
    try:
        with open(whitelist_file, "r", encoding="utf-8", errors="ignore") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line:
                    continue
                return line.startswith("#") and "DESACTIVADO" in line.upper()
    except Exception as e:
        log_debug(f"Error checking whitelist disabled marker: {e}")

    return False


def is_dns_policy_active():
    if get_system_disabled_flag_path().exists():
        return False

    whitelist_file = get_whitelist_file_path()
    if whitelist_file is None:
        return False

    return not whitelist_marks_system_disabled(whitelist_file)


def whitelist_file_contains_domain(whitelist_file, domain):
    try:
        expected = domain.lower()
        with open(whitelist_file, "r", encoding="utf-8", errors="ignore") as f:
            for raw_line in f:
                line = raw_line.strip().lower()
                if not line or line.startswith("#"):
                    continue
                if line == expected:
                    return True
    except Exception as e:
        log_debug(f"Error reading whitelist file for {domain}: {e}")

    return False


def get_valid_domains(domains):
    valid_domains = []
    for domain in domains[:MAX_DOMAINS]:
        if not domain or not isinstance(domain, str):
            continue

        normalized = domain.strip().lower()
        if not normalized:
            continue
        if not all(c.isalnum() or c in '.-' for c in normalized):
            continue

        valid_domains.append(normalized)

    return valid_domains


def whitelist_contains_domains(whitelist_file, domains):
    if not domains:
        return True
    if whitelist_file is None:
        return False

    return all(whitelist_file_contains_domain(whitelist_file, domain) for domain in domains)


def get_update_script_path():
    env_path = os.environ.get("OPENPATH_NATIVE_HOST_UPDATE_SCRIPT")
    if env_path:
        return env_path
    return "/usr/local/bin/openpath-update.sh"


def get_update_timeout_ms():
    raw_value = os.environ.get("OPENPATH_NATIVE_HOST_UPDATE_TIMEOUT_MS", "45000")
    try:
        parsed = int(raw_value)
    except (TypeError, ValueError):
        return 45000

    return max(parsed, 0)


def get_update_lock_path():
    env_path = os.environ.get("OPENPATH_NATIVE_HOST_UPDATE_LOCK")
    if env_path:
        return env_path
    return "/tmp/openpath-native-host-update.lock"


def wait_for_whitelist_domains(domains, timeout_ms):
    if not domains:
        return True

    deadline = time.monotonic() + (timeout_ms / 1000)
    while time.monotonic() <= deadline:
        whitelist_file = get_whitelist_file_path()
        if whitelist_contains_domains(whitelist_file, domains):
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(1, remaining))

    whitelist_file = get_whitelist_file_path()
    return whitelist_contains_domains(whitelist_file, domains)


def run_update_script(update_script, timeout_ms):
    return subprocess.run(
        [update_script, "--update"],
        capture_output=True,
        text=True,
        timeout=max(timeout_ms / 1000, 0.001),
    )


def trigger_update_whitelist(domains):
    update_script = get_update_script_path()
    timeout_ms = get_update_timeout_ms()
    requires_domain_convergence = len(domains) > 0

    if requires_domain_convergence and whitelist_contains_domains(get_whitelist_file_path(), domains):
        return {
            "success": True,
            "action": "update-whitelist",
            "message": "OpenPath update wrote expected domains",
            "domains": domains,
        }

    try:
        with UPDATE_TRIGGER_LOCK:
            lock_path = get_update_lock_path()
            with open(lock_path, "a+", encoding="utf-8") as lock_file:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                try:
                    if requires_domain_convergence and whitelist_contains_domains(
                        get_whitelist_file_path(), domains
                    ):
                        return {
                            "success": True,
                            "action": "update-whitelist",
                            "message": "OpenPath update wrote expected domains",
                            "domains": domains,
                        }

                    if not os.path.exists(update_script):
                        return {
                            "success": False,
                            "action": "update-whitelist",
                            "domains": domains,
                            "error": "Update script not found",
                        }

                    deadline = time.monotonic() + (timeout_ms / 1000)
                    proc = run_update_script(update_script, timeout_ms)
                    if proc.returncode != 0:
                        return {
                            "success": False,
                            "action": "update-whitelist",
                            "domains": domains,
                            "output": proc.stdout,
                            "error": proc.stderr or f"Update exited with code {proc.returncode}",
                        }

                    if not requires_domain_convergence:
                        return {
                            "success": True,
                            "action": "update-whitelist",
                            "domains": domains,
                            "message": "OpenPath update triggered",
                            "output": proc.stdout,
                        }

                    remaining_timeout_ms = max(int((deadline - time.monotonic()) * 1000), 0)
                    if wait_for_whitelist_domains(domains, remaining_timeout_ms):
                        return {
                            "success": True,
                            "action": "update-whitelist",
                            "domains": domains,
                            "message": "OpenPath update wrote expected domains",
                            "output": proc.stdout,
                        }

                    return {
                        "success": False,
                        "action": "update-whitelist",
                        "domains": domains,
                        "output": proc.stdout,
                        "error": f"OpenPath update did not write expected domains: {', '.join(domains)}",
                    }
                finally:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    except subprocess.TimeoutExpired:
        return {
            "success": False,
            "action": "update-whitelist",
            "domains": domains,
            "error": "Update timed out",
        }
    except Exception as e:
        return {
            "success": False,
            "action": "update-whitelist",
            "domains": domains,
            "error": str(e),
        }


def resolve_domain_with_system_dns(domain):
    try:
        addresses = socket.getaddrinfo(domain, None)
    except socket.gaierror:
        return False, None
    except Exception as e:
        log_debug(f"Error resolving domain {domain}: {e}")
        return False, None

    first_blocked_sentinel = None
    for address in addresses:
        ip = address[4][0]
        if ip in BLOCKED_DNS_SENTINELS:
            if first_blocked_sentinel is None:
                first_blocked_sentinel = ip
            continue
        return True, ip

    return False, first_blocked_sentinel


def is_blocked_dns_sentinel(ip):
    return ip in BLOCKED_DNS_SENTINELS


def clean_cli_token(value):
    return ANSI_ESCAPE_RE.sub("", value).strip()


def check_domain(domain):
    """
    Verifica si un dominio está en la whitelist y si resuelve.

    Returns:
        dict: {
            "domain": str,
            "in_whitelist": bool,
            "resolves": bool,
            "resolved_ip": str or None
        }
    """
    whitelist_cmd = get_whitelist_command_path()
    result = {
        "domain": domain,
        "in_whitelist": False,
        "policy_active": is_dns_policy_active(),
        "resolves": False,
        "resolved_ip": None,
    }

    whitelist_file = get_whitelist_file_path()
    if whitelist_file is not None:
        result["in_whitelist"] = whitelist_file_contains_domain(whitelist_file, domain)

    if whitelist_cmd is None:
        resolves, resolved_ip = resolve_domain_with_system_dns(domain)
        result["resolves"] = resolves
        result["resolved_ip"] = resolved_ip
        return result

    try:
        # Ejecutar whitelist check
        proc = subprocess.run(
            [whitelist_cmd, "check", domain], capture_output=True, text=True, timeout=10
        )

        output = proc.stdout

        # Parsear resultado
        if "SÍ" in output or "YES" in output:
            result["in_whitelist"] = True

        if "→" in output:
            # Extraer IP
            ip_match = re.search(r"→\s*(\S+)", output)
            if ip_match:
                resolved_ip = clean_cli_token(ip_match.group(1))
                result["resolved_ip"] = resolved_ip
                result["resolves"] = not is_blocked_dns_sentinel(resolved_ip)
            else:
                result["resolves"] = True

    except subprocess.TimeoutExpired:
        log_debug(f"Timeout checking domain: {domain}")
    except Exception as e:
        log_debug(f"Error checking domain {domain}: {e}")

    return result


def check_domains(domains):
    """Verifica múltiples dominios"""
    results = []

    for domain in get_valid_domains(domains):

        result = check_domain(domain)
        results.append(result)

    return results


def get_whitelist_domains():
    """Obtiene la lista de dominios en la whitelist"""
    whitelist_cmd = get_whitelist_command_path()
    if whitelist_cmd is None:
        log_debug("OpenPath whitelist command not found")
        return []

    try:
        proc = subprocess.run(
            [whitelist_cmd, "domains"], capture_output=True, text=True, timeout=10
        )

        domains = [d.strip() for d in proc.stdout.split("\n") if d.strip()]
        return domains

    except Exception as e:
        log_debug(f"Error getting domains: {e}")
        return []


def get_system_status():
    """Obtiene el estado del sistema whitelist"""
    whitelist_cmd = get_whitelist_command_path()
    if whitelist_cmd is None:
        return {"output": "", "active": False}

    try:
        proc = subprocess.run(
            [whitelist_cmd, "status"], capture_output=True, text=True, timeout=10
        )

        return {
            "output": proc.stdout,
            "active": "activo" in proc.stdout.lower()
            or "active" in proc.stdout.lower(),
        }

    except Exception as e:
        log_debug(f"Error getting status: {e}")
        return {"output": "", "active": False}


def get_whitelist_file_path():
    """Detecta la ruta activa del archivo whitelist local"""
    candidates = []

    env_path = os.environ.get("OPENPATH_WHITELIST_FILE")
    if env_path:
        candidates.append(Path(env_path))

    candidates.extend(
        [Path("/var/lib/openpath/whitelist.txt"), Path("/etc/openpath/whitelist.txt")]
    )

    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate

    return None


def get_blocked_paths():
    """Obtiene reglas de ## BLOCKED-PATHS del whitelist local"""
    whitelist_file = get_whitelist_file_path()
    if whitelist_file is None:
        return {
            "success": False,
            "action": "get-blocked-paths",
            "error": "Whitelist file not found",
        }

    blocked_paths = []
    section = ""
    found_blocked_path_section = False

    try:
        with open(whitelist_file, "r", encoding="utf-8", errors="ignore") as f:
            for raw_line in f:
                line = raw_line.strip()
                line_upper = line.upper()

                if line_upper == "## WHITELIST":
                    section = "whitelist"
                    continue
                if line_upper == "## BLOCKED-SUBDOMAINS":
                    section = "blocked_sub"
                    continue
                if line_upper == "## BLOCKED-PATHS":
                    section = "blocked_path"
                    found_blocked_path_section = True
                    continue
                if line_upper == "## ALLOWED-PATHS":
                    section = "allowed_path"
                    continue

                if not line or line.startswith("#"):
                    continue

                if not section:
                    section = "whitelist"

                if section == "blocked_path":
                    blocked_paths.append(line)
                    if len(blocked_paths) >= MAX_PATH_RULES:
                        break

        if not found_blocked_path_section:
            log_debug("Warning: ## BLOCKED-PATHS section not found in whitelist file")

        digest = hashlib.sha256("\n".join(blocked_paths).encode("utf-8")).hexdigest()
        mtime = int(whitelist_file.stat().st_mtime)

        return {
            "success": True,
            "action": "get-blocked-paths",
            "paths": blocked_paths,
            "count": len(blocked_paths),
            "hash": digest,
            "mtime": mtime,
            "source": str(whitelist_file),
        }
    except Exception as e:
        log_debug(f"Error getting blocked paths: {e}")
        return {"success": False, "action": "get-blocked-paths", "error": str(e)}


def get_allowed_paths():
    """Obtiene reglas de ## ALLOWED-PATHS del whitelist local (allow-por-ruta).

    El DNS/firewall ignoran esta seccion; solo la usa la extension del navegador.
    """
    whitelist_file = get_whitelist_file_path()
    if whitelist_file is None:
        return {
            "success": False,
            "action": "get-allowed-paths",
            "error": "Whitelist file not found",
        }

    allowed_paths = []
    section = ""
    found_allowed_path_section = False

    try:
        with open(whitelist_file, "r", encoding="utf-8", errors="ignore") as f:
            for raw_line in f:
                line = raw_line.strip()
                line_upper = line.upper()

                if line_upper == "## WHITELIST":
                    section = "whitelist"
                    continue
                if line_upper == "## BLOCKED-SUBDOMAINS":
                    section = "blocked_sub"
                    continue
                if line_upper == "## BLOCKED-PATHS":
                    section = "blocked_path"
                    continue
                if line_upper == "## ALLOWED-PATHS":
                    section = "allowed_path"
                    found_allowed_path_section = True
                    continue

                if not line or line.startswith("#"):
                    continue

                if not section:
                    section = "whitelist"

                if section == "allowed_path":
                    allowed_paths.append(line)
                    if len(allowed_paths) >= MAX_PATH_RULES:
                        break

        if not found_allowed_path_section:
            log_debug("Warning: ## ALLOWED-PATHS section not found in whitelist file")

        digest = hashlib.sha256("\n".join(allowed_paths).encode("utf-8")).hexdigest()
        mtime = int(whitelist_file.stat().st_mtime)

        return {
            "success": True,
            "action": "get-allowed-paths",
            "paths": allowed_paths,
            "count": len(allowed_paths),
            "hash": digest,
            "mtime": mtime,
            "source": str(whitelist_file),
        }
    except Exception as e:
        log_debug(f"Error getting allowed paths: {e}")
        return {"success": False, "action": "get-allowed-paths", "error": str(e)}


def get_blocked_subdomains():
    """Obtiene reglas de ## BLOCKED-SUBDOMAINS del whitelist local"""
    whitelist_file = get_whitelist_file_path()
    if whitelist_file is None:
        return {
            "success": False,
            "action": "get-blocked-subdomains",
            "error": "Whitelist file not found",
        }

    blocked_subdomains = []
    section = ""

    try:
        with open(whitelist_file, "r", encoding="utf-8", errors="ignore") as f:
            for raw_line in f:
                line = raw_line.strip()
                line_upper = line.upper()

                if line_upper == "## BLOCKED-SUBDOMAINS":
                    section = "blocked_sub"
                    continue
                if line_upper in ("## WHITELIST", "## BLOCKED-PATHS", "## ALLOWED-PATHS"):
                    section = "other"
                    continue
                if not line or line.startswith("#"):
                    continue
                if section == "blocked_sub":
                    blocked_subdomains.append(line)

        digest = hashlib.sha256("\n".join(blocked_subdomains).encode("utf-8")).hexdigest()
        return {
            "success": True,
            "action": "get-blocked-subdomains",
            "subdomains": blocked_subdomains,
            "count": len(blocked_subdomains),
            "hash": digest,
            "mtime": int(whitelist_file.stat().st_mtime),
            "source": str(whitelist_file),
        }
    except Exception as e:
        log_debug(f"Error getting blocked subdomains: {e}")
        return {"success": False, "action": "get-blocked-subdomains", "error": str(e)}


def get_policy_version():
    """Devuelve un sello de versión barato del whitelist local (mtime_ns:size).

    Solo hace stat() del archivo local; no lee su contenido ni contacta la red.
    """
    whitelist_file = get_whitelist_file_path()
    if whitelist_file is None:
        return {"success": True, "action": "get-policy-version", "version": ""}

    try:
        st = whitelist_file.stat()
        version = f"{st.st_mtime_ns}:{st.st_size}"
        return {"success": True, "action": "get-policy-version", "version": version}
    except Exception as e:
        log_debug(f"Error getting policy version: {e}")
        return {"success": False, "action": "get-policy-version", "error": str(e)}


def handle_message(message):
    """Procesa un mensaje y devuelve la respuesta"""

    if not isinstance(message, dict):
        return {"success": False, "error": "Invalid message format"}

    action = message.get("action", "")

    if action == "check":
        domains = message.get("domains", [])
        if not domains:
            return {"success": False, "error": "No domains provided"}

        results = check_domains(domains)
        return {"success": True, "action": "check", "results": results}

    elif action == "list":
        domains = get_whitelist_domains()
        return {"success": True, "action": "list", "domains": domains}

    elif action == "status":
        status = get_system_status()
        return {"success": True, "action": "status", "status": status}

    elif action == "ping":
        return {"success": True, "action": "ping", "message": "pong"}

    elif action == "get-hostname":
        # Return the system hostname for token generation
        hostname = socket.gethostname()
        return {"success": True, "action": "get-hostname", "hostname": hostname}

    elif action == "get-machine-token":
        return get_machine_token()

    elif action == "get-config":
        return get_native_config()

    elif action == "update-whitelist":
        return trigger_update_whitelist(get_valid_domains(message.get("domains", [])))

    elif action == "get-blocked-paths":
        return get_blocked_paths()

    elif action == "get-allowed-paths":
        return get_allowed_paths()

    elif action == "get-blocked-subdomains":
        return get_blocked_subdomains()

    elif action == "get-policy-version":
        return get_policy_version()

    elif action == "allow-local-runtime-dependency":
        return write_runtime_dependency_request(message)

    elif action == "allow-local-runtime-dependency-batch":
        entries = message.get("entries", [])
        if not isinstance(entries, list) or not entries:
            return {
                "success": False,
                "action": "allow-local-runtime-dependency-batch",
                "error": "Invalid runtime dependency batch payload",
                "results": [],
            }

        results = [
            write_runtime_dependency_request(entry)
            for entry in entries[:RUNTIME_DEPENDENCY_BATCH_LIMIT]
        ]
        if len(entries) > RUNTIME_DEPENDENCY_BATCH_LIMIT:
            results.append(
                {
                    "success": False,
                    "action": "allow-local-runtime-dependency",
                    "error": "Runtime dependency batch limit exceeded",
                }
            )

        return {
            "success": all(result.get("success") is True for result in results),
            "action": "allow-local-runtime-dependency-batch",
            "count": len(results),
            "queuedCount": len(
                [result for result in results if result.get("queued") is True]
            ),
            "results": results,
        }

    else:
        return {"success": False, "error": f"Unknown action: {action}"}


def main():
    rotate_log_if_needed()
    log_debug("Native host started")

    while True:
        message = read_message()

        if message is None:
            log_debug("No message received, exiting")
            break

        log_debug(f"Received: {message}")

        response = handle_message(message)

        log_debug(f"Sending: {response}")
        send_message(response)


if __name__ == "__main__":
    main()
