from __future__ import annotations

import json
import re
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Iterable


ABSTAIN_ANSWER = "现有可信资料未提供足够依据，请查阅对应手册或请专家席确认。"
INJECTION_MARKERS = (
    "忽略之前",
    "忽略以上",
    "忽略系统",
    "system prompt",
    "立即操作",
    "无需确认",
)
QUESTION_STOP_TERMS = frozenset(
    {
        "什么",
        "怎么",
        "怎样",
        "多少",
        "哪个",
        "哪些",
        "需要",
        "应该",
        "可以",
        "能否",
        "是否",
        "现在",
        "当前",
        "这一步",
        "操作",
        "进行",
        "一下",
    }
)
DOMAIN_TERMS = (
    "氧气分压",
    "主备传感器",
    "供给阀门",
    "调压阀",
    "管路连接",
    "舱门密封圈",
    "防静电手环",
    "连接器",
    "样品盒",
    "轴心机构",
    "科学实验操作盖",
    "无容器实验平台",
    "无容器实验柜",
    "天地通话",
    "地面确认",
    "断电",
    "螺钉",
    "力矩",
    "手套",
    "工具",
    "对角线",
    "第二遍",
    "对位标识",
    "温度",
    "发射任务",
    "专家席",
    "关键步骤",
    "执行前确认",
    "口令复述",
    "对象确认",
    "状态确认",
    "预期结果",
)
ASR_REPLACEMENTS = {
    "叉零一": "X01",
    "叉零二": "X02",
    "叉零三": "X03",
    "m六": "M6",
    "M六": "M6",
    "m五": "M5",
    "M五": "M5",
    "二点五牛米": "2.5Nm",
    "放静电手环": "防静电手环",
}
PARAMETER_PATTERNS = {
    "temperature": re.compile(r"温度|°\s*C|℃|摄氏", re.IGNORECASE),
    "torque": re.compile(r"力矩|扭矩|N\s*[·.・]?\s*m|牛(?:顿)?米", re.IGNORECASE),
    "connector": re.compile(r"连接器|\bX\s*0?\d+\b", re.IGNORECASE),
    "identifier": re.compile(r"编号|代号|平台号", re.IGNORECASE),
    "count": re.compile(r"多少|几(?:颗|名|个)|数量", re.IGNORECASE),
    "date": re.compile(r"日期|哪一天|何时|什么时候|发射任务", re.IGNORECASE),
}
VALUE_PATTERNS = {
    "temperature": re.compile(r"[-+]?\d+(?:\.\d+)?\s*(?:°\s*C|℃|摄氏度?)", re.IGNORECASE),
    "torque": re.compile(r"\d+(?:\.\d+)?\s*(?:N\s*[·.・]?\s*m|牛(?:顿)?米)", re.IGNORECASE),
    "connector": re.compile(r"(?<![A-Z0-9])X\s*0?\d+(?![A-Z0-9])", re.IGNORECASE),
    "identifier": re.compile(
        r"(?<![A-Z0-9])(?:[A-Z]{2,}\d{3,}[A-Z0-9-]*|[A-Z]\d{2,}-\d+|\d+\s*[-至到]\s*\d+)(?![A-Z0-9])",
        re.IGNORECASE,
    ),
    "count": re.compile(r"\d+\s*(?:颗|名|个)|[一二两三四五六七八九十]+\s*(?:颗|名|个)"),
    "date": re.compile(r"\d{4}\s*年|\d{1,2}\s*月\s*\d{1,2}\s*日"),
}
ENTITY_PATTERN = re.compile(
    r"(?<![A-Z0-9])(?:X\s*0?\d+|M\s*\d+|[A-Z]{2,}\d{3,}[A-Z0-9-]*|[A-Z]\d{2,}-\d+)(?![A-Z0-9])",
    re.IGNORECASE,
)
CONNECTOR_ENTITY_PATTERN = re.compile(r"(?<![A-Z0-9])X\s*0?\d+(?![A-Z0-9])", re.IGNORECASE)


@dataclass(frozen=True, slots=True)
class EvidenceEntry:
    id: str
    title: str
    source: str
    content: str
    trust: str = "trusted"
    priority: int = 0


@dataclass(frozen=True, slots=True)
class EvidenceQuote:
    evidence_id: str
    quote: str


@dataclass(frozen=True, slots=True)
class KnowledgeAnswer:
    answer: str
    decision: str
    citations: tuple[EvidenceQuote, ...]
    reason: str
    retrieved_ids: tuple[str, ...]
    model_attempts: int

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["citations"] = [asdict(item) for item in self.citations]
        value["retrieved_ids"] = list(self.retrieved_ids)
        return value


class TrustedEvidenceStore:
    """Immutable server-owned corpus; request payloads can only select registered IDs."""

    def __init__(self, entries: Iterable[EvidenceEntry] = ()) -> None:
        trusted: list[EvidenceEntry] = []
        seen: set[str] = set()
        for entry in entries:
            if entry.id in seen:
                raise ValueError(f"duplicate trusted evidence id: {entry.id}")
            seen.add(entry.id)
            trusted.append(
                EvidenceEntry(
                    id=entry.id,
                    title=entry.title,
                    source=entry.source,
                    content=entry.content,
                    trust="trusted",
                    priority=0,
                )
            )
        self._entries = tuple(trusted)
        self._by_id = {entry.id: entry for entry in trusted}

    @classmethod
    def from_json_file(cls, path: str) -> "TrustedEvidenceStore":
        if not path:
            return cls()
        corpus_path = Path(path).expanduser().resolve()
        try:
            value = json.loads(corpus_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"cannot load KNOWLEDGE_CORPUS_PATH {corpus_path}: {exc}") from exc
        raw_entries = value.get("corpus") if isinstance(value, dict) else value
        if not isinstance(raw_entries, list):
            raise ValueError("knowledge corpus must be a JSON array or an object with a corpus array")
        entries = [evidence_entry_from_dict(item, index) for index, item in enumerate(raw_entries)]
        return cls(entries)

    def select(self, evidence_ids: list[str] | None = None) -> list[EvidenceEntry]:
        if evidence_ids is None:
            return list(self._entries)
        unknown = [entry_id for entry_id in evidence_ids if entry_id not in self._by_id]
        if unknown:
            raise ValueError(f"unknown corpus_entry_ids: {unknown}")
        return [self._by_id[entry_id] for entry_id in evidence_ids]

    @property
    def count(self) -> int:
        return len(self._entries)


ModelInvoker = Callable[[str, dict[str, Any]], str]


def normalize_for_matching(value: str) -> str:
    text = value
    for source, target in ASR_REPLACEMENTS.items():
        text = text.replace(source, target)
    text = text.upper().replace("N·M", "NM").replace("N.M", "NM")
    return re.sub(r"[\s，。！？、,!?：:；;（）()\[\]【】'\"`_*#-]+", "", text)


def _entry_haystack(entry: EvidenceEntry) -> str:
    return f"{entry.title}\n{entry.source}\n{entry.content}"


def _question_terms(question: str) -> list[str]:
    normalized = normalize_for_matching(question)
    terms = [term for term in DOMAIN_TERMS if normalize_for_matching(term) in normalized]
    terms.extend(match.group(0).upper().replace(" ", "") for match in ENTITY_PATTERN.finditer(question))
    ascii_terms = re.findall(r"[A-Za-z]+\d+(?:-\d+)?|\d+(?:\.\d+)?", question)
    terms.extend(ascii_terms)
    for chunk in re.split(r"[\s，。！？、,!?：:；;（）()]", question):
        clean = chunk.strip()
        if 2 <= len(clean) <= 12 and clean not in QUESTION_STOP_TERMS:
            terms.append(clean)
    unique: list[str] = []
    for term in terms:
        normalized_term = normalize_for_matching(term)
        if len(normalized_term) >= 2 and normalized_term not in unique:
            unique.append(normalized_term)
    return unique


def _is_untrusted(entry: EvidenceEntry) -> bool:
    if entry.trust.lower() not in {"trusted", "runtime"}:
        return True
    normalized = normalize_for_matching(_entry_haystack(entry))
    return any(normalize_for_matching(marker) in normalized for marker in INJECTION_MARKERS)


def score_evidence(question: str, entry: EvidenceEntry) -> float:
    if _is_untrusted(entry):
        return float("-inf")
    haystack = normalize_for_matching(_entry_haystack(entry))
    question_normalized = normalize_for_matching(question)
    score = float(entry.priority)
    if entry.trust.lower() == "runtime":
        score += 4.0
    if question_normalized and question_normalized in haystack:
        score += 12.0
    for term in _question_terms(question):
        if term in haystack:
            score += 5.0 if term in normalize_for_matching(entry.title) else 2.0
    for name, pattern in PARAMETER_PATTERNS.items():
        if pattern.search(question) and pattern.search(_entry_haystack(entry)):
            score += 2.0
        if pattern.search(question) and VALUE_PATTERNS[name].search(entry.content):
            score += 2.0
    if re.search(r"(?:能|可以|是否).*(?:继续|拆|拔|操作)", question) and re.search(
        r"确认|不得|不应|暂停|停止|安全|拆装", _entry_haystack(entry)
    ):
        score += 4.0
    if re.search(r"(?:继续拆|拆连接器|拔连接器)", question) and re.search(
        r"断电|天地通话|地面确认", entry.content
    ):
        score += 12.0
    return score


def retrieve_evidence(
    question: str,
    entries: Iterable[EvidenceEntry],
    *,
    limit: int = 5,
    minimum_score: float = 2.0,
) -> list[EvidenceEntry]:
    scored = [(score_evidence(question, entry), index, entry) for index, entry in enumerate(entries)]
    scored = [item for item in scored if item[0] >= minimum_score]
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [item[2] for item in scored[:limit]]


def _requested_parameter_types(question: str) -> set[str]:
    requested: set[str] = set()
    if re.search(r"温度.*(?:多少|几|范围|值)|(?:多少|几|范围|值).*温度", question):
        requested.add("temperature")
    if re.search(r"(?:力矩|扭矩).*(?:多少|几|目标|应该用|是不是用|是否用)", question):
        requested.add("torque")
    if re.search(r"(?:编号|代号|平台号).*(?:什么|多少|哪个)|(?:什么|哪个).*(?:编号|代号|平台号)", question):
        requested.add("identifier")
    if re.search(r"多少|几(?:颗|名|个)|数量", question):
        requested.add("count")
    if re.search(r"日期|哪一天|何时|什么时候|发射任务", question):
        requested.add("date")
    if _question_connector_entities(question) or re.search(r"(?:哪个|哪些|编号).{0,4}连接器", question):
        requested.add("connector")
    return requested


def _question_entities(question: str) -> set[str]:
    normalized_question = question
    for source, target in ASR_REPLACEMENTS.items():
        normalized_question = normalized_question.replace(source, target)
    return {
        match.group(0).upper().replace(" ", "")
        for match in ENTITY_PATTERN.finditer(normalized_question)
    }


def _question_connector_entities(question: str) -> set[str]:
    normalized_question = question
    for source, target in ASR_REPLACEMENTS.items():
        normalized_question = normalized_question.replace(source, target)
    return {
        match.group(0).upper().replace(" ", "")
        for match in CONNECTOR_ENTITY_PATTERN.finditer(normalized_question)
    }


def evidence_is_potentially_sufficient(question: str, entries: list[EvidenceEntry]) -> bool:
    if not entries:
        return False
    combined = "\n".join(entry.content for entry in entries)
    combined_normalized = normalize_for_matching(combined)
    entities = _question_entities(question)
    if entities and not entities <= {
        match.group(0).upper().replace(" ", "") for match in ENTITY_PATTERN.finditer(combined)
    }:
        return False
    for parameter_type in _requested_parameter_types(question):
        if parameter_type == "connector" and entities:
            continue
        if not VALUE_PATTERNS[parameter_type].search(combined):
            return False
    terms = _question_terms(question)
    if not terms:
        return any(entry.trust == "runtime" for entry in entries)
    if any(term in combined_normalized for term in terms):
        return True
    if re.search(r"(?:能|可以|是否).*(?:继续|拆|拔|操作)", question) and re.search(
        r"确认|不得|不应|暂停|停止|安全", combined
    ):
        return True
    return any(entry.trust == "runtime" and entry.priority >= 5 for entry in entries)


def find_evidence_conflicts(
    question: str,
    entries: list[EvidenceEntry],
) -> dict[str, list[str]]:
    conflicts: dict[str, list[str]] = {}
    for parameter_type in _requested_parameter_types(question) & {
        "temperature",
        "torque",
        "identifier",
        "date",
    }:
        values: set[str] = set()
        for entry in entries:
            for match in VALUE_PATTERNS[parameter_type].finditer(entry.content):
                values.add(normalize_for_matching(match.group(0)))
        if len(values) > 1:
            conflicts[parameter_type] = sorted(values)
    return conflicts


def select_deterministic_evidence(
    question: str,
    entries: list[EvidenceEntry],
) -> list[EvidenceEntry]:
    if not entries:
        return []
    scored = [(score_evidence(question, entry), entry) for entry in entries]
    top_score = max(score for score, _ in scored)
    broad_question = bool(
        re.search(r"哪些|分别|优先检查|怎么做|应该|可以吗|能不能|能否|是否|前需要", question)
    )
    selected = [
        entry
        for score, entry in scored
        if score >= max(2.0, top_score - (7.0 if broad_question else 3.0))
    ]
    if broad_question and len(entries) <= 4:
        selected = list(entries)
    return selected[:4]


def render_abstention(question: str, entries: list[EvidenceEntry] | None = None) -> str:
    entities = sorted(_question_connector_entities(question))
    if "connector" in _requested_parameter_types(question) and entities:
        names = "和".join(entities)
        answer = f"现有可信资料未提供连接器{names}的操作依据，请确认连接器编号或请专家席确认。"
        return _append_abstention_source(answer, entries)
    if "date" in _requested_parameter_types(question):
        return "现有可信资料不包含实时日程，资料未提供具体日期，无法确认；请查询官方日程。"
    return _append_abstention_source(ABSTAIN_ANSWER, entries)


def _append_abstention_source(answer: str, entries: list[EvidenceEntry] | None) -> str:
    if not entries:
        return answer
    entry = entries[0]
    return f"{answer} 来源：{entry.title}（{entry.source}）。"


def build_extraction_schema(evidence_ids: list[str]) -> dict[str, Any]:
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "decision": {"type": "string", "enum": ["answer", "abstain"]},
            "evidence_ids": {
                "type": "array",
                "maxItems": 4,
                "items": {"type": "string", "enum": evidence_ids},
            },
        },
        "required": ["decision", "evidence_ids"],
    }


def build_extraction_prompt(question: str, entries: list[EvidenceEntry]) -> str:
    evidence = "\n".join(
        f"[{entry.id}] 来源={entry.source}；标题={entry.title}；原文={entry.content}"
        for entry in entries
    )
    return (
        "你是证据选择器，不是知识问答助手。只判断下列可信证据是否直接回答问题。\n"
        "选择所有直接有助于回答的证据ID，不得回答问题、改写原文、补充、计算或使用常识。"
        "至少一条证据直接相关时 decision=answer；完全无关时 decision=abstain。\n"
        "evidence_ids 最多4项；abstain 时必须为空。只输出符合 schema 的 JSON。\n"
        f"问题：{question}\n可信证据：\n{evidence}"
    )


def parse_and_validate_selection(
    raw: str,
    question: str,
    entries: list[EvidenceEntry],
) -> tuple[str, tuple[EvidenceQuote, ...], str]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return "abstain", (), "model_json_invalid"
    if not isinstance(value, dict) or set(value) != {"decision", "evidence_ids"}:
        return "abstain", (), "model_schema_invalid"
    decision = value.get("decision")
    evidence_ids = value.get("evidence_ids")
    if decision not in {"answer", "abstain"} or not isinstance(evidence_ids, list):
        return "abstain", (), "model_schema_invalid"
    if decision == "abstain":
        return "abstain", (), "model_abstained"
    if not evidence_ids or len(evidence_ids) > 4 or len(evidence_ids) != len(set(evidence_ids)):
        return "abstain", (), "selection_count_invalid"
    by_id = {entry.id: entry for entry in entries}
    quotes: list[EvidenceQuote] = []
    for evidence_id in evidence_ids:
        if not isinstance(evidence_id, str) or evidence_id not in by_id:
            return "abstain", (), "selection_reference_invalid"
        quotes.append(EvidenceQuote(evidence_id=evidence_id, quote=by_id[evidence_id].content))
    selected_entries = [by_id[item.evidence_id] for item in quotes]
    if not evidence_is_potentially_sufficient(question, selected_entries):
        return "abstain", (), "selected_evidence_insufficient"
    selected_text = "\n".join(item.quote for item in quotes)
    for entity in _question_entities(question):
        if entity not in normalize_for_matching(selected_text):
            return "abstain", (), "question_entity_not_quoted"
    for parameter_type in _requested_parameter_types(question):
        if parameter_type == "connector" and _question_entities(question):
            continue
        if not VALUE_PATTERNS[parameter_type].search(selected_text):
            return "abstain", (), "requested_value_not_quoted"
    return "answer", tuple(quotes), "verified"


def render_verified_answer(
    question: str,
    quotes: tuple[EvidenceQuote, ...],
    entries: list[EvidenceEntry],
) -> str:
    by_id = {entry.id: entry for entry in entries}
    normalized = normalize_for_matching(question)
    prefix = "根据可信资料："
    if "对吧" in normalized or "是不是" in normalized:
        prefix = "提问中的说法不对，应为资料原文中的要求："
    elif re.search(r"先.*(?:之后|再).*(?:可以吗|能否|是否)", question):
        prefix = "不可以先执行提问中的操作，必须先确认断电并满足资料中的前置条件："
    elif re.search(r"(?:能|可以|是否).*(?:继续|拆|拔|操作)", question):
        prefix = "当前状态无法确认，不能直接继续；必须先满足资料中的前置条件："
    elif any(term in normalized for term in ("这一步怎么", "现在应该", "现在能")):
        prefix = "请按资料原文执行："
    lines = [prefix]
    for item in quotes:
        entry = by_id[item.evidence_id]
        lines.append(f"{item.quote} 来源：{entry.title}（{entry.source}）。")
    combined = "".join(item.quote for item in quotes)
    if re.search(r"几颗|多少颗", question):
        match = re.search(r"(\d+)\s*个[^。；]*螺钉", combined)
        if match:
            lines.insert(1, f"数量为{match.group(1)}颗。")
    return "\n".join(lines)


class OpenAICompatibleJsonClient:
    def __init__(
        self,
        endpoint: str,
        model: str,
        *,
        api_key: str = "EMPTY",
        timeout_seconds: float = 2.0,
    ) -> None:
        self._endpoint = endpoint.rstrip("/")
        self._model = model
        self._api_key = api_key
        self._timeout_seconds = timeout_seconds

    def __call__(self, prompt: str, schema: dict[str, Any]) -> str:
        url = self._endpoint
        if not url.endswith("/chat/completions"):
            url = f"{url}/chat/completions"
        payload = {
            "model": self._model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.0,
            "max_tokens": 256,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "evidence_selection",
                    "strict": True,
                    "schema": schema,
                },
            },
        }
        request = urllib.request.Request(
            url,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._api_key}",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=self._timeout_seconds) as response:
            result = json.loads(response.read().decode("utf-8"))
        choices = result.get("choices", [])
        if not choices:
            raise RuntimeError("The evidence selector returned no choices")
        return str(choices[0].get("message", {}).get("content", ""))


class KnowledgeHarness:
    def __init__(
        self,
        model_invoker: ModelInvoker,
        *,
        retrieval_limit: int = 5,
        minimum_score: float = 2.0,
    ) -> None:
        self._model_invoker = model_invoker
        self._retrieval_limit = retrieval_limit
        self._minimum_score = minimum_score

    def answer(self, question: str, entries: Iterable[EvidenceEntry]) -> KnowledgeAnswer:
        clean_question = question.strip()
        available = list(entries)
        retrieved = retrieve_evidence(
            clean_question,
            available,
            limit=self._retrieval_limit,
            minimum_score=self._minimum_score,
        )
        retrieved_ids = tuple(entry.id for entry in retrieved)
        if find_evidence_conflicts(clean_question, retrieved):
            return KnowledgeAnswer(
                answer=_append_abstention_source(
                    "可信资料中的关键参数互相冲突，无法确认；请由专家席核对有效版本。",
                    retrieved,
                ),
                decision="abstain",
                citations=(),
                reason="evidence_conflict",
                retrieved_ids=retrieved_ids,
                model_attempts=0,
            )
        requires_power_confirmation = bool(
            re.search(r"(?:继续拆|拆连接器|拔连接器|连接器.*(?:拆|拔))", clean_question)
            and not _question_entities(clean_question)
        )
        if requires_power_confirmation and not any(
            re.search(r"断电|天地通话|地面确认", entry.content) for entry in retrieved
        ):
            return KnowledgeAnswer(
                answer=(
                    "当前不能确认断电状态，不能直接继续操作；请先通过天地通话向地面确认。"
                ),
                decision="abstain",
                citations=(),
                reason="safety_state_unverified",
                retrieved_ids=retrieved_ids,
                model_attempts=0,
            )
        if not evidence_is_potentially_sufficient(clean_question, retrieved):
            return KnowledgeAnswer(
                answer=render_abstention(clean_question, retrieved),
                decision="abstain",
                citations=(),
                reason="retrieval_insufficient",
                retrieved_ids=retrieved_ids,
                model_attempts=0,
            )
        deterministic = select_deterministic_evidence(clean_question, retrieved)
        if deterministic and evidence_is_potentially_sufficient(clean_question, deterministic):
            if len(deterministic) > 1:
                decision, quotes, reason = self._select_with_model(
                    clean_question,
                    deterministic,
                )
                if decision == "answer":
                    selected_ids = {quote.evidence_id for quote in quotes}
                    required_ids = {
                        entry.id
                        for entry in deterministic
                        if _entry_has_safety_directive(entry)
                    }
                    if required_ids - selected_ids:
                        decision = "abstain"
                        reason = "model_omitted_safety_evidence"
                if decision == "answer":
                    return KnowledgeAnswer(
                        answer=render_verified_answer(clean_question, quotes, deterministic),
                        decision="answer",
                        citations=quotes,
                        reason=reason,
                        retrieved_ids=retrieved_ids,
                        model_attempts=1,
                    )
                fallback_quotes = tuple(
                    EvidenceQuote(evidence_id=entry.id, quote=entry.content)
                    for entry in deterministic
                )
                return KnowledgeAnswer(
                    answer=render_verified_answer(
                        clean_question,
                        fallback_quotes,
                        deterministic,
                    ),
                    decision="answer",
                    citations=fallback_quotes,
                    reason=f"deterministic_fallback:{reason}",
                    retrieved_ids=retrieved_ids,
                    model_attempts=1,
                )
            quotes = tuple(
                EvidenceQuote(evidence_id=entry.id, quote=entry.content) for entry in deterministic
            )
            return KnowledgeAnswer(
                answer=render_verified_answer(clean_question, quotes, deterministic),
                decision="answer",
                citations=quotes,
                reason="deterministic_evidence",
                retrieved_ids=retrieved_ids,
                model_attempts=0,
            )
        decision, quotes, reason = self._select_with_model(clean_question, retrieved)
        if decision != "answer":
            return KnowledgeAnswer(
                answer=render_abstention(clean_question, retrieved),
                decision="abstain",
                citations=(),
                reason=reason,
                retrieved_ids=retrieved_ids,
                model_attempts=1,
            )
        return KnowledgeAnswer(
            answer=render_verified_answer(clean_question, quotes, retrieved),
            decision="answer",
            citations=quotes,
            reason=reason,
            retrieved_ids=retrieved_ids,
            model_attempts=1,
        )

    def _select_with_model(
        self,
        question: str,
        entries: list[EvidenceEntry],
    ) -> tuple[str, tuple[EvidenceQuote, ...], str]:
        schema = build_extraction_schema([entry.id for entry in entries])
        prompt = build_extraction_prompt(question, entries)
        try:
            raw = self._model_invoker(prompt, schema)
        except Exception as exc:
            return "abstain", (), f"model_error:{type(exc).__name__}"
        return parse_and_validate_selection(raw, question, entries)


def _entry_has_safety_directive(entry: EvidenceEntry) -> bool:
    return bool(
        re.search(
            r"停止|暂停|不得|不应|确认断电|地面确认|天地通话|专家席确认|请求专家席|安全构型",
            entry.content,
        )
    )


def evidence_entry_from_dict(value: dict[str, Any], index: int) -> EvidenceEntry:
    if not isinstance(value, dict):
        raise ValueError(f"entries[{index}] must be an object")
    allowed = {"id", "title", "source", "content", "trust", "priority", "tags"}
    unknown = set(value) - allowed
    if unknown:
        raise ValueError(f"entries[{index}] contains unsupported fields: {sorted(unknown)}")
    entry_id = str(value.get("id", "")).strip()
    title = str(value.get("title", "")).strip()
    source = str(value.get("source", "")).strip()
    content = str(value.get("content", "")).strip()
    trust = str(value.get("trust", "trusted")).strip().lower()
    priority = value.get("priority", 0)
    if not entry_id or not title or not source or not content:
        raise ValueError(f"entries[{index}] requires non-empty id, title, source and content")
    if trust not in {"trusted", "runtime", "untrusted"}:
        raise ValueError(f"entries[{index}].trust must be trusted, runtime or untrusted")
    if not isinstance(priority, int) or isinstance(priority, bool) or not -10 <= priority <= 10:
        raise ValueError(f"entries[{index}].priority must be an integer from -10 to 10")
    if len(entry_id) > 100 or len(title) > 200 or len(source) > 300 or len(content) > 4000:
        raise ValueError(f"entries[{index}] exceeds a field length limit")
    return EvidenceEntry(entry_id, title, source, content, trust, priority)


def runtime_evidence_entry_from_request(
    value: dict[str, Any],
    index: int,
    source: str,
) -> EvidenceEntry:
    if not isinstance(value, dict):
        raise ValueError(f"runtime_entries[{index}] must be an object")
    forbidden = {"trust", "priority", "source"} & set(value)
    if forbidden:
        raise ValueError(
            f"runtime_entries[{index}] cannot set server-owned fields: {sorted(forbidden)}"
        )
    return evidence_entry_from_dict(
        {**value, "source": source, "trust": "runtime", "priority": 5},
        index,
    )
