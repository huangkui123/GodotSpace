from __future__ import annotations

import importlib.util
from importlib import metadata
from dataclasses import dataclass
from typing import Any

from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager


SYSTEM_MESSAGE = """You are the local GodotSpace control assistant.

Your current responsibility is deliberately narrow: help with explicitly requested,
reversible UI actions exposed through the available tools. Use a tool only when the
user clearly asks for that action. Pay special attention to negation, cancellation,
and quoted examples. Never claim an action succeeded until its tool result says
ok=true. Do not invent tools, Godot nodes, paths, object identifiers, or execution
results. If a tool is unavailable or fails, explain that briefly in Chinese.

For open_album specifically, call it only when the user asks to open, show, or view
the photo album. Do not call it for requests such as "不要打开相册" or when the user
is merely discussing the phrase. Return the final answer as concise plain Chinese
text without Markdown."""

EXPECTED_QWEN_AGENT_VERSION = "0.0.34"


@dataclass(slots=True)
class AgentRunResult:
    answer: str
    messages: list[dict[str, Any]]


class AgentFactory:
    def __init__(self, settings: Settings, connection_manager: ConnectionManager) -> None:
        self._settings = settings
        self._connection_manager = connection_manager

    @staticmethod
    def is_available() -> bool:
        return AgentFactory.installed_version() == EXPECTED_QWEN_AGENT_VERSION

    @staticmethod
    def installed_version() -> str:
        if importlib.util.find_spec("qwen_agent") is None:
            return ""
        try:
            return metadata.version("qwen-agent")
        except metadata.PackageNotFoundError:
            return "unknown"

    def run(
        self,
        session_id: str,
        request_id: str,
        messages: list[dict[str, Any]],
    ) -> AgentRunResult:
        from qwen_agent.agents import FnCallAgent

        from agent_service.tools import OpenAlbumTool

        tool = OpenAlbumTool(
            self._connection_manager,
            session_id,
            request_id,
            timeout_seconds=self._settings.tool_timeout_seconds,
            max_calls=self._settings.max_tool_calls_per_run,
        )
        bot = FnCallAgent(
            llm=self._llm_config(),
            function_list=[tool],
            name="GodotSpace Local Qwen Agent",
            system_message=SYSTEM_MESSAGE,
        )

        final_messages: list[Any] = []
        for response in bot.run(messages=messages, lang="zh"):
            final_messages = response

        serialized = [_message_to_dict(message) for message in final_messages]
        answer = _extract_final_answer(serialized)
        if not answer:
            raise RuntimeError("Qwen-Agent completed without a final assistant answer")
        return AgentRunResult(answer=answer, messages=serialized)

    def _llm_config(self) -> dict[str, Any]:
        return {
            "model_type": "qwenvl_oai",
            "model": self._settings.model_name,
            "model_server": self._settings.model_server,
            "api_key": self._settings.api_key,
            "generate_cfg": {
                "temperature": 0.1,
                "top_p": 0.8,
                "max_tokens": 256,
                "fncall_prompt_type": "nous",
            },
        }


def _message_to_dict(message: Any) -> dict[str, Any]:
    if isinstance(message, dict):
        return dict(message)
    if hasattr(message, "model_dump"):
        return message.model_dump(exclude_none=True)
    result: dict[str, Any] = {}
    for name in ("role", "content", "name", "function_call", "extra"):
        value = getattr(message, name, None)
        if value is not None:
            result[name] = value
    return result


def _extract_final_answer(messages: list[dict[str, Any]]) -> str:
    for message in reversed(messages):
        if message.get("role") != "assistant":
            continue
        content = message.get("content", "")
        if isinstance(content, str):
            if content.strip():
                return content.strip()
            continue
        if isinstance(content, list):
            text_parts: list[str] = []
            for item in content:
                if isinstance(item, dict) and isinstance(item.get("text"), str):
                    text_parts.append(item["text"])
            answer = "\n".join(text_parts).strip()
            if answer:
                return answer
    return ""
