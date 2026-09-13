from __future__ import annotations

import argparse
import contextlib
import io
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

import deployment_check as check
import launch_service as launch


def payloads():
    return {
        "model": {"data": [{"id": "chosen-8B"}]},
        "gateway_identity": {"service": "godotspace-local-agent"},
        "gateway": {"status": "ready", "model": "chosen-8B", "vllm": True,
                    "model_found": True, "qwen_agent": True},
        "asr": {"service": "local-funasr", "status": "ready",
                "vad_loaded": True, "warmed_up": True},
        "tts": {"service": "local-tts", "status": "ready", "device": "cpu"},
    }


class CheckTests(unittest.TestCase):
    def test_ready_requires_all_four(self):
        self.assertTrue(all(check.assess(payloads(), "chosen-8B").values()))

    def test_tts_supports_cuda_but_rejects_unknown_device(self):
        for device, expected in (("cuda", True), (None, False), ("auto", False)):
            data = payloads()
            data["tts"]["device"] = device
            self.assertEqual(check.assess(data, "chosen-8B")["tts"], expected)


    def test_model_mismatch(self):
        result = check.assess(payloads(), "other-2B")
        self.assertFalse(result["model"])
        self.assertFalse(result["gateway"])

    def test_http_200_not_enough(self):
        self.assertFalse(any(check.assess({}, "chosen-8B").values()))

    def test_missing_vad_warmup_and_wrong_identity(self):
        for key, value in (("vad_loaded", False), ("warmed_up", False),
                           ("service", "depth-pro"), ("warmed_up", "true")):
            data = payloads()
            data["asr"][key] = value
            self.assertFalse(check.assess(data, "chosen-8B")["asr"])

    def test_gateway_not_ready_and_wrong_identity(self):
        data = payloads()
        data["gateway"]["status"] = "not_ready"
        self.assertFalse(check.assess(data, "chosen-8B")["gateway"])
        data = payloads()
        data["gateway_identity"]["service"] = "mock"
        self.assertFalse(check.assess(data, "chosen-8B")["gateway"])

    def test_bad_models_shape(self):
        data = payloads()
        for models in (None, {}, [1, "bad"]):
            data["model"]["data"] = models
            self.assertFalse(check.assess(data, "chosen-8B")["model"])

    def test_network_errors_fail_closed(self):
        with patch.object(check, "fetch_json", side_effect=OSError("closed")):
            result = check.services(check.PORTS, "chosen-8B")
        self.assertFalse(result["ok"])
        self.assertEqual(len(result["errors"]), 5)

    def test_services_default_to_8b(self):
        with patch("sys.argv", ["check", "services"]), \
                patch.object(check, "services", return_value={"ok": True}) as probe, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(check.main(), 0)
        probe.assert_called_once_with(check.PORTS, "Qwen/Qwen3-VL-8B-Instruct")

    def test_default_identity_rejects_running_2b(self):
        data = payloads()
        data["model"]["data"] = [{"id": "Qwen/Qwen3-VL-2B-Instruct"}]
        data["gateway"]["model"] = "Qwen/Qwen3-VL-2B-Instruct"
        result = check.assess(data, check.DEFAULT_MODEL_ID)
        self.assertFalse(result["model"])
        self.assertFalse(result["gateway"])

    def test_duplicate_ports_are_cli_error(self):
        with patch("sys.argv", ["check", "inventory", "--asr-port", "8000"]), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                check.main()
        self.assertEqual(error.exception.code, 2)

    def test_port_range(self):
        for value in ("0", "65536", "-1"):
            with self.assertRaises(argparse.ArgumentTypeError):
                check.port_number(value)

    def test_synthetic_smoke_validates_pcm(self):
        reply = json.dumps({"choices": [{"message": {"content": "部署测试"}}]}).encode()
        with patch.object(check, "request", side_effect=[
            (reply, {}), (b"\x01\x00" * 8000,
                          {"X-Sample-Rate": "8000", "X-Audio-Format": "pcm_s16le"})]):
            self.assertEqual(check.smoke(check.PORTS, "chosen-8B")["tts_audio_seconds"], 1)

    def test_silent_pcm_fails(self):
        reply = json.dumps({"choices": [{"message": {"content": "ok"}}]}).encode()
        with patch.object(check, "request", side_effect=[
            (reply, {}), (bytes(16000), {"X-Sample-Rate": "8000", "X-Audio-Format": "pcm_s16le"})]):
            with self.assertRaises(ValueError):
                check.smoke(check.PORTS, "chosen-8B")

    def test_smoke_skipped_when_services_fail(self):
        with patch("sys.argv", ["check", "smoke", "--model-id", "chosen-8B"]), \
                patch.object(check, "services", return_value={"ok": False}), \
                patch.object(check, "smoke") as synth, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(check.main(), 1)
            synth.assert_not_called()


class PathAndLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="deploy test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "迁移 仓库"
        for name in check.REQUIRED:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.touch()
        self.env_dir = self.root / "isolated env"
        (self.env_dir / "bin").mkdir(parents=True)
        (self.env_dir / "bin/python").touch()
        (self.env_dir / "bin/vllm").touch()
        self.model = self.root / "model weights"
        self.model.mkdir()
        self.args = argparse.Namespace(
            repo=str(self.root), env_dir=str(self.env_dir), service="gateway",
            model_id="chosen-8B", model_path=str(self.model), port=None,
            model_port=18000, dtype="auto", max_model_len=2048, gpu_memory_utilization=0.60,
            asr_device="cpu", asr_model="local asr", vad_model="local vad", tts_device=None)

    def test_repository_with_spaces_and_unicode(self):
        self.assertEqual(check.repository(str(self.root)), self.root.resolve())

    def test_default_5090_profile_reaches_vllm_and_gateway(self):
        for service in ("vllm", "gateway"):
            args = launch.parse_args([service, "--repo", str(self.root),
                                      "--env-dir", str(self.env_dir),
                                      "--model-path", str(self.model)])
            argv, env = launch.build(args, {"MODEL_NAME": "stale-2B"})
            if service == "vllm":
                for flag, expected in (("--served-model-name", "Qwen/Qwen3-VL-8B-Instruct"),
                                       ("--dtype", "bfloat16"), ("--max-model-len", "8192"),
                                       ("--gpu-memory-utilization", "0.75")):
                    self.assertEqual(argv[argv.index(flag) + 1], expected)
                self.assertNotIn("--quantization", argv)
            else:
                self.assertEqual(env["MODEL_NAME"], "Qwen/Qwen3-VL-8B-Instruct")

    def test_explicit_profile_overrides_are_preserved(self):
        args = launch.parse_args(["vllm", "--repo", str(self.root),
                                  "--env-dir", str(self.env_dir), "--model-path", str(self.model),
                                  "--model-id", "chosen-model", "--dtype", "float16",
                                  "--max-model-len", "4096", "--gpu-memory-utilization", "0.65"])
        argv, _ = launch.build(args, {})
        for flag, expected in (("--served-model-name", "chosen-model"), ("--dtype", "float16"),
                               ("--max-model-len", "4096"), ("--gpu-memory-utilization", "0.65")):
            self.assertEqual(argv[argv.index(flag) + 1], expected)

    def test_backend_only_is_rejected(self):
        with self.assertRaises(ValueError):
            check.repository(str(self.root / "Model"))

    def test_gateway_exact_model_and_no_shell(self):
        source_env = {"MODEL_NAME": "stale-2B", "MODEL_SERVER": "https://old.example"}
        argv, env = launch.build(self.args, source_env)
        self.assertEqual(argv[:4], [str(self.env_dir / "bin/python"), "-m", "uvicorn",
                                   "agent_service.app:app"])
        self.assertEqual(env["MODEL_NAME"], "chosen-8B")
        self.assertEqual(env["MODEL_SERVER"], "http://127.0.0.1:18000/v1")
        self.assertEqual(source_env["MODEL_NAME"], "stale-2B")
        self.assertIn("127.0.0.1", argv)

    def test_vllm_paths_not_split_and_offline(self):
        self.args.service = "vllm"
        argv, env = launch.build(self.args, {})
        self.assertEqual(argv[2], str(self.model.resolve()))
        self.assertEqual(argv[argv.index("--served-model-name") + 1], "chosen-8B")
        self.assertEqual(env["HF_HUB_OFFLINE"], "1")

    def test_missing_model_or_environment_rejected(self):
        self.args.model_id = None
        with self.assertRaises(ValueError):
            launch.build(self.args, {})
        self.args.model_id = "chosen-8B"
        self.args.env_dir = str(self.root / "missing")
        with self.assertRaises(ValueError):
            launch.build(self.args, {})

    def test_vllm_rejects_missing_weights_and_invalid_memory(self):
        self.args.service = "vllm"
        self.args.model_path = None
        with self.assertRaises(ValueError):
            launch.build(self.args, {})
        self.args.model_path = str(self.model)
        self.args.gpu_memory_utilization = 1.2
        with self.assertRaises(ValueError):
            launch.build(self.args, {})

    def test_asr_env_is_explicit_and_preloads(self):
        self.args.service = "asr"
        argv, env = launch.build(self.args, {"FUNASR_DEVICE": "cuda", "FUNASR_PRELOAD": "0"})
        self.assertIn("asr_service.app:app", argv)
        self.assertEqual(env["FUNASR_DEVICE"], "cpu")
        self.assertEqual(env["FUNASR_PRELOAD"], "1")
        self.assertEqual(env["FUNASR_MODEL"], "local asr")

    def test_tts_uses_repository_model(self):
        self.args.service = "tts"
        argv, env = launch.build(self.args, {})
        self.assertIn("tts_service.app:app", argv)
        self.assertNotIn("LOCAL_TTS_MODEL_DIR", env)
        _, overrides = launch.build(self.args, {"LOCAL_TTS_MODEL": "vits", "LOCAL_TTS_THREADS": "4"})
        self.assertEqual(overrides["LOCAL_TTS_MODEL"], "vits")
        self.assertEqual(overrides["LOCAL_TTS_THREADS"], "4")

    def test_tts_device_is_explicit_and_portable(self):
        args = launch.parse_args(["tts", "--repo", str(self.root), "--env-dir", str(self.env_dir), "--tts-device", "cuda"])
        _, env = launch.build(args, {"LOCAL_TTS_DEVICE": "cpu"})
        self.assertEqual(env["LOCAL_TTS_DEVICE"], "cuda")

    def test_busy_port_never_executes_or_kills(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            with patch("sys.platform", "linux"), patch("sys.argv", [
                "launch", "gateway", "--repo", str(self.root),
                "--env-dir", str(self.env_dir), "--model-id", "chosen-8B", "--port", str(port)
            ]), patch.object(launch.os, "execve") as execute, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(launch.main(), 1)
                execute.assert_not_called()
            self.assertTrue(check.port_open(port))

    def test_lfs_pointer_detection_without_reading_whole_binary(self):
        target = self.root / "asset.bin"
        target.write_bytes(b"version https://git-lfs.github.com/spec/v1\n")
        with patch.object(check, "command", return_value={"code": 0, "output": "asset.bin"}):
            self.assertEqual(check.lfs_pointers(self.root)["pointers"], ["asset.bin"])

    def test_unavailable_lfs_not_reported_as_checked(self):
        with patch.object(check, "command", return_value={"code": 1, "error": "missing git-lfs"}):
            self.assertFalse(check.lfs_pointers(self.root)["checked"])


if __name__ == "__main__":
    unittest.main()
