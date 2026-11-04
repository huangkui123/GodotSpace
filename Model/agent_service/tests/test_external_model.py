from __future__ import annotations

from contextlib import contextmanager
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from agent_service.agent_factory import AgentFactory
from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager
from agent_service.confirmation import classify_reply
from agent_service.action_entailment import QwenActionEntailmentVerifier
from agent_service.health import _probe_model_server_sync
from agent_service.knowledge_harness import OpenAICompatibleJsonClient
from agent_service.model_endpoint import validate_base_url, request_json, request_tool_call
from scripts.check_external_model import check
from scripts import local_agent_runtime as runtime


@contextmanager
def model_server():
    state = {"requests": [], "selected": [], "bad_tools": False, "status": 200, "models_missing": False}

    class Handler(BaseHTTPRequestHandler):
        def reply(self, data, status=200):
            raw = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            state["requests"].append((self.path, self.headers.get("Authorization"), None))
            self.reply({"data": [{"id": "customer-model"}]}, 404 if state["models_missing"] else state["status"])

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state["requests"].append((self.path, self.headers.get("Authorization"), body))
            if state.get("redirect"):
                self.send_response(307)
                self.send_header("Location", "/redirected")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if state["status"] != 200:
                self.reply({"error": "do-not-echo-secret"}, state["status"])
                return
            if "tools" in body:
                choice = body.get("tool_choice")
                name = choice["function"]["name"] if isinstance(choice, dict) else "respond_directly"
                question = str(body["messages"][-1]["content"]).split("\n")[0]
                if not isinstance(choice, dict):
                    if "打开工作清单" in question:
                        name = "open_task_guide"
                    elif "翻到第二页" in question:
                        name = "go_to_task_guide_page"
                args = {"ok": True}
                if name == "respond_directly":
                    args = {"text": "你好。", "semantic_context": {"request_mode": "conversation", "target": "none",
                        "operation": "respond", "target_source": "not_applicable", "arguments_grounded": True}}
                elif name == "resolve_confirmation":
                    args = {"verdict": "confirm"}
                elif name == "verify_action_entailment":
                    args = {"verdict": "entailed"}
                elif name in ("open_task_guide", "go_to_task_guide_page"):
                    args = {"task_id": 1} if name == "open_task_guide" else {"page": 2}
                    args["semantic_context"] = {"request_mode": "execute", "target": "task_guide",
                        "operation": "open" if name == "open_task_guide" else "go_to", "target_source": "explicit" if name == "open_task_guide" else "context",
                        "arguments_grounded": True}
                if state["bad_tools"]:
                    name = "unregistered_destructive_tool"
                state["selected"].append(name)
                message = {"role": "assistant", "content": None, "tool_calls": [{"id": "call-test", "type": "function",
                    "function": {"name": name, "arguments": json.dumps(args)}}]}
            else:
                message = {"role": "assistant", "content": '{"ok":true}'}
            self.reply({"id": "completion-test", "object": "chat.completion", "created": 1, "model": "customer-model",
                "choices": [{"index": 0, "message": message, "finish_reason": state.get("finish_reason", "tool_calls" if "tools" in body else "stop")}]})

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    settings = Settings(model_server=f"http://127.0.0.1:{server.server_port}/tenant/v1", model_name="customer-model",
        api_key="synthetic-key", model_backend="openai", model_json_mode="prompt")
    try:
        yield settings, state
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class ExternalModelTests(unittest.TestCase):
    def test_real_http_adapter_and_all_model_consumers(self):
        with model_server() as (settings, state):
            check(settings) # actual HTTP + tool proxies + existing harness, not a mocked agent
            self.assertEqual(classify_reply("嗯，就按照你刚才提议的来", "打开工作清单", settings), "confirm")
            verdict = QwenActionEntailmentVerifier(settings).verify("麻烦让相册先退场一下", "close_album")
            self.assertEqual(verdict.verdict, "entailed")
            bodies = [body for _, _, body in state["requests"] if body]
            names = {body["tool_choice"]["function"]["name"] for body in bodies if isinstance(body.get("tool_choice"), dict)}
            self.assertIn("verify_action_entailment", names)
            self.assertIn("resolve_confirmation", names)
            for path, auth, body in state["requests"]:
                self.assertTrue(path.startswith("/tenant/v1/"))
                self.assertEqual(auth, "Bearer synthetic-key")
                if body:
                    self.assertEqual(body["model"], "customer-model")
                    self.assertNotIn("chat_template_kwargs", body)
                    self.assertNotIn("seed", body)
                    self.assertFalse(body.get("stream", False))

    def test_anonymous_endpoint_has_no_placeholder_bearer_header(self):
        with model_server() as (settings, state):
            settings = replace(settings, api_key="EMPTY")
            check(settings)
            self.assertEqual(classify_reply("就按刚才提议的来", "打开工作清单", settings), "confirm")
            self.assertEqual(QwenActionEntailmentVerifier(settings).verify("让相册先退场一下", "close_album").verdict, "entailed")
            self.assertTrue(state["requests"])
            self.assertTrue(all(auth is None for _, auth, _ in state["requests"]))

    def test_external_consumers_reject_redirects_and_do_not_retry_errors(self):
        with model_server() as (settings, state):
            for mode in ("redirect", "server_error"):
                state["redirect"] = mode == "redirect"
                state["status"] = 503 if mode == "server_error" else 200
                consumers = [
                    lambda: AgentFactory(settings, ConnectionManager()).run("s", "r", [{"role": "user", "content": "你好"}], []),
                    lambda: classify_reply("就按刚才提议的来", "打开工作清单", settings),
                    lambda: QwenActionEntailmentVerifier(settings).verify("让相册先退场一下", "close_album"),
                ]
                for consumer in consumers:
                    state["requests"].clear()
                    try:
                        result = consumer()
                    except RuntimeError as exc:
                        self.assertNotIn("secret", str(exc))
                    else:
                        self.assertEqual(getattr(result, "verdict", result), "unclear")
                    self.assertEqual(len(state["requests"]), 1, (mode, state["requests"]))
                    self.assertTrue(state["requests"][0][0].startswith("/tenant/v1/"))

    def test_truncated_function_output_cannot_authorize_an_action(self):
        with model_server() as (settings, state):
            state["finish_reason"] = "length"
            self.assertEqual(classify_reply("就按刚才提议的来", "打开工作清单", settings), "unclear")
            self.assertEqual(QwenActionEntailmentVerifier(settings).verify("让相册先退场一下", "close_album").verdict, "unclear")
            with self.assertRaises(RuntimeError):
                check(settings)

    def test_malformed_function_calls_fail_closed(self):
        for response in ({}, {"choices": []}, {"choices": [{"message": {"tool_calls": None}}]},
                         {"choices": [{"message": {"tool_calls": [{"type": "function", "function": {"name": "x", "arguments": {}}}]}}]}):
            with self.subTest(response=response), patch("agent_service.model_endpoint.request_json", return_value=response):
                with self.assertRaises(RuntimeError):
                    request_tool_call("unused", "EMPTY", 1, {})

    def test_unsupported_tools_do_not_execute(self):
        with model_server() as (settings, state):
            state["bad_tools"] = True
            result = AgentFactory(settings, ConnectionManager()).run("s", "r", [{"role": "user", "content": "你好"}], [])
            self.assertNotEqual(result.route, "tool_executed")
            with self.assertRaises(RuntimeError):
                check(settings)

    def test_health_404_does_not_silently_fallback(self):
        with model_server() as (settings, state):
            state["models_missing"] = True
            self.assertFalse(_probe_model_server_sync(settings).model_found)
            self.assertTrue(all(body is None for _, _, body in state["requests"]))
            self.assertTrue(_probe_model_server_sync(replace(settings, model_health_check="chat")).model_found)

    def test_malformed_models_response_is_not_ready(self):
        with patch("agent_service.health.request_json", return_value={"data": None}):
            result = _probe_model_server_sync(Settings())
            self.assertTrue(result.reachable)
            self.assertFalse(result.model_found)

    def test_json_modes_and_redacted_errors(self):
        with model_server() as (settings, state):
            for mode in ("prompt", "json_object", "json_schema"):
                client = OpenAICompatibleJsonClient(settings.model_server, settings.model_name, api_key=settings.api_key, json_mode=mode)
                self.assertEqual(json.loads(client("Return JSON", {"type": "object"})), {"ok": True})
                body = state["requests"][-1][2]
                if mode == "prompt":
                    self.assertNotIn("response_format", body)
                else:
                    self.assertEqual(body["response_format"]["type"], mode)
            state["status"] = 401
            with self.assertRaisesRegex(RuntimeError, "HTTP 401") as caught:
                request_json(settings.models_url, settings.api_key, 2)
            self.assertNotIn("secret", str(caught.exception))

    def test_endpoint_validation(self):
        self.assertEqual(validate_base_url("https://models.example.test/api/v1/"), "https://models.example.test/api/v1")
        for url in ("file:///tmp/model", "https://u:secret@models.test/v1", "https://models.test/v1?key=secret",
                    "http://192.0.2.10:8000/v1", "https://models.test/v1/chat/completions", "https://models.test/v1#secret"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate_base_url(url)
        self.assertTrue(validate_base_url("http://192.0.2.10:8000/v1", allow_insecure_http=True))

    def external_config(self):
        return {"gateway_env": "/env/gateway", "compute": {"external": {
            "base_url": "https://models.example.test/custom/v1", "model_id": "customer-model", "api_key_env": "CUSTOMER_MODEL_KEY"}}}

    def test_external_only_starts_gateway_and_preserves_local_defaults(self):
        specs = runtime.service_specs(self.external_config(), "server", "external")
        self.assertEqual([s["service"] for s in specs], ["gateway"])
        self.assertEqual(specs[0]["port"], 7863)
        self.assertEqual(specs[0]["model_json_mode"], "prompt")
        self.assertNotIn("model_path", specs[0])
        config = self.external_config()
        config["compute"]["external"]["api_key"] = "not-allowed"
        with self.assertRaises(ValueError):
            runtime.service_specs(config, "server", "external")
        for key_env in (None, 0, False, [], {}, "not an env name"):
            config = self.external_config()
            config["compute"]["external"]["api_key_env"] = key_env
            with self.subTest(key_env=key_env), self.assertRaises(ValueError):
                runtime.service_specs(config, "server", "external")

    def test_gateway_environment_covers_every_model_consumer_without_secret_in_argv(self):
        spec = runtime.service_specs(self.external_config(), "server", "external")[0]
        repo = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as folder:
            env = Path(folder)
            (env / "bin").mkdir()
            (env / "bin/python").touch()
            spec["env_dir"] = str(env)
            with patch.dict(os.environ, {"CUSTOMER_MODEL_KEY": "synthetic-secret", "MODEL_ENABLE_THINKING": "1"}):
                argv, child_env = runtime.command(spec, repo)
                with patch.dict(os.environ, child_env, clear=True):
                    settings = Settings.from_env()
                self.assertEqual(settings.model_backend, "openai")
                self.assertEqual(settings.model_server, spec["model_server"])
                self.assertEqual(settings.api_key, "synthetic-secret")
                self.assertIsNone(settings.model_enable_thinking)
                self.assertNotIn("synthetic-secret", " ".join(argv) + json.dumps(spec))
            with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "missing or empty"):
                runtime.command(spec, repo)

    def test_failed_compatibility_never_starts_gateway(self):
        spec = runtime.service_specs(self.external_config(), "server", "external")[0]
        repo = Path(__file__).resolve().parents[3]
        failures = [subprocess.CompletedProcess([], 1, "synthetic-secret", "upstream-secret"),
                    subprocess.TimeoutExpired("probe", 90)]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as folder:
                with patch.dict(os.environ, {"CUSTOMER_MODEL_KEY": "synthetic-secret"}), \
                     patch.object(runtime, "live_owner_fingerprint", return_value=""), \
                     patch.object(runtime, "ready", return_value=False), \
                     patch.object(runtime, "port_open", return_value=False), \
                     patch.object(runtime, "command", return_value=(["python"], {})), \
                     patch.object(runtime.subprocess, "run") as probe, \
                     patch.object(runtime.subprocess, "Popen") as launch:
                    if isinstance(failure, Exception):
                        probe.side_effect = failure
                    else:
                        probe.return_value = failure
                    with self.assertRaisesRegex(RuntimeError, "Gateway was not started") as caught:
                        runtime.ensure(spec, repo, Path(folder) / "status.json")
                    self.assertNotIn("secret", str(caught.exception))
                    launch.assert_not_called()

    def test_reuse_requires_key_and_matching_configuration(self):
        spec = runtime.service_specs(self.external_config(), "server", "external")[0]
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "ready") as ready:
            with self.assertRaisesRegex(ValueError, "missing or empty"):
                runtime.ensure(spec, Path("unused"), Path("unused"))
            ready.assert_not_called()
        with patch.dict(os.environ, {"CUSTOMER_MODEL_KEY": "synthetic-key"}), \
             patch.object(runtime, "live_owner_fingerprint", return_value=runtime.fingerprint(spec)), \
             patch.object(runtime, "ready", return_value=True), \
             patch.object(runtime.subprocess, "run") as probe:
            self.assertEqual(runtime.ensure(spec, Path("unused"), Path("unused")), "reused")
            probe.assert_not_called()
            changed = dict(spec, credential_revision="rotated")
            with self.assertRaisesRegex(RuntimeError, "another managed configuration"):
                runtime.ensure(changed, Path("unused"), Path("unused"))
