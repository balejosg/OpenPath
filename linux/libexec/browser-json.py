#!/usr/bin/env python3

import argparse
import json
import os
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse


def load_json_file(path: Path, default: dict, warn_prefix: str | None = None) -> dict:
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception as exc:
            if warn_prefix:
                print(f"{warn_prefix}: {exc}", file=sys.stderr)
    return dict(default)


def save_json_file(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def env_blocked_paths() -> list[str]:
    return [
        line.strip()
        for line in os.environ.get("OPENPATH_BLOCKED_PATHS", "").splitlines()
        if line.strip()
    ]


def get_browser_policy_spec_path() -> Path:
    override_path = os.environ.get("OPENPATH_BROWSER_POLICY_SPEC", "").strip()
    if override_path:
        return Path(override_path)

    installed_path = Path(__file__).resolve().with_name("browser-policy-spec.json")
    if installed_path.is_file():
        return installed_path

    source_tree_path = Path(__file__).resolve().parents[2] / "runtime" / "browser-policy-spec.json"
    if source_tree_path.is_file():
        return source_tree_path

    raise FileNotFoundError("Browser policy spec not found")


def load_browser_policy_spec() -> dict:
    return json.loads(get_browser_policy_spec_path().read_text(encoding="utf-8"))


def normalize_firefox_path(path: str) -> str:
    clean = path
    for prefix in ("http://", "https://", "*://"):
        if clean.startswith(prefix):
            clean = clean[len(prefix) :]
            break

    if "/" not in clean and "." not in clean and "*" not in clean:
        clean = f"*{clean}*"
    elif not clean.endswith("*"):
        clean = f"{clean}*"

    if clean.startswith("*."):
        return f"*://{clean}"
    if clean.startswith("*/"):
        return f"*://*{clean[1:]}"
    if "." in clean and "/" in clean:
        return f"*://*.{clean}"
    return f"*://{clean}"


def normalize_chromium_path(path: str) -> str:
    clean = path
    for prefix in ("http://", "https://", "*://"):
        if clean.startswith(prefix):
            clean = clean[len(prefix) :]
            break
    if not clean.endswith("*"):
        clean = f"{clean}*"
    return clean


def emit_firefox_policy_contract(
    extension_id: str, install_entry: str, install_url: str, source: str
) -> int:
    print(f"extension_id={extension_id}")
    print(f"install_entry={install_entry}")
    print(f"install_url={install_url}")
    print(f"source={source}")
    return 0


def cmd_read_json_field(args: argparse.Namespace) -> int:
    json_path = Path(args.json_file)
    try:
        payload = json.loads(json_path.read_text(encoding="utf-8"))
    except Exception:
        return 1

    field_value = str(payload.get(args.field, "")).strip()
    if not field_value:
        return 2

    print(field_value)
    return 0


def cmd_read_firefox_managed_install_url(args: argparse.Namespace) -> int:
    policies_path = Path(args.policies_file)
    extension_id = str(args.extension_id or "").strip()
    if not extension_id:
        return 2

    try:
        policies = json.loads(policies_path.read_text(encoding="utf-8"))
    except Exception:
        return 1

    policy_root = policies.get("policies")
    if not isinstance(policy_root, dict):
        return 2

    extension_settings = policy_root.get("ExtensionSettings")
    if not isinstance(extension_settings, dict):
        return 2

    managed_entry = extension_settings.get(extension_id)
    if not isinstance(managed_entry, dict):
        return 2

    install_url = str(managed_entry.get("install_url", "")).strip()
    if not install_url:
        return 2

    print(install_url)
    return 0


def cmd_read_firefox_local_install_entry(args: argparse.Namespace) -> int:
    policies_path = Path(args.policies_file)
    extension_id = str(args.extension_id or "").strip()
    if not extension_id:
        return 2

    try:
        policies = json.loads(policies_path.read_text(encoding="utf-8"))
    except Exception:
        return 1

    policy_root = policies.get("policies")
    if not isinstance(policy_root, dict):
        return 2

    extensions = policy_root.get("Extensions")
    if not isinstance(extensions, dict):
        return 2

    installs = extensions.get("Install", [])
    if not isinstance(installs, list):
        return 2

    for entry in installs:
        install_entry = str(entry or "").strip()
        if install_entry and extension_id in install_entry and Path(install_entry).is_absolute():
            print(install_entry)
            return 0

    return 2


def cmd_resolve_firefox_release_policy(args: argparse.Namespace) -> int:
    release_dir = Path(args.release_dir)
    metadata_path = release_dir / "metadata.json"
    signed_xpi_path = release_dir / "openpath-firefox-extension.xpi"

    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except Exception:
        return 1

    extension_id = str(metadata.get("extensionId", "")).strip()
    if not extension_id:
        return 2

    if signed_xpi_path.is_file():
        return emit_firefox_policy_contract(
            extension_id=extension_id,
            install_entry=str(signed_xpi_path.resolve()),
            install_url=signed_xpi_path.resolve().as_uri(),
            source="staged-release",
        )

    return 3


def cmd_mutate_firefox_policies(args: argparse.Namespace) -> int:
    policies_file = Path(args.policies_file)
    action = args.action
    ext_id = (args.extension_id or "").strip()
    install_entry = (args.install_entry or "").strip()
    install_url = (args.install_url or "").strip()

    policies = load_json_file(
        policies_file,
        {"policies": {}},
        warn_prefix="Warning: Failed to read existing policies",
    )
    policy_root = policies.get("policies")
    if not isinstance(policy_root, dict):
        policy_root = {}
        policies["policies"] = policy_root

    if action == "ensure_managed_extension":
        if not ext_id or not install_url:
            return 1

        extension_settings = policy_root.setdefault("ExtensionSettings", {})
        previous_entry = extension_settings.get(ext_id)
        extension_settings[ext_id] = {
            "installation_mode": "force_installed",
            "install_url": install_url,
        }

        extensions = policy_root.setdefault("Extensions", {})
        installs = extensions.setdefault("Install", [])
        install_targets: set[str] = set()
        if isinstance(previous_entry, dict):
            previous_install_url = previous_entry.get("install_url")
            if isinstance(previous_install_url, str) and previous_install_url:
                install_targets.add(previous_install_url)
                parsed = urlparse(previous_install_url)
                if parsed.scheme == "file":
                    try:
                        install_targets.add(unquote(parsed.path))
                    except Exception:
                        pass

        if isinstance(installs, list):
            installs = [
                item
                for item in installs
                if item not in install_targets and item != ext_id and ext_id not in str(item)
            ]
            if installs:
                extensions["Install"] = installs
            else:
                extensions.pop("Install", None)

        locked = extensions.setdefault("Locked", [])
        if ext_id not in locked:
            locked.append(ext_id)

        print(f"Extension {ext_id} added to policies")
    elif action == "remove_managed_extension":
        extension_settings = policy_root.get("ExtensionSettings", {})
        managed_entry = extension_settings.pop(ext_id, None)
        if not extension_settings:
            policy_root.pop("ExtensionSettings", None)

        install_targets: set[str] = set()
        if isinstance(managed_entry, dict):
            managed_url = managed_entry.get("install_url")
            if isinstance(managed_url, str) and managed_url:
                install_targets.add(managed_url)

        extensions = policy_root.get("Extensions")
        if isinstance(extensions, dict):
            installs = extensions.get("Install", [])
            if isinstance(installs, list):
                extensions["Install"] = [
                    item
                    for item in installs
                    if item not in install_targets and item != ext_id and ext_id not in item
                ]
                if not extensions["Install"]:
                    extensions.pop("Install", None)

            locked = extensions.get("Locked", [])
            if isinstance(locked, list):
                extensions["Locked"] = [item for item in locked if item != ext_id]
                if not extensions["Locked"]:
                    extensions.pop("Locked", None)

            if not extensions:
                policy_root.pop("Extensions", None)
    else:
        raise SystemExit(f"Unsupported Firefox policy action: {action}")

    save_json_file(policies_file, policies)
    return 0


def cmd_write_chromium_policy(args: argparse.Namespace) -> int:
    output_path = Path(args.output)
    blocked_paths = env_blocked_paths()
    spec = load_browser_policy_spec()
    chromium_spec = spec.get("chromium", {})
    google_search_block = chromium_spec.get("googleSearchBlock", "*://www.google.*/search*")
    google_game_blocks = chromium_spec.get(
        "googleGameBlocks",
        [
            "*://www.google.*/fbx?fbx=snake_arcade*",
            "*://doodles.google/*",
            "*://*.doodles.google/*",
            "*://www.google.*/logos/*",
        ],
    )
    policy = {
        "URLBlocklist": [
            *[normalize_chromium_path(path) for path in blocked_paths],
            str(google_search_block),
            *[str(path) for path in google_game_blocks if str(path).strip()],
        ]
    }
    save_json_file(output_path, policy)
    return 0


def cmd_rewrite_chromium_manifest(args: argparse.Namespace) -> int:
    source_manifest = Path(args.source_manifest)
    target_manifest = Path(args.target_manifest)

    with source_manifest.open("r", encoding="utf-8") as fh:
        manifest = json.load(fh)

    manifest.pop("browser_specific_settings", None)
    manifest["background"] = {
        "service_worker": "dist/background.js",
        "type": "module",
    }

    save_json_file(target_manifest, manifest)
    return 0


def cmd_get_extension_version(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    with manifest_path.open("r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    print(manifest.get("version", "0.0.0"))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    read_field = subparsers.add_parser("read-json-field")
    read_field.add_argument("--json-file", required=True)
    read_field.add_argument("--field", required=True)
    read_field.set_defaults(func=cmd_read_json_field)

    managed_install_url = subparsers.add_parser("read-firefox-managed-install-url")
    managed_install_url.add_argument("--policies-file", required=True)
    managed_install_url.add_argument("--extension-id", required=True)
    managed_install_url.set_defaults(func=cmd_read_firefox_managed_install_url)

    local_install_entry = subparsers.add_parser("read-firefox-local-install-entry")
    local_install_entry.add_argument("--policies-file", required=True)
    local_install_entry.add_argument("--extension-id", required=True)
    local_install_entry.set_defaults(func=cmd_read_firefox_local_install_entry)

    release_policy = subparsers.add_parser("resolve-firefox-release-policy")
    release_policy.add_argument("--release-dir", required=True)
    release_policy.set_defaults(func=cmd_resolve_firefox_release_policy)

    mutate_firefox = subparsers.add_parser("mutate-firefox-policies")
    mutate_firefox.add_argument("--policies-file", required=True)
    mutate_firefox.add_argument("--action", required=True)
    mutate_firefox.add_argument("--extension-id")
    mutate_firefox.add_argument("--install-entry")
    mutate_firefox.add_argument("--install-url")
    mutate_firefox.set_defaults(func=cmd_mutate_firefox_policies)

    chromium_policy = subparsers.add_parser("write-chromium-policy")
    chromium_policy.add_argument("--output", required=True)
    chromium_policy.set_defaults(func=cmd_write_chromium_policy)

    rewrite_manifest = subparsers.add_parser("rewrite-chromium-manifest")
    rewrite_manifest.add_argument("--source-manifest", required=True)
    rewrite_manifest.add_argument("--target-manifest", required=True)
    rewrite_manifest.set_defaults(func=cmd_rewrite_chromium_manifest)

    extension_version = subparsers.add_parser("get-extension-version")
    extension_version.add_argument("--manifest", required=True)
    extension_version.set_defaults(func=cmd_get_extension_version)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
