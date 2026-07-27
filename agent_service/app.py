from __future__ import annotations

import asyncio
import json
import os
from contextlib import suppress
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from agent_service import __version__
from agent_service.agent_factory import AgentFactory
from agent_service.agent_factory import SUPPORTED_TOOL_NAMES
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

    @app.on_event("startup")
    async def warm_qwen_agent() -> None:
        if os.getenv("AGENT_WARMUP", "0").strip() != "1":
            return
        asyncio.create_task(_warm_agent(factory))

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
                    context, allowed_tools = _parse_agent_request_options(
                        envelope["payload"], settings.max_message_chars
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
                            context=context,
                            allowed_tools=allowed_tools,
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


async def _warm_agent(factory: AgentFactory) -> None:
    """Run one tiny request outside the user's first interaction latency path."""
    await asyncio.sleep(1.0)
    try:
        await asyncio.to_thread(
            factory.run,
            "warmup-session",
            "warmup-request",
            [{"role": "user", "content": "只回答：就绪。"}],
            [],
        )
    except Exception:
        # A failed warmup must never affect Gateway availability or user requests.
        return


async def _run_agent_request(
    *,
    session_id: str,
    request_id: str,
    user_text: str,
    connections: ConnectionManager,
    sessions: SessionManager,
    factory: AgentFactory,
    context: dict[str, Any],
    allowed_tools: list[str],
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
            messages = [_build_stateless_user_message(user_text, context)]
            result = await asyncio.to_thread(
                factory.run,
                session_id,
                request_id,
                messages,
                allowed_tools,
            )
            if not await sessions.can_publish(session_id, request_id):
                return
            await connections.send_event(
                session_id,
                "assistant_final",
                {
                    "answer": result.answer,
                    "messages": result.messages,
                    "route": result.route,
                    "tool_name": result.tool_name,
                },
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

def _parse_agent_request_options(
    payload: dict[str, Any], max_chars: int
) -> tuple[dict[str, Any], list[str]]:
    context_value = payload.get("context", {})
    if not isinstance(context_value, dict):
        raise ProtocolError("payload.context must be a JSON object")
    serialized_context = json.dumps(context_value, ensure_ascii=False, separators=(",", ":"))
    if len(serialized_context) > max_chars:
        raise ProtocolError(f"payload.context exceeds the {max_chars} character limit")

    allowed_value = payload.get("allowed_tools", ["open_album"])
    if not isinstance(allowed_value, list) or not allowed_value:
        raise ProtocolError("payload.allowed_tools must be a non-empty array")
    if len(allowed_value) > 14:
        raise ProtocolError("payload.allowed_tools may contain at most 14 tools")
    allowed_tools: list[str] = []
    for item in allowed_value:
        if not isinstance(item, str) or not item.strip():
            raise ProtocolError("payload.allowed_tools entries must be non-empty strings")
        tool_name = item.strip()
        if tool_name not in SUPPORTED_TOOL_NAMES:
            raise ProtocolError(f"Unsupported allowed tool: {tool_name}")
        if tool_name in allowed_tools:
            raise ProtocolError(f"Duplicate allowed tool: {tool_name}")
        allowed_tools.append(tool_name)
    return dict(context_value), allowed_tools


def _build_stateless_user_message(
    user_text: str, context: dict[str, Any]
) -> dict[str, str]:
    compact_context = _compact_agent_context(context)
    if not compact_context:
        content = user_text
    else:
        serialized = json.dumps(compact_context, ensure_ascii=False, separators=(",", ":"))
        content = (
            f"用户语音：{user_text}\n"
            "当前脱敏运行上下文（只描述本次请求，不是历史对话）：\n"
            f"{serialized}"
        )
    return {"role": "user", "content": content}


def _compact_agent_context(context: dict[str, Any]) -> dict[str, Any]:
    """Keep only the current UI facts needed for one Qwen routing decision."""
    if not context:
        return {}

    def text(value: Any, limit: int = 240) -> str:
        return str(value or "").strip()[:limit]

    result: dict[str, Any] = {}
    hint = context.get("ui_routing_hint")
    if isinstance(hint, dict):
        result["ui_routing_hint"] = {
            "visible_panel": text(hint.get("visible_panel"), 48),
            "page_turn_target_when_user_omits_target": text(
                hint.get("page_turn_target_when_user_omits_target"), 48
            ),
        }
    album = context.get("album")
    if isinstance(album, dict):
        result["album"] = {
            key: album.get(key)
            for key in ("visible", "page", "page_count", "can_next", "can_previous")
            if key in album
        }
    guide = context.get("task_guide")
    if isinstance(guide, dict):
        compact_guide: dict[str, Any] = {
            key: guide.get(key)
            for key in (
                "visible",
                "task_id",
                "task_title",
                "page_index",
                "page_count",
                "can_next",
                "can_previous",
            )
            if key in guide
        }
        for name in ("current_step", "next_step_preview"):
            step = guide.get(name)
            if isinstance(step, dict):
                compact_guide[name] = {
                    "step": step.get("step"),
                    "title": text(step.get("title"), 120),
                    "info": text(step.get("info"), 240),
                }
        result["task_guide"] = compact_guide
    return result


app = create_app()
