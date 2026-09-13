from __future__ import annotations

import asyncio
import json
import os
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from fastapi.testclient import TestClient
from agent_service.app import create_app
from agent_service.agent_factory import AgentFactory, AgentRunResult
from agent_service.config import Settings
from agent_service.confirmation import classify_reply
from agent_service.connection_manager import ConnectionManager, GodotRequestCancelledError
from agent_service.protocol import make_envelope
from agent_service.session_manager import SessionManager
from agent_service.tests.test_app_websocket import PendingConfirmationAgentFactory


class ConfirmationTests(unittest.TestCase):
    def test_positive_reply_requires_matching_action(self):
        with patch('openai.OpenAI', side_effect=RuntimeError('offline')):
            self.assertEqual(classify_reply('是的，打开吧。', '打开工作清单', Settings()), 'confirm')
            self.assertEqual(classify_reply('是的，打开吧。', '关闭工作清单', Settings()), 'unclear')
            self.assertEqual(classify_reply('是的，但不要打开', '打开工作清单', Settings()), 'unclear')
            self.assertEqual(classify_reply('是吗？', '打开工作清单', Settings()), 'unclear')

    def test_model_verdict_is_checked_and_negation_cannot_confirm(self):
        for verdict, text, expected in [
            ('confirm', '就按你说的办', 'confirm'),
            ('confirm', '是的，但不要打开', 'unclear'),
            ('new', '改成第八页', 'new'),
            ('invalid', '就按你说的办', 'unclear'),
        ]:
            with self.subTest(text=text, verdict=verdict), patch('openai.OpenAI') as api:
                api.return_value.__enter__.return_value.chat.completions.create.return_value = SimpleNamespace(
                    choices=[SimpleNamespace(message=SimpleNamespace(tool_calls=[SimpleNamespace(
                        function=SimpleNamespace(name='resolve_confirmation', arguments=json.dumps({'verdict': verdict})))]))])
                self.assertEqual(classify_reply(text, '打开工作清单', Settings()), expected)

    def test_model_deadlines_configured_and_finite(self):
        with patch.dict(os.environ, {'AGENT_MODEL_TIMEOUT': '12', 'AGENT_RUN_TIMEOUT': '40'}, clear=True):
            settings = Settings.from_env()
        self.assertEqual(settings.run_timeout_seconds, 40)
        self.assertEqual(AgentFactory(settings, ConnectionManager())._llm_config()['generate_cfg']['request_timeout'], 12)
        for value in ('nan', 'inf', '-1'):
            with patch.dict(os.environ, {'AGENT_RUN_TIMEOUT': value}, clear=True), self.assertRaises(ValueError):
                Settings.from_env()


class LeaseTests(unittest.IsolatedAsyncioTestCase):
    async def test_renewal_identity_hard_limit_and_expired_cannot_revive(self):
        manager = SessionManager()
        with patch('agent_service.session_manager.time.monotonic', return_value=100):
            await manager.set_pending_action('s', 'p', tool_name='open_task_guide', arguments={},
                                             action_text='打开工作清单', confirmation_id='c', ttl_seconds=180)
        with patch('agent_service.session_manager.time.monotonic', return_value=140):
            self.assertIsNone(await manager.update_confirmation('s', 'other', 'c', 'cancel'))
            self.assertIsNone(await manager.update_confirmation('s', 'p', 'stale', 'cancel'))
            renewed = await manager.update_confirmation('s', 'p', 'c', 'listening')
            self.assertEqual(renewed.expires_at_monotonic, 160)
        with patch('agent_service.session_manager.time.monotonic', return_value=150):
            await manager.update_confirmation('s', 'p', 'c', 'speaking')
        with patch('agent_service.session_manager.time.monotonic', return_value=320):
            renewed = await manager.update_confirmation('s', 'p', 'c', 'speaking')
            self.assertEqual(renewed.expires_at_monotonic, 400)
        with patch('agent_service.session_manager.time.monotonic', return_value=401):
            self.assertIsNone(await manager.update_confirmation('s', 'p', 'c', 'listening'))
            self.assertIsNone(await manager.get_pending_action('s', 'p'))


class WireTests(unittest.TestCase):
    @staticmethod
    def hello(ws):
        ws.send_json(make_envelope('hello', {'client_id': 'test'}, session_id='lifecycle-test'))
        return ws.receive_json()['session_id']

    @staticmethod
    def request(ws, sid, rid, text, cid=''):
        ws.send_json(make_envelope('user_message', {'text': text, 'conversation_id': 'p',
            'allowed_tools': ['open_task_guide'], 'confirmation_id': cid}, session_id=sid, request_id=rid))
        while True:
            event = ws.receive_json()
            if event['type'] in ('assistant_final', 'run_error'):
                return event

    @staticmethod
    def update(ws, sid, cid, phase):
        ws.send_json(make_envelope('confirmation_update', {'conversation_id': 'p',
            'confirmation_id': cid, 'phase': phase}, session_id=sid))
        return ws.receive_json()['payload']

    def test_lease_roundtrip_and_natural_confirmation(self):
        factory = PendingConfirmationAgentFactory()
        with TestClient(create_app(Settings(), agent_factory=factory)) as client:
            with client.websocket_connect('/ws/godot') as ws:
                sid = self.hello(ws)
                cid = self.request(ws, sid, 'r1', '打开工作文档')['payload']['confirmation_id']
                self.assertEqual(cid, 'r1')
                self.assertTrue(self.update(ws, sid, cid, 'speaking')['active'])
                self.assertTrue(self.update(ws, sid, cid, 'listening')['active'])
                final = self.request(ws, sid, 'r2', '是的，打开吧', cid)
                self.assertEqual(final['payload']['answer'], '工作清单已打开。')
        self.assertEqual(len(factory.confirmed), 1)

    def test_unclear_keeps_id_and_cancelled_reply_cannot_execute(self):
        factory = PendingConfirmationAgentFactory()
        with TestClient(create_app(Settings(), agent_factory=factory)) as client:
            with client.websocket_connect('/ws/godot') as ws:
                sid = self.hello(ws)
                cid = self.request(ws, sid, 'r1', '打开工作文档')['payload']['confirmation_id']
                with patch('agent_service.app.classify_reply', return_value='unclear'):
                    final = self.request(ws, sid, 'r2', '你说的是哪个', cid)
                self.assertEqual(final['payload']['confirmation_id'], cid)
                self.assertEqual(final['payload']['route'], 'confirm_action')
                self.assertFalse(self.update(ws, sid, cid, 'cancel')['active'])
                self.assertEqual(self.request(ws, sid, 'r3', '是的', cid)['type'], 'run_error')
        self.assertFalse(factory.confirmed)

    def test_disconnect_invalidates_confirmation(self):
        factory = PendingConfirmationAgentFactory()
        with TestClient(create_app(Settings(), agent_factory=factory)) as client:
            with client.websocket_connect('/ws/godot') as ws:
                sid = self.hello(ws)
                cid = self.request(ws, sid, 'r1', '打开工作文档')['payload']['confirmation_id']
            with client.websocket_connect('/ws/godot') as ws:
                sid = self.hello(ws)
                self.assertEqual(self.request(ws, sid, 'r2', '是的', cid)['type'], 'run_error')
        self.assertFalse(factory.confirmed)

    def test_timeout_blocks_late_tools_and_retains_worker_slot(self):
        connections = ConnectionManager()
        release, finished = threading.Event(), threading.Event()
        class BlockingFactory:
            calls = 0
            error = None
            def run(self, sid, rid, messages, tools):
                self.calls += 1
                if rid == 'r1':
                    release.wait(3)
                    try:
                        connections.request_tool_sync(sid, rid, 'open_task_guide', {}, .2)
                    except Exception as exc:
                        self.error = exc
                    finally:
                        finished.set()
                return AgentRunResult(answer='done', messages=messages)
        factory = BlockingFactory()
        with TestClient(create_app(Settings(run_timeout_seconds=.15), connection_manager=connections, agent_factory=factory)) as client:
            with client.websocket_connect('/ws/godot') as ws:
                sid = self.hello(ws)
                try:
                    error = self.request(ws, sid, 'r1', '打开工作清单')
                    self.assertEqual(error['payload']['code'], 'run_timeout')
                    self.assertEqual(self.request(ws, sid, 'r2', '打开工作清单')['type'], 'run_error')
                    self.assertEqual(factory.calls, 1)
                finally:
                    release.set()
                self.assertTrue(finished.wait(1))
                self.assertIsInstance(factory.error, GodotRequestCancelledError)


if __name__ == '__main__':
    unittest.main()
