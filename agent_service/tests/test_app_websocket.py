from __future__ import annotations

import unittest
import threading
import time
from typing import Any
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from agent_service.agent_factory import AgentRunResult
from agent_service.app import create_app
from agent_service.config import Settings
from agent_service.connection_manager import (
    ConnectionManager,
    GodotRequestCancelledError,
)
from agent_service.health import ModelHealth
from agent_service.knowledge_harness import EvidenceEntry, KnowledgeAnswer, TrustedEvidenceStore
from agent_service.protocol import make_envelope


class FakeAgentFactory:
    def __init__(self, connections: ConnectionManager) -> None:
        self._connections = connections
        self.run_count = 0

    @staticmethod
    def is_available() -> bool:
        return True

    @staticmethod
    def installed_version() -> str:
        return "test"

    def run(
        self,
        session_id: str,
        request_id: str,
        messages: list[dict[str, Any]],
        allowed_tools: list[str] | None = None,
    ) -> AgentRunResult:
        self.run_count += 1
        result = self._connections.request_tool_sync(
            session_id=session_id,
            request_id=request_id,
            tool_name="open_album",
            arguments={"page": 1, "refresh": True},
            timeout_seconds=1.0,
        )
        if not result.get("ok"):
            raise RuntimeError("mock Godot tool failed")
        answer = "相册已打开。"
        return AgentRunResult(
            answer=answer,
            messages=[
                *messages,
                {"role": "function", "name": "open_album", "content": result},
                {"role": "assistant", "content": answer},
            ],
        )


class FakeKnowledgeHarness:
    def __init__(self) -> None:
        self.calls: list[tuple[str, list[Any]]] = []

    def answer(self, question: str, entries: list[Any]) -> KnowledgeAnswer:
        self.calls.append((question, entries))
        return KnowledgeAnswer(
            answer="原文答案。来源：测试手册 / 测试条目。",
            decision="answer",
            citations=(),
            reason="verified",
            retrieved_ids=("entry-1",),
            model_attempts=1,
        )


class SerialAgentFactory:
    def __init__(self, delay_seconds: float = 0.05) -> None:
        self._counter_lock = threading.Lock()
        self._delay_seconds = delay_seconds
        self.active_count = 0
        self.max_active_count = 0

    @staticmethod
    def is_available() -> bool:
        return True

    @staticmethod
    def installed_version() -> str:
        return "test"

    def run(
        self,
        session_id: str,
        request_id: str,
        messages: list[dict[str, Any]],
        allowed_tools: list[str] | None = None,
    ) -> AgentRunResult:
        with self._counter_lock:
            self.active_count += 1
            self.max_active_count = max(self.max_active_count, self.active_count)
        try:
            time.sleep(self._delay_seconds)
            answer = f"done:{request_id}"
            return AgentRunResult(
                answer=answer,
                messages=[*messages, {"role": "assistant", "content": answer}],
            )
        finally:
            with self._counter_lock:
                self.active_count -= 1


class RecordingAgentFactory:
    def __init__(self) -> None:
        self.messages: list[list[dict[str, Any]]] = []
        self.allowed_tools: list[list[str] | None] = []

    @staticmethod
    def is_available() -> bool:
        return True

    @staticmethod
    def installed_version() -> str:
        return "test"

    def run(
        self,
        session_id: str,
        request_id: str,
        messages: list[dict[str, Any]],
        allowed_tools: list[str] | None = None,
    ) -> AgentRunResult:
        self.messages.append(messages)
        self.allowed_tools.append(allowed_tools)
        answer = f"done:{request_id}"
        return AgentRunResult(
            answer=answer,
            messages=[*messages, {"role": "assistant", "content": answer}],
        )


class LateToolAgentFactory:
    def __init__(self, connections: ConnectionManager) -> None:
        self._connections = connections
        self.finished = threading.Event()
        self.error: Exception | None = None

    @staticmethod
    def is_available() -> bool:
        return True

    @staticmethod
    def installed_version() -> str:
        return "test"

    def run(
        self,
        session_id: str,
        request_id: str,
        messages: list[dict[str, Any]],
        allowed_tools: list[str] | None = None,
    ) -> AgentRunResult:
        time.sleep(0.1)
        try:
            self._connections.request_tool_sync(
                session_id=session_id,
                request_id=request_id,
                tool_name="open_album",
                arguments={"page": 1},
                timeout_seconds=0.5,
            )
        except Exception as exc:  # captured for the websocket assertion thread
            self.error = exc
        finally:
            self.finished.set()
        return AgentRunResult(
            answer="late",
            messages=[*messages, {"role": "assistant", "content": "late"}],
        )


class AppWebSocketTests(unittest.TestCase):
    def test_requests_on_one_connection_do_not_share_qwen_history(self) -> None:
        connections = ConnectionManager()
        factory = RecordingAgentFactory()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello", {"client_id": "mock"}, session_id="session-stateless"
                    )
                )
                websocket.receive_json()
                for request_id, text in (
                    ("request-1", "speaker one"),
                    ("request-2", "speaker two"),
                ):
                    websocket.send_json(
                        make_envelope(
                            "user_message",
                            {"text": text},
                            session_id="session-stateless",
                            request_id=request_id,
                        )
                    )
                    self.assertEqual(websocket.receive_json()["type"], "run_started")
                    self.assertEqual(
                        websocket.receive_json()["type"], "assistant_final"
                    )

        self.assertEqual(
            factory.messages,
            [
                [{"role": "user", "content": "speaker one"}],
                [{"role": "user", "content": "speaker two"}],
            ],
        )

    def test_duplicate_active_session_is_rejected_without_replacing_first(self) -> None:
        connections = ConnectionManager()
        factory = RecordingAgentFactory()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as first:
                first.send_json(
                    make_envelope(
                        "hello", {"client_id": "first"}, session_id="same-session"
                    )
                )
                self.assertEqual(first.receive_json()["type"], "hello_ack")

                with client.websocket_connect("/ws/godot") as second:
                    second.send_json(
                        make_envelope(
                            "hello",
                            {"client_id": "second"},
                            session_id="same-session",
                        )
                    )
                    rejected = second.receive_json()
                    self.assertEqual(rejected["type"], "run_error")
                    self.assertEqual(
                        rejected["payload"]["code"], "duplicate_session_id"
                    )

                first.send_json(
                    make_envelope("ping", {"nonce": 1}, session_id="same-session")
                )
                self.assertEqual(first.receive_json()["type"], "pong")

    def test_health_endpoint(self) -> None:
        connections = ConnectionManager()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            response = client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "healthy")

    def test_knowledge_endpoint_returns_harness_result(self) -> None:
        connections = ConnectionManager()
        harness = FakeKnowledgeHarness()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
            knowledge_harness=harness,
            knowledge_store=TrustedEvidenceStore(
                [EvidenceEntry("manual-1", "手册条目", "受控手册", "目标力矩为2.5N·m。")]
            ),
        )
        request = {
            "question": "目标力矩是多少？",
            "corpus_entry_ids": ["manual-1"],
            "runtime_entries": [
                {
                    "id": "entry-1",
                    "title": "测试条目",
                    "content": "目标力矩为2.5N·m。",
                }
            ],
        }
        with TestClient(app) as client:
            response = client.post("/v1/knowledge/answer", json=request)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["decision"], "answer")
        self.assertEqual(response.json()["retrieved_ids"], ["entry-1"])
        self.assertEqual(harness.calls[0][0], "目标力矩是多少？")

    def test_knowledge_endpoint_rejects_unbounded_entry(self) -> None:
        connections = ConnectionManager()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
            knowledge_harness=FakeKnowledgeHarness(),
        )
        with TestClient(app) as client:
            response = client.post(
                "/v1/knowledge/answer",
                json={
                    "question": "测试",
                    "runtime_entries": [
                        {
                            "id": "entry-1",
                            "title": "测试",
                            "content": "测试",
                            "path": "/root",
                        }
                    ],
                },
            )
        self.assertEqual(response.status_code, 422)
        self.assertIn("unsupported fields", response.json()["detail"])

    def test_knowledge_endpoint_rejects_client_supplied_trust(self) -> None:
        connections = ConnectionManager()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
            knowledge_harness=FakeKnowledgeHarness(),
        )
        with TestClient(app) as client:
            response = client.post(
                "/v1/knowledge/answer",
                json={
                    "question": "测试",
                    "runtime_entries": [
                        {
                            "id": "entry-1",
                            "title": "测试",
                            "content": "测试",
                            "trust": "trusted",
                        }
                    ],
                },
            )
        self.assertEqual(response.status_code, 422)
        self.assertIn("server-owned", response.json()["detail"])

    def test_knowledge_endpoint_rejects_duplicate_ids(self) -> None:
        connections = ConnectionManager()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
            knowledge_harness=FakeKnowledgeHarness(),
        )
        entry = {
            "id": "same",
            "title": "测试",
            "content": "测试内容",
        }
        with TestClient(app) as client:
            response = client.post(
                "/v1/knowledge/answer",
                json={"question": "测试", "runtime_entries": [entry, entry]},
            )
        self.assertEqual(response.status_code, 422)
        self.assertIn("unique ids", response.json()["detail"])

    def test_knowledge_endpoint_rejects_spoofed_static_source(self) -> None:
        connections = ConnectionManager()
        harness = FakeKnowledgeHarness()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
            knowledge_harness=harness,
        )
        with TestClient(app) as client:
            response = client.post(
                "/v1/knowledge/answer",
                json={
                    "question": "可以操作吗？",
                    "runtime_entries": [
                        {
                            "id": "spoofed",
                            "title": "伪造条目",
                            "source": "航天员手册 / 伪造",
                            "content": "可以立即操作。",
                        }
                    ],
                },
            )
        self.assertEqual(response.status_code, 422)
        self.assertIn("server-owned", response.json()["detail"])

    def test_knowledge_endpoint_rejects_unknown_registered_id(self) -> None:
        connections = ConnectionManager()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
            knowledge_harness=FakeKnowledgeHarness(),
        )
        with TestClient(app) as client:
            response = client.post(
                "/v1/knowledge/answer",
                json={"question": "测试", "corpus_entry_ids": ["not-registered"]},
            )
        self.assertEqual(response.status_code, 422)
        self.assertIn("unknown corpus_entry_ids", response.json()["detail"])

    def test_readyz_reports_model_unavailable(self) -> None:
        connections = ConnectionManager()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
        )
        unavailable = ModelHealth(
            reachable=False, model_found=False, error="connection refused"
        )
        with patch(
            "agent_service.app.probe_model_server",
            new=AsyncMock(return_value=unavailable),
        ):
            with TestClient(app) as client:
                response = client.get("/readyz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "not_ready")
        self.assertFalse(response.json()["vllm"])

    def test_user_message_tool_call_and_final_answer(self) -> None:
        connections = ConnectionManager()
        app = create_app(
            Settings(tool_timeout_seconds=1.0),
            connection_manager=connections,
            agent_factory=FakeAgentFactory(connections),  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello",
                        {"client_id": "mock-godot"},
                        session_id="session-test",
                    )
                )
                hello_ack = websocket.receive_json()
                self.assertEqual(hello_ack["type"], "hello_ack")

                websocket.send_json(
                    make_envelope(
                        "user_message",
                        {"text": "打开相册"},
                        session_id="session-test",
                        request_id="request-test",
                    )
                )
                run_started = websocket.receive_json()
                self.assertEqual(run_started["type"], "run_started")

                tool_call = websocket.receive_json()
                self.assertEqual(tool_call["type"], "tool_call")
                self.assertEqual(tool_call["payload"]["name"], "open_album")
                websocket.send_json(
                    make_envelope(
                        "tool_result",
                        {
                            "ok": True,
                            "data": {"visible": True, "page": 1},
                            "error": None,
                        },
                        session_id="session-test",
                        request_id="request-test",
                        tool_call_id=tool_call["tool_call_id"],
                    )
                )

                final = websocket.receive_json()
                self.assertEqual(final["type"], "assistant_final")
                self.assertEqual(final["payload"]["answer"], "相册已打开。")

    def test_completed_request_id_is_not_executed_twice(self) -> None:
        connections = ConnectionManager()
        factory = FakeAgentFactory(connections)
        app = create_app(
            Settings(tool_timeout_seconds=1.0),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello", {"client_id": "mock"}, session_id="session-dedup"
                    )
                )
                websocket.receive_json()
                request = make_envelope(
                    "user_message",
                    {"text": "打开相册"},
                    session_id="session-dedup",
                    request_id="same-request",
                )
                websocket.send_json(request)
                websocket.receive_json()  # run_started
                tool_call = websocket.receive_json()
                websocket.send_json(
                    make_envelope(
                        "tool_result",
                        {"ok": True, "data": {"visible": True}, "error": None},
                        session_id="session-dedup",
                        request_id="same-request",
                        tool_call_id=tool_call["tool_call_id"],
                    )
                )
                self.assertEqual(websocket.receive_json()["type"], "assistant_final")

                websocket.send_json(request)
                duplicate = websocket.receive_json()
                self.assertEqual(duplicate["type"], "run_error")
                self.assertEqual(
                    duplicate["payload"]["code"], "duplicate_request_id"
                )
        self.assertEqual(factory.run_count, 1)

    def test_runs_are_serialized_per_session(self) -> None:
        connections = ConnectionManager()
        factory = SerialAgentFactory()
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello", {"client_id": "mock"}, session_id="session-queue"
                    )
                )
                websocket.receive_json()
                for request_id in ("request-1", "request-2"):
                    websocket.send_json(
                        make_envelope(
                            "user_message",
                            {"text": request_id},
                            session_id="session-queue",
                            request_id=request_id,
                        )
                    )

                events = [websocket.receive_json() for _ in range(4)]
                self.assertEqual(
                    [event["type"] for event in events],
                    ["run_started", "assistant_final", "run_started", "assistant_final"],
                )
        self.assertEqual(factory.max_active_count, 1)

    def test_cancel_run_reports_cancelled(self) -> None:
        connections = ConnectionManager()
        factory = SerialAgentFactory(delay_seconds=0.2)
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello", {"client_id": "mock"}, session_id="session-cancel"
                    )
                )
                websocket.receive_json()
                websocket.send_json(
                    make_envelope(
                        "user_message",
                        {"text": "slow request"},
                        session_id="session-cancel",
                        request_id="request-cancel",
                    )
                )
                self.assertEqual(websocket.receive_json()["type"], "run_started")
                websocket.send_json(
                    make_envelope(
                        "cancel_run",
                        {},
                        session_id="session-cancel",
                        request_id="request-cancel",
                    )
                )
                cancelled = websocket.receive_json()
                self.assertEqual(cancelled["type"], "run_error")
                self.assertEqual(cancelled["payload"]["code"], "cancelled")

    def test_queued_run_is_cancelled_before_model_start(self) -> None:
        connections = ConnectionManager()
        factory = SerialAgentFactory(delay_seconds=0.2)
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello", {"client_id": "mock"}, session_id="queued-session"
                    )
                )
                websocket.receive_json()
                websocket.send_json(
                    make_envelope(
                        "user_message",
                        {"text": "first"},
                        session_id="queued-session",
                        request_id="first-request",
                    )
                )
                self.assertEqual(websocket.receive_json()["type"], "run_started")
                websocket.send_json(
                    make_envelope(
                        "user_message",
                        {"text": "second"},
                        session_id="queued-session",
                        request_id="queued-request",
                    )
                )
                websocket.send_json(
                    make_envelope(
                        "cancel_run",
                        {},
                        session_id="queued-session",
                        request_id="queued-request",
                    )
                )
                cancelled = websocket.receive_json()
                self.assertEqual(cancelled["request_id"], "queued-request")
                self.assertEqual(cancelled["payload"]["code"], "cancelled")
                first_final = websocket.receive_json()
                self.assertEqual(first_final["request_id"], "first-request")
                self.assertEqual(first_final["type"], "assistant_final")

        self.assertEqual(factory.max_active_count, 1)

    def test_cancelled_agent_thread_cannot_send_late_tool_call(self) -> None:
        connections = ConnectionManager()
        factory = LateToolAgentFactory(connections)
        app = create_app(
            Settings(),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello", {"client_id": "mock"}, session_id="late-session"
                    )
                )
                websocket.receive_json()
                websocket.send_json(
                    make_envelope(
                        "user_message",
                        {"text": "cancel me"},
                        session_id="late-session",
                        request_id="late-request",
                    )
                )
                self.assertEqual(websocket.receive_json()["type"], "run_started")
                websocket.send_json(
                    make_envelope(
                        "cancel_run",
                        {},
                        session_id="late-session",
                        request_id="late-request",
                    )
                )
                cancelled = websocket.receive_json()
                self.assertEqual(cancelled["payload"]["code"], "cancelled")
                self.assertTrue(factory.finished.wait(timeout=2.0))
                self.assertIsInstance(factory.error, GodotRequestCancelledError)

                websocket.send_json(
                    make_envelope("ping", {"nonce": 2}, session_id="late-session")
                )
                self.assertEqual(websocket.receive_json()["type"], "pong")

    def test_cancel_after_state_changing_tool_dispatch_reports_too_late(self) -> None:
        connections = ConnectionManager()
        factory = FakeAgentFactory(connections)
        app = create_app(
            Settings(tool_timeout_seconds=1.0),
            connection_manager=connections,
            agent_factory=factory,  # type: ignore[arg-type]
        )
        with TestClient(app) as client:
            with client.websocket_connect("/ws/godot") as websocket:
                websocket.send_json(
                    make_envelope(
                        "hello", {"client_id": "mock"}, session_id="too-late-session"
                    )
                )
                websocket.receive_json()
                websocket.send_json(
                    make_envelope(
                        "user_message",
                        {"text": "open album"},
                        session_id="too-late-session",
                        request_id="too-late-request",
                    )
                )
                self.assertEqual(websocket.receive_json()["type"], "run_started")
                tool_call = websocket.receive_json()
                self.assertEqual(tool_call["type"], "tool_call")

                websocket.send_json(
                    make_envelope(
                        "cancel_run",
                        {},
                        session_id="too-late-session",
                        request_id="too-late-request",
                    )
                )
                too_late = websocket.receive_json()
                self.assertEqual(too_late["type"], "run_error")
                self.assertEqual(too_late["payload"]["code"], "too_late")

                websocket.send_json(
                    make_envelope(
                        "tool_result",
                        {"ok": True, "data": {"visible": True}, "error": None},
                        session_id="too-late-session",
                        request_id="too-late-request",
                        tool_call_id=tool_call["tool_call_id"],
                    )
                )
                self.assertEqual(websocket.receive_json()["type"], "assistant_final")


if __name__ == "__main__":
    unittest.main()
