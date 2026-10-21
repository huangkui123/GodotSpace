from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from agent_service.config import Settings


class SettingsTests(unittest.TestCase):
    def test_model_adapter_defaults_preserve_production_behavior(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            settings = Settings.from_env()

        self.assertEqual(settings.model_type, "qwenvl_oai")
        self.assertFalse(settings.model_use_raw_api)
        self.assertEqual(settings.model_fncall_prompt_type, "nous")
        self.assertIsNone(settings.model_enable_thinking)

    def test_model_adapter_can_use_native_openai_tool_calls(self) -> None:
        env = {
            "MODEL_TYPE": "oai",
            "MODEL_USE_RAW_API": "true",
            "MODEL_FNCALL_PROMPT_TYPE": "nous",
            "MODEL_ENABLE_THINKING": "false",
        }
        with patch.dict(os.environ, env, clear=True):
            settings = Settings.from_env()

        self.assertEqual(settings.model_type, "oai")
        self.assertTrue(settings.model_use_raw_api)
        self.assertFalse(settings.model_enable_thinking)

    def test_model_adapter_rejects_invalid_boolean(self) -> None:
        with patch.dict(os.environ, {"MODEL_USE_RAW_API": "sometimes"}, clear=True):
            with self.assertRaisesRegex(ValueError, "MODEL_USE_RAW_API"):
                Settings.from_env()


if __name__ == "__main__":
    unittest.main()
