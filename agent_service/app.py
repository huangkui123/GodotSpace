from __future__ import annotations

import asyncio
import json
import os
import re
import time
from contextlib import suppress
from typing import Any

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect

from agent_service import __version__
from agent_service.agent_factory import AgentFactory, AgentRunResult
from agent_service.agent_factory import SUPPORTED_TOOL_NAMES
from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager, GodotConnectionError
from agent_service.connection_manager import GodotSessionAlreadyConnectedError
from agent_service.health import probe_model_server
from agent_service.harness_protocol import HarnessTrace
from agent_service.knowledge_harness import (
    KnowledgeHarness,
    OpenAICompatibleJsonClient,
    TrustedEvidenceStore,
    runtime_evidence_entry_from_request,
)
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
    knowledge_harness: KnowledgeHarness | None = None,
    knowledge_store: TrustedEvidenceStore | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    connections = connection_manager or ConnectionManager()
    sessions = session_manager or SessionManager()
    connections.set_request_lifecycle(sessions)
    harness = knowledge_harness or KnowledgeHarness(
        OpenAICompatibleJsonClient(
            settings.model_server,
            settings.model_name,
            api_key=settings.api_key,
            timeout_seconds=settings.knowledge_model_timeout_seconds,
        ),
        retrieval_limit=settings.knowledge_retrieval_limit,
        minimum_score=settings.knowledge_minimum_score,
    )
    store = knowledge_store or TrustedEvidenceStore.from_json_file(
        settings.knowledge_corpus_path
    )
    factory = agent_factory or AgentFactory(
        settings,
        connections,
        knowledge_harness=harness,
        knowledge_store=store,
    )

    app = FastAPI(title="GodotSpace Local Qwen Agent Gateway", version=__version__)
    app.state.settings = settings
    app.state.connections = connections
    app.state.sessions = sessions
    app.state.agent_factory = factory
    app.state.knowledge_harness = harness
    app.state.knowledge_store = store

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
            "knowledge_corpus_entries": store.count,
        }

    @app.post("/v1/knowledge/answer")
    async def answer_from_trusted_evidence(request: dict[str, Any]) -> dict[str, Any]:
        question = request.get("question")
        runtime_entries = request.get("runtime_entries", [])
        corpus_entry_ids = request.get("corpus_entry_ids")
        if not isinstance(question, str) or not question.strip():
            raise HTTPException(status_code=422, detail="question must be a non-empty string")
        if len(question) > settings.max_message_chars:
            raise HTTPException(status_code=422, detail="question exceeds the configured message limit")
        if set(request) - {"question", "runtime_entries", "corpus_entry_ids"}:
            raise HTTPException(status_code=422, detail="request contains unsupported fields")
        if not isinstance(runtime_entries, list) or len(runtime_entries) > 20:
            raise HTTPException(
                status_code=422,
                detail="runtime_entries must be an array containing at most 20 items",
            )
        if corpus_entry_ids is not None and (
            not isinstance(corpus_entry_ids, list)
            or len(corpus_entry_ids) > 50
            or any(not isinstance(item, str) or not item.strip() for item in corpus_entry_ids)
        ):
            raise HTTPException(
                status_code=422,
                detail="corpus_entry_ids must be an array of at most 50 non-empty strings",
            )
        knowledge_started = time.perf_counter()
        try:
            registered = store.select(
                [item.strip() for item in corpus_entry_ids]
                if corpus_entry_ids is not None
                else None
            )
            runtime = [
                runtime_evidence_entry_from_request(
                    item,
                    index,
                    settings.knowledge_runtime_source,
                )
                for index, item in enumerate(runtime_entries)
            ]
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        evidence = [*runtime, *registered]
        entry_ids = [entry.id for entry in evidence]
        if len(entry_ids) != len(set(entry_ids)):
            raise HTTPException(status_code=422, detail="evidence must have unique ids")
        total_chars = sum(
            len(entry.id) + len(entry.title) + len(entry.source) + len(entry.content)
            for entry in evidence
        )
        if total_chars > 40_000:
            raise HTTPException(status_code=422, detail="evidence exceeds the 40000 character limit")
        result = await asyncio.to_thread(harness.answer, question, evidence)
        latency_ms = max(0.0, (time.perf_counter() - knowledge_started) * 1000.0)
        payload = result.to_dict()
        payload["harness_trace"] = HarnessTrace(
            stages=(result.to_stage_trace(latency_ms=latency_ms),)
        ).to_dict()
        return payload

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
                    context, allowed_tools, conversation_id = _parse_agent_request_options(
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
                            conversation_id=conversation_id,
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
    conversation_id: str,
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
            pending = await sessions.get_pending_action(session_id, conversation_id)
            follow_up = _classify_pending_follow_up(user_text) if pending else "new"
            if pending is not None and follow_up == "confirm":
                await sessions.clear_pending_action(session_id, conversation_id)
                result = await asyncio.to_thread(
                    factory.run_confirmed_action,
                    session_id,
                    request_id,
                    messages,
                    allowed_tools,
                    pending.tool_name,
                    pending.arguments,
                )
            elif pending is not None and follow_up == "reject":
                await sessions.clear_pending_action(session_id, conversation_id)
                result = _pending_action_cancelled_result(messages)
            else:
                if pending is not None:
                    await sessions.clear_pending_action(session_id, conversation_id)
                result = await asyncio.to_thread(
                    factory.run,
                    session_id,
                    request_id,
                    messages,
                    allowed_tools,
                )
                harness = result.tool_harness or {}
                suggested_tool = harness.get("suggested_tool")
                suggested_arguments = harness.get("suggested_arguments")
                suggested_action_text = harness.get("suggested_action_text")
                if (
                    result.route == "confirm_action"
                    and isinstance(suggested_tool, str)
                    and suggested_tool
                    and isinstance(suggested_arguments, dict)
                    and isinstance(suggested_action_text, str)
                    and suggested_action_text
                ):
                    await sessions.set_pending_action(
                        session_id,
                        conversation_id,
                        tool_name=suggested_tool,
                        arguments=suggested_arguments,
                        action_text=suggested_action_text,
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
                    "tool_harness": result.tool_harness or {},
                    "harness_trace": (
                        result.harness_trace.to_dict()
                        if result.harness_trace is not None
                        else HarnessTrace().to_dict()
                    ),
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
) -> tuple[dict[str, Any], list[str], str]:
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
    conversation_value = payload.get("conversation_id", "default")
    if not isinstance(conversation_value, str) or not conversation_value.strip():
        raise ProtocolError("payload.conversation_id must be a non-empty string")
    conversation_id = conversation_value.strip()
    if len(conversation_id) > 128:
        raise ProtocolError("payload.conversation_id exceeds the 128 character limit")
    return dict(context_value), allowed_tools, conversation_id


_PENDING_CONFIRMATIONS = frozenset(
    {"是", "是的", "对", "对的", "没错", "好的", "好", "可以", "确认", "就这个", "就是它"}
)
_PENDING_REJECTIONS = frozenset(
    {"不是", "不对", "取消", "算了", "不要", "不用", "不用了", "不需要"}
)


def _classify_pending_follow_up(text: str) -> str:
    normalized = re.sub(r"[\s，。！？、,.!?；;：:]+", "", text).strip()
    if normalized in _PENDING_CONFIRMATIONS:
        return "confirm"
    if normalized in _PENDING_REJECTIONS:
        return "reject"
    return "new"


def _pending_action_cancelled_result(
    messages: list[dict[str, Any]],
) -> AgentRunResult:
    answer = "好的，已取消，不执行任何操作。"
    return AgentRunResult(
        answer=answer,
        messages=[*messages, {"role": "assistant", "content": answer}],
        route="direct_answer",
        tool_name="respond_directly",
        tool_harness={
            "action": "respond",
            "reason": "pending_action_rejected",
            "tool_name": "",
            "arguments": {},
        },
    )


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
    visible_panels: list[str] = []
    album = context.get("album")
    if isinstance(album, dict):
        if album.get("visible") is True:
            visible_panels.append("album")
        result["album"] = {
            key: album.get(key)
            for key in ("visible", "page", "page_count", "can_next", "can_previous")
            if key in album
        }
    guide = context.get("task_guide")
    if isinstance(guide, dict):
        if guide.get("visible") is True:
            visible_panels.append("task_guide")
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
        result["task_guide"] = compact_guide
    result["visible_panels"] = visible_panels
    return result


app = create_app()
