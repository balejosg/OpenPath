#!/usr/bin/env python3
"""Generic multi-host first-visit fixture server (Phase 3A).

Serves, from one HTTP port and routed by Host header, the anchors and the
runtime dependency hosts for the site-agnostic first-visit lane:

  anchor page  -> blocking CSS (styles host), core <script> (core host),
                  web font with font-display:block (font host), image (image
                  host);
  wave 2       -> core.js injects a deferred <script> from the deferred host;
  wave 3       -> deferred.js fetches JSON from the api host and paints it.

Every hostname is random and unique per run (``<role><n>-<token>.<ip>.sslip.io``)
and learns nothing in advance: the dependency hosts are absent from the served
whitelist and resolve only once the product learns them.

The page self-reports its wave state (computed style, executed scripts, painted
API, font/image load, navigation type and reload count, timings from
navigationStart) to ``POST /__report`` on the anchor; the server records every
request and every report as JSONL so the lane can decide the verdict from the
self-report instead of MOZ_LOG heuristics.

Usage:
  fixture_server.py --state-dir DIR [--port 80] [--seed N] [--run-id X]
                    [--ip 192.168.1.150] [--token phase3a]
                    [--font /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf]

Routes:
  GET  /plan.json                deterministic run plan (hosts, roles, whitelist)
  GET  /state.json               requests count + last report
  GET  /whitelist.txt            served whitelist (also /w/<token>/whitelist.txt)
  POST /__report                 page self-report
  GET  /__ping                   liveness probe
  <anchor>/                      anchor page
  <role host>/<path>             wave assets
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import random
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLES = ("styles", "core", "deferred", "font", "image", "api")

PIXEL_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
    "890000000d49444154789c626001000000ffff03000006000557bfabd4000000"
    "0049454e44ae426082"
)


def build_plan(run_id: str, seed: int, ip: str, token: str) -> dict:
    rng = random.Random(seed)
    suffix = f"{ip}.sslip.io"

    def host(role: str, n: int) -> str:
        unique = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(6))
        return f"{role}{n}-{unique}.{suffix}"

    anchors = {}
    for index in (1, 2):
        role_hosts = {role: host(role, index) for role in ROLES}
        anchors[f"a{index}"] = {
            "host": host("anchor", index),
            "roles": role_hosts,
        }
    never_learnable = host("blocked", 9)
    unlisted = host("unlisted", 8)
    whitelist_hosts = [entry["host"] for entry in anchors.values()]
    control_dependencies = sorted(
        {role_host for entry in anchors.values() for role_host in entry["roles"].values()}
    )
    # Phase 5.2 E3: a blocked path on an *allowed* anchor. DNS cannot block
    # paths, so this signal isolates the host-driven path rules: with the native
    # host unavailable the extension loads no blocked-path rules and the probe
    # succeeds (fail open); with the healthy compiled host the fetch is
    # cancelled. The probe is a same-origin fetch (xmlhttprequest), one of the
    # request types background-path-rules.ts enforces.
    blocked_paths = [f"{entry['host']}/blocked-path/probe.bin" for entry in anchors.values()]
    return {
        "schemaVersion": 1,
        "runId": run_id,
        "seed": seed,
        "ip": ip,
        "token": token,
        "roles": list(ROLES),
        "anchors": anchors,
        "controlDependencies": control_dependencies,
        "neverLearnable": never_learnable,
        "unlisted": unlisted,
        "whitelistHosts": whitelist_hosts,
        "blockedSubdomains": [never_learnable],
        "blockedPaths": blocked_paths,
        "waveCriteria": {
            "wave1": ["cssApplied", "coreExecuted", "imageLoaded"],
            "wave2": ["deferredExecuted"],
            "wave3": ["apiPainted"],
        },
    }


def whitelist_body(plan: dict) -> str:
    lines = ["## WHITELIST"]
    lines.extend(plan["whitelistHosts"])
    lines.append("## BLOCKED-SUBDOMAINS")
    lines.extend(plan["blockedSubdomains"])
    lines.append("## BLOCKED-PATHS")
    lines.extend(plan.get("blockedPaths", []))
    return "\r\n".join(lines) + "\r\n"


def anchor_html(plan: dict, anchor_key: str) -> str:
    entry = plan["anchors"][anchor_key]
    roles = entry["roles"]
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>first-visit {anchor_key}</title>
<link rel="stylesheet" href="http://{roles['styles']}/first-visit.css">
<link rel="stylesheet" href="http://{plan['neverLearnable']}/never-learnable.css">
<script src="http://{roles['core']}/core.js"></script>
<style>
@font-face {{ font-family: 'fixture-font'; src: url('http://{roles['font']}/fixture-font.ttf'); font-display: block; }}
#probe {{ font-family: 'fixture-font', serif; }}
</style>
</head><body>
<h1 id="probe" class="probe">first-visit {anchor_key}</h1>
<img id="px" alt="" src="http://{roles['image']}/pixel.png" width="64" height="64">
<div id="api-out">pending</div>
<script>
window.__firstVisit = {{
  schemaVersion: 1,
  anchor: {json.dumps(anchor_key)},
  anchorHost: {json.dumps(entry['host'])},
  reportUrl: 'http://' + location.host + '/__report',
  roles: {json.dumps(roles)},
  blockedHost: {json.dumps(plan['neverLearnable'])},
  waves: {{ cssApplied: false, fontLoaded: false, imageLoaded: false, coreExecuted: false, deferredExecuted: false, apiPainted: false, blockedCssFailed: false }},
  blockedPath: {{ attempts: [], enforced: null, final: false }},
  marks: {{ start: 0, core: 0, deferred: 0, api: 0, load: 0 }},
  loads: 0
}};
(function () {{
  var fv = window.__firstVisit;
  fv.marks.start = performance.now();
  // Phase 5.2 E3: probe the blocked path on this allowed anchor. The request
  // type is enforced by background-path-rules.ts; only the native host can
  // supply the rules, so this is a generic host-driven path signal (DNS cannot
  // block paths). Three attempts settle the value; the report that carries
  // blockedPathFinal=true is the one the controller consumes.
  function probeBlockedPath() {{
    fetch('http://' + location.host + '/blocked-path/probe.bin?n=' + fv.blockedPath.attempts.length, {{ cache: 'no-store' }})
      .then(function () {{ fv.blockedPath.attempts.push({{ seq: fv.blockedPath.attempts.length + 1, blocked: false }}); }})
      .catch(function () {{ fv.blockedPath.attempts.push({{ seq: fv.blockedPath.attempts.length + 1, blocked: true }}); }})
      .then(function () {{
        if (fv.blockedPath.attempts.length >= 3) {{
          fv.blockedPath.enforced = fv.blockedPath.attempts[fv.blockedPath.attempts.length - 1].blocked;
          fv.blockedPath.final = true;
        }}
        send();
      }});
  }}
  // Hot-session scenario: the same page navigates to the second anchor after
  // the hot window, keeping the Firefox instance and the host process.
  try {{
    var params = new URLSearchParams(location.search);
    var hot = params.get('hot');
    var after = parseInt(params.get('after') || '0', 10);
    if (hot && after > 0) {{
      setTimeout(function () {{ location.href = 'http://' + hot + '/?from=hot'; }}, after);
    }}
  }} catch (e) {{}}
  try {{
    fv.loads = (parseInt(sessionStorage.getItem('firstVisitLoads') || '0', 10) || 0) + 1;
    sessionStorage.setItem('firstVisitLoads', String(fv.loads));
  }} catch (e) {{ fv.loads = 1; }}
  function resourceEnd(haystack) {{
    var entries = performance.getEntriesByType('resource') || [];
    for (var i = 0; i < entries.length; i++) {{
      if (entries[i].name.indexOf(haystack) !== -1) {{ return entries[i].responseEnd; }}
    }}
    return 0;
  }}
  function send() {{
    var payload = {{
      schemaVersion: 1,
      runId: {json.dumps(plan['runId'])},
      anchor: fv.anchor,
      anchorHost: fv.anchorHost,
      navigationType: (performance.getEntriesByType('navigation')[0] || {{}}).type || 'unknown',
      loads: fv.loads,
      ts: Date.now(),
      timeOrigin: performance.timeOrigin,
      waves: fv.waves,
      blockedPathEnforced: fv.blockedPath.final ? fv.blockedPath.enforced : null,
      blockedPathFinal: fv.blockedPath.final,
      blockedPathAttempts: fv.blockedPath.attempts,
      marks: fv.marks,
      timings: {{
        start: fv.marks.start,
        cssDone: resourceEnd('first-visit.css'),
        coreDone: fv.marks.core,
        deferredDone: fv.marks.deferred,
        apiDone: fv.marks.api,
        imageDone: resourceEnd('pixel.png'),
        fontDone: resourceEnd('fixture-font.ttf'),
        load: fv.marks.load
      }},
      href: location.href
    }};
    try {{
      fetch(fv.reportUrl, {{ method: 'POST', headers: {{ 'Content-Type': 'application/json' }}, body: JSON.stringify(payload), keepalive: true }});
    }} catch (e) {{}}
  }}
  window.__firstVisitSend = send;
  probeBlockedPath();
  setTimeout(probeBlockedPath, 2000);
  setTimeout(probeBlockedPath, 4000);
  var probe = document.getElementById('probe');
  var px = document.getElementById('px');
  window.addEventListener('load', function () {{
    fv.marks.load = performance.now();
    fv.waves.cssApplied = getComputedStyle(probe).backgroundColor === 'rgb(1, 2, 3)';
    fv.waves.imageLoaded = !!(px && px.complete && px.naturalWidth > 0);
    // The never-learnable CSS sets a distinctive letter-spacing; the wave is
    // only 'blocked' when that external stylesheet did NOT apply. A comment-only
    // stylesheet (or a flag set by a script that the page never loads) would
    // make the previous check trivially true (Phase 5 A1).
    fv.waves.blockedCssFailed = getComputedStyle(probe).letterSpacing !== '7px';
    if (document.fonts && document.fonts.check) {{
      document.fonts.check("12px 'fixture-font'").valueOf();
      document.fonts.load("12px 'fixture-font'").then(function () {{
        fv.waves.fontLoaded = document.fonts.check("12px 'fixture-font'");
        send();
      }}).catch(function () {{ fv.waves.fontLoaded = false; send(); }});
    }} else {{
      send();
    }}
    send();
    setTimeout(send, 3000);
    setTimeout(send, 10000);
  }});
}})();
</script>
</body></html>
"""


CORE_JS = """/* wave 2: the core script injects the deferred script from another host */
(function () {
  window.__firstVisit.waves.coreExecuted = true;
  window.__firstVisit.marks.core = performance.now();
  var deferred = document.createElement('script');
  deferred.src = 'http://' + window.__firstVisit.roles.deferred + '/deferred.js';
  document.head.appendChild(deferred);
  window.__firstVisitSend();
})();
"""

DEFERRED_JS = """/* wave 3: the deferred script fetches the API host and paints the result */
(async function () {
  var fv = window.__firstVisit;
  fv.waves.deferredExecuted = true;
  fv.marks.deferred = performance.now();
  try {
    var response = await fetch('http://' + fv.roles.api + '/api.json', { cache: 'no-store' });
    var data = await response.json();
    document.getElementById('api-out').textContent = 'api:' + data.payload;
    fv.waves.apiPainted = true;
    fv.marks.api = performance.now();
  } catch (error) {
    fv.waves.apiPainted = false;
  }
  fv.waves.blockedCssFailed = getComputedStyle(document.getElementById('probe')).letterSpacing !== '7px';
  fv.waves.cssApplied = getComputedStyle(document.getElementById('probe')).backgroundColor === 'rgb(1, 2, 3)';
  var deferredImage = document.getElementById('px');
  fv.waves.imageLoaded = !!(deferredImage && deferredImage.complete && deferredImage.naturalWidth > 0);
  fv.waves.fontLoaded = document.fonts && document.fonts.check ? document.fonts.check("12px 'fixture-font'") : false;
  fv.waves.coreExecuted = true;
  fv.marks.load = performance.now();
  window.__firstVisitSend();
})();
"""

NEVER_LEARNABLE_CSS = (
    "/* This host is in BLOCKED-SUBDOMAINS and must never be learned. */\n"
    "/* A distinctive rule the page can measure: applying it means the block failed. */\n"
    "#probe { letter-spacing: 7px; }\n"
)
NEVER_LEARNABLE_JS = "window.__neverLearnableLoaded = true;\n"


class FixtureState:
    def __init__(self, state_dir: pathlib.Path, plan: dict, font_path: str) -> None:
        self.state_dir = state_dir
        self.plan = plan
        self.font_path = font_path
        self.lock = threading.Lock()
        self.requests = 0
        self.browser_requests = 0
        self.last_report = None
        self.started_at = time.time()
        # Phase 3A.2: the warm-up verification reads the managed-extension fetch
        # from here (one host clock) instead of inferring it from the browser.
        self.xpi_fetches = 0
        self.xpi_last_fetched_at = 0.0
        self.xpi_last_path = ""
        state_dir.mkdir(parents=True, exist_ok=True)
        self.requests_path = state_dir / "requests.jsonl"
        self.reports_path = state_dir / "reports.jsonl"
        (state_dir / "plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
        (state_dir / "whitelist.txt").write_text(whitelist_body(plan), encoding="utf-8")
        self.whitelist_sha256 = hashlib.sha256(whitelist_body(plan).encode("utf-8")).hexdigest()

    def log_request(self, entry: dict) -> None:
        with self.lock:
            self.requests += 1
            note = str(entry.get("note") or "")
            if note.startswith("anchor=") or note.startswith("wave"):
                # Only a browser fetching page content counts here: the lane's
                # plan/state curls and the agent's whitelist bootstrap do not.
                self.browser_requests += 1
            if note.startswith("xpi-served"):
                self.xpi_fetches += 1
                self.xpi_last_fetched_at = float(entry.get("ts") or 0.0)
                self.xpi_last_path = str(entry.get("path") or "")
            with self.requests_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry) + "\n")

    def log_report(self, report: object) -> None:
        with self.lock:
            self.last_report = report
            with self.reports_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(report) + "\n")
            (self.state_dir / "last_report.json").write_text(
                json.dumps(report, indent=2) + "\n", encoding="utf-8"
            )


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "OpenPathFirstVisitFixture/1.0"

    def log_message(self, fmt: str, *args) -> None:  # keep stderr quiet; JSONL is the log
        return

    @property
    def state(self) -> FixtureState:
        return self.server.state  # type: ignore[attr-defined]

    def _host_name(self) -> str:
        host = (self.headers.get("Host") or "").split(":")[0].strip().lower()
        return host

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload: object) -> None:
        self._send(status, json.dumps(payload).encode("utf-8"), "application/json")

    def _finish(self, status: int, path: str, note: str = "") -> None:
        self.state.log_request(
            {
                "ts": time.time(),
                "host": self._host_name(),
                "path": path,
                "method": self.command,
                "status": status,
                "note": note,
            }
        )

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        host = self._host_name()
        plan = self.state.plan

        if path == "/api/extensions/firefox/openpath.xpi":
            # The managed API path the production agent policy points Firefox
            # at. The fixture serves the exact signed XPI of the template (the
            # guest stages the installed copy via POST /xpi); no other path
            # serves extension bytes.
            target = self.state.state_dir / "openpath-firefox-extension.xpi"
            if target.exists():
                body = target.read_bytes()
                self._send(200, body, "application/x-xpinstall")
                self._finish(200, path, "xpi-served bytes=" + str(len(body)))
                return
            self._send(404, b"xpi not staged", "text/plain")
            self._finish(404, path)
            return
        if path == "/__ping":
            self._json(200, {"ok": True, "runId": plan["runId"], "host": host})
            self._finish(200, path)
            return
        if path == "/plan.json":
            self._json(200, plan)
            self._finish(200, path)
            return
        if path == "/state.json":
            self._json(
                200,
                {
                    "runId": plan["runId"],
                    "serverNow": time.time(),
                    "requests": self.state.requests,
                    "browserRequests": self.state.browser_requests,
                    "lastReport": self.state.last_report,
                    "whitelistSha256": self.state.whitelist_sha256,
                    "xpi": {
                        "count": self.state.xpi_fetches,
                        "lastFetchedAt": self.state.xpi_last_fetched_at,
                        "lastPath": self.state.xpi_last_path,
                    },
                },
            )
            self._finish(200, path)
            return
        if path == "/whitelist.txt" or re.match(r"^/w/[^/]+/whitelist\.txt$", path):
            body = whitelist_body(plan).encode("utf-8")
            self._send(200, body, "text/plain; charset=utf-8")
            self._finish(200, path, "sha256=" + self.state.whitelist_sha256)
            return

        anchor_match = next(
            (key for key, entry in plan["anchors"].items() if entry["host"] == host), None
        )
        if anchor_match is not None:
            if path in ("/", "/index.html"):
                self._send(200, anchor_html(plan, anchor_match).encode("utf-8"), "text/html; charset=utf-8")
                self._finish(200, path, f"anchor={anchor_match}")
                return
            if path == "/favicon.ico":
                self._send(204, b"", "image/x-icon")
                self._finish(204, path)
                return
            if path == "/blocked-path/probe.bin":
                # Served so an unenforced (host-less) fetch succeeds; the
                # extension cancels it when the blocked-path rules are loaded.
                self._send(200, PIXEL_PNG, "application/octet-stream")
                self._finish(200, path, "blocked-path-probe")
                return
            self._send(404, b"anchor: not found", "text/plain")
            self._finish(404, path)
            return

        if host == plan["neverLearnable"]:
            if path == "/never-learnable.css":
                self._send(200, NEVER_LEARNABLE_CSS.encode("utf-8"), "text/css; charset=utf-8")
                self._finish(200, path, "never-learnable-requested")
                return
            if path == "/never-learnable.js":
                self._send(200, NEVER_LEARNABLE_JS.encode("utf-8"), "application/javascript")
                self._finish(200, path, "never-learnable-requested")
                return
            self._send(404, b"never-learnable", "text/plain")
            self._finish(404, path)
            return

        for entry in plan["anchors"].values():
            roles = entry["roles"]
            if host == roles["styles"] and path == "/first-visit.css":
                body = (
                    "#probe { background-color: rgb(1, 2, 3); }\n"
                    "body { margin: 24px; font-family: sans-serif; }\n"
                ).encode("utf-8")
                self._send(200, body, "text/css; charset=utf-8")
                self._finish(200, path, "wave1-styles")
                return
            if host == roles["core"] and path == "/core.js":
                self._send(200, CORE_JS.encode("utf-8"), "application/javascript")
                self._finish(200, path, "wave1-core")
                return
            if host == roles["deferred"] and path == "/deferred.js":
                self._send(200, DEFERRED_JS.encode("utf-8"), "application/javascript")
                self._finish(200, path, "wave2-deferred")
                return
            if host == roles["font"] and path == "/fixture-font.ttf":
                font = pathlib.Path(self.state.font_path)
                if font.is_file():
                    self._send(200, font.read_bytes(), "font/ttf")
                    self._finish(200, path, "wave1-font")
                else:
                    self._send(503, b"font unavailable", "text/plain")
                    self._finish(503, path, "font-missing")
                return
            if host == roles["image"] and path == "/pixel.png":
                self._send(200, PIXEL_PNG, "image/png")
                self._finish(200, path, "wave1-image")
                return
            if host == roles["api"] and path == "/api.json":
                self._json(200, {"payload": "wave3", "ts": time.time()})
                self._finish(200, path, "wave3-api")
                return

        self._send(404, b"fixture: unknown host or path", "text/plain")
        self._finish(404, path, "unexpected")

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if path == "/xpi":
            if not body:
                self._send(400, b"empty xpi", "text/plain")
                self._finish(400, path)
                return
            target = self.state.state_dir / "openpath-firefox-extension.xpi"
            target.write_bytes(body)
            digest = hashlib.sha256(body).hexdigest()
            self._json(200, {"ok": True, "bytes": len(body), "sha256": digest})
            self._finish(200, path, "bytes=" + str(len(body)) + " sha256=" + digest)
            return
        if path != "/__report":
            self._send(404, b"fixture: unknown post", "text/plain")
            self._finish(404, path)
            return
        try:
            report = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            report = {"parseError": True, "rawLength": len(body)}
        self.state.log_report(report)
        self._send(204, b"", "text/plain")
        self._finish(204, path, "report")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--run-id", default=os.environ.get("OPENPATH_FIRST_VISIT_RUN_ID", "local"))
    parser.add_argument("--ip", default=os.environ.get("OPENPATH_FIRST_VISIT_IP", "192.168.1.150"))
    parser.add_argument("--token", default="phase3a")
    parser.add_argument(
        "--font",
        default="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    )
    args = parser.parse_args()

    seed = args.seed if args.seed is not None else int(time.time() * 1000) % 2_000_000_000
    plan = build_plan(args.run_id, seed, args.ip, args.token)
    state = FixtureState(pathlib.Path(args.state_dir), plan, args.font)
    server = ThreadingHTTPServer((args.listen, args.port), FixtureHandler)
    server.state = state  # type: ignore[attr-defined]
    print(json.dumps({"listening": f"{args.listen}:{args.port}", "plan": plan}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
