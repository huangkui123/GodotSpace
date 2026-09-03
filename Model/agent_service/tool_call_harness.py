from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Iterable, Literal

from agent_service.action_entailment import (
    ActionEntailment,
    final_intent_segment,
    has_explicit_contradiction_evidence,
    has_explicit_nonexecution_cue,
)
from agent_service.harness_protocol import HarnessOutcome, HarnessStageTrace
from agent_service.tools.page_number import parse_positive_page


STATE_CHANGING_TOOLS = frozenset(
    {
        "open_album",
        "close_album",
        "next_album_page",
        "go_to_album_page",
        "previous_album_page",
        "open_task_guide",
        "close_task_guide",
        "next_task_step",
        "go_to_task_guide_page",
        "previous_task_step",
        "replay_current_task_step",
    }
)

READ_ONLY_TOOLS = frozenset(
    {
        "get_album_state",
        "get_current_task_step",
        "query_task_knowledge",
    }
)

DECISION_TOOLS = frozenset({"respond_directly", "clarify_ui_target"})

REQUEST_MODES = frozenset(
    {"execute", "inquire", "non_executable", "conversation", "unclear"}
)
SEMANTIC_TARGETS = frozenset(
    {"album", "task_guide", "knowledge", "none", "unclear"}
)
SEMANTIC_OPERATIONS = frozenset(
    {
        "open",
        "close",
        "next",
        "previous",
        "go_to",
        "read_state",
        "replay",
        "knowledge",
        "respond",
        "clarify",
        "none",
    }
)
TARGET_SOURCES = frozenset(
    {"explicit", "approximate", "context", "not_applicable", "unclear"}
)
EXPLICIT_TARGET_PATTERNS = {
    "album": re.compile(r"相册|照片墙|照片集|照片区域|照片"),
    "task_guide": re.compile(r"工作清单|任务清单|指导书|实验流程说明|流程说明|操作说明"),
}
CANONICAL_PAGE_TARGET_PATTERNS = {
    "album": re.compile(r"相册|照片墙|照片集|照片区域"),
    "task_guide": EXPLICIT_TARGET_PATTERNS["task_guide"],
}
HOW_TO_STEP_PATTERN = re.compile(
    r"(?:(?:这|当前)(?:一)?步[^。！？?!]{0,8}(?:怎么|咋|如何)(?:做|弄|操作|完成)"
    r"|(?:怎么|咋|如何)(?:做|弄|操作|完成)[^。！？?!]{0,8}(?:这|当前)(?:一)?步)"
)
EXPLICIT_PAGE_PATTERN = re.compile(r"第\s*(?:\d+|[一二三四五六七八九十百]+)\s*(?:页|步|步骤)")

SEMANTIC_FRAME_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "request_mode": {
            "type": "string",
            "enum": sorted(REQUEST_MODES),
            "description": "请求模式；取值含义见系统消息。",
        },
        "target": {
            "type": "string",
            "enum": sorted(SEMANTIC_TARGETS),
            "description": "用户指向的对象；取值含义见系统消息。",
        },
        "operation": {
            "type": "string",
            "enum": sorted(SEMANTIC_OPERATIONS),
            "description": "用户要求的操作；取值含义见系统消息。",
        },
        "target_source": {
            "type": "string",
            "enum": sorted(TARGET_SOURCES),
            "description": "对象来源；取值含义见系统消息。",
        },
        "arguments_grounded": {
            "type": "boolean",
            "description": "非默认参数是否都直接来自本次请求。",
        },
    },
    "required": [
        "request_mode",
        "target",
        "operation",
        "target_source",
        "arguments_grounded",
    ],
}

_TOOL_SEMANTICS: dict[str, tuple[str, str]] = {
    "open_album": ("album", "open"),
    "close_album": ("album", "close"),
    "next_album_page": ("album", "next"),
    "previous_album_page": ("album", "previous"),
    "go_to_album_page": ("album", "go_to"),
    "get_album_state": ("album", "read_state"),
    "open_task_guide": ("task_guide", "open"),
    "close_task_guide": ("task_guide", "close"),
    "next_task_step": ("task_guide", "next"),
    "previous_task_step": ("task_guide", "previous"),
    "go_to_task_guide_page": ("task_guide", "go_to"),
    "get_current_task_step": ("task_guide", "read_state"),
    "replay_current_task_step": ("task_guide", "replay"),
    "query_task_knowledge": ("knowledge", "knowledge"),
    "respond_directly": ("none", "respond"),
    "clarify_ui_target": ("unclear", "clarify"),
}
_SEMANTICS_TO_TOOL = {value: key for key, value in _TOOL_SEMANTICS.items()}
_ALBUM_TOOLS = frozenset(
    name for name, (target, _operation) in _TOOL_SEMANTICS.items() if target == "album"
)
_GUIDE_TOOLS = frozenset(
    name
    for name, (target, _operation) in _TOOL_SEMANTICS.items()
    if target == "task_guide"
)

_ACTION_DISPLAY_TEXT: dict[str, str] = {
    "open_album": "打开相册",
    "close_album": "关闭相册",
    "next_album_page": "翻到相册下一页",
    "go_to_album_page": "翻到指定相册页",
    "previous_album_page": "翻到相册上一页",
    "open_task_guide": "打开工作清单",
    "close_task_guide": "关闭工作清单",
    "next_task_step": "翻到工作清单下一页",
    "go_to_task_guide_page": "翻到工作清单指定页",
    "previous_task_step": "翻到工作清单上一页",
    "replay_current_task_step": "重播当前工作清单步骤",
}


def _action_display_text(tool_name: str, arguments: dict[str, Any]) -> str:
    page = arguments.get("page")
    if isinstance(page, int) and not isinstance(page, bool) and page > 0:
        if tool_name == "go_to_album_page":
            return f"翻到相册第 {page} 页"
        if tool_name == "go_to_task_guide_page":
            return f"翻到工作清单第 {page} 页"
        if tool_name == "open_album" and page != 1:
            return f"打开相册并显示第 {page} 页"
    return _ACTION_DISPLAY_TEXT.get(tool_name, "")


@dataclass(frozen=True, slots=True)
class SemanticFrame:
    request_mode: str
    target: str
    operation: str
    target_source: str
    arguments_grounded: bool

    @classmethod
    def from_mapping(cls, value: Any) -> SemanticFrame | None:
        if not isinstance(value, dict) or set(value) != {
            "request_mode",
            "target",
            "operation",
            "target_source",
            "arguments_grounded",
        }:
            return None
        request_mode = value.get("request_mode")
        target = value.get("target")
        operation = value.get("operation")
        target_source = value.get("target_source")
        arguments_grounded = value.get("arguments_grounded")
        if (
            request_mode not in REQUEST_MODES
            or target not in SEMANTIC_TARGETS
            or operation not in SEMANTIC_OPERATIONS
            or target_source not in TARGET_SOURCES
            or not isinstance(arguments_grounded, bool)
        ):
            return None
        return cls(
            request_mode=request_mode,
            target=target,
            operation=operation,
            target_source=target_source,
            arguments_grounded=arguments_grounded,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "request_mode": self.request_mode,
            "target": self.target,
            "operation": self.operation,
            "target_source": self.target_source,
            "arguments_grounded": self.arguments_grounded,
        }


@dataclass(frozen=True, slots=True)
class ToolProposal:
    name: str
    arguments: dict[str, Any] = field(default_factory=dict)
    arguments_valid: bool = True
    raw_arguments: str = ""
    semantic_frame: dict[str, Any] = field(default_factory=dict)
    action_entailment: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class ToolCallDecision:
    action: Literal["execute", "respond", "clarify", "reject"]
    tool_name: str = ""
    arguments: dict[str, Any] = field(default_factory=dict)
    reason: str = ""
    answer: str = ""
    proposed_tool: str = ""
    proposed_arguments: dict[str, Any] = field(default_factory=dict)
    semantic_frame: dict[str, Any] = field(default_factory=dict)
    action_entailment: dict[str, Any] = field(default_factory=dict)
    suggested_tool: str = ""
    suggested_arguments: dict[str, Any] = field(default_factory=dict)
    suggested_action_text: str = ""
    corrected: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "action": self.action,
            "reason": self.reason,
            "tool_name": self.tool_name,
            "arguments": dict(self.arguments),
            "proposed_tool": self.proposed_tool,
            "proposed_arguments": dict(self.proposed_arguments),
            "semantic_frame": dict(self.semantic_frame),
            "action_entailment": dict(self.action_entailment),
            "suggested_tool": self.suggested_tool,
            "suggested_arguments": dict(self.suggested_arguments),
            "suggested_action_text": self.suggested_action_text,
            "corrected": self.corrected,
        }

    def to_stage_trace(
        self,
        *,
        model_attempts: int,
        semantic_verifier_attempts: int,
        latency_ms: float | None = None,
    ) -> HarnessStageTrace:
        outcome_by_action: dict[str, HarnessOutcome] = {
            "execute": "executed",
            "respond": "answered",
            "clarify": "clarified",
            "reject": "rejected",
        }
        frame = SemanticFrame.from_mapping(self.semantic_frame)
        fallback_used = bool(
            self.action in {"clarify", "respond"}
            and frame is not None
            and frame.request_mode == "execute"
        )
        details = self.to_dict()
        details.pop("action")
        details.pop("reason")
        details["semantic_verifier_attempts"] = semantic_verifier_attempts
        return HarnessStageTrace(
            stage_type="tool_call",
            outcome=outcome_by_action[self.action],
            reason=self.reason,
            model_attempts=model_attempts,
            fallback_used=fallback_used,
            latency_ms=latency_ms,
            details=details,
        )


class ToolCallHarness:
    """Validate model-produced semantics against code-owned safety invariants."""

    def preflight(
        self,
        question: str,
        _context: dict[str, Any],
        _allowed_tools: Iterable[str],
    ) -> ToolCallDecision | None:
        # Preflight intentionally handles only protocol-shaped unsafe input. The
        # model semantic frame handles natural-language variation.
        invalid_reason = _invalid_requested_parameter(question.strip())
        if not invalid_reason:
            return None
        return ToolCallDecision(
            action="reject",
            reason=invalid_reason,
            answer="请求包含无效或未授权的工具参数，未执行任何操作。",
        )

    def validate(
        self,
        question: str,
        context: dict[str, Any],
        allowed_tools: Iterable[str],
        proposals: list[ToolProposal],
    ) -> ToolCallDecision:
        preflight = self.preflight(question, context, allowed_tools)
        if preflight is not None:
            return preflight
        allowed = set(allowed_tools)
        if len(proposals) > 1:
            return ToolCallDecision(
                action="reject",
                reason="multiple_model_tool_calls",
                answer="模型提出了多个互相竞争的操作，未执行任何操作。",
                proposed_tool=",".join(item.name for item in proposals),
            )
        if not proposals:
            return ToolCallDecision(
                action="clarify",
                reason="model_omitted_semantic_decision",
                answer="我没有可靠理解你的意图，请换一种方式说明。",
            )

        proposed = proposals[0]
        proposed_fields = {
            "proposed_tool": proposed.name,
            "proposed_arguments": dict(proposed.arguments),
            "semantic_frame": dict(proposed.semantic_frame),
            "action_entailment": dict(proposed.action_entailment),
        }
        if proposed.name not in allowed and proposed.name not in DECISION_TOOLS:
            return ToolCallDecision(
                action="reject",
                reason="unauthorized_model_tool",
                answer="模型选择了未授权工具，未执行任何操作。",
                **proposed_fields,
            )
        if not proposed.arguments_valid:
            return ToolCallDecision(
                action="reject",
                reason="malformed_model_arguments",
                answer="模型生成了无效工具参数，未执行任何操作。",
                **proposed_fields,
            )

        frame = SemanticFrame.from_mapping(proposed.semantic_frame)
        if frame is None:
            return ToolCallDecision(
                action="reject",
                reason="missing_or_invalid_semantic_frame",
                answer="模型没有提供完整的语义判断，未执行任何操作。",
                **proposed_fields,
            )
        if proposed.name == "respond_directly" and frame.request_mode != "execute":
            return ToolCallDecision(
                action="respond",
                reason="verified_semantic_direct_response",
                answer=_response_text(proposed.arguments) or "好的，我不会执行任何操作。",
                **proposed_fields,
            )
        if proposed.name == "clarify_ui_target" and frame.request_mode in {
            "unclear",
            "inquire",
        }:
            return ToolCallDecision(
                action="clarify",
                reason="verified_semantic_clarification",
                answer=_response_text(proposed.arguments) or "请进一步说明你的意图。",
                **proposed_fields,
            )
        derived_tool = _tool_for_semantic_request(
            frame,
            question=question,
            context=context,
            allowed_tools=allowed,
        )
        if frame.request_mode == "non_executable":
            return ToolCallDecision(
                action="respond",
                reason="semantic_non_executable_request",
                answer=(
                    _response_text(proposed.arguments)
                    if proposed.name == "respond_directly"
                    else "好的，我不会执行这个操作。"
                ),
                **proposed_fields,
            )
        if frame.request_mode == "conversation":
            return ToolCallDecision(
                action="respond",
                reason="semantic_conversation",
                answer=(
                    _response_text(proposed.arguments)
                    if proposed.name == "respond_directly"
                    else "你好。"
                ),
                **proposed_fields,
            )
        if frame.request_mode == "unclear" or derived_tool == "clarify_ui_target":
            return ToolCallDecision(
                action="clarify",
                reason="semantic_intent_unclear",
                answer=(
                    _response_text(proposed.arguments)
                    if proposed.name == "clarify_ui_target"
                    else "请进一步说明要操作的对象和动作。"
                ),
                **proposed_fields,
            )
        if derived_tool == "respond_directly":
            return ToolCallDecision(
                action="respond",
                reason="verified_semantic_direct_response",
                answer=_response_text(proposed.arguments) or "请再说明一下你的需求。",
                **proposed_fields,
            )
        if not derived_tool:
            return ToolCallDecision(
                action="clarify",
                reason="semantic_frame_has_no_tool_mapping",
                answer="我理解了部分意思，但还不能确定应该执行什么操作。",
                **proposed_fields,
            )
        if derived_tool not in allowed:
            return ToolCallDecision(
                action="reject",
                reason="semantic_tool_not_authorized",
                answer="当前客户端没有授权这一操作，未执行任何操作。",
                **proposed_fields,
            )
        semantic_error = _semantic_policy_error(
            derived_tool,
            frame,
            context,
            question,
        )
        if semantic_error == "ambiguous_visible_targets":
            entailment = ActionEntailment.from_mapping(proposed.action_entailment)
            if (
                proposed.name == derived_tool
                and derived_tool in STATE_CHANGING_TOOLS
                and entailment is not None
                and entailment.candidate_tool == derived_tool
                and entailment.verdict == "unclear"
                and not has_explicit_nonexecution_cue(question)
                and not has_explicit_contradiction_evidence(question, derived_tool)
            ):
                return _confirmable_candidate_decision(
                    derived_tool=derived_tool,
                    proposed=proposed,
                    proposed_fields=proposed_fields,
                    frame=frame,
                    context=context,
                    reason="candidate_action_nearest_target",
                )
        if semantic_error:
            action = "respond" if semantic_error == "semantic_non_executable_request" else "clarify"
            return ToolCallDecision(
                action=action,
                reason=semantic_error,
                answer=_semantic_rejection_answer(semantic_error),
                **proposed_fields,
            )
        if derived_tool in STATE_CHANGING_TOOLS:
            if has_explicit_nonexecution_cue(question):
                return ToolCallDecision(
                    action="respond",
                    reason="explicit_non_execution_safety_veto",
                    answer="好的，我会保持当前状态，不执行界面操作。",
                    **proposed_fields,
                )
            entailment = ActionEntailment.from_mapping(proposed.action_entailment)
            if entailment is None or entailment.candidate_tool != derived_tool:
                return ToolCallDecision(
                    action="clarify",
                    reason="missing_or_invalid_action_entailment",
                    answer="无法独立确认你是否授权立即执行，请明确确认。",
                    **proposed_fields,
                )
            if entailment.verdict == "contradicted" and has_explicit_contradiction_evidence(
                question, derived_tool
            ):
                return ToolCallDecision(
                    action="respond",
                    reason="candidate_action_contradicted",
                    answer="好的，我不会执行这个操作。",
                    **proposed_fields,
                )
            target_name_requires_confirmation = (
                frame.target_source == "approximate"
                or (
                    derived_tool in {"go_to_album_page", "go_to_task_guide_page"}
                    and frame.target_source == "explicit"
                    and not _uniquely_names_canonical_page_target(
                        question,
                        frame.target,
                    )
                )
            )
            if entailment.verdict != "entailed" or target_name_requires_confirmation:
                return _confirmable_candidate_decision(
                    derived_tool=derived_tool,
                    proposed=proposed,
                    proposed_fields=proposed_fields,
                    frame=frame,
                    context=context,
                    reason=(
                        "candidate_action_approximate_target"
                        if target_name_requires_confirmation
                        else "candidate_action_contradiction_unsubstantiated"
                        if entailment.verdict == "contradicted"
                        else "candidate_action_not_entailed"
                    ),
                )

        candidate_arguments = (
            {}
            if proposed.name in DECISION_TOOLS and derived_tool not in DECISION_TOOLS
            else proposed.arguments
        )
        normalized, argument_error = normalize_tool_arguments(
            derived_tool,
            candidate_arguments,
        )
        if argument_error:
            return ToolCallDecision(
                action="reject",
                reason=argument_error,
                answer="模型生成的工具参数不满足严格 schema，未执行任何操作。",
                **proposed_fields,
            )
        if _requires_grounded_arguments(derived_tool, normalized) and not frame.arguments_grounded:
            return ToolCallDecision(
                action="clarify",
                reason="tool_arguments_not_grounded",
                answer="工具参数没有明确出现在本次请求中，请补充具体参数。",
                **proposed_fields,
            )
        state_error = _state_precondition_error(derived_tool, normalized, context)
        if state_error:
            return ToolCallDecision(
                action="reject",
                reason=state_error,
                answer=_state_rejection_answer(state_error),
                **proposed_fields,
            )

        corrected = proposed.name != derived_tool
        return ToolCallDecision(
            action="execute",
            tool_name=derived_tool,
            arguments=normalized,
            reason=(
                "semantic_frame_corrected_tool"
                if corrected
                else "verified_semantic_tool_call"
            ),
            corrected=corrected,
            **proposed_fields,
        )

    def validate_confirmed_action(
        self,
        context: dict[str, Any],
        allowed_tools: Iterable[str],
        tool_name: str,
        arguments: dict[str, Any],
    ) -> ToolCallDecision:
        """Revalidate a previously suggested action against current UI state."""

        allowed = set(allowed_tools)
        if tool_name not in STATE_CHANGING_TOOLS or tool_name not in allowed:
            return ToolCallDecision(
                action="reject",
                reason="confirmed_action_no_longer_available",
                answer="这个操作当前已经不可用，因此没有执行。",
                proposed_tool=tool_name,
                proposed_arguments=dict(arguments),
            )
        normalized, argument_error = normalize_tool_arguments(tool_name, arguments)
        if argument_error:
            return ToolCallDecision(
                action="reject",
                reason=argument_error,
                answer="待确认操作的参数已失效，因此没有执行。",
                proposed_tool=tool_name,
                proposed_arguments=dict(arguments),
            )
        state_error = _state_precondition_error(tool_name, normalized, context)
        if state_error:
            return ToolCallDecision(
                action="reject",
                reason=state_error,
                answer=_state_rejection_answer(state_error),
                proposed_tool=tool_name,
                proposed_arguments=dict(arguments),
            )
        return ToolCallDecision(
            action="execute",
            tool_name=tool_name,
            arguments=normalized,
            reason="confirmed_pending_action",
            proposed_tool=tool_name,
            proposed_arguments=dict(arguments),
            suggested_tool=tool_name,
            suggested_arguments=normalized,
            suggested_action_text=_action_display_text(tool_name, normalized),
        )


def _confirmable_candidate_decision(
    *,
    derived_tool: str,
    proposed: ToolProposal,
    proposed_fields: dict[str, Any],
    frame: SemanticFrame,
    context: dict[str, Any],
    reason: str,
) -> ToolCallDecision:
    candidate_arguments = (
        {}
        if proposed.name in DECISION_TOOLS and derived_tool not in DECISION_TOOLS
        else proposed.arguments
    )
    suggested_arguments, suggestion_error = normalize_tool_arguments(
        derived_tool,
        candidate_arguments,
    )
    action_text = _action_display_text(derived_tool, suggested_arguments)
    if suggestion_error or not action_text:
        return ToolCallDecision(
            action="clarify",
            reason="candidate_action_not_entailed",
            answer="我不能确认你是否希望现在执行，请明确说明。",
            **proposed_fields,
        )
    if (
        _requires_grounded_arguments(derived_tool, suggested_arguments)
        and not frame.arguments_grounded
    ):
        return ToolCallDecision(
            action="clarify",
            reason="tool_arguments_not_grounded",
            answer="工具参数没有明确出现在本次请求中，请补充具体参数。",
            **proposed_fields,
        )
    state_error = _state_precondition_error(derived_tool, suggested_arguments, context)
    if state_error:
        return ToolCallDecision(
            action="reject",
            reason=state_error,
            answer=_state_rejection_answer(state_error),
            **proposed_fields,
        )
    return ToolCallDecision(
        action="clarify",
        reason=reason,
        answer=(
            "我没有找到与你说法完全一致的可操作项。"
            f"当前最接近的是“{action_text}”，你是想执行它吗？"
        ),
        suggested_tool=derived_tool,
        suggested_arguments=suggested_arguments,
        suggested_action_text=action_text,
        **proposed_fields,
    )


def semantic_frame_schema() -> dict[str, Any]:
    """Return an isolated copy suitable for adding to selection-only schemas."""

    import json

    return json.loads(json.dumps(SEMANTIC_FRAME_SCHEMA, ensure_ascii=False))


def tool_for_semantic_frame(value: dict[str, Any]) -> str:
    """Resolve a validated semantic frame to its canonical tool name."""

    frame = SemanticFrame.from_mapping(value)
    return _tool_for_semantic_frame(frame) if frame is not None else ""


def tool_for_semantic_request(
    value: dict[str, Any],
    *,
    question: str,
    context: dict[str, Any],
    allowed_tools: Iterable[str],
) -> str:
    """Resolve model semantics with narrow, code-owned contextual corrections."""

    frame = SemanticFrame.from_mapping(value)
    if frame is None:
        return ""
    return _tool_for_semantic_request(
        frame,
        question=question,
        context=context,
        allowed_tools=set(allowed_tools),
    )


def _tool_for_semantic_request(
    frame: SemanticFrame,
    *,
    question: str,
    context: dict[str, Any],
    allowed_tools: set[str],
) -> str:
    derived_tool = _tool_for_semantic_frame(frame)
    final_question = final_intent_segment(question)

    # Reading which step is visible and asking how to perform that step are
    # different read-only intents. Correct this high-confidence confusion so a
    # router cannot replace the evidence-backed answer with a state snapshot.
    if (
        frame.request_mode == "inquire"
        and frame.target == "task_guide"
        and frame.operation == "read_state"
        and HOW_TO_STEP_PATTERN.search(final_question)
        and "query_task_knowledge" in allowed_tools
    ):
        return "query_task_knowledge"

    # A closed panel cannot be navigated internally. If the semantic frame says
    # to navigate to that explicitly named panel, no page was requested, and
    # only opening it is authorized, resolve the action to the panel opener.
    if (
        frame.request_mode == "execute"
        and frame.target_source == "explicit"
        and frame.operation == "go_to"
        and not EXPLICIT_PAGE_PATTERN.search(final_question)
    ):
        panel_to_open_tool = {
            "album": "open_album",
            "task_guide": "open_task_guide",
        }
        open_tool = panel_to_open_tool.get(frame.target, "")
        panel_visible = _panel_value(context, frame.target, "visible")
        if open_tool in allowed_tools and panel_visible is False:
            return open_tool

    return derived_tool


def normalize_tool_arguments(
    tool_name: str,
    arguments: dict[str, Any],
) -> tuple[dict[str, Any], str]:
    if not isinstance(arguments, dict):
        return {}, "model_arguments_not_object"
    if tool_name in {
        "close_album",
        "next_album_page",
        "previous_album_page",
        "get_album_state",
        "close_task_guide",
        "get_current_task_step",
        "next_task_step",
        "previous_task_step",
        "replay_current_task_step",
        "query_task_knowledge",
    }:
        return ({}, "model_extra_arguments") if arguments else ({}, "")
    if tool_name == "open_album":
        if set(arguments) - {"page", "refresh"}:
            return {}, "model_extra_arguments"
        page = parse_positive_page(arguments.get("page", 1))
        refresh = arguments.get("refresh", True)
        if page is None or not isinstance(refresh, bool):
            return {}, "model_arguments_invalid"
        return {"page": page, "refresh": refresh}, ""
    if tool_name in {"go_to_album_page", "go_to_task_guide_page"}:
        if set(arguments) != {"page"}:
            return {}, "model_arguments_invalid"
        page = parse_positive_page(arguments.get("page"))
        if page is None:
            return {}, "model_arguments_invalid"
        return {"page": page}, ""
    if tool_name == "open_task_guide":
        if set(arguments) != {"task_id"}:
            return {}, "model_arguments_invalid"
        task_id = arguments.get("task_id")
        if not isinstance(task_id, int) or isinstance(task_id, bool) or task_id != 1:
            return {}, "model_arguments_invalid"
        return {"task_id": 1}, ""
    if tool_name in DECISION_TOOLS:
        return (dict(arguments), "") if _response_text(arguments) else ({}, "model_arguments_invalid")
    return {}, "unknown_tool"


def _tool_for_semantic_frame(frame: SemanticFrame) -> str:
    # Knowledge can concern the current task guide while still requiring the
    # evidence tool. The operation is authoritative for this read-only route.
    if frame.operation == "knowledge" and frame.target in {
        "knowledge",
        "task_guide",
    }:
        return "query_task_knowledge"
    return _SEMANTICS_TO_TOOL.get((frame.target, frame.operation), "")


def _semantic_policy_error(
    tool_name: str,
    frame: SemanticFrame,
    context: dict[str, Any],
    question: str,
) -> str:
    if tool_name in STATE_CHANGING_TOOLS and frame.request_mode != "execute":
        return "semantic_action_requires_confirmation"
    if tool_name in READ_ONLY_TOOLS and frame.request_mode not in {"execute", "inquire"}:
        return "semantic_request_mode_mismatch"
    if frame.target_source == "unclear":
        return "semantic_target_unclear"
    if frame.target in {"album", "task_guide"}:
        album_visible = _panel_value(context, "album", "visible") is True
        guide_visible = _panel_value(context, "task_guide", "visible") is True
        target_is_grounded = frame.target_source in {
            "explicit",
            "approximate",
        } or _uniquely_names_target(question, frame.target)
        if album_visible and guide_visible and not target_is_grounded:
            return "ambiguous_visible_targets"
        if (
            tool_name in {"open_album", "open_task_guide"}
            and not album_visible
            and not guide_visible
            and not target_is_grounded
        ):
            return "open_target_not_explicit"
    return ""


def _uniquely_names_target(text: str, target: str) -> bool:
    mentions = {
        name
        for name, pattern in EXPLICIT_TARGET_PATTERNS.items()
        if pattern.search(text)
    }
    return mentions == {target}


def _uniquely_names_canonical_page_target(text: str, target: str) -> bool:
    mentions = {
        name
        for name, pattern in CANONICAL_PAGE_TARGET_PATTERNS.items()
        if pattern.search(text)
    }
    return mentions == {target}


def _requires_grounded_arguments(tool_name: str, arguments: dict[str, Any]) -> bool:
    if tool_name in {"go_to_album_page", "go_to_task_guide_page"}:
        return True
    if tool_name == "open_album":
        return arguments.get("page", 1) != 1 or arguments.get("refresh") is not True
    return False


def _invalid_requested_parameter(text: str) -> str:
    if re.search(
        r"忽略.{0,12}(?:规则|要求|系统|工具)|system\s*prompt|绕过.{0,8}(?:校验|权限)",
        text,
        re.IGNORECASE,
    ):
        return "instruction_injection"
    if re.search(
        r"(?:path|method|url|文件路径|节点路径)\s*=|额外(?:传入|参数)|附加参数",
        text,
        re.IGNORECASE,
    ):
        return "unsupported_requested_parameter"
    task_id = _explicit_task_id(text)
    if task_id is not None and task_id != 1:
        return "unsupported_task_id"
    if re.search(r"第\s*(?:0+(?:\.0+)?|[-−]\s*\d+|\d+\.\d+)\s*(?:页|步|步骤)", text):
        return "invalid_requested_position"
    return ""


def _explicit_task_id(text: str) -> int | None:
    match = re.search(r"任务(?:编号|ID|id)?\s*([0-9]+)", text)
    return int(match.group(1)) if match else None


def _panel_value(context: dict[str, Any], panel: str, key: str) -> Any:
    value = context.get(panel)
    return value.get(key) if isinstance(value, dict) else None


def _state_precondition_error(
    tool_name: str,
    arguments: dict[str, Any],
    context: dict[str, Any],
) -> str:
    panel = (
        "album"
        if tool_name in _ALBUM_TOOLS
        else "task_guide"
        if tool_name in _GUIDE_TOOLS
        else ""
    )
    visible = _panel_value(context, panel, "visible") if panel else None
    requires_visible = tool_name not in {
        "open_album",
        "open_task_guide",
        "query_task_knowledge",
    }
    if requires_visible and visible is False:
        return "target_panel_not_visible"
    if tool_name in {"next_album_page", "next_task_step"} and _panel_value(
        context, panel, "can_next"
    ) is False:
        return "already_at_last_position"
    if tool_name in {"previous_album_page", "previous_task_step"} and _panel_value(
        context, panel, "can_previous"
    ) is False:
        return "already_at_first_position"
    if tool_name in {"go_to_album_page", "go_to_task_guide_page"}:
        page_count = _panel_value(context, panel, "page_count")
        page = arguments.get("page")
        if isinstance(page_count, int) and isinstance(page, int) and page > page_count:
            return "requested_position_out_of_range"
    return ""


def _state_rejection_answer(reason: str) -> str:
    return {
        "target_panel_not_visible": "目标界面当前不可见，未执行操作。",
        "already_at_last_position": "当前已经是最后一页或最后一步，未继续前进。",
        "already_at_first_position": "当前已经是第一页或第一步，未继续后退。",
        "requested_position_out_of_range": "请求的位置超出当前界面范围，未执行操作。",
    }.get(reason, "当前状态不允许执行该操作。")


def _semantic_rejection_answer(reason: str) -> str:
    return {
        "semantic_action_requires_confirmation": "这更像询问而不是执行指令，请确认是否现在执行。",
        "semantic_request_mode_mismatch": "当前表达不足以确认需要调用这个工具。",
        "semantic_target_unclear": "请说明要操作相册还是工作清单。",
        "ambiguous_visible_targets": "相册和工作清单都处于显示状态，请明确要操作哪一个。",
        "open_target_not_explicit": "请明确要打开相册还是工作清单。",
    }.get(reason, "请进一步说明你的意图。")


def _response_text(arguments: dict[str, Any]) -> str:
    value = arguments.get("text") if isinstance(arguments, dict) else None
    if not isinstance(value, str):
        return ""
    return value.strip()[:300]
