"""Native Chat Completions adapter: propose tools, never execute Godot actions."""
from __future__ import annotations

from typing import Any, Iterator

from agent_service.config import Settings
from agent_service.model_endpoint import request_tool_call


class OpenAIToolSelector:
    def __init__(self, settings: Settings, selection_tools: list[Any], system_message: str) -> None:
        self.settings = settings
        self.tools = {tool.name: tool for tool in selection_tools}
        self.system_message = system_message

    def run(self, messages: list[dict[str, Any]], **_kwargs: Any) -> Iterator[list[dict[str, Any]]]:
        definitions = [{"type": "function", "function": {
            "name": tool.name, "description": tool.description, "parameters": tool.parameters,
        }} for tool in self.tools.values()]
        try:
            name, arguments = request_tool_call(
                self.settings.model_server + "/chat/completions", self.settings.api_key,
                self.settings.model_request_timeout_seconds, dict(
                    model=self.settings.model_name,
                    messages=[{"role": "system", "content": self.system_message}, *messages],
                    tools=definitions, tool_choice="auto", stream=False,
                    temperature=0.0, max_tokens=512,
                ))
            if name not in self.tools:
                # No arbitrary text or unknown/multiple tools may bypass the harness.
                yield [{"role": "assistant", "content": ""}]
                return
            # These are selection proxies, not the executable tool instances.
            proposal = self.tools[name].call(arguments)
            yield [{"role": "function", "name": name, "content": proposal}]
        except Exception as exc:
            raise RuntimeError(f"External model tool selection failed ({type(exc).__name__})") from None
