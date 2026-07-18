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
from agent_service.connection_manager import ConnectionManager
from agent_service.health import ModelHealth
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


class AppWebSocketTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
