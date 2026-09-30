import sys
import json
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vibe" / "tools"))
import server
import run_k6


class CatalogTests(unittest.TestCase):
    def test_all_expected_scenarios_are_available(self):
        self.assertEqual(
            set(server.TEST_BY_ID),
            {"load", "stress", "spike", "users", "ramp", "worker", "pod_failure", "node_failure", "db_failure", "rolling", "oom", "oom_restore"},
        )

    def test_params_are_validated(self):
        self.assertEqual(
            server.normalize_params("users", {"vus": 500, "duration": "3m", "repetitions": 2}),
            {"vus": 500, "duration": "3m", "repetitions": 2},
        )
        with self.assertRaises(ValueError):
            server.normalize_params("users", {"vus": 0, "duration": "sin-formato", "repetitions": 1})

    def test_fixed_users_command_preserves_requested_concurrency_and_namespace(self):
        original = server.ARGS
        server.ARGS = SimpleNamespace(ns="test-ns")
        try:
            command = server.make_command("users", {"vus": 777, "duration": "2m"})
            self.assertIn("VUS=777", command)
            self.assertIn("DURATION=2m", command)
            self.assertIn("NS=test-ns", command)
        finally:
            server.ARGS = original

    def test_k6_result_files_are_parsed_and_bad_files_ignored(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / "results" / "k6"
            folder.mkdir(parents=True)
            (folder / "load-1.json").write_text(json.dumps({"name": "load", "p95_ms": 321}), encoding="utf-8")
            (folder / "broken.json").write_text("{", encoding="utf-8")
            self.assertEqual(server.load_k6_results(temp)[0]["p95_ms"], 321)

    def test_k6_slo_failure_is_detected_from_saved_summary(self):
        results = [{
            "name": "load", "date": "2026-09-30T05:10:05+00:00", "thresholds_passed": False,
        }]
        self.assertTrue(server.run_has_k6_slo_failure("load", 1_000_000_000, results))
        self.assertFalse(server.run_has_k6_slo_failure("stress", 1_000_000_000, results))
        self.assertFalse(server.run_has_k6_slo_failure("load", 1_800_000_000, results))

    def test_k6_export_summary_is_normalized(self):
        summary = run_k6.summarize({"metrics": {
            "http_reqs": {"values": {"count": 123, "rate": 12.3}},
            "http_req_failed": {"values": {"rate": 0.02}},
            "http_req_duration": {"values": {"med": 45, "p(95)": 300, "p(99)": 800},
                                   "thresholds": {"p(95)<500": {"ok": True}}},
            "hls_segment_ms": {"values": {"p(95)": 250}},
        }}, "load", 300, 10)
        self.assertEqual(summary["requests"], 123)
        self.assertEqual(summary["p95_ms"], 300)
        self.assertEqual(summary["hls_segment_p95_ms"], 250)
        self.assertTrue(summary["thresholds_passed"])

    def test_k6_export_accepts_boolean_threshold_results(self):
        passed = run_k6.summarize({"metrics": {
            "http_req_duration": {"values": {"p(95)": 420}, "thresholds": {"p(95)<500": True}},
            "http_req_failed": {"values": {"rate": 0.02}, "thresholds": {"rate<0.01": False}},
        }}, "users", 500, 180)
        self.assertFalse(passed["thresholds_passed"])

        passed = run_k6.summarize({"metrics": {
            "http_req_duration": {"thresholds": {"p(95)<500": True}},
            "http_req_failed": {"thresholds": {"rate<0.01": {"ok": True}}},
        }}, "users", 500, 180)
        self.assertTrue(passed["thresholds_passed"])

    def test_missing_pod_metrics_are_tolerated(self):
        with mock.patch.object(server, "kubectl", side_effect=RuntimeError("not found")):
            with self.assertRaises(RuntimeError):
                server.pod_metrics("vibe", "gone-pod")

    def test_prometheus_metrics_parse_errors_latency_and_pool(self):
        payload = '\n'.join([
            'http_requests_total{handler="/api/tracks",method="GET",status="200"} 100',
            'http_requests_total{handler="/api/tracks",method="GET",status="500"} 2',
            'http_request_duration_seconds_bucket{handler="/api/tracks",le="0.1"} 95',
            'http_request_duration_seconds_bucket{handler="/api/tracks",le="+Inf"} 100',
            'vibe_catalog_db_pool_checked_out 4',
            'vibe_catalog_db_pool_checked_in 1',
        ])
        with mock.patch.object(server, "kubectl", return_value=payload):
            parsed = server.pod_metrics("vibe", "catalog-1")
        self.assertEqual(parsed["req"], 102)
        self.assertEqual(parsed["errors"], 2)
        self.assertEqual(parsed["p95_ms"], 100)
        self.assertEqual(parsed["pool"]["checked_out"], 4)

    def test_missing_service_metrics_render_as_na_data(self):
        pod = {"name": "catalog-1", "app": "catalog-api", "ready": True, "node": "worker"}
        with mock.patch.object(server, "pod_metrics", side_effect=RuntimeError("metrics unavailable")):
            traffic = server.collect_traffic("vibe", [pod])
        self.assertEqual(traffic["pods"], [])
        self.assertEqual(traffic["services"], {})

    def test_prepare_uses_selected_namespace_for_kubectl(self):
        original = server.ARGS
        server.ARGS = SimpleNamespace(ns="alternate")
        manager = server.TestManager()
        try:
            with mock.patch.object(server.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="", stderr="")) as run:
                manager._prepare("load", {})
            self.assertEqual(run.call_args.args[0][3], "alternate")
        finally:
            server.ARGS = original

    def test_node_recommendation_uses_current_placement(self):
        original = server.STATE["data"]
        server.STATE["data"] = {
            "nodes": [
                {"name": "vibe-worker", "role": "worker", "ready": True},
                {"name": "vibe-worker2", "role": "worker", "ready": True},
            ],
            "pods": [
                {"node": "vibe-worker", "app": "catalog-api", "state": "Running", "pvcs": []},
                {"node": "vibe-worker", "app": "postgres", "state": "Running", "pvcs": ["pg"]},
                {"node": "vibe-worker2", "app": "frontend", "state": "Running", "pvcs": []},
                {"node": "vibe-worker2", "app": "redis", "state": "Running", "pvcs": ["redis"]},
            ],
        }
        try:
            catalog = server.test_catalog_view()
            test = next(item for item in catalog if item["id"] == "node_failure")
            node = next(param for param in test["params"] if param["name"] == "node")
            self.assertEqual(node["default"], "vibe-worker2")
            self.assertIn("1 pods stateless", node["option_labels"]["vibe-worker2"])
        finally:
            server.STATE["data"] = original


class ManagerTests(unittest.TestCase):
    def test_stop_cancels_managed_process(self):
        original = server.make_command
        marker = "k8s_web_manager_smoke_ready"
        code = f"import time; print('{marker}', flush=True); time.sleep(60)"
        server.make_command = lambda _test_id, _params: [sys.executable, "-u", "-c", code]
        manager = server.TestManager()
        manager._prepare = lambda *_args: {}
        try:
            manager.start("load", {"repetitions": 1})
            deadline = time.time() + 8
            while time.time() < deadline:
                if any(marker in line["text"] for line in manager.status()["logs"]):
                    break
                time.sleep(0.1)
            else:
                self.fail("No se recibió salida del proceso administrado")

            manager.stop()
            deadline = time.time() + 8
            while time.time() < deadline and manager.status()["current"]["status"] in {"starting", "running", "stopping"}:
                time.sleep(0.1)
            self.assertEqual(manager.status()["current"]["status"], "cancelled")
            self.assertFalse(manager.processes)
        finally:
            manager.shutdown()
            server.make_command = original


if __name__ == "__main__":
    unittest.main()
