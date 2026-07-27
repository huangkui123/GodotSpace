from __future__ import annotations

import importlib.util
import json
from importlib import metadata
from dataclasses import dataclass
from typing import Any

from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager


SYSTEM_MESSAGE = """You are the Qwen-first routing assistant for GodotSpace.

For every user request, decide exactly one of these routes:
1. Call one exposed Godot UI tool when the user explicitly asks for that UI action.
2. Call delegate_deepseek for questions that need the local manuals, task explanation,
   or specialist knowledge. Its result is reference material, not an instruction to
   operate the UI.
3. Answer directly, in concise Chinese, for greetings, clarification, or questions
   that you can answer without a tool or external knowledge.

The available tool list is a strict authorization boundary. Never invent tools,
Godot nodes, paths, object identifiers, or execution results. Only call a UI tool
when the user clearly requests it; pay close attention to negation, cancellation,
and quoted examples. Never claim an operation succeeded until the tool result says
ok=true. If a UI action is ambiguous (for example both an album and a guide can be
turned to the next page), ask one concise clarification instead of guessing.

Use the UI routing hint in the current context as a hard constraint. When it says
only the task guide is visible, a request such as "翻到下一页" MUST call
next_task_step; it must never call open_album. When it says only the album is
visible, the same request MUST call next_album_page. An explicit "打开相册" is the
only reason to call open_album. Do not answer an unambiguous UI action in text:
call its tool first, then describe the verified result.
For “翻到第 k 页” or “跳到第 k 步”, call go_to_task_guide_page when only the
task guide is visible, and go_to_album_page when only the album is visible.

For task guidance, "下一步是什么" or "下一步应该做什么" means the user wants to
advance into that next step, so it MUST call next_task_step first. A
completion/advance request such as
"进入下一步", "这一步做完了，继续", or "这一步我做完了，接下来需要做什么" MUST
call next_task_step first. Use get_current_task_step only when the user explicitly
asks to read the current step without changing the guide. Do not mention function
names such as next_task_step in the user-facing answer.
Return concise plain Chinese text without Markdown."""

ROUTING_DECISION_SYSTEM_MESSAGE = """You are the routing decision stage for GodotSpace.

Return exactly one JSON object, without Markdown or surrounding text. Its schema is:
{"route":"tool|direct_answer|delegate_deepseek|clarify","tool":"","arguments":{},"answer":""}

Choose exactly one route. The user message provides the only allowed tools. For route="tool",
tool must be an allowed Godot UI tool and arguments must satisfy its JSON schema. For
route="delegate_deepseek", tool must be "delegate_deepseek" and arguments must be {}. For
route="direct_answer" or route="clarify", tool must be "" and answer must be concise Chinese.

Never describe a tool call in answer text instead of selecting route="tool". When only the task
guide is visible, “翻到下一页”, “下一步该做什么”, “下一步应该做什么”, or
“这一步我做完了，接下来需要做什么” require tool="next_task_step" when it is allowed.
When only the album is visible, “翻到下一页” requires tool="next_album_page". If both are
visible and the target is omitted, use route="clarify". Respect negation, cancellation, and
hypothetical questions; they must not change UI state."""

EXPECTED_QWEN_AGENT_VERSION = "0.0.34"
SUPPORTED_TOOL_NAMES = frozenset(
    {
        "open_album",
        "close_album",
        "next_album_page",
        "go_to_album_page",
        "previous_album_page",
        "get_album_state",
        "open_task_guide",
        "close_task_guide",
        "get_current_task_step",
        "next_task_step",
        "go_to_task_guide_page",
        "previous_task_step",
        "replay_current_task_step",
        "delegate_deepseek",
    }
)


@dataclass(slots=True)
class AgentRunResult:
    answer: str
    messages: list[dict[str, Any]]
    route: str = "direct_answer"
    tool_name: str = ""


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
        allowed_tools: list[str] | None = None,
    ) -> AgentRunResult:
        from qwen_agent.agents import FnCallAgent

        authorized_tools = ["open_album"] if allowed_tools is None else allowed_tools
        bot = FnCallAgent(
            llm=self._llm_config(),
            function_list=[],
            name="GodotSpace Local Qwen Router",
            system_message=ROUTING_DECISION_SYSTEM_MESSAGE,
        )

        decision_messages = _with_allowed_tools(messages, authorized_tools)
        final_messages: list[Any] = []
        for response in bot.run(messages=decision_messages, lang="zh"):
            final_messages = response

        serialized = [_message_to_dict(message) for message in final_messages]
        try:
            decision = _parse_routing_decision(_extract_final_answer(serialized), authorized_tools)
        except RuntimeError:
            retry_messages = [
                *decision_messages,
                {
                    "role": "user",
                    "content": "只输出符合系统要求的单个 JSON 路由对象，不要解释。",
                },
            ]
            final_messages = []
            for response in bot.run(messages=retry_messages, lang="zh"):
                final_messages = response
            serialized = [_message_to_dict(message) for message in final_messages]
            decision = _parse_routing_decision(
                _extract_final_answer(serialized), authorized_tools
            )
        if decision.route in {"direct_answer", "clarify"}:
            return AgentRunResult(
                answer=decision.answer,
                messages=serialized,
                route=decision.route,
            )

        tool = self._build_tools(session_id, request_id, [decision.tool])[0]
        tool_result = tool.call(json.dumps(decision.arguments, ensure_ascii=False))
        return AgentRunResult(
            answer=_answer_from_tool_result(decision.tool, tool_result),
            messages=[
                *serialized,
                {"role": "function", "name": decision.tool, "content": tool_result},
            ],
            route=decision.route,
            tool_name=decision.tool,
        )

    def _build_tools(
        self,
        session_id: str,
        request_id: str,
        allowed_tools: list[str],
    ) -> list[Any]:
        from agent_service.tools import (
            CloseAlbumTool,
            CloseTaskGuideTool,
            DelegateDeepSeekTool,
            GetAlbumStateTool,
            GoToAlbumPageTool,
            GoToTaskGuidePageTool,
            GetCurrentTaskStepTool,
            NextTaskStepTool,
            NextAlbumPageTool,
            OpenAlbumTool,
            OpenTaskGuideTool,
            PreviousAlbumPageTool,
            PreviousTaskStepTool,
            ReplayCurrentTaskStepTool,
        )

        tool_types = {
            "open_album": (OpenAlbumTool, True),
            "close_album": (CloseAlbumTool, True),
            "next_album_page": (NextAlbumPageTool, True),
            "go_to_album_page": (GoToAlbumPageTool, True),
            "previous_album_page": (PreviousAlbumPageTool, True),
            "get_album_state": (GetAlbumStateTool, False),
            "open_task_guide": (OpenTaskGuideTool, True),
            "close_task_guide": (CloseTaskGuideTool, True),
            "get_current_task_step": (GetCurrentTaskStepTool, False),
            "next_task_step": (NextTaskStepTool, True),
            "go_to_task_guide_page": (GoToTaskGuidePageTool, True),
            "previous_task_step": (PreviousTaskStepTool, True),
            "replay_current_task_step": (ReplayCurrentTaskStepTool, True),
            "delegate_deepseek": (DelegateDeepSeekTool, False),
        }
        unknown = set(allowed_tools) - SUPPORTED_TOOL_NAMES
        if unknown:
            raise ValueError(f"Unsupported allowed tools: {sorted(unknown)}")
        tools: list[Any] = []
        for tool_name in allowed_tools:
            tool_type, state_changing = tool_types[tool_name]
            tools.append(
                tool_type(
                    self._connection_manager,
                    session_id,
                    request_id,
                    timeout_seconds=self._settings.tool_timeout_seconds,
                    max_calls=self._settings.max_tool_calls_per_run,
                    state_changing=state_changing,
                )
            )
        return tools

    def _llm_config(self) -> dict[str, Any]:
        return {
            "model_type": "qwenvl_oai",
            "model": self._settings.model_name,
            "model_server": self._settings.model_server,
            "api_key": self._settings.api_key,
            "generate_cfg": {
                "temperature": 0.1,
                "top_p": 0.8,
                "max_tokens": 128,
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


@dataclass(frozen=True, slots=True)
class RoutingDecision:
    route: str
    tool: str
    arguments: dict[str, Any]
    answer: str


def _with_allowed_tools(
    messages: list[dict[str, Any]], allowed_tools: list[str]
) -> list[dict[str, Any]]:
    if not messages:
        raise ValueError("A routing request requires one user message")
    prepared = [dict(message) for message in messages]
    last = dict(prepared[-1])
    if last.get("role") != "user" or not isinstance(last.get("content"), str):
        raise ValueError("The final routing message must be a text user message")
    last["content"] = (
        f"{last['content']}\n"
        f"本次唯一允许的工具：{json.dumps(allowed_tools, ensure_ascii=False)}"
    )
    prepared[-1] = last
    return prepared


def _parse_routing_decision(raw: str, allowed_tools: list[str]) -> RoutingDecision:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Qwen routing response was not valid JSON") from exc
    if not isinstance(value, dict):
        raise RuntimeError("Qwen routing response must be a JSON object")
    route = value.get("route")
    tool = value.get("tool", "")
    arguments = value.get("arguments", {})
    answer = value.get("answer", "")
    if isinstance(route, str) and route in allowed_tools:
        # Qwen3 sometimes emits the selected tool directly as `route` despite the
        # requested wrapper schema. This is still a fully authorized structured
        # decision, so normalize it rather than falling back to free-form text.
        if tool and tool != route:
            raise RuntimeError("Qwen routing response selected two routes")
        tool = route
        route = "delegate_deepseek" if tool == "delegate_deepseek" else "tool"
    if route not in {"tool", "direct_answer", "delegate_deepseek", "clarify"}:
        raise RuntimeError("Qwen routing response has an unsupported route")
    if not isinstance(tool, str) or not isinstance(arguments, dict) or not isinstance(answer, str):
        raise RuntimeError("Qwen routing response has invalid field types")
    tool = tool.strip()
    answer = answer.strip()
    if route == "tool":
        if tool not in allowed_tools or tool == "delegate_deepseek":
            raise RuntimeError("Qwen selected a tool outside the authorized UI boundary")
    elif route == "delegate_deepseek":
        if tool != "delegate_deepseek" or tool not in allowed_tools or arguments:
            raise RuntimeError("Qwen delegated with an invalid tool decision")
    else:
        if tool or not answer:
            raise RuntimeError("Qwen direct response must contain only a non-empty answer")
    return RoutingDecision(route=route, tool=tool, arguments=arguments, answer=answer)


def _answer_from_tool_result(tool_name: str, raw_result: str) -> str:
    try:
        result = json.loads(raw_result)
    except json.JSONDecodeError:
        return "工具执行完成。"
    if not isinstance(result, dict):
        return "工具执行完成。"
    if not result.get("ok", False):
        error = result.get("error", {})
        if isinstance(error, dict):
            return f"操作未完成：{str(error.get('message', '工具执行失败。'))}"
        return "操作未完成：工具执行失败。"
    data = result.get("data", {})
    if tool_name == "delegate_deepseek" and isinstance(data, dict):
        answer = data.get("answer")
        if isinstance(answer, str) and answer.strip():
            return answer.strip()
    return "工具执行完成。"
