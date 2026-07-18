from __future__ import annotations

import asyncio
from contextlib import suppress
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from agent_service import __version__
from agent_service.agent_factory import AgentFactory
from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager, GodotConnectionError
from agent_service.connection_manager import GodotSessionAlreadyConnectedError
from agent_service.health import probe_model_server
from agent_service.protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    make_envelope,
    new_id,
    parse_envelope,
    require_payload_string,
)
from agent_service.session_manager import CancelOutcome, SessionManager


def create_app(
    settings: Settings | None = None,
    *,
    connection_manager: ConnectionManager | None = None,
    session_manager: SessionManager | None = None,
    agent_factory: AgentFactory | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    connections = connection_manager or ConnectionManager()
    sessions = session_manager or SessionManager()
    connections.set_request_lifecycle(sessions)
    factory = agent_factory or AgentFactory(settings, connections)

    app = FastAPI(title="GodotSpace Local Qwen Agent Gateway", version=__version__)
    app.state.settings = settings
    app.state.connections = connections
    app.state.sessions = sessions
    app.state.agent_factory = factory

    @app.get("/healthz")
    async def healthz() -> dict[str, Any]:
        return {
            "status": "healthy",
            "service": "godotspace-local-agent",
            "version": __version__,
            "protocol_version": PROTOCOL_VERSION,
        }

    @app.get("/readyz")
    async def readyz() -> dict[str, Any]:
        model_health = await probe_model_server(settings)
        qwen_agent_available = factory.is_available()
        qwen_agent_version = factory.installed_version()
        godot_connection_count = await connections.connected_count()
        model_ready = model_health.reachable and model_health.model_found
        return {
            "status": "ready" if model_ready and qwen_agent_available else "not_ready",
            "vllm": model_health.reachable,
            "model_found": model_health.model_found,
            "model": settings.model_name,
            "qwen_agent": qwen_agent_available,
            "qwen_agent_version": qwen_agent_version,
            "godot_connected": godot_connection_count > 0,
            "godot_connection_count": godot_connection_count,
            "tool_calls_ready": model_ready
            and qwen_agent_available
            and godot_connection_count > 0,
            "detail": model_health.error,
        }

    @app.websocket("/ws/godot")
    async def godot_websocket(websocket: WebSocket) -> None:
        await websocket.accept()
        session_id = ""
        spawned_tasks: set[asyncio.Task[Any]] = set()
        try:
            hello = parse_envelope(await websocket.receive_json())
            if hello["type"] != "hello":
                raise ProtocolError("The first websocket message must be hello")
            client_id = str(hello["payload"].get("client_id", "godotspace")).strip()
            if not client_id:
                raise ProtocolError("payload.client_id must be a non-empty string")
            session_id = hello["session_id"] or new_id("session")
            try:
                await connections.register(session_id, client_id, websocket)
            except GodotSessionAlreadyConnectedError as exc:
                await websocket.send_json(
                    make_envelope(
                        "run_error",
                        {"code": "duplicate_session_id", "message": str(exc)},
                        session_id=session_id,
                    )
                )
                await websocket.close(code=1008, reason="Duplicate active session")
                return
            await connections.send_event(
                session_id,
                "hello_ack",
                {
                    "client_id": client_id,
                    "server_version": __version__,
                    "protocol_version": PROTOCOL_VERSION,
                },
            )

            while True:
                envelope = parse_envelope(await websocket.receive_json())
                if envelope["session_id"] and envelope["session_id"] != session_id:
                    raise ProtocolError("Message session_id does not match this connection")

                message_type = envelope["type"]
                if message_type == "ping":
                    await connections.send_event(
                        session_id,
                        "pong",
                        envelope["payload"],
                        request_id=envelope["request_id"],
                    )
                elif message_type == "tool_result":
                    await connections.resolve_tool_result(session_id, envelope)
                elif message_type == "user_message":
                    text = require_payload_string(
                        envelope, "text", max_chars=settings.max_message_chars
                    )
                    request_id = envelope["request_id"] or new_id("request")
                    task = await sessions.start_task(
                        session_id,
                        request_id,
                        lambda: _run_agent_request(
                            session_id=session_id,
                            request_id=request_id,
                            user_text=text,
                            connections=connections,
                            sessions=sessions,
                            factory=factory,
                        ),
                    )
                    if task is None:
                        await connections.send_event(
                            session_id,
                            "run_error",
                            {
                                "code": "duplicate_request_id",
                                "message": "This request_id was already accepted.",
                            },
                            request_id=request_id,
                        )
                        continue
                    spawned_tasks.add(task)
                    task.add_done_callback(spawned_tasks.discard)
                elif message_type == "cancel_run":
                    request_id = envelope["request_id"]
                    if not request_id:
                        raise ProtocolError("cancel_run requires request_id")
                    outcome = await sessions.cancel(session_id, request_id)
                    if outcome == CancelOutcome.CANCELLED:
                        with suppress(GodotConnectionError):
                            await connections.cancel_request(session_id, request_id)
                        with suppress(GodotConnectionError):
                            await connections.send_event(
                                session_id,
                                "run_error",
                                {
                                    "code": "cancelled",
                                    "message": "Agent run was cancelled.",
                                },
                                request_id=request_id,
                            )
                    else:
                        with suppress(GodotConnectionError):
                            await connections.send_event(
                                session_id,
                                "run_error",
                                {
                                    "code": "too_late",
                                    "message": (
                                        "The request already crossed its cancellation "
                                        "boundary or is no longer active."
                                    ),
                                },
                                request_id=request_id,
                            )
                else:
                    raise ProtocolError(f"Unexpected client message type: {message_type}")
        except WebSocketDisconnect:
            pass
        except ProtocolError as exc:
            if session_id:
                with suppress(Exception):
                    await connections.send_event(
                        session_id,
                        "run_error",
                        {"code": "protocol_error", "message": str(exc)},
                    )
            else:
                with suppress(Exception):
                    await websocket.send_json(
                        make_envelope(
                            "run_error",
                            {"code": "protocol_error", "message": str(exc)},
                        )
                    )
                with suppress(Exception):
                    await websocket.close(code=1008, reason="Protocol error")
        finally:
            for task in list(spawned_tasks):
                task.cancel()
            if spawned_tasks:
                await asyncio.gather(*spawned_tasks, return_exceptions=True)
            if session_id:
                await connections.unregister(session_id, websocket)
                await sessions.remove_if_idle(session_id)

    return app


async def _run_agent_request(
    *,
    session_id: str,
    request_id: str,
    user_text: str,
    connections: ConnectionManager,
    sessions: SessionManager,
    factory: AgentFactory,
) -> None:
    state = await sessions.get(session_id)
    try:
        async with state.run_lock:
            if not await sessions.mark_model_running(session_id, request_id):
                return
            await connections.send_event(
                session_id,
                "run_started",
                {"provider": "local_qwen_agent"},
                request_id=request_id,
            )
            messages = [{"role": "user", "content": user_text}]
            result = await asyncio.to_thread(
                factory.run,
                session_id,
                request_id,
                messages,
            )
            if not await sessions.can_publish(session_id, request_id):
                return
            await connections.send_event(
                session_id,
                "assistant_final",
                {"answer": result.answer, "messages": result.messages},
                request_id=request_id,
            )
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        with suppress(GodotConnectionError):
            await connections.send_event(
                session_id,
                "run_error",
                {"code": "agent_error", "message": str(exc)},
                request_id=request_id,
            )
    finally:
        await sessions.finish_task(session_id, request_id)


app = create_app()
