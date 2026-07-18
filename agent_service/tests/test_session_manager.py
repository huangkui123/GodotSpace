from __future__ import annotations

import asyncio
import unittest

from agent_service.session_manager import SessionManager


class SessionManagerTests(unittest.IsolatedAsyncioTestCase):
    async def test_history_is_bounded(self) -> None:
        manager = SessionManager(max_history_messages=4)
        await manager.append_turn("session-1", "q1", "a1")
        await manager.append_turn("session-1", "q2", "a2")
        await manager.append_turn("session-1", "q3", "a3")
        messages = await manager.build_messages("session-1", "q4")
        self.assertEqual(
            messages,
            [
                {"role": "user", "content": "q2"},
                {"role": "assistant", "content": "a2"},
                {"role": "user", "content": "q3"},
                {"role": "assistant", "content": "a3"},
                {"role": "user", "content": "q4"},
            ],
        )

    async def test_completed_request_id_remains_deduplicated(self) -> None:
        manager = SessionManager()

        async def complete_immediately() -> None:
            return None

        task = await manager.start_task(
            "session-1", "request-1", complete_immediately
        )
        self.assertIsNotNone(task)
        await task
        await manager.finish_task("session-1", "request-1")

        duplicate = await manager.start_task(
            "session-1", "request-1", complete_immediately
        )
        self.assertIsNone(duplicate)

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

    async def test_cancel_stops_an_active_task(self) -> None:
        manager = SessionManager()
        started = asyncio.Event()

        async def wait_forever() -> None:
            started.set()
            await asyncio.Event().wait()

        task = await manager.start_task("session-1", "request-1", wait_forever)
        self.assertIsNotNone(task)
        await started.wait()
        self.assertTrue(await manager.cancel("session-1", "request-1"))
        with self.assertRaises(asyncio.CancelledError):
            await task
        await manager.finish_task("session-1", "request-1")
        self.assertFalse(await manager.cancel("session-1", "request-1"))
        self.assertTrue(await manager.has_seen_request("session-1", "request-1"))

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
