from __future__ import annotations

import asyncio
import time
from collections.abc import Callable, Coroutine
from dataclasses import dataclass, field
from typing import Any


@dataclass(slots=True)
class SessionState:
    session_id: str
    history: list[dict[str, str]] = field(default_factory=list)
    run_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    active_tasks: dict[str, asyncio.Task[Any]] = field(default_factory=dict)
    seen_request_ids: dict[str, None] = field(default_factory=dict)
    last_access_monotonic: float = field(default_factory=time.monotonic)


class SessionManager:
    def __init__(
        self,
        max_history_messages: int = 8,
        *,
        max_recent_request_ids: int = 128,
        max_sessions: int = 64,
    ) -> None:
        self._max_history_messages = max_history_messages
        self._max_recent_request_ids = max_recent_request_ids
        self._max_sessions = max_sessions
        self._sessions: dict[str, SessionState] = {}
        self._lock = asyncio.Lock()

    async def get(self, session_id: str) -> SessionState:
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is None:
                self._prune_oldest_idle_session()
                state = SessionState(session_id=session_id)
                self._sessions[session_id] = state
            state.last_access_monotonic = time.monotonic()
            return state

    async def build_messages(self, session_id: str, user_text: str) -> list[dict[str, str]]:
        state = await self.get(session_id)
        return [*state.history, {"role": "user", "content": user_text}]

    async def append_turn(self, session_id: str, user_text: str, answer: str) -> None:
        state = await self.get(session_id)
        state.history.extend(
            [
                {"role": "user", "content": user_text},
                {"role": "assistant", "content": answer},
            ]
        )
        if len(state.history) > self._max_history_messages:
            state.history = state.history[-self._max_history_messages :]

    async def start_task(
        self,
        session_id: str,
        request_id: str,
        coroutine_factory: Callable[[], Coroutine[Any, Any, Any]],
    ) -> asyncio.Task[Any] | None:
        """Atomically reserve a request ID and register its task before it can run."""
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is None:
                self._prune_oldest_idle_session()
                state = SessionState(session_id=session_id)
                self._sessions[session_id] = state
            state.last_access_monotonic = time.monotonic()
            if request_id in state.seen_request_ids:
                return None
            state.seen_request_ids[request_id] = None
            try:
                task = asyncio.create_task(coroutine_factory())
            except Exception:
                state.seen_request_ids.pop(request_id, None)
                raise
            state.active_tasks[request_id] = task
            self._trim_request_ids(state)
            return task

    async def has_seen_request(self, session_id: str, request_id: str) -> bool:
        state = await self.get(session_id)
        return request_id in state.seen_request_ids

    async def finish_task(self, session_id: str, request_id: str) -> None:
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is None:
                return
            state.last_access_monotonic = time.monotonic()
            state.active_tasks.pop(request_id, None)
            self._trim_request_ids(state)

    async def cancel(self, session_id: str, request_id: str) -> bool:
        state = await self.get(session_id)
        task = state.active_tasks.get(request_id)
        if task is None or task.done():
            return False
        task.cancel()
        return True

    async def remove_if_idle(self, session_id: str) -> None:
        """Retain bounded idle session state so reconnects remain idempotent."""
        async with self._lock:
            state = self._sessions.get(session_id)
            if state is not None:
                state.last_access_monotonic = time.monotonic()
            self._prune_oldest_idle_session()

    def _trim_request_ids(self, state: SessionState) -> None:
        while len(state.seen_request_ids) > self._max_recent_request_ids:
            removed = False
            for request_id in list(state.seen_request_ids):
                if request_id not in state.active_tasks:
                    state.seen_request_ids.pop(request_id, None)
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
            ]
            if not idle:
                return
            oldest = min(idle, key=lambda state: state.last_access_monotonic)
            self._sessions.pop(oldest.session_id, None)
