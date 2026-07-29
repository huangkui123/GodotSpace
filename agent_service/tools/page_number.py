from __future__ import annotations

import json
import re
from typing import Any

_CHINESE_DIGITS = {
    "零": 0,
    "〇": 0,
    "一": 1,
    "二": 2,
    "两": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
}
_CHINESE_UNITS = {"十": 10, "百": 100, "千": 1000}


def parse_page_arguments(
    params: str | dict[str, Any],
    *,
    tool_name: str,
) -> dict[str, int]:
    if isinstance(params, str):
        try:
            arguments = json.loads(params)
        except json.JSONDecodeError as exc:
            raise ValueError("Parameters must be formatted as valid JSON") from exc
    else:
        arguments = params
    if not isinstance(arguments, dict) or set(arguments) != {"page"}:
        raise ValueError(f"{tool_name} requires only a page parameter")
    page = parse_positive_page(arguments["page"])
    if page is None:
        raise ValueError("page must identify a positive integer page")
    return {"page": page}


def parse_positive_page(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, float):
        return int(value) if value.is_integer() and value > 0 else None
    if not isinstance(value, str):
        return None

    text = value.strip().replace(" ", "")
    text = text.removeprefix("第")
    for suffix in ("页面", "页", "步骤", "步"):
        if text.endswith(suffix):
            text = text[: -len(suffix)]
            break
    if re.fullmatch(r"[0-9]+(?:\.0+)?", text):
        page = int(float(text))
        return page if page > 0 else None
    page = _parse_chinese_integer(text)
    return page if page is not None and page > 0 else None


def _parse_chinese_integer(text: str) -> int | None:
    if not text or any(
        character not in _CHINESE_DIGITS and character not in _CHINESE_UNITS
        for character in text
    ):
        return None
    total = 0
    current_digit: int | None = None
    for character in text:
        if character in _CHINESE_DIGITS:
            current_digit = _CHINESE_DIGITS[character]
            continue
        unit = _CHINESE_UNITS[character]
        total += (1 if current_digit is None else current_digit) * unit
        current_digit = None
    return total + (0 if current_digit is None else current_digit)
