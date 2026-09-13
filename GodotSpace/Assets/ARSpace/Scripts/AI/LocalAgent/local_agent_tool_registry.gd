class_name LocalAgentToolRegistry
extends RefCounted

var _handlers: Dictionary = {}
var _handler_owners: Dictionary = {}


func register_tool(tool_name: StringName, handler: Callable) -> bool:
	var normalized := String(tool_name).strip_edges()
	if normalized.is_empty() or not handler.is_valid() or _handlers.has(normalized):
		return false
	_handlers[normalized] = handler
	var owner := handler.get_object()
	if owner != null:
		_handler_owners[normalized] = owner
	return true


func replace_tool(tool_name: StringName, handler: Callable) -> bool:
	var normalized := String(tool_name).strip_edges()
	if normalized.is_empty() or not handler.is_valid() or not _handlers.has(normalized):
		return false
	_handlers[normalized] = handler
	var owner := handler.get_object()
	if owner != null:
		_handler_owners[normalized] = owner
	else:
		_handler_owners.erase(normalized)
	return true


func dispatch(
	tool_name: String,
	arguments: Dictionary,
	context: Dictionary = {}
) -> Dictionary:
	if not _handlers.has(tool_name):
		return _error("unknown_tool", "Tool is not registered: %s" % tool_name)
	var handler := _handlers[tool_name] as Callable
	var result: Variant
	if handler.get_argument_count() >= 2:
		result = handler.call(arguments.duplicate(true), context.duplicate(true))
	else:
		result = handler.call(arguments.duplicate(true))
	if typeof(result) == TYPE_DICTIONARY and bool((result as Dictionary).get("__deferred__", false)):
		return (result as Dictionary).duplicate(true)
	if typeof(result) != TYPE_DICTIONARY:
		return _error("invalid_tool_result", "Tool returned a non-dictionary result.")
	return _normalize_result(result as Dictionary)


func normalize_result(result: Dictionary) -> Dictionary:
	return _normalize_result(result)


func registered_tools() -> PackedStringArray:
	var names := PackedStringArray()
	for tool_name in _handlers.keys():
		names.append(String(tool_name))
	return names


func _normalize_result(result: Dictionary) -> Dictionary:
	if typeof(result.get("ok")) != TYPE_BOOL:
		return _error("invalid_tool_result", "Tool result is missing boolean ok.")
	if typeof(result.get("data", {})) != TYPE_DICTIONARY:
		return _error("invalid_tool_result", "Tool result data must be a dictionary.")
	var error_value: Variant = result.get("error")
	if error_value != null and typeof(error_value) != TYPE_DICTIONARY:
		return _error("invalid_tool_result", "Tool result error must be null or a dictionary.")
	return {
		"ok": bool(result["ok"]),
		"data": (result.get("data", {}) as Dictionary).duplicate(true),
		"error": error_value,
	}


static func _error(code: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"data": {},
		"error": {"code": code, "message": message},
	}
