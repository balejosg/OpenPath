#!/usr/bin/env python3
"""Unit tests for the Phase 3A first-visit fixture (server + DNS helpers).

Run directly (``python3 test_fixture.py``) or through unittest discovery. No
network configuration is touched: the HTTP fixture binds an ephemeral local
port and the DNS assertions only exercise the pure packet helpers.
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import socket
import sys
import tempfile
import threading
import time
import unittest
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
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}")
        request.add_header("Host", host)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:  # type: ignore[attr-defined]
            return error.code, error.read()

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

    def test_whitelist_and_plan_endpoints(self) -> None:
        status, body = self.fetch(self.plan["anchors"]["a1"]["host"], "/whitelist.txt")
        self.assertEqual(status, 200)
        self.assertIn(self.plan["anchors"]["a2"]["host"], body.decode("utf-8"))
        status, body = self.fetch("whatever.example", "/plan.json")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["runId"], "unit-run")
        status, _ = self.fetch(self.plan["anchors"]["a1"]["host"], "/w/t/whitelist.txt")
        self.assertEqual(status, 200)

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
