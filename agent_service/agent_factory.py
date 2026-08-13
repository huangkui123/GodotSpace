from __future__ import annotations

import importlib.util
import json
import re
from importlib import metadata
from dataclasses import dataclass
from typing import Any

from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager
from agent_service.knowledge_harness import (
    KnowledgeHarness,
    TrustedEvidenceStore,
    runtime_evidence_entry_from_request,
)
from agent_service.tools.page_number import extract_explicit_page

ROUTING_DECISION_SYSTEM_MESSAGE = """你是 GodotSpace 的语音助手。

根据用户自然语言、当前 UI 事实以及本次提供的工具名称、作用和参数定义，自主选择并
调用恰好一个工具。所有回复方式也都由工具表示，禁止绕过工具直接输出答案。

- 用户要求改变或读取当前 UI 时，调用对象、动作和方向都匹配的工具，不要只描述操作。
- 用户询问实验手册、操作方法、步骤解释或专业知识时，调用相应的知识问答工具。
- 当前上下文的 visible_panels 同时列出多个对象，并且同一操作可作用于其中多个
  对象时：用户未明确对象必须选择澄清；用户已明确说出对象则直接选择对应工具。
  不得根据工具顺序或当前页码猜测对象。
- 普通交流且不需要工具或专业资料时，选择直接回答工具。

本次提供的工具是完整权限边界。禁止虚构工具、参数、UI 对象或执行结果。参数化工具
只能使用用户明确提供的参数，禁止猜测页码。否定、取消、假设或引用的操作不得改变
UI。“不要、别、无需、取消”等否定请求只能选择直接回答或澄清，绝对不得调用改变
状态的工具。一次请求最多选择一个改变状态的工具。工具返回成功前不得声称操作已经完成。"""

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
    def __init__(
        self,
        settings: Settings,
        connection_manager: ConnectionManager,
        *,
        knowledge_harness: KnowledgeHarness | None = None,
        knowledge_store: TrustedEvidenceStore | None = None,
    ) -> None:
        self._settings = settings
        self._connection_manager = connection_manager
        self._knowledge_harness = knowledge_harness
        self._knowledge_store = knowledge_store

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

        authorized_tool_names = ["open_album"] if allowed_tools is None else allowed_tools
        original_question = _extract_last_user_text(messages)
        if _is_negated_action(original_question):
            return AgentRunResult(
                answer="好的，我会保持当前状态，不执行该操作。",
                messages=[
                    *messages,
                    {
                        "role": "assistant",
                        "content": "好的，我会保持当前状态，不执行该操作。",
                    },
                ],
                route="direct_answer",
                tool_name="respond_directly",
            )
        direct_page_tool = _explicit_page_tool(original_question, authorized_tool_names)
        if direct_page_tool is not None:
            tool_name, page = direct_page_tool
            tool = self._build_tools(session_id, request_id, [tool_name])[0]
            raw_result = str(tool.call({"page": page}))
            return AgentRunResult(
                answer=_answer_from_tool_result(tool_name, raw_result),
                messages=[
                    *messages,
                    {
                        "role": "assistant",
                        "content": "",
                        "function_call": {
                            "name": tool_name,
                            "arguments": json.dumps({"page": page}),
                        },
                    },
                    {"role": "function", "name": tool_name, "content": raw_result},
                ],
                route="tool",
                tool_name=tool_name,
            )
        authorized_tools = self._build_tools(
            session_id,
            request_id,
            authorized_tool_names,
        )
        from agent_service.tools.routing_response import (
            ClarifyUITargetTool,
            RespondDirectlyTool,
        )

        decision_tools = [
            *authorized_tools,
            RespondDirectlyTool(),
            ClarifyUITargetTool(),
        ]
        decision_tool_names = [str(tool.name) for tool in decision_tools]
        bot = FnCallAgent(
            llm=self._llm_config(),
            function_list=decision_tools,
            name="GodotSpace Local Qwen Router",
            system_message=ROUTING_DECISION_SYSTEM_MESSAGE,
        )

        # FnCallAgent passes every BaseTool definition to Qwen through the native
        # function-calling prompt. Do not append a second JSON copy to the user
        # message: that duplicate catalog can exceed small vLLM context windows.
        decision_messages = _with_tool_purpose_summary(
            messages,
            decision_tools,
        )
        final_messages: list[Any] = []
        for response in bot.run(messages=decision_messages, lang="zh"):
            final_messages = response
            if _contains_function_result(final_messages):
                break

        serialized = [_message_to_dict(message) for message in final_messages]
        tool_name = _extract_selected_tool(serialized)
        direct_fallback = _extract_final_answer(serialized)
        if not tool_name:
            retry_messages = [
                *decision_messages,
                *serialized,
                {
                    "role": "user",
                    "content": (
                        "现在是工具选择阶段。请重新检查全部工具定义；如果有匹配能力，"
                        "只调用最匹配的一个工具，不要描述应该怎样操作。"
                    ),
                },
            ]
            final_messages = []
            for response in bot.run(messages=retry_messages, lang="zh"):
                final_messages = response
                if _contains_function_result(final_messages):
                    break
            retry_serialized = [
                _message_to_dict(message) for message in final_messages
            ]
            retry_tool_name = _extract_selected_tool(retry_serialized)
            if retry_tool_name:
                serialized = retry_serialized
                tool_name = retry_tool_name
        if tool_name and tool_name not in decision_tool_names:
            raise RuntimeError("Qwen selected a tool outside the authorization boundary")
        answer = _extract_final_answer(serialized) if tool_name else direct_fallback
        function_result = _extract_last_function_result(serialized)
        if tool_name in {"respond_directly", "clarify_ui_target"}:
            answer = _answer_from_tool_result(tool_name, function_result)
        elif tool_name == "delegate_deepseek":
            if self._knowledge_harness is None:
                raise RuntimeError("local knowledge harness is not configured")
            answer = self._answer_from_local_knowledge(messages, function_result)
        elif not answer:
            answer = _answer_from_tool_result(
                tool_name,
                function_result,
            )
        if not answer:
            answer = "请再说明一下你的需求。"
        route = (
            "delegate_deepseek"
            if tool_name == "delegate_deepseek"
            else "direct_answer"
            if tool_name == "respond_directly"
            else "clarify"
            if tool_name == "clarify_ui_target"
            else "tool"
            if tool_name
            else "direct_answer"
        )
        return AgentRunResult(
            answer=answer,
            messages=serialized,
            route=route,
            tool_name=tool_name,
        )

    def _answer_from_local_knowledge(
        self,
        messages: list[dict[str, Any]],
        raw_result: str,
    ) -> str:
        question = _extract_last_user_text(messages)
        runtime_values = _extract_knowledge_entries_from_tool_result(raw_result)
        runtime = [
            runtime_evidence_entry_from_request(
                item,
                index,
                self._settings.knowledge_runtime_source,
            )
            for index, item in enumerate(runtime_values)
        ]
        registered = self._knowledge_store.select() if self._knowledge_store else []
        return self._knowledge_harness.answer(question, [*runtime, *registered]).answer

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
            timeout_seconds = (
                self._settings.knowledge_context_tool_timeout_seconds
                if tool_name == "delegate_deepseek"
                else self._settings.tool_timeout_seconds
            )
            tools.append(
                tool_type(
                    self._connection_manager,
                    session_id,
                    request_id,
                    timeout_seconds=timeout_seconds,
                    max_calls=self._settings.max_tool_calls_per_run,
                    state_changing=state_changing,
                )
            )
        return tools

    def _llm_config(self) -> dict[str, Any]:
        generate_cfg: dict[str, Any] = {
            "temperature": 0.0,
            "top_p": 1.0,
            "max_tokens": 128,
            "fncall_prompt_type": self._settings.model_fncall_prompt_type,
            "use_raw_api": self._settings.model_use_raw_api,
        }
        if self._settings.model_enable_thinking is not None:
            generate_cfg["extra_body"] = {
                "chat_template_kwargs": {
                    "enable_thinking": self._settings.model_enable_thinking,
                }
            }
        return {
            "model_type": self._settings.model_type,
            "model": self._settings.model_name,
            "model_server": self._settings.model_server,
            "api_key": self._settings.api_key,
            "generate_cfg": generate_cfg,
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


def _contains_function_result(messages: list[Any]) -> bool:
    return any(_message_to_dict(message).get("role") == "function" for message in messages)


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


def _extract_last_user_text(messages: list[dict[str, Any]]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user" and isinstance(message.get("content"), str):
            content = str(message["content"])
            if content.startswith("用户语音："):
                return content.partition("\n")[0].removeprefix("用户语音：").strip()
            return content.strip()
    raise ValueError("knowledge routing requires the original user question")


def _is_negated_action(text: str) -> bool:
    if re.search(r"(?:不是|并非).{0,2}(?:不要|别|无需|不用|不必|取消)", text):
        return False
    return bool(
        re.search(r"(?:不要|别|无需|不用|不必|取消).{0,12}(?:打开|关闭|翻|切换|跳转|播放|执行)", text)
        or re.search(r"(?:打开|关闭|翻|切换|跳转|播放|执行).{0,8}(?:不要|别|取消)", text)
    )


def _explicit_page_tool(text: str, allowed_tools: list[str]) -> tuple[str, int] | None:
    page = extract_explicit_page(text)
    if page is None:
        return None
    if any(term in text for term in ("相册", "照片")):
        return ("go_to_album_page", page) if "go_to_album_page" in allowed_tools else None
    if any(term in text for term in ("任务", "步骤", "指导书", "工作清单")):
        return (
            ("go_to_task_guide_page", page)
            if "go_to_task_guide_page" in allowed_tools
            else None
        )
    candidates = [
        name
        for name in ("go_to_album_page", "go_to_task_guide_page")
        if name in allowed_tools
    ]
    return (candidates[0], page) if len(candidates) == 1 else None


def _extract_knowledge_entries_from_tool_result(raw_result: str) -> list[dict[str, Any]]:
    try:
        result = json.loads(raw_result)
    except json.JSONDecodeError as exc:
        raise RuntimeError("knowledge context tool returned invalid JSON") from exc
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise RuntimeError("knowledge context tool did not complete successfully")
    data = result.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("knowledge context tool returned no data")
    entries = data.get("entries", [])
    if not isinstance(entries, list) or len(entries) > 20:
        raise RuntimeError("knowledge context tool returned invalid entries")
    if any(not isinstance(item, dict) for item in entries):
        raise RuntimeError("knowledge context entries must be objects")
    return [dict(item) for item in entries]


def _tool_catalog(tools: list[Any]) -> list[dict[str, Any]]:
    catalog: list[dict[str, Any]] = []
    for tool in tools:
        name = str(getattr(tool, "name", "")).strip()
        description = str(getattr(tool, "description", "")).strip()
        parameters = getattr(tool, "parameters", {})
        if not name or not description or not isinstance(parameters, dict):
            raise ValueError(f"Tool {name or '<unnamed>'} has an incomplete definition")
        schema = json.loads(json.dumps(parameters, ensure_ascii=False))
        if schema.get("type") == "object":
            schema.setdefault("additionalProperties", False)
        catalog.append(
            {
                "name": name,
                "description": description,
                "parameters": schema,
            }
        )
    return catalog


def _with_tool_purpose_summary(
    messages: list[dict[str, Any]],
    tools: list[Any],
) -> list[dict[str, Any]]:
    if not messages:
        raise ValueError("A routing request requires one user message")
    prepared = [dict(message) for message in messages]
    last = dict(prepared[-1])
    if last.get("role") != "user" or not isinstance(last.get("content"), str):
        raise ValueError("The final routing message must be a text user message")
    summaries = "\n".join(
        f"- {tool.name}：{tool.description}" for tool in tools
    )
    last["content"] = f"{last['content']}\n本次工具作用摘要（参数仍以函数定义为准）：\n{summaries}"
    prepared[-1] = last
    return prepared


def _extract_selected_tool(messages: list[dict[str, Any]]) -> str:
    selected = ""
    for message in messages:
        if message.get("role") != "function":
            continue
        name = message.get("name")
        if isinstance(name, str) and name.strip():
            if selected and selected != name.strip():
                raise RuntimeError("Qwen attempted to execute more than one tool")
            selected = name.strip()
    return selected


def _extract_last_function_result(messages: list[dict[str, Any]]) -> str:
    for message in reversed(messages):
        if message.get("role") != "function":
            continue
        content = message.get("content", "")
        if isinstance(content, str):
            return content
    return ""


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
    if tool_name in {
        "respond_directly",
        "clarify_ui_target",
    } and isinstance(data, dict):
        answer = data.get("answer")
        if isinstance(answer, str) and answer.strip():
            return answer.strip()
    return "工具执行完成。"
