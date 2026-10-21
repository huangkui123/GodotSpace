from __future__ import annotations

import unittest

from agent_service.protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    make_envelope,
    parse_envelope,
    require_payload_string,
    validate_tool_result_payload,
)


class ProtocolTests(unittest.TestCase):
    def test_round_trip_envelope(self) -> None:
        envelope = make_envelope(
            "user_message",
            {"text": "打开相册"},
            session_id="session-1",
            request_id="request-1",
        )
        parsed = parse_envelope(envelope)
        self.assertEqual(parsed["protocol_version"], PROTOCOL_VERSION)
        self.assertEqual(parsed["type"], "user_message")
        self.assertEqual(parsed["payload"]["text"], "打开相册")

    def test_rejects_unknown_protocol_version(self) -> None:
        envelope = make_envelope("ping")
        envelope["protocol_version"] = "99"
        with self.assertRaises(ProtocolError):
            parse_envelope(envelope)

    def test_rejects_non_object_payload(self) -> None:
        envelope = make_envelope("ping")
        envelope["payload"] = []
        with self.assertRaises(ProtocolError):
            parse_envelope(envelope)

    def test_payload_string_limit(self) -> None:
        envelope = make_envelope("user_message", {"text": "12345"})
        parsed = parse_envelope(envelope)
        with self.assertRaises(ProtocolError):
            require_payload_string(parsed, "text", max_chars=4)

    def test_tool_result_contract_is_strict(self) -> None:
        validate_tool_result_payload(
            {"ok": True, "data": {"visible": True}, "error": None}
        )
        with self.assertRaises(ProtocolError):
            validate_tool_result_payload(
                {"ok": "yes", "data": {"visible": True}, "error": None}
            )
        with self.assertRaises(ProtocolError):
            validate_tool_result_payload(
                {"ok": False, "data": {}, "error": None}
            )
        with self.assertRaises(ProtocolError):
            validate_tool_result_payload(
                {
                    "ok": False,
                    "data": {},
                    "error": {"code": "", "message": "failed"},
                }
            )
        validate_tool_result_payload(
            {
                "ok": False,
                "data": {},
                "error": {"code": "not_ready", "message": "Godot is not ready"},
            }
        )


if __name__ == "__main__":
    unittest.main()
