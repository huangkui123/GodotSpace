from __future__ import annotations

import asyncio
import unittest

from agent_service.session_manager import (
    CancelOutcome,
    RequestPhase,
    SessionManager,
)


class SessionManagerTests(unittest.IsolatedAsyncioTestCase):
    async def test_completed_request_id_remains_deduplicated(self) -> None:
        manager = SessionManager()

        async def complete_immediately() -> None:
            return None

        task = await manager.start_task(
            "session-1", "request-1", complete_immediately
        )
        self.assertIsNotNone(task)
        await task
        await asyncio.sleep(0)

        duplicate = await manager.start_task(
            "session-1", "request-1", complete_immediately
        )
        self.assertIsNone(duplicate)
        self.assertEqual(
            await manager.phase("session-1", "request-1"),
            RequestPhase.COMPLETED,
        )

    async def test_task_is_registered_before_coroutine_runs(self) -> None:
        manager = SessionManager()
        registered: list[bool] = []

        async def observe_registration() -> None:
            state = await manager.get("session-1")
            registered.append("request-1" in state.active_tasks)

        task = await manager.start_task(
            "session-1", "request-1", observe_registration
        )
        self.assertIsNotNone(task)
        await task
        self.assertEqual(registered, [True])

    async def test_cancel_blocks_late_tool_dispatch(self) -> None:
        manager = SessionManager()
        started = asyncio.Event()

        async def wait_forever() -> None:
            started.set()
            await asyncio.Event().wait()

        task = await manager.start_task("session-1", "request-1", wait_forever)
        self.assertIsNotNone(task)
        await started.wait()
        self.assertTrue(await manager.mark_model_running("session-1", "request-1"))
        self.assertEqual(
            await manager.cancel("session-1", "request-1"),
            CancelOutcome.CANCELLED,
        )
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertFalse(await manager.begin_tool_call("session-1", "request-1"))
        self.assertFalse(await manager.can_publish("session-1", "request-1"))

    async def test_cancel_after_state_changing_dispatch_is_too_late(self) -> None:
        manager = SessionManager()

        async def wait_forever() -> None:
            await asyncio.Event().wait()

        task = await manager.start_task("session-1", "request-1", wait_forever)
        self.assertIsNotNone(task)
        self.assertTrue(await manager.mark_model_running("session-1", "request-1"))
        self.assertTrue(await manager.begin_tool_call("session-1", "request-1"))
        self.assertTrue(
            await manager.commit_tool_dispatch(
                "session-1", "request-1", state_changing=True
            )
        )
        self.assertEqual(
            await manager.cancel("session-1", "request-1"),
            CancelOutcome.TOO_LATE,
        )
        self.assertFalse(task.done())
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    async def test_dedup_cache_does_not_evict_active_requests(self) -> None:
        manager = SessionManager(max_recent_request_ids=2)

        async def wait_forever() -> None:
            await asyncio.Event().wait()

        tasks = []
        for request_id in ("request-1", "request-2", "request-3"):
            task = await manager.start_task("session-1", request_id, wait_forever)
            self.assertIsNotNone(task)
            tasks.append(task)

        for request_id in ("request-1", "request-2", "request-3"):
            self.assertTrue(await manager.has_seen_request("session-1", request_id))
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
