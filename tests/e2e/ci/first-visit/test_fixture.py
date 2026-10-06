#!/usr/bin/env python3
"""Unit tests for the Phase 3A first-visit fixture (server + DNS helpers).

Run directly (``python3 test_fixture.py``) or through unittest discovery. No
network configuration is touched: the HTTP fixture binds an ephemeral local
port and the DNS assertions only exercise the pure packet helpers.
"""

from __future__ import annotations

import importlib.util
import hashlib
import json
import pathlib
import re
import socket
import sys
import tempfile
import threading
import time
import unittest
import zlib
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent


def load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


fixture_server = load("fixture_server", HERE / "fixture_server.py")
dns_fixture = load("dns_fixture", HERE / "dns_fixture.py")


class PlanTests(unittest.TestCase):
    def test_plan_hosts_are_unique_random_and_whitelist_ready(self) -> None:
        plan = fixture_server.build_plan("run-1", seed=1234, ip="192.168.1.150", token="phase3a")
        hosts = [plan["neverLearnable"], plan["unlisted"]] + plan["whitelistHosts"]
        hosts += [host for entry in plan["anchors"].values() for host in entry["roles"].values()]
        self.assertEqual(len(hosts), len(set(hosts)), "every fixture host must be unique")
        for host in hosts:
            self.assertTrue(host.endswith(".192.168.1.150.sslip.io"), host)
            self.assertRegex(host, r"^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+$")
        self.assertEqual(set(plan["anchors"]["a1"]["roles"]), set(fixture_server.ROLES))
        self.assertEqual(len(plan["controlDependencies"]), 12)

    def test_plan_is_deterministic_per_seed(self) -> None:
        first = fixture_server.build_plan("run-1", seed=42, ip="192.168.1.150", token="t")
        second = fixture_server.build_plan("run-1", seed=42, ip="192.168.1.150", token="t")
        third = fixture_server.build_plan("run-1", seed=43, ip="192.168.1.150", token="t")
        self.assertEqual(first, second)
        self.assertNotEqual(first["anchors"], third["anchors"])

    def test_whitelist_lists_both_anchors_and_blocks_the_never_learnable_host(self) -> None:
        plan = fixture_server.build_plan("run-2", seed=7, ip="192.168.1.150", token="t")
        body = fixture_server.whitelist_body(plan)
        self.assertIn("## WHITELIST", body)
        self.assertIn(plan["anchors"]["a1"]["host"], body)
        self.assertIn(plan["anchors"]["a2"]["host"], body)
        self.assertIn("## BLOCKED-SUBDOMAINS", body)
        self.assertIn(plan["neverLearnable"], body)
        for dependency in plan["controlDependencies"]:
            self.assertNotIn(dependency, body)

    def test_whitelist_carries_a_blocked_path_on_each_allowed_anchor(self) -> None:
        # Phase 5.2 E3: DNS cannot block paths; the blocked path on an allowed
        # anchor only takes effect through the host-driven path rules.
        plan = fixture_server.build_plan("run-3", seed=11, ip="192.168.1.150", token="t")
        self.assertEqual(len(plan["blockedPaths"]), 2)
        for entry in plan["anchors"].values():
            self.assertTrue(
                any(rule.startswith(f"{entry['host']}/blocked-path/probe.bin") for rule in plan["blockedPaths"])
            )
        body = fixture_server.whitelist_body(plan)
        self.assertIn("## BLOCKED-PATHS", body)
        for rule in plan["blockedPaths"]:
            self.assertIn(rule, body)

    def test_floor_whitelists_every_dependency_host(self) -> None:
        # Phase 5.3 B4: the floor is an environment control; it serves the
        # anchors plus every dependency host so the three waves must load.
        floor = fixture_server.build_plan("unit-run", 42, "192.168.1.150", "unit-token", "floor")
        self.assertTrue(floor["floorMode"])
        floor_body = fixture_server.whitelist_body(floor)
        self.assertEqual(floor_body.splitlines()[0], "## WHITELIST")
        for host in floor["controlDependencies"]:
            self.assertIn(host, floor_body)
        # The measurement scenarios keep the dependencies out (learning is the
        # signal the lane exists to capture).
        settled = fixture_server.build_plan("unit-run", 42, "192.168.1.150", "unit-token", "settled")
        self.assertFalse(settled["floorMode"])
        settled_body = fixture_server.whitelist_body(settled)
        for host in settled["controlDependencies"]:
            self.assertNotIn(host, settled_body)

    def test_site_plan_uses_the_real_url_and_serves_only_its_domains(self) -> None:
        # Phase 6 C: the canary anchor is the real URL and the served whitelist
        # carries only the requested domains (the real site learns its CDNs).
        plan = fixture_server.build_plan(
            "unit-run",
            42,
            "192.168.1.150",
            "unit-token",
            "site",
            "https://www.reddit.com/",
            ["reddit.com"],
        )
        self.assertTrue(plan["siteMode"])
        self.assertEqual(plan["siteUrl"], "https://www.reddit.com/")
        self.assertEqual(plan["anchors"]["a1"]["url"], "https://www.reddit.com/")
        self.assertEqual(plan["anchors"]["a1"]["host"], "www.reddit.com")
        self.assertEqual(plan["controlDependencies"], [])
        self.assertEqual(plan["blockedSubdomains"], [])
        body = fixture_server.whitelist_body(plan)
        self.assertIn("reddit.com", body)
        self.assertNotIn(".sslip.io", body)
        self.assertNotIn("## BLOCKED-SUBDOMAINS\r\nblocked", body)
        # No site_url is an input error, never a silent fixture plan.
        with self.assertRaises(ValueError):
            fixture_server.build_plan("unit-run", 42, "192.168.1.150", "t", "site", "", [])
        # Without an explicit domain list the host is the only served domain.
        defaulted = fixture_server.build_plan(
            "unit-run", 42, "192.168.1.150", "t", "site", "https://example.invalid/app", []
        )
        self.assertEqual(defaulted["whitelistHosts"], ["example.invalid"])


class FixtureServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix="first-visit-fixture-")
        cls.state_dir = pathlib.Path(cls.temp.name)
        plan = fixture_server.build_plan("unit-run", seed=99, ip="192.168.1.150", token="t")
        state = fixture_server.FixtureState(cls.state_dir, plan, "/nonexistent-font.ttf")
        cls.plan = plan
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        cls.server = fixture_server.ThreadingHTTPServer(("127.0.0.1", port), fixture_server.FixtureHandler)
        cls.server.state = state
        cls.port = port
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        time.sleep(0.1)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.temp.cleanup()

    def fetch(self, host: str, path: str) -> tuple[int, bytes]:
        status, body, _headers = self.fetch_with_headers(host, path)
        return status, body

    def fetch_with_headers(self, host: str, path: str) -> tuple[int, bytes, object]:
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}")
        request.add_header("Host", host)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:  # type: ignore[attr-defined]
            return error.code, error.read(), error.headers

    def test_anchor_page_embeds_the_run_hosts_and_waves(self) -> None:
        host = self.plan["anchors"]["a1"]["host"]
        status, body = self.fetch(host, "/")
        self.assertEqual(status, 200)
        text = body.decode("utf-8")
        roles = self.plan["anchors"]["a1"]["roles"]
        for role in ("styles", "core", "font", "image"):
            self.assertIn(roles[role], text)
        self.assertIn("__firstVisit", text)
        self.assertIn("/__report", text)
        self.assertIn(self.plan["neverLearnable"], text)
        # Phase 5.2 E3: the page probes the blocked path and reports the final
        # value for the controller verdict.
        self.assertIn("/blocked-path/probe.bin", text)
        self.assertIn("blockedPathEnforced", text)
        self.assertIn("blockedPathFinal", text)
        # Phase 5.3 B3: the fixture behaves like a real SPA that does not
        # recover on its own. The push-3 learning nudge and the 20 s repair
        # reload changed what the lane measures and are reverted.
        self.assertNotIn("learningNudge", text)
        self.assertNotIn("firstVisitRecovery", text)
        self.assertNotIn("location.reload()", text)


    def test_anchor_initializes_state_before_the_synchronous_core_script(self) -> None:
        # Phase 5.3 P2: core.js runs synchronously in <head>; __firstVisit must
        # already exist or its first line throws and waves 1-2 never happen.
        host = self.plan["anchors"]["a1"]["host"]
        status, body = self.fetch(host, "/")
        self.assertEqual(status, 200)
        text = body.decode("utf-8")
        init_index = text.index("window.__firstVisit = {")
        core_index = text.index("/core.js")
        self.assertLess(init_index, core_index, "the state init must precede core.js")
        # The DOM-dependent half stays after the body elements exist.
        self.assertGreater(text.index("getElementById('probe')"), text.index("<body>"))

    def test_dependency_responses_carry_cors_headers(self) -> None:
        # Phase 5.3 P2: a real CDN sends Access-Control-Allow-Origin. Without it
        # the api.json fetch (wave 3) and the cross-origin font always failed.
        roles = self.plan["anchors"]["a1"]["roles"]
        for host, path in (
            (roles["core"], "/core.js"),
            (roles["deferred"], "/deferred.js"),
            (roles["api"], "/api.json"),
            (roles["font"], "/fixture-font.ttf"),
            (roles["styles"], "/first-visit.css"),
        ):
            status, _body, headers = self.fetch_with_headers(host, path)
            self.assertIn(status, (200, 503), f"{path} status")
            self.assertEqual(
                headers.get("Access-Control-Allow-Origin"),
                "*",
                f"{path} must carry Access-Control-Allow-Origin",
            )


    def test_pixel_asset_is_a_valid_png(self) -> None:
        # Phase 5.3 P2: the previous pixel had a bad IDAT CRC and a truncated
        # stream; Firefox decoded it as complete with naturalWidth=0.
        data = fixture_server.PIXEL_PNG
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        pos = 8
        saw_end = False
        while pos + 12 <= len(data):
            length = int.from_bytes(data[pos : pos + 4], "big")
            ctype = data[pos + 4 : pos + 8]
            chunk = data[pos + 8 : pos + 8 + length]
            crc = int.from_bytes(data[pos + 8 + length : pos + 12 + length], "big")
            self.assertEqual(crc, zlib.crc32(ctype + chunk) & 0xFFFFFFFF, ctype)
            pos += 12 + length
            if ctype == b"IEND":
                saw_end = True
                break
        self.assertTrue(saw_end)
        self.assertEqual(pos, len(data))

    def test_blocked_path_probe_is_served_so_only_enforcement_can_stop_it(self) -> None:
        host = self.plan["anchors"]["a1"]["host"]
        status, body = self.fetch(host, "/blocked-path/probe.bin")
        self.assertEqual(status, 200, "without host enforcement the probe must load")
        self.assertGreater(len(body), 0)

    def test_wave_assets_are_served_per_host(self) -> None:
        roles = self.plan["anchors"]["a2"]["roles"]
        for role, path, needle in (
            ("styles", "/first-visit.css", "rgb(1, 2, 3)"),
            ("core", "/core.js", "deferred.js"),
            ("deferred", "/deferred.js", "api.json"),
            ("image", "/pixel.png", None),
            ("api", "/api.json", "wave3"),
        ):
            status, body = self.fetch(roles[role], path)
            self.assertEqual(status, 200, f"{role} {path}")
            if needle:
                self.assertIn(needle, body.decode("utf-8"))
        status, _ = self.fetch(roles["font"], "/fixture-font.ttf")
        self.assertEqual(status, 503, "a missing font path must surface as 503, never a fake 200")

    def test_wave_css_signals_depend_on_the_external_stylesheet(self) -> None:
        # Phase 5 A1: an inline rule with the same declaration made cssApplied
        # true even when the styles host never answered, so the lane could not
        # detect a failed external stylesheet. The anchor may only carry @font-face
        # and font-family inline.
        host = self.plan["anchors"]["a1"]["host"]
        status, body = self.fetch(host, "/")
        self.assertEqual(status, 200)
        html = body.decode("utf-8")
        inline_match = re.search(r"<style>(?P<css>.*?)</style>", html, re.DOTALL)
        self.assertIsNotNone(inline_match, "the anchor keeps an inline style block for @font-face")
        inline_css = inline_match.group("css")
        self.assertNotIn("background-color", inline_css, "cssApplied must come from the external stylesheet only")
        self.assertNotIn("letter-spacing", inline_css, "blockedCssFailed must come from the blocked stylesheet only")
        self.assertIn("backgroundColor === 'rgb(1, 2, 3)'", html, "the page still measures the external css value")
        self.assertIn("letterSpacing !== '7px'", html, "the page measures the blocked stylesheet's distinctive rule")
        styles = self.plan["anchors"]["a1"]["roles"]["styles"]
        status, css = self.fetch(styles, "/first-visit.css")
        self.assertEqual(status, 200)
        self.assertIn("#probe { background-color: rgb(1, 2, 3); }", css.decode("utf-8"))
        status, blocked_css = self.fetch(self.plan["neverLearnable"], "/never-learnable.css")
        self.assertEqual(status, 200)
        self.assertIn("#probe { letter-spacing: 7px; }", blocked_css.decode("utf-8"))

    def test_whitelist_and_plan_endpoints(self) -> None:
        status, body = self.fetch(self.plan["anchors"]["a1"]["host"], "/whitelist.txt")
        self.assertEqual(status, 200)
        self.assertIn(self.plan["anchors"]["a2"]["host"], body.decode("utf-8"))
        status, body = self.fetch("whatever.example", "/plan.json")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["runId"], "unit-run")
        status, _ = self.fetch(self.plan["anchors"]["a1"]["host"], "/w/t/whitelist.txt")
        self.assertEqual(status, 200)

    def test_signed_xpi_upload_and_serve(self) -> None:
        anchor_host = self.plan["anchors"]["a1"]["host"]
        status, _ = self.fetch(anchor_host, "/openpath-firefox-extension.xpi")
        self.assertEqual(status, 404, "extension bytes are only served on the managed API path")
        status, _ = self.fetch("whatever.example", "/api/extensions/firefox/openpath.xpi")
        self.assertEqual(status, 404, "the managed xpi route must 404 until the guest uploads it")
        payload = b"PK\x03\x04" + bytes(range(64))
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/xpi",
            data=payload,
            method="POST",
        )
        request.add_header("Host", anchor_host)
        request.add_header("Content-Type", "application/x-xpinstall")
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(response.status, 200)
            body = json.loads(response.read())
        self.assertEqual(body["bytes"], len(payload))
        self.assertEqual(body["sha256"], hashlib.sha256(payload).hexdigest())
        status, served = self.fetch("whatever.example", "/api/extensions/firefox/openpath.xpi")
        self.assertEqual(status, 200, "the managed API path must serve the staged xpi")
        self.assertEqual(served, payload)
        status, state = self.fetch("whatever.example", "/state.json")
        self.assertEqual(status, 200)
        parsed = json.loads(state)
        self.assertGreaterEqual(parsed["xpi"]["count"], 1, "the xpi fetch is recorded for the warm-up verification")
        self.assertEqual(parsed["xpi"]["lastPath"], "/api/extensions/firefox/openpath.xpi")
        self.assertGreater(parsed["serverNow"], 0, "state.json carries the fixture clock for one-clock deltas")

    def test_reports_and_request_log_are_recorded(self) -> None:
        anchor = self.plan["anchors"]["a1"]["host"]
        styles = self.plan["anchors"]["a1"]["roles"]["styles"]
        status, _ = self.fetch(styles, "/first-visit.css")
        self.assertEqual(status, 200)
        status, _ = self.fetch(anchor, "/")
        self.assertEqual(status, 200)
        status, body = self.fetch("whatever.example", "/state.json")
        self.assertEqual(status, 200)
        self.assertGreaterEqual(json.loads(body)["browserRequests"], 2, "anchor + styles are browser requests")
        report = {"runId": "unit-run", "loads": 2, "waves": {"cssApplied": True}}
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/__report",
            data=json.dumps(report).encode("utf-8"),
            method="POST",
        )
        request.add_header("Host", anchor)
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(response.status, 204)
        self.assertTrue(self.wait_for_log(lambda entry: entry.get("path") == "/__report"))
        self.assertTrue(self.wait_for_log(lambda entry: entry.get("note") == "wave1-styles"))
        deadline = time.time() + 5
        while time.time() < deadline and not (self.state_dir / "last_report.json").is_file():
            time.sleep(0.05)
        self.assertEqual(json.loads((self.state_dir / "last_report.json").read_text())["loads"], 2)

    def wait_for_log(self, predicate, timeout: float = 5.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            requests_path = self.state_dir / "requests.jsonl"
            if requests_path.is_file():
                for line in requests_path.read_text().splitlines():
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if predicate(entry):
                        return True
            time.sleep(0.05)
        return False

    def test_unexpected_hosts_are_logged_as_such(self) -> None:
        status, _ = self.fetch("mystery.example.com", "/anything")
        self.assertEqual(status, 404)
        self.assertTrue(self.wait_for_log(lambda entry: entry.get("note") == "unexpected"))


class DnsFixtureTests(unittest.TestCase):
    def make_query(self, name: str) -> bytes:
        labels = b"".join(bytes([len(part)]) + part.encode("ascii") for part in name.split("."))
        return b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + labels + b"\x00\x00\x01\x00\x01"

    def test_parses_question_name_and_type(self) -> None:
        name, qtype = dns_fixture.parse_question_name(self.make_query("styles1-abc.192.168.1.150.sslip.io"))
        self.assertEqual(name, "styles1-abc.192.168.1.150.sslip.io")
        self.assertEqual(qtype, 1)

    def test_builds_a_record_with_the_embedded_ipv4(self) -> None:
        query = self.make_query("api-xyz.192.168.1.150.sslip.io")
        response = dns_fixture.build_a_response(query, "192.168.1.150")
        self.assertEqual(response[:2], query[:2], "transaction id must be echoed")
        self.assertEqual(response[2:4], b"\x81\x80")
        self.assertEqual(response[-4:], bytes([192, 168, 1, 150]))

    def test_sslip_pattern_matches_only_embedded_ipv4_names(self) -> None:
        self.assertIsNotNone(dns_fixture.SSLP_IPV4.search("a.192.168.1.150.sslip.io"))
        self.assertIsNone(dns_fixture.SSLP_IPV4.search("a.example.com"))
        self.assertIsNone(dns_fixture.SSLP_IPV4.search("a.192.168.1.150.example.com"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
