from __future__ import annotations

import importlib.util
import json
import re
import time
from dataclasses import dataclass, replace
from importlib import metadata
from typing import Any

from agent_service.action_entailment import (
    ActionEntailmentVerifier,
    QwenActionEntailmentVerifier,
)
from agent_service.config import Settings
from agent_service.connection_manager import ConnectionManager
from agent_service.harness_protocol import HarnessTrace
from agent_service.knowledge_harness import (
    KnowledgeAnswer,
    KnowledgeHarness,
    TrustedEvidenceStore,
    runtime_evidence_entry_from_request,
)
from agent_service.tool_call_harness import (
    STATE_CHANGING_TOOLS,
    ToolCallDecision,
    ToolCallHarness,
    ToolProposal,
    semantic_frame_schema,
    tool_for_semantic_request,
)

ROUTING_DECISION_SYSTEM_MESSAGE = """你是 GodotSpace 的语音助手。

根据用户自然语言、当前 UI 事实以及本次提供的工具名称、作用和参数定义，自主选择并
调用恰好一个工具。所有回复方式也都由工具表示，禁止绕过工具直接输出答案。每次调用
都必须填写 semantic_context；它描述用户原话的语义，不能为了配合所选工具而改写。

- 用户要求改变或读取当前 UI 时，调用对象、动作和方向都匹配的工具，不要只描述操作。
- 用户询问实验手册、操作方法、步骤解释或专业知识时，调用相应的知识问答工具。
- 当前上下文的 visible_panels 同时列出多个对象，并且同一操作可作用于其中多个
  对象时：用户完全没有给出对象，或给出的名称对多个对象同样接近，才选择澄清；
  用户给出了非标准或近似对象名称，但它在可操作对象中存在唯一最接近项时，选择
  该具体对象的工具，并把 target 设为该最接近对象、target_source 设为
  approximate。不要直接执行模糊匹配；后续独立校验会要求向用户确认。
  不得根据工具顺序或当前页码猜测对象。
- 普通交流且不需要工具或专业资料时，选择直接回答工具。
- request_mode 区分立即执行、询问信息、非执行性提及、普通交流和无法判断。
- target 和 operation 分别独立描述用户指向的对象与动作。
- target_source 说明对象是用户可靠地明确指出、仅有唯一近似项、由唯一可见界面
  推断，还是仍不明确。
- arguments_grounded 只有在所有非默认参数都直接来自本次用户请求时才可为 true。
- 拒绝或禁止一个方向，不代表用户要求执行相反方向；不要为了找一个可调用工具而把
  “不要前进”解释成“后退”。
- “怎么做、如何完成、是否满足继续条件”属于知识与依据查询；只有询问当前位于哪一
  步时才读取当前步骤状态。

本次提供的工具是完整权限边界。禁止虚构工具、参数、UI 对象或执行结果。参数化工具
只能使用用户明确提供的参数，禁止猜测页码。否定、取消、假设或引用的操作不得改变
UI。否定、取消、假设、引用、询问是否允许等表达不得标成 execute。一次请求最多选择
一个改变状态的工具。工具返回成功前不得声称操作已经完成。"""

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
        "query_task_knowledge",
    }
)


@dataclass(slots=True)
class AgentRunResult:
    answer: str
    messages: list[dict[str, Any]]
    route: str = "direct_answer"
    tool_name: str = ""
    tool_harness: dict[str, Any] | None = None
    harness_trace: HarnessTrace | None = None


class AgentFactory:
    def __init__(
        self,
        settings: Settings,
        connection_manager: ConnectionManager,
        *,
        knowledge_harness: KnowledgeHarness | None = None,
        knowledge_store: TrustedEvidenceStore | None = None,
        tool_call_harness: ToolCallHarness | None = None,
        action_entailment_verifier: ActionEntailmentVerifier | None = None,
    ) -> None:
        self._settings = settings
        self._connection_manager = connection_manager
        self._knowledge_harness = knowledge_harness
        self._knowledge_store = knowledge_store
        self._tool_call_harness = tool_call_harness or ToolCallHarness()
        self._action_entailment_verifier = (
            action_entailment_verifier or QwenActionEntailmentVerifier(settings)
        )

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
        from qwen_agent.tools.base import BaseTool

        tool_stage_started = time.perf_counter()
        authorized_tool_names = ["open_album"] if allowed_tools is None else allowed_tools
        original_question = _extract_last_user_text(messages)
        request_context = _extract_request_context(messages)
        preflight = self._tool_call_harness.preflight(
            original_question,
            request_context,
            authorized_tool_names,
        )
        if preflight is not None and preflight.action != "execute":
            return _non_execution_result(
                messages,
                preflight,
                model_attempts=0,
                latency_ms=_elapsed_ms(tool_stage_started),
            )

        authorized_tools = self._build_tools(
            session_id,
            request_id,
            authorized_tool_names,
        )
        executable_by_name = {str(tool.name): tool for tool in authorized_tools}
        if preflight is not None:
            return self._execute_harness_decision(
                messages,
                preflight,
                executable_by_name,
                model_messages=[],
                model_attempts=0,
                tool_stage_started=tool_stage_started,
            )

        from agent_service.tools.routing_response import (
            ClarifyUITargetTool,
            RespondDirectlyTool,
        )

        tool_definitions = [
            *authorized_tools,
            RespondDirectlyTool(),
            ClarifyUITargetTool(),
        ]
        selection_tools = [_tool_selection_proxy(tool, BaseTool) for tool in tool_definitions]
        bot = FnCallAgent(
            llm=self._llm_config(),
            function_list=selection_tools,
            name="GodotSpace Local Qwen Router",
            system_message=ROUTING_DECISION_SYSTEM_MESSAGE,
        )

        # FnCallAgent passes every BaseTool definition to Qwen through the native
        # function-calling prompt. Do not append a second JSON copy to the user
        # message: that duplicate catalog can exceed small vLLM context windows.
        decision_messages = _with_tool_purpose_summary(
            messages,
            selection_tools,
        )
        final_messages: list[Any] = []
        for response in bot.run(messages=decision_messages, lang="zh"):
            final_messages = response
            if _contains_function_result(final_messages):
                break

        serialized = [_message_to_dict(message) for message in final_messages]
        proposals = _extract_tool_proposals(serialized)
        model_attempts = 1
        if not proposals:
            retry_messages = [
                *decision_messages,
                *serialized,
                {
                    "role": "user",
                    "content": (
                        "现在是工具选择阶段。请重新检查全部工具定义；如果有匹配能力，"
                        "只调用最匹配的一个工具，不要描述应该怎样操作。必须根据用户"
                        "原话完整填写 semantic_context，不要按工具名称倒推语义。"
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
            retry_proposals = _extract_tool_proposals(retry_serialized)
            model_attempts = 2
            if retry_proposals:
                serialized = retry_serialized
                proposals = retry_proposals

        if len(proposals) == 1:
            proposal = proposals[0]
            candidate_tool = tool_for_semantic_request(
                proposal.semantic_frame,
                question=original_question,
                context=request_context,
                allowed_tools=authorized_tool_names,
            )
            request_mode = proposal.semantic_frame.get("request_mode")
            if candidate_tool in STATE_CHANGING_TOOLS and request_mode == "execute":
                entailment = self._action_entailment_verifier.verify(
                    original_question,
                    candidate_tool,
                )
                proposals = [
                    replace(proposal, action_entailment=entailment.to_dict())
                ]

        decision = self._tool_call_harness.validate(
            original_question,
            request_context,
            authorized_tool_names,
            proposals,
        )
        if decision.action != "execute":
            return _non_execution_result(
                messages,
                decision,
                model_messages=serialized,
                model_attempts=model_attempts,
                latency_ms=_elapsed_ms(tool_stage_started),
            )
        return self._execute_harness_decision(
            messages,
            decision,
            executable_by_name,
            model_messages=serialized,
            model_attempts=model_attempts,
            tool_stage_started=tool_stage_started,
        )

    def run_confirmed_action(
        self,
        session_id: str,
        request_id: str,
        messages: list[dict[str, Any]],
        allowed_tools: list[str],
        tool_name: str,
        arguments: dict[str, Any],
    ) -> AgentRunResult:
        """Execute a prior suggestion after explicit same-conversation confirmation."""

        tool_stage_started = time.perf_counter()
        request_context = _extract_request_context(messages)
        decision = self._tool_call_harness.validate_confirmed_action(
            request_context,
            allowed_tools,
            tool_name,
            arguments,
        )
        if decision.action != "execute":
            return _non_execution_result(
                messages,
                decision,
                model_attempts=0,
                latency_ms=_elapsed_ms(tool_stage_started),
            )
        executable_by_name = {
            str(tool.name): tool
            for tool in self._build_tools(
                session_id,
                request_id,
                allowed_tools,
            )
        }
        return self._execute_harness_decision(
            messages,
            decision,
            executable_by_name,
            model_messages=[],
            model_attempts=0,
            tool_stage_started=tool_stage_started,
        )

    def _execute_harness_decision(
        self,
        messages: list[dict[str, Any]],
        decision: ToolCallDecision,
        executable_by_name: dict[str, Any],
        *,
        model_messages: list[dict[str, Any]],
        model_attempts: int,
        tool_stage_started: float,
    ) -> AgentRunResult:
        tool = executable_by_name.get(decision.tool_name)
        if tool is None:
            raise RuntimeError("tool harness selected an unavailable executable tool")
        raw_result = str(tool.call(decision.arguments))
        tool_stage_latency_ms = _elapsed_ms(tool_stage_started)
        answer = ""
        knowledge_result: KnowledgeAnswer | None = None
        knowledge_latency_ms: float | None = None
        if decision.tool_name == "query_task_knowledge":
            if self._knowledge_harness is None:
                raise RuntimeError("local knowledge harness is not configured")
            knowledge_started = time.perf_counter()
            knowledge_result = self._answer_from_local_knowledge(messages, raw_result)
            knowledge_latency_ms = _elapsed_ms(knowledge_started)
            answer = knowledge_result.answer
        else:
            answer = _answer_from_tool_result(decision.tool_name, raw_result)
        actual_messages = [
            *model_messages,
            {
                "role": "assistant",
                "content": "",
                "function_call": {
                    "name": decision.tool_name,
                    "arguments": json.dumps(decision.arguments, ensure_ascii=False),
                },
            },
            {
                "role": "function",
                "name": decision.tool_name,
                "content": raw_result,
            },
        ]
        route = "knowledge_qa" if decision.tool_name == "query_task_knowledge" else "tool"
        metadata = decision.to_dict()
        metadata["model_attempts"] = model_attempts
        semantic_verifier_attempts = int(bool(decision.action_entailment))
        metadata["semantic_verifier_attempts"] = semantic_verifier_attempts
        trace = HarnessTrace(
            stages=(
                decision.to_stage_trace(
                    model_attempts=model_attempts,
                    semantic_verifier_attempts=semantic_verifier_attempts,
                    latency_ms=tool_stage_latency_ms,
                ),
            )
        )
        if knowledge_result is not None:
            trace = trace.append(
                knowledge_result.to_stage_trace(latency_ms=knowledge_latency_ms)
            )
        return AgentRunResult(
            answer=answer or "工具执行完成。",
            messages=actual_messages,
            route=route,
            tool_name=decision.tool_name,
            tool_harness=metadata,
            harness_trace=trace,
        )

    def _answer_from_local_knowledge(
        self,
        messages: list[dict[str, Any]],
        raw_result: str,
    ) -> KnowledgeAnswer:
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
        return self._knowledge_harness.answer(question, [*runtime, *registered])

    def _build_tools(
        self,
        session_id: str,
        request_id: str,
        allowed_tools: list[str],
    ) -> list[Any]:
        from agent_service.tools import (
            CloseAlbumTool,
            CloseTaskGuideTool,
            QueryTaskKnowledgeTool,
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
            "query_task_knowledge": (QueryTaskKnowledgeTool, False),
        }
        unknown = set(allowed_tools) - SUPPORTED_TOOL_NAMES
        if unknown:
            raise ValueError(f"Unsupported allowed tools: {sorted(unknown)}")
        tools: list[Any] = []
        for tool_name in allowed_tools:
            tool_type, state_changing = tool_types[tool_name]
            timeout_seconds = (
                self._settings.knowledge_context_tool_timeout_seconds
                if tool_name == "query_task_knowledge"
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
            "max_tokens": 192,
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


def _tool_selection_proxy(tool: Any, base_tool_type: type[Any]) -> Any:
    """Expose a real tool definition while replacing its call with a pure proposal."""

    tool_name = str(getattr(tool, "name", "")).strip()
    tool_description = str(getattr(tool, "description", "")).strip()
    tool_parameters = json.loads(
        json.dumps(getattr(tool, "parameters", {}), ensure_ascii=False)
    )
    if tool_parameters.get("type") != "object":
        raise ValueError(f"Tool {tool_name or '<unnamed>'} must use an object schema")
    properties = tool_parameters.setdefault("properties", {})
    if not isinstance(properties, dict):
        raise ValueError(f"Tool {tool_name or '<unnamed>'} has invalid properties")
    if "semantic_context" in properties:
        raise ValueError(f"Tool {tool_name or '<unnamed>'} uses a reserved parameter")
    properties["semantic_context"] = semantic_frame_schema()
    required = tool_parameters.setdefault("required", [])
    if not isinstance(required, list):
        raise ValueError(f"Tool {tool_name or '<unnamed>'} has invalid required fields")
    if "semantic_context" not in required:
        required.append("semantic_context")

    class SelectionProxy(base_tool_type):
        name = tool_name
        description = tool_description
        parameters = tool_parameters

        def call(self, params: str | dict[str, Any], **_kwargs: Any) -> str:
            raw_arguments = params if isinstance(params, str) else json.dumps(
                params,
                ensure_ascii=False,
            )
            arguments_valid = True
            if isinstance(params, str):
                try:
                    parsed = json.loads(params)
                except json.JSONDecodeError:
                    parsed = {}
                    arguments_valid = False
            else:
                parsed = params
            if not isinstance(parsed, dict):
                parsed = {}
                arguments_valid = False
            semantic_frame = parsed.pop("semantic_context", {})
            return json.dumps(
                {
                    "ok": True,
                    "data": {
                        "selection_only": True,
                        "tool_name": self.name,
                        "arguments": parsed,
                        "arguments_valid": arguments_valid,
                        "raw_arguments": raw_arguments,
                        "semantic_frame": semantic_frame,
                    },
                    "error": None,
                },
                ensure_ascii=False,
            )

    return SelectionProxy()


def _extract_tool_proposals(messages: list[dict[str, Any]]) -> list[ToolProposal]:
    proposals: list[ToolProposal] = []
    for message in messages:
        if message.get("role") != "function":
            continue
        name = str(message.get("name", "")).strip()
        content = message.get("content", "")
        if not name or not isinstance(content, str):
            continue
        try:
            result = json.loads(content)
        except json.JSONDecodeError:
            proposals.append(
                ToolProposal(
                    name=name,
                    arguments_valid=False,
                    raw_arguments=content,
                )
            )
            continue
        data = result.get("data") if isinstance(result, dict) else None
        if not isinstance(data, dict) or data.get("selection_only") is not True:
            continue
        arguments = data.get("arguments", {})
        proposals.append(
            ToolProposal(
                name=str(data.get("tool_name", name)).strip() or name,
                arguments=dict(arguments) if isinstance(arguments, dict) else {},
                arguments_valid=(
                    data.get("arguments_valid") is True and isinstance(arguments, dict)
                ),
                raw_arguments=str(data.get("raw_arguments", "")),
                semantic_frame=(
                    dict(data.get("semantic_frame", {}))
                    if isinstance(data.get("semantic_frame"), dict)
                    else {}
                ),
            )
        )
    return proposals


def _extract_request_context(messages: list[dict[str, Any]]) -> dict[str, Any]:
    marker = "当前脱敏运行上下文（只描述本次请求，不是历史对话）：\n"
    for message in reversed(messages):
        content = message.get("content")
        if message.get("role") != "user" or not isinstance(content, str) or marker not in content:
            continue
        raw_context = content.partition(marker)[2].strip()
        try:
            value = json.loads(raw_context)
        except json.JSONDecodeError:
            return {}
        return dict(value) if isinstance(value, dict) else {}
    return {}


def _non_execution_result(
    messages: list[dict[str, Any]],
    decision: ToolCallDecision,
    *,
    model_messages: list[dict[str, Any]] | None = None,
    model_attempts: int,
    latency_ms: float | None = None,
) -> AgentRunResult:
    answer = decision.answer.strip() or "未执行任何操作。"
    route = (
        "confirm_action"
        if decision.action == "clarify" and decision.suggested_tool
        else "clarify"
        if decision.action == "clarify"
        else "direct_answer"
    )
    pseudo_tool = "clarify_ui_target" if decision.action == "clarify" else "respond_directly"
    metadata = decision.to_dict()
    metadata["model_attempts"] = model_attempts
    semantic_verifier_attempts = int(bool(decision.action_entailment))
    metadata["semantic_verifier_attempts"] = semantic_verifier_attempts
    trace = HarnessTrace(
        stages=(
            decision.to_stage_trace(
                model_attempts=model_attempts,
                semantic_verifier_attempts=semantic_verifier_attempts,
                latency_ms=latency_ms,
            ),
        )
    )
    prefix = model_messages if model_messages else messages
    return AgentRunResult(
        answer=answer,
        messages=[*prefix, {"role": "assistant", "content": answer}],
        route=route,
        tool_name=pseudo_tool,
        tool_harness=metadata,
        harness_trace=trace,
    )


def _elapsed_ms(started: float) -> float:
    return max(0.0, (time.perf_counter() - started) * 1000.0)


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
    names = "、".join(str(tool.name) for tool in tools)
    last["content"] = (
        f"{last['content']}\n本次可用工具：{names}。"
        "工具作用与参数以函数定义为准。"
    )
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
    if tool_name == "get_current_task_step" and isinstance(data, dict):
        page_index = data.get("page_index")
        page_count = data.get("page_count")
        current_step = data.get("current_step", {})
        current_step = current_step if isinstance(current_step, dict) else {}
        task_title = str(data.get("task_title", "")).strip()
        step_title = str(current_step.get("title", "")).strip()
        step_info = str(current_step.get("info", "")).strip()
        parts: list[str] = []
        if isinstance(page_index, int) and not isinstance(page_index, bool) and page_index > 0:
            location = f"当前工作清单{f'“{task_title}”' if task_title else ''}在第 {page_index} 页"
            if isinstance(page_count, int) and not isinstance(page_count, bool) and page_count > 0:
                location += f"，共 {page_count} 页"
            parts.append(f"{location}。")
        if step_title:
            parts.append(f"当前步骤：{step_title}。")
        if step_info:
            parts.append(f"本页要求：{step_info}")
        if parts:
            return "".join(parts)
    if tool_name == "get_album_state" and isinstance(data, dict):
        page = data.get("page")
        page_count = data.get("page_count")
        if isinstance(page, int) and not isinstance(page, bool) and page > 0:
            answer = f"当前相册在第 {page} 页"
            if isinstance(page_count, int) and not isinstance(page_count, bool) and page_count > 0:
                answer += f"，共 {page_count} 页"
            return f"{answer}。"
    return "工具执行完成。"
