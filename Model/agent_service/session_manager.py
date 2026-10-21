from __future__ import annotations

import asyncio
import time
from collections.abc import Callable, Coroutine
from dataclasses import dataclass, field, replace
from enum import Enum
from typing import Any

try:
    from enum import StrEnum
except ImportError:  # Python 3.10 deployment compatibility.
    class StrEnum(str, Enum):
        def __str__(self) -> str:
            return str(self.value)


class RequestPhase(StrEnum):
    QUEUED = "queued"
    MODEL_RUNNING = "model_running"
    TOOL_PENDING = "tool_pending"
    TOOL_DISPATCHED = "tool_dispatched"
    CANCELLED = "cancelled"
    COMPLETED = "completed"


class CancelOutcome(StrEnum):
    CANCELLED = "cancelled"
    TOO_LATE = "too_late"
    NOT_FOUND = "not_found"


@dataclass(slots=True)
class RequestRecord:
    phase: RequestPhase = RequestPhase.QUEUED
    state_changing_tool_dispatched: bool = False


@dataclass(frozen=True, slots=True)
class PendingAction:
    tool_name: str
    arguments: dict[str, Any]
    action_text: str
    expires_at_monotonic: float
    confirmation_id: str = ""
    hard_expires_at_monotonic: float = 0.0


@dataclass(slots=True)
class SessionState:
    session_id: str
    run_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    worker_task: asyncio.Task[Any] | None = None
    active_tasks: dict[str, asyncio.Task[Any]] = field(default_factory=dict)
    seen_request_ids: dict[str, None] = field(default_factory=dict)
    requests: dict[str, RequestRecord] = field(default_factory=dict)
    pending_actions: dict[str, PendingAction] = field(default_factory=dict)
    last_access_monotonic: float = field(default_factory=time.monotonic)


class SessionManager:
    """Owns request deduplication and lifecycle for a transport session.

    Qwen conversation history deliberately does not live here. Each accepted request
    is independent even when several speakers share one Godot websocket connection.
    """

    def __init__(
        self,
        *,
        max_recent_request_ids: int = 128,
        max_sessions: int = 64,
    ) -> None:
        self._max_recent_request_ids = max_recent_request_ids
        self._max_sessions = max_sessions
        self._sessions: dict[str, SessionState] = {}
        self._lock = asyncio.Lock()

    async def get(self, session_id: str) -> SessionState:
        async with self._lock:
            return self._get_or_create_locked(session_id)

    async def start_task(
        self,
        session_id: str,
        request_id: str,
        coroutine_factory: Callable[[], Coroutine[Any, Any, Any]],
    ) -> asyncio.Task[Any] | None:
        """Atomically reserve a request ID and register its task before it can run."""
        async with self._lock:
            state = self._get_or_create_locked(session_id)
            if request_id in state.seen_request_ids:
                return None
            state.seen_request_ids[request_id] = None
            state.requests[request_id] = RequestRecord()
            try:
                task = asyncio.create_task(coroutine_factory())
            except Exception:
                state.seen_request_ids.pop(request_id, None)
                state.requests.pop(request_id, None)
                raise
            state.active_tasks[request_id] = task
            task.add_done_callback(
                lambda _task: asyncio.create_task(
                    self.finish_task(session_id, request_id)
                )
            )
            self._trim_request_ids(state)
            return task

    async def mark_model_running(self, session_id: str, request_id: str) -> bool:
        async with self._lock:
            record = self._find_record_locked(session_id, request_id)
            if record is None or record.phase == RequestPhase.CANCELLED:
                return False
            if record.phase in (RequestPhase.COMPLETED, RequestPhase.TOOL_DISPATCHED):
                return False
            record.phase = RequestPhase.MODEL_RUNNING
            return True

    async def begin_tool_call(self, session_id: str, request_id: str) -> bool:
        async with self._lock:
            record = self._find_record_locked(session_id, request_id)
            if record is None or record.phase in (
                RequestPhase.CANCELLED,
                RequestPhase.COMPLETED,
            ):
                return False
            record.phase = RequestPhase.TOOL_PENDING
            return True

    async def commit_tool_dispatch(
        self,
        session_id: str,
        request_id: str,
        *,
        state_changing: bool,
    ) -> bool:
        async with self._lock:
            record = self._find_record_locked(session_id, request_id)
            if record is None or record.phase == RequestPhase.CANCELLED:
                return False
            if record.phase != RequestPhase.TOOL_PENDING:
                return False
            record.phase = RequestPhase.TOOL_DISPATCHED
            if state_changing:
                record.state_changing_tool_dispatched = True
            return True

    async def finish_tool_call(self, session_id: str, request_id: str) -> None:
        async with self._lock:
            record = self._find_record_locked(session_id, request_id)
            if record is not None and record.phase == RequestPhase.TOOL_DISPATCHED:
                record.phase = RequestPhase.MODEL_RUNNING

    async def cancel(self, session_id: str, request_id: str) -> CancelOutcome:
        task: asyncio.Task[Any] | None = None
        async with self._lock:
            state = self._sessions.get(session_id)
            record = state.requests.get(request_id) if state is not None else None
            if record is None:
                return CancelOutcome.NOT_FOUND
            if record.phase == RequestPhase.COMPLETED:
                return CancelOutcome.TOO_LATE
            if record.state_changing_tool_dispatched:
                return CancelOutcome.TOO_LATE
            if record.phase == RequestPhase.CANCELLED:
                return CancelOutcome.CANCELLED
            record.phase = RequestPhase.CANCELLED
            task = state.active_tasks.get(request_id)
        if task is not None and not task.done():
            task.cancel()
        return CancelOutcome.CANCELLED

    async def can_publish(self, session_id: str, request_id: str) -> bool:
        async with self._lock:
            record = self._find_record_locked(session_id, request_id)
            return record is not None and record.phase != RequestPhase.CANCELLED

    async def phase(
        self, session_id: str, request_id: str
    ) -> RequestPhase | None:
        async with self._lock:
            record = self._find_record_locked(session_id, request_id)
            return record.phase if record is not None else None

    async def has_seen_request(self, session_id: str, request_id: str) -> bool:
        state = await self.get(session_id)
        return request_id in state.seen_request_ids

    async def set_pending_action(
        self,
        session_id: str,
        conversation_id: str,
        *,
        tool_name: str,
        arguments: dict[str, Any],
        action_text: str,
        ttl_seconds: float = 30.0,
        confirmation_id: str = "",
    ) -> None:
        async with self._lock:
            state = self._get_or_create_locked(session_id)
            state.pending_actions[conversation_id] = PendingAction(
                tool_name=tool_name,
                arguments=dict(arguments),
                action_text=action_text,
                expires_at_monotonic=time.monotonic() + max(0.0, ttl_seconds),
                confirmation_id=confirmation_id,
                hard_expires_at_monotonic=time.monotonic() + 300.0,
            )

    async def update_confirmation(
        self, session_id: str, conversation_id: str, confirmation_id: str, phase: str,
    ) -> PendingAction | None:
        async with self._lock:
            state = self._sessions.get(session_id)
            pending = state.pending_actions.get(conversation_id) if state else None
            if pending is None or pending.confirmation_id != confirmation_id:
                return None
            now = time.monotonic()
            if phase == "cancel" or now >= min(pending.expires_at_monotonic, pending.hard_expires_at_monotonic):
                state.pending_actions.pop(conversation_id, None)
                return None
            ttl = 180.0 if phase == "speaking" else 20.0
            pending = replace(pending, expires_at_monotonic=min(now + ttl, pending.hard_expires_at_monotonic))
            state.pending_actions[conversation_id] = pending
            return pending

    async def clear_confirmations(self, session_id: str) -> None:
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is not None:
                state.pending_actions.clear()

    async def get_pending_action(
        self, session_id: str, conversation_id: str
    ) -> PendingAction | None:
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is None:
                return None
            pending = state.pending_actions.get(conversation_id)
            if pending is None:
                return None
            if pending.expires_at_monotonic <= time.monotonic():
                state.pending_actions.pop(conversation_id, None)
                return None
            state.last_access_monotonic = time.monotonic()
            return pending

    async def clear_pending_action(
        self, session_id: str, conversation_id: str
    ) -> PendingAction | None:
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is None:
                return None
            state.last_access_monotonic = time.monotonic()
            return state.pending_actions.pop(conversation_id, None)

    async def finish_task(self, session_id: str, request_id: str) -> None:
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is None:
                return
            state.last_access_monotonic = time.monotonic()
            state.active_tasks.pop(request_id, None)
            record = state.requests.get(request_id)
            if record is not None and record.phase != RequestPhase.CANCELLED:
                record.phase = RequestPhase.COMPLETED
            self._trim_request_ids(state)

    async def remove_if_idle(self, session_id: str) -> None:
        """Retain bounded request IDs so reconnects remain idempotent."""
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is not None:
                state.last_access_monotonic = time.monotonic()
            self._prune_oldest_idle_session()

    def _get_or_create_locked(self, session_id: str) -> SessionState:
        state = self._sessions.get(session_id)
        if state is None:
            self._prune_oldest_idle_session()
            state = SessionState(session_id=session_id)
            self._sessions[session_id] = state
        state.last_access_monotonic = time.monotonic()
        return state

    def _find_record_locked(
        self, session_id: str, request_id: str
    ) -> RequestRecord | None:
        state = self._sessions.get(session_id)
        if state is None:
            return None
        state.last_access_monotonic = time.monotonic()
        return state.requests.get(request_id)

    def _trim_request_ids(self, state: SessionState) -> None:
        while len(state.seen_request_ids) > self._max_recent_request_ids:
            removed = False
            for request_id in list(state.seen_request_ids):
                if request_id not in state.active_tasks:
                    state.seen_request_ids.pop(request_id, None)
                    state.requests.pop(request_id, None)
                    removed = True
                    break
            if not removed:
                break

    def _prune_oldest_idle_session(self) -> None:
        while len(self._sessions) >= self._max_sessions:
            idle = [
                state
                for state in self._sessions.values()
                if not state.active_tasks and not state.run_lock.locked()
                and (state.worker_task is None or state.worker_task.done())
            ]
            if not idle:
                return
            oldest = min(idle, key=lambda state: state.last_access_monotonic)
            self._sessions.pop(oldest.session_id, None)
