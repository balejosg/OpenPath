#!/usr/bin/env python3
"""Manage local OpenPath browser runtime dependency overlays."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


HOST_PATTERN = re.compile(
    r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"
)
SENSITIVE_FIELDS = {
    "url",
    "resourceUrl",
    "target_url",
    "targetUrl",
    "originUrl",
    "documentUrl",
    "pageUrl",
    "headers",
    "header",
    "body",
    "path",
    "query",
    "dom",
    "title",
    "referrer",
    "token",
    "authorization",
    "cookie",
    "cookies",
}


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def isoformat(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def split_hosts(value: str) -> list[str]:
    return [normalize_host(item) for item in value.split() if normalize_host(item)]


def normalize_host(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    normalized = value.strip().strip(".").lower()
    if normalized.endswith(".local"):
        return ""
    if len(normalized) < 4 or len(normalized) > 253:
        return ""
    if not HOST_PATTERN.match(normalized):
        return ""
    return normalized


def host_matches(host: str, domains: list[str]) -> bool:
    return any(host == domain or host.endswith(f".{domain}") for domain in domains)


def validate_candidate(
    entry: dict[str, Any],
    whitelist: list[str],
    protected_hosts: list[str],
    blocked_subdomains: list[str],
) -> tuple[bool, dict[str, str]]:
    if any(field in entry for field in SENSITIVE_FIELDS):
        return False, {}
    anchor_host = normalize_host(entry.get("anchorHost"))
    dependency_host = normalize_host(entry.get("dependencyHost"))
    request_type = str(entry.get("requestType", "")).strip().lower()
    if not anchor_host or not dependency_host or not request_type:
        return False, {}
    if request_type == "main_frame":
        return False, {}
    if anchor_host == dependency_host:
        return False, {}
    if not host_matches(anchor_host, whitelist):
        return False, {}
    if host_matches(anchor_host, protected_hosts) or host_matches(dependency_host, protected_hosts):
        return False, {}
    if host_matches(dependency_host, blocked_subdomains):
        return False, {}
    return True, {
        "anchorHost": anchor_host,
        "dependencyHost": dependency_host,
        "requestType": request_type,
    }


def load_overlay_document(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def load_overlay(path: Path) -> list[dict[str, Any]]:
    entries = load_overlay_document(path).get("entries", [])
    return [entry for entry in entries if isinstance(entry, dict)]


def read_generations(path: Path) -> tuple[int, int]:
    document = load_overlay_document(path)
    generation = document.get("generation", 0)
    applied_generation = document.get("appliedGeneration", 0)
    if not isinstance(generation, int) or isinstance(generation, bool):
        generation = 0
    if not isinstance(applied_generation, int) or isinstance(applied_generation, bool):
        applied_generation = 0
    return max(generation, 0), max(applied_generation, 0)


def entry_generation(entry: dict[str, Any]) -> int:
    """Returns the per-entry generation when present, else 0 (legacy entry)."""
    value = entry.get("generation")
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        return 0
    return value


def next_document_generation(entries: list[dict[str, Any]], previous_generation: int) -> int:
    """Document generation is the highest per-entry generation ever stamped."""
    return max([max(previous_generation, 0)] + [entry_generation(entry) for entry in entries])



def prune_entries(
    entries: list[dict[str, Any]],
    now: datetime,
    whitelist: list[str],
    protected_hosts: list[str],
    blocked_subdomains: list[str],
) -> list[dict[str, Any]]:
    pruned: list[dict[str, Any]] = []
    for entry in entries:
        expires_at = parse_time(entry.get("expiresAt"))
        if expires_at is None or expires_at <= now:
            continue
        valid, normalized = validate_candidate(
            {
                "anchorHost": entry.get("anchorHost"),
                "dependencyHost": entry.get("dependencyHost"),
                "requestType": (entry.get("requestTypes") or ["fetch"])[0],
            },
            whitelist,
            protected_hosts,
            blocked_subdomains,
        )
        if not valid:
            continue
        next_entry = dict(entry)
        next_entry["anchorHost"] = normalized["anchorHost"]
        next_entry["dependencyHost"] = normalized["dependencyHost"]
        pruned.append(next_entry)
    return pruned


def write_overlay(
    path: Path,
    entries: list[dict[str, Any]],
    now: datetime,
    generation: int,
    applied_generation: int,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "generation": max(generation, 0),
        "appliedGeneration": max(applied_generation, 0),
        "updatedAt": isoformat(now),
        "entries": entries,
    }
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        # The native messaging host polls this file as the interactive desktop
        # user; mkstemp creates it 0600, which would leave every runtime
        # dependency stuck `pending` because `appliedGeneration` is unreadable.
        # Widen the mode before the atomic replace.
        os.chmod(temp_name, 0o644)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def widen_overlay_permissions(path: Path) -> None:
    """Keep the overlay world-readable across upgrades and unchanged rewrites."""
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass


def command_update(args: argparse.Namespace) -> int:
    now = utc_now()
    ttl = timedelta(days=max(args.ttl_days, 1))
    whitelist = split_hosts(args.whitelist)
    protected_hosts = split_hosts(args.protected_hosts)
    blocked_subdomains = split_hosts(args.blocked_subdomains)
    overlay_path = Path(args.overlay)
    previous_generation, previous_applied = read_generations(overlay_path)
    entries = prune_entries(load_overlay(overlay_path), now, whitelist, protected_hosts, blocked_subdomains)
    by_key = {(entry["anchorHost"], entry["dependencyHost"]): entry for entry in entries}
    # Snapshot the pruned content before the merge loop mutates the entry dicts
    # in place. Taking it afterwards (the historical defect) made every
    # metadata-only refresh look like "unchanged", so the refreshed lastSeen /
    # expiresAt values were never persisted and entries expired early.
    before = json.dumps(entries, sort_keys=True)
    processed = 0
    rejected = 0

    with Path(args.requests).open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError:
                rejected += 1
                continue
            if not isinstance(request, dict):
                rejected += 1
                continue
            valid, normalized = validate_candidate(request, whitelist, protected_hosts, blocked_subdomains)
            if not valid:
                rejected += 1
                continue
            processed += 1
            key = (normalized["anchorHost"], normalized["dependencyHost"])
            existing = by_key.get(key)
            if existing is None:
                existing = {
                    "anchorHost": normalized["anchorHost"],
                    "dependencyHost": normalized["dependencyHost"],
                    "requestTypes": [],
                    "firstSeen": isoformat(now),
                    "source": "firefox-webrequest-local",
                }
                by_key[key] = existing
            request_types = set(existing.get("requestTypes") or [])
            request_types.add(normalized["requestType"])
            existing["requestTypes"] = sorted(request_types)
            existing["lastSeen"] = isoformat(now)
            existing["expiresAt"] = isoformat(now + ttl)

    # Per-entry generations: only facts that make a dependency newly resolvable
    # (a pair that was not in the pruned snapshot) move the document
    # generation. Metadata-only refreshes and prune rewrites keep it, so an
    # already-applied entry never falls back to "not ready" because another
    # entry is waiting to be applied.
    added_keys = [key for key in by_key if key not in {(entry.get("anchorHost"), entry.get("dependencyHost")) for entry in entries}]
    if added_keys:
        new_generation = previous_generation + 1
        for key in added_keys:
            by_key[key]["generation"] = new_generation

    next_entries = sorted(by_key.values(), key=lambda item: item.get("lastSeen", ""), reverse=True)[: args.capacity]
    after = json.dumps(next_entries, sort_keys=True)
    changed = before != after
    if changed or not overlay_path.exists():
        write_overlay(
            overlay_path,
            next_entries,
            now,
            next_document_generation(next_entries, previous_generation),
            previous_applied,
        )
    widen_overlay_permissions(overlay_path)
    print(f"processed={processed}")
    print(f"rejected={rejected}")
    print(f"changed={'true' if changed else 'false'}")
    return 0


def command_mark_applied(args: argparse.Namespace) -> int:
    overlay_path = Path(args.overlay)
    generation, applied_generation = read_generations(overlay_path)
    if generation <= 0 or applied_generation >= generation:
        widen_overlay_permissions(overlay_path)
        return 0
    entries = load_overlay(overlay_path)
    write_overlay(overlay_path, entries, utc_now(), generation, generation)
    widen_overlay_permissions(overlay_path)
    return 0


def command_domains(args: argparse.Namespace) -> int:
    now = utc_now()
    whitelist = split_hosts(args.whitelist)
    protected_hosts = split_hosts(args.protected_hosts)
    blocked_subdomains = split_hosts(args.blocked_subdomains)
    overlay_path = Path(args.overlay)
    existing_entries = load_overlay(overlay_path)
    entries = prune_entries(existing_entries, now, whitelist, protected_hosts, blocked_subdomains)
    if args.prune == "true" and json.dumps(entries, sort_keys=True) != json.dumps(existing_entries, sort_keys=True):
        # Pruning drops stale entries only; it never makes a remaining entry
        # newly resolvable, so the document generation must not move (that
        # would reopen the "not ready" window for already-applied entries).
        previous_generation, previous_applied = read_generations(overlay_path)
        write_overlay(
            overlay_path,
            entries,
            now,
            next_document_generation(entries, previous_generation),
            previous_applied,
        )
    for host in sorted({entry["dependencyHost"] for entry in entries}):
        print(host)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    update = subparsers.add_parser("update")
    update.add_argument("--overlay", required=True)
    update.add_argument("--requests", required=True)
    update.add_argument("--ttl-days", type=int, default=7)
    update.add_argument("--capacity", type=int, default=300)
    update.add_argument("--whitelist", default="")
    update.add_argument("--protected-hosts", default="")
    update.add_argument("--blocked-subdomains", default="")
    update.set_defaults(func=command_update)
    domains = subparsers.add_parser("domains")
    domains.add_argument("--overlay", required=True)
    domains.add_argument("--prune", choices=["true", "false"], default="false")
    domains.add_argument("--whitelist", default="")
    domains.add_argument("--protected-hosts", default="")
    domains.add_argument("--blocked-subdomains", default="")
    domains.set_defaults(func=command_domains)
    mark_applied = subparsers.add_parser("mark-applied")
    mark_applied.add_argument("--overlay", required=True)
    mark_applied.set_defaults(func=command_mark_applied)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
