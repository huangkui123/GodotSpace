"""Shared, provider-neutral endpoint validation and bounded JSON transport."""
from __future__ import annotations

import ipaddress
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


def validate_base_url(value: str, *, allow_insecure_http: bool = False) -> str:
    if not isinstance(value, str) or any(ord(c) < 33 for c in value):
        raise ValueError("base_url must be an HTTP(S) API base URL without whitespace")
    try:
        parts = urllib.parse.urlsplit(value)
        port = parts.port
    except ValueError:
        raise ValueError("Invalid model base_url") from None
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError("base_url must not contain credentials, query parameters or fragments")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("Invalid model endpoint port")
    if parts.path.rstrip("/").endswith(("/chat/completions", "/models")):
        raise ValueError("Use the API base URL (e.g. /v1), not /chat/completions or /models")
    loopback = parts.hostname.lower() == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(parts.hostname).is_loopback
    except ValueError:
        pass
    if parts.scheme == "http" and not loopback and not allow_insecure_http:
        raise ValueError("Non-loopback HTTP requires allow_insecure_http=true; prefer HTTPS or an SSH tunnel")
    return value.rstrip("/")


def validate_key_env(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value):
        raise ValueError("api_key_env must name an environment variable, not contain a key")
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Model endpoint redirects are not accepted; configure its final base URL")


def request_json(url: str, api_key: str, timeout: float, payload: dict | None = None) -> dict[str, Any]:
    headers = {"Content-Type": "application/json"}
    if api_key and api_key != "EMPTY":
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(url, headers=headers,
        data=None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        method="GET" if payload is None else "POST")
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise ValueError("Model response exceeds 2 MiB")
            result = json.loads(raw)
        if not isinstance(result, dict):
            raise ValueError("Model response must be a JSON object")
        return result
    except urllib.error.HTTPError as exc:
        # Do not echo server-provided bodies/URLs: they may contain secrets.
        raise RuntimeError(f"Model API returned HTTP {exc.code}") from None
    except (OSError, urllib.error.URLError):
        raise RuntimeError("Model API connection/TLS/timeout failure") from None
    except (ValueError, UnicodeError):
        raise RuntimeError("Model API returned invalid/oversized JSON or a redirect") from None


def request_tool_call(url: str, api_key: str, timeout: float, payload: dict) -> tuple[str, str]:
    """Use the same bounded, non-redirecting transport for every external tool call."""
    result = request_json(url, api_key, timeout, dict(payload, stream=False))
    try:
        choice = result["choices"][0]
        calls = choice["message"]["tool_calls"]
        if choice.get("finish_reason") in {"length", "content_filter"} or len(calls) != 1:
            raise ValueError
        call = calls[0]
        name, arguments = call["function"]["name"], call["function"]["arguments"]
        if call.get("type") != "function" or not isinstance(name, str) or not isinstance(arguments, str):
            raise ValueError
        return name, arguments
    except (KeyError, IndexError, TypeError, ValueError):
        raise RuntimeError("Model must return exactly one complete function call") from None
