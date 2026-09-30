import sys
import time
import unittest

import server


class CatalogTests(unittest.TestCase):
    def test_all_expected_scenarios_are_available(self):
        self.assertEqual(
            set(server.TEST_BY_ID),
            {"load", "stress", "spike", "users", "worker", "pod_failure", "node_failure", "db_failure", "rolling", "oom", "oom_restore"},
        )

    def test_params_are_validated(self):
        self.assertEqual(
            server.normalize_params("users", {"vus": 500, "duration": "3m", "repetitions": 2}),
            {"vus": 500, "duration": "3m", "repetitions": 2},
        )
        with self.assertRaises(ValueError):
            server.normalize_params("users", {"vus": 0, "duration": "sin-formato", "repetitions": 1})

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
