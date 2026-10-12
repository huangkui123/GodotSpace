from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import sys
import concurrent.futures
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("runtime", Path(__file__).parents[2] / "scripts/local_agent_runtime.py")
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def config(self) -> dict:
        return {"gateway_env": "/env/model", "compute": {
            "local": {"env_dir": "/env/model", "model_path": "/models/8b"},
            "remote": {"ssh_host": "compute", "remote_port": 8000}},
            "asr": {"env_dir": "/env/asr", "asr_model": "/models/asr", "vad_model": "/models/vad"},
            "tts": {"env_dir": "/env/tts", "model_dir": "/models/tts"}}

    def test_role_ownership_and_separate_compute_ports(self):
        config = self.config()
        self.assertEqual([s["service"] for s in runtime.service_specs(config, "client", "local")], ["asr", "tts"])
        local = runtime.service_specs(config, "server", "local")
        remote = runtime.service_specs(config, "server", "remote")
        self.assertEqual([s["service"] for s in local], ["vllm", "gateway"])
        self.assertEqual(local[0]["model_id"], "Qwen/Qwen3-VL-8B-Instruct")
        self.assertNotEqual(local[1]["port"], remote[1]["port"])
        self.assertEqual(len(runtime.service_specs(config, "server_voice", "local")), 4)

    def test_reuse_never_starts_or_stops_process(self):
        with patch.object(runtime, "ready", return_value=True), patch.object(runtime.subprocess, "Popen") as start:
            self.assertEqual(runtime.ensure({"service": "gateway", "port": 19761}, Path("/repo"), Path("/status")), "reused")
            start.assert_not_called()

    def test_occupied_port_never_evicted(self):
        with patch.object(runtime, "ready", return_value=False), patch.object(runtime, "port_open", return_value=True), patch.object(runtime.subprocess, "Popen") as start:
            with self.assertRaisesRegex(RuntimeError, "no process stopped"):
                runtime.ensure({"service": "gateway", "port": 7861}, Path("/repo"), Path("/status"))
            start.assert_not_called()

    def test_starting_other_configuration_never_duplicated(self):
        with patch.object(runtime, "live_owner_fingerprint", return_value="other-config"), patch.object(runtime.subprocess, "Popen") as start:
            with self.assertRaisesRegex(RuntimeError, "still running/starting"):
                runtime.ensure({"service": "vllm", "port": 19800}, Path("/repo"), Path("/status"))
            start.assert_not_called()

    def test_gateway_config_identity_is_required(self):
        spec = {"service": "gateway", "port": 7861, "model_id": "8b", "model_port": 8000}
        data = {"status": "ready", "model": "8b", "runtime_id": runtime.fingerprint(spec)}
        with patch.object(runtime, "get_json", return_value=data):
            self.assertTrue(runtime.ready(spec))
            self.assertFalse(runtime.ready(dict(spec, model_port=18000)))

    def test_remote_ssh_has_no_shell_or_password_prompt(self):
        spec = runtime.service_specs(self.config(), "server", "remote")[0]
        argv, _ = runtime.command(spec, Path("/repo"))
        self.assertIn("BatchMode=yes", argv)
        self.assertIn("127.0.0.1:18000:127.0.0.1:8000", argv)
        with self.assertRaises(ValueError):
            runtime.command(dict(spec, ssh_host="-oProxyCommand=bad"), Path("/repo"))

    def test_status_and_invalid_ports(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            runtime.write_status(path, "ready", "ok")
            self.assertIn('"ready"', path.read_text())
        config = self.config()
        config["tts"]["port"] = 8765
        with self.assertRaises(ValueError):
            runtime.service_specs(config, "client", "local")

    def test_launch_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Model").mkdir()
            with patch.object(runtime, "ready", return_value=False), patch.object(runtime, "port_open", return_value=False), patch.object(runtime, "command", return_value=(["missing"], {})), patch.object(runtime.subprocess, "Popen", side_effect=OSError("missing executable")):
                with self.assertRaisesRegex(OSError, "missing executable"):
                    runtime.ensure({"service": "tts", "port": 8767}, root, root / "status.json")

    def test_concurrent_start_reuses_one_real_process(self):
        import socket
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Model").mkdir()
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            spec = dict(service="gateway", port=port, model_id="fixture")
            children = []
            original = subprocess.Popen

            def spawn(*args, **kwargs):
                child = original(*args, **kwargs)
                children.append(child)
                return child

            def start(index):
                with runtime.host_lock(timeout=5):
                    return runtime.ensure(spec, root, root / f"status-{index}.json", timeout=5)

            argv = [sys.executable, str(Path(__file__).with_name("runtime_http_fixture.py")), str(port)]
            try:
                with patch.object(Path, "home", return_value=root), patch.object(runtime, "command", return_value=(argv, {"LOCAL_AGENT_RUNTIME_ID": runtime.fingerprint(spec)})), patch.object(runtime.subprocess, "Popen", side_effect=spawn):
                    with concurrent.futures.ThreadPoolExecutor(2) as pool:
                        results = list(pool.map(start, (1, 2)))
                    self.assertEqual(sorted(results), ["reused", "started"])
                    self.assertEqual(len(children), 1)
                    self.assertTrue(runtime.matching_owner(spec))
                    self.assertFalse(runtime.matching_owner(dict(spec, model_id="other")))
            finally:
                for child in children:
                    child.terminate()
                    child.wait(timeout=5)
