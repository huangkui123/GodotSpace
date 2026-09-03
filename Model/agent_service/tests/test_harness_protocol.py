from __future__ import annotations

import unittest

from agent_service.harness_protocol import HarnessStageTrace, HarnessTrace


class HarnessProtocolTests(unittest.TestCase):
    def test_serializes_versioned_ordered_stages(self) -> None:
        tool_stage = HarnessStageTrace(
            stage_type="tool_call",
            outcome="executed",
            reason="verified_semantic_tool_call",
            model_attempts=1,
            latency_ms=12.345,
            details={"tool_name": "query_task_knowledge"},
        )
        knowledge_stage = HarnessStageTrace(
            stage_type="knowledge_qa",
            outcome="answered",
            reason="deterministic_evidence",
            fallback_used=False,
            details={"citation_ids": ["entry-1"]},
        )

        trace = HarnessTrace(stages=(tool_stage,)).append(knowledge_stage)

        self.assertEqual(
            trace.to_dict(),
            {
                "version": 1,
                "stages": [
                    {
                        "type": "tool_call",
                        "outcome": "executed",
                        "reason": "verified_semantic_tool_call",
                        "model_attempts": 1,
                        "fallback_used": False,
                        "latency_ms": 12.3,
                        "details": {"tool_name": "query_task_knowledge"},
                    },
                    {
                        "type": "knowledge_qa",
                        "outcome": "answered",
                        "reason": "deterministic_evidence",
                        "model_attempts": 0,
                        "fallback_used": False,
                        "latency_ms": None,
                        "details": {"citation_ids": ["entry-1"]},
                    },
                ],
            },
        )

    def test_rejects_invalid_common_fields(self) -> None:
        invalid = (
            {"stage_type": "", "outcome": "answered", "reason": "ok"},
            {"stage_type": "test", "outcome": "unknown", "reason": "ok"},
            {"stage_type": "test", "outcome": "answered", "reason": ""},
            {
                "stage_type": "test",
                "outcome": "answered",
                "reason": "ok",
                "model_attempts": -1,
            },
            {
                "stage_type": "test",
                "outcome": "answered",
                "reason": "ok",
                "latency_ms": float("nan"),
            },
        )
        for values in invalid:
            with self.subTest(values=values):
                with self.assertRaises(ValueError):
                    HarnessStageTrace(**values)  # type: ignore[arg-type]

    def test_empty_trace_has_stable_shape(self) -> None:
        self.assertEqual(HarnessTrace().to_dict(), {"version": 1, "stages": []})


if __name__ == "__main__":
    unittest.main()
