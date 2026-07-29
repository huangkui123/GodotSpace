extends Node

signal command_routed(request_id: String, intent: String, speaker_peer_id: int)
signal assistant_interaction_state_changed(speaker_peer_id: int, state: String, text: String)

const ROUTE_QWEN_FIRST := "QWEN_FIRST"
const SERVER_PEER_ID := 1
const SNAPSHOT_TIMEOUT_SECONDS := 3.0
const MAX_DEBUG_EVENTS := 64
const REQUIRED_WAKE_WORD := "助手"
const WAKE_COMMAND_TIMEOUT_SECONDS := 8.0
const OpenAlbumAdapterScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/open_album_tool_adapter.gd")

var _requests: Dictionary = {}
var _operation_to_request: Dictionary = {}
var _deepseek_tool_calls: Dictionary = {}
var _recent_events: Array[Dictionary] = []
var _wake_sessions: Dictionary = {}


func _ready() -> void:
	var voice_chat := get_node_or_null("/root/VoiceChat")
	if voice_chat != null and voice_chat.has_signal("voice_transcript_received"):
		voice_chat.voice_transcript_received.connect(_on_voice_transcript_received)
	var assistant := get_node_or_null("/root/LLMAssistantService")
	if assistant != null:
		if assistant.has_method("set_external_transcript_router_enabled"):
			assistant.call("set_external_transcript_router_enabled", true)
		if assistant.has_signal("delegated_answer_completed"):
			assistant.delegated_answer_completed.connect(_on_deepseek_answer)
		if assistant.has_signal("delegated_answer_failed"):
			assistant.delegated_answer_failed.connect(_on_deepseek_error)
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent != null:
		agent.replace_tool("open_album", Callable(self, "_tool_open_album"))
		agent.register_tool("close_album", Callable(self, "_tool_close_album"))
		agent.register_tool("next_album_page", Callable(self, "_tool_next_album_page"))
		agent.register_tool("go_to_album_page", Callable(self, "_tool_go_to_album_page"))
		agent.register_tool("previous_album_page", Callable(self, "_tool_previous_album_page"))
		agent.register_tool("get_album_state", Callable(self, "_tool_get_album_state"))
		agent.register_tool("open_task_guide", Callable(self, "_tool_open_task_guide"))
		agent.register_tool("close_task_guide", Callable(self, "_tool_close_task_guide"))
		agent.register_tool("get_current_task_step", Callable(self, "_tool_get_current_task_step"))
		agent.register_tool("next_task_step", Callable(self, "_tool_next_task_step"))
		agent.register_tool("go_to_task_guide_page", Callable(self, "_tool_go_to_task_guide_page"))
		agent.register_tool("previous_task_step", Callable(self, "_tool_previous_task_step"))
		agent.register_tool("replay_current_task_step", Callable(self, "_tool_replay_current_task_step"))
		agent.register_tool("delegate_deepseek", Callable(self, "_tool_delegate_deepseek"))
		agent.assistant_routing_decision_received.connect(_on_agent_routing_decision)
		agent.assistant_final_received.connect(_on_agent_answer)
		agent.run_error_received.connect(_on_agent_error)


func classify_text(_text: String) -> String:
	# Kept only for compatibility with older self-tests. Routing is now Qwen-first.
	return ROUTE_QWEN_FIRST


func route_transcript_for_test(data: Dictionary) -> String:
	return _route_final_transcript(data)


func get_request_debug_state(request_id: String) -> Dictionary:
	return (_requests.get(request_id, {}) as Dictionary).duplicate(true)


func get_debug_state() -> Dictionary:
	return {
		"active_request_count": _requests.size(),
		"wake_session_count": _wake_sessions.size(),
		"pending_remote_operation_count": _operation_to_request.size(),
		"pending_deepseek_count": _deepseek_tool_calls.size(),
		"recent_events": _recent_events.duplicate(true),
	}


func _on_voice_transcript_received(data: Dictionary) -> void:
	if str(data.get("source", "")) == "llm_assistant":
		return
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	_handle_wake_transcript(data)


func _route_final_transcript(data: Dictionary) -> String:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return ""
	var text := _strip_required_wake_word(str(data.get("text", "")))
	if text.is_empty():
		return ""
	var speaker_peer_id := int(data.get("speaker_peer_id", SERVER_PEER_ID))
	if speaker_peer_id <= 0:
		speaker_peer_id = SERVER_PEER_ID
	return _route_command(text, speaker_peer_id)


func _route_command(text: String, speaker_peer_id: int) -> String:
	var clean_text := text.strip_edges()
	if clean_text.is_empty():
		return ""
	var request_id := _new_id("request")
	_requests[request_id] = {
		"speaker_peer_id": speaker_peer_id,
		"intent": ROUTE_QWEN_FIRST,
		"text": clean_text,
		"status": "preparing",
		"snapshot": {},
		"allowed_tools": [],
		"created_msec": Time.get_ticks_msec(),
	}
	_record_event("routed", request_id, {"target": "local" if _is_local_target(speaker_peer_id) else "remote"})
	command_routed.emit(request_id, ROUTE_QWEN_FIRST, speaker_peer_id)
	_publish_interaction_state(speaker_peer_id, "processing", "正在理解你的请求…")
	_request_target_snapshot(request_id, speaker_peer_id)
	return request_id


func _strip_required_wake_word(raw_text: String) -> String:
	var wake_index := raw_text.find(REQUIRED_WAKE_WORD)
	if wake_index < 0:
		return ""
	var text := raw_text.substr(wake_index + REQUIRED_WAKE_WORD.length()).strip_edges()
	while text.begins_with(",") or text.begins_with("，") or text.begins_with(":") or text.begins_with("："):
		text = text.substr(1).strip_edges()
	return text


func _handle_wake_transcript(data: Dictionary) -> void:
	var text := str(data.get("text", "")).strip_edges()
	if text.is_empty():
		return
	var speaker_peer_id := int(data.get("speaker_peer_id", SERVER_PEER_ID))
	if speaker_peer_id <= 0:
		speaker_peer_id = SERVER_PEER_ID
	var utterance_id := int(data.get("utterance_id", 0))
	var is_final := bool(data.get("is_final", false))
	var session := _wake_sessions.get(speaker_peer_id, {}) as Dictionary
	if session.is_empty():
		if text.find(REQUIRED_WAKE_WORD) < 0:
			return
		session = {
			"id": _new_id("wake"),
			"utterance_id": utterance_id,
			"command": _strip_required_wake_word(text),
		}
		_wake_sessions[speaker_peer_id] = session
		_publish_interaction_state(speaker_peer_id, "listening", "我在，请说。")
		_expire_wake_session(speaker_peer_id, str(session.get("id", "")))
	else:
		var command := ""
		if utterance_id == int(session.get("utterance_id", -1)):
			command = _strip_required_wake_word(text)
		else:
			command = text
		if not command.is_empty():
			session["command"] = command
			_wake_sessions[speaker_peer_id] = session

	var command_text := str(session.get("command", "")).strip_edges()
	if not command_text.is_empty():
		_publish_interaction_state(speaker_peer_id, "listening", "正在听：%s" % command_text)
	if not is_final:
		return
	if command_text.is_empty():
		return
	if _is_local_wake_cancel(command_text):
		_wake_sessions.erase(speaker_peer_id)
		_publish_interaction_state(speaker_peer_id, "idle")
		return
	_wake_sessions.erase(speaker_peer_id)
	_route_command(command_text, speaker_peer_id)


func _expire_wake_session(speaker_peer_id: int, session_id: String) -> void:
	await get_tree().create_timer(WAKE_COMMAND_TIMEOUT_SECONDS).timeout
	var session := _wake_sessions.get(speaker_peer_id, {}) as Dictionary
	if session.is_empty() or str(session.get("id", "")) != session_id:
		return
	_wake_sessions.erase(speaker_peer_id)
	_publish_interaction_state(speaker_peer_id, "timeout", "等待命令超时，请再次呼叫助手。")


func _is_local_wake_cancel(text: String) -> bool:
	var normalized := text.strip_edges().replace("，", "").replace(",", "").replace("。", "")
	return normalized in ["取消", "算了", "不用了", "不需要了"]


func _request_target_snapshot(request_id: String, speaker_peer_id: int) -> void:
	if _is_local_target(speaker_peer_id):
		_receive_snapshot(request_id, _execute_get_snapshot())
	elif _is_peer_connected(speaker_peer_id):
		rpc_id(speaker_peer_id, "_client_request_task_snapshot", request_id)
		_expire_snapshot_request(request_id)
	else:
		_fail_request(request_id, "target_offline", "The speaking client is offline.")


@rpc("authority", "call_remote", "reliable")
func _client_request_task_snapshot(request_id: String) -> void:
	rpc_id(SERVER_PEER_ID, "_server_receive_task_snapshot", request_id, _execute_get_snapshot())


@rpc("any_peer", "call_remote", "reliable")
func _server_receive_task_snapshot(request_id: String, result: Dictionary) -> void:
	if not multiplayer.is_server() or not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	if multiplayer.get_remote_sender_id() != int(record.get("speaker_peer_id", 0)):
		return
	_receive_snapshot(request_id, result)


func _receive_snapshot(request_id: String, result: Dictionary) -> void:
	if not _requests.has(request_id):
		return
	if not bool(result.get("ok", false)):
		_fail_request(request_id, "snapshot_failed", "Unable to read the current UI state.")
		return
	var record := _requests[request_id] as Dictionary
	var snapshot := (result.get("data", {}) as Dictionary).duplicate(true)
	record["snapshot"] = snapshot
	record["allowed_tools"] = _allowed_tools_for_snapshot(snapshot)
	_requests[request_id] = record
	_record_event("snapshot_received", request_id, {"tool_count": (record["allowed_tools"] as Array).size()})
	_submit_agent_request(request_id)


func _allowed_tools_for_snapshot(snapshot: Dictionary) -> PackedStringArray:
	var tools := PackedStringArray()
	var album := snapshot.get("album", {}) as Dictionary
	var guide := snapshot.get("task_guide", {}) as Dictionary
	var album_visible := bool(album.get("visible", false))
	var guide_visible := bool(guide.get("visible", false))
	# Put operations for the uniquely visible panel first. This is still only an
	# authorization list; Qwen makes the semantic routing decision.
	if guide_visible and not album_visible:
		_append_task_guide_tools(tools, guide)
	elif album_visible and not guide_visible:
		_append_album_tools(tools, album)
	else:
		if album_visible:
			_append_album_tools(tools, album)
		if guide_visible:
			_append_task_guide_tools(tools, guide)
	tools.append("open_album")
	tools.append("open_task_guide")
	tools.append("delegate_deepseek")
	tools.sort()
	return tools


func _append_album_tools(tools: PackedStringArray, album: Dictionary) -> void:
	if bool(album.get("visible", false)):
		tools.append("close_album")
		tools.append("get_album_state")
		if bool(album.get("can_next", false)):
			tools.append("next_album_page")
		tools.append("go_to_album_page")
		if bool(album.get("can_previous", false)):
			tools.append("previous_album_page")


func _append_task_guide_tools(tools: PackedStringArray, guide: Dictionary) -> void:
	if bool(guide.get("visible", false)):
		tools.append("close_task_guide")
		tools.append("replay_current_task_step")
		if bool(guide.get("can_next", false)):
			tools.append("next_task_step")
		tools.append("go_to_task_guide_page")
		if bool(guide.get("can_previous", false)):
			tools.append("previous_task_step")


func _expire_snapshot_request(request_id: String, timeout_seconds: float = SNAPSHOT_TIMEOUT_SECONDS) -> void:
	await get_tree().create_timer(timeout_seconds).timeout
	if _requests.has(request_id) and str((_requests[request_id] as Dictionary).get("status", "")) == "preparing":
		_fail_request(request_id, "tool_timeout", "Timed out waiting for the target client UI state.")


func _submit_agent_request(request_id: String) -> void:
	if not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent == null or not agent.submit_user_message(
		request_id,
		str(record.get("text", "")),
		(record.get("snapshot", {}) as Dictionary).duplicate(true),
		record.get("allowed_tools", PackedStringArray())
	):
		_fail_request(request_id, "target_offline", "The Local Agent Gateway is not connected.")
		return
	record["status"] = "agent_running"
	_requests[request_id] = record


func _tool_open_album(arguments: Dictionary, context: Dictionary) -> Dictionary:
	var validation := _authorize(context, "open_album")
	if not bool(validation.get("ok", false)):
		return validation
	return _execute_or_defer_target_tool(_request_id(context), context, "album_open", arguments)


func _tool_close_album(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_empty_tool(arguments, context, "close_album", "album_close")

func _tool_next_album_page(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_empty_tool(arguments, context, "next_album_page", "album_next")

func _tool_go_to_album_page(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_page_tool(arguments, context, "go_to_album_page", "album_goto")

func _tool_previous_album_page(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_empty_tool(arguments, context, "previous_album_page", "album_previous")

func _tool_get_album_state(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_empty_tool(arguments, context, "get_album_state", "album_state")

func _tool_open_task_guide(arguments: Dictionary, context: Dictionary) -> Dictionary:
	var validation := _authorize(context, "open_task_guide")
	if not bool(validation.get("ok", false)):
		return validation
	if int(arguments.get("task_id", 0)) != 1 or arguments.size() != 1:
		return _error("invalid_arguments", "Only task_id 1 is enabled.")
	return _execute_or_defer_target_tool(_request_id(context), context, "guide_open", {"task_id": 1})

func _tool_close_task_guide(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_empty_tool(arguments, context, "close_task_guide", "guide_close")

func _tool_get_current_task_step(arguments: Dictionary, context: Dictionary) -> Dictionary:
	var validation := _authorize(context, "get_current_task_step")
	if not bool(validation.get("ok", false)):
		return validation
	if not arguments.is_empty():
		return _error("invalid_arguments", "get_current_task_step does not accept arguments.")
	return _success(((_requests[_request_id(context)] as Dictionary).get("snapshot", {}) as Dictionary).get("task_guide", {}))

func _tool_next_task_step(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _move_task_step(arguments, context, "next_task_step", "guide_advance")

func _tool_go_to_task_guide_page(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_page_tool(arguments, context, "go_to_task_guide_page", "guide_goto")

func _tool_previous_task_step(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _move_task_step(arguments, context, "previous_task_step", "guide_previous")

func _tool_replay_current_task_step(arguments: Dictionary, context: Dictionary) -> Dictionary:
	return _execute_authorized_empty_tool(arguments, context, "replay_current_task_step", "guide_replay")

func _tool_delegate_deepseek(arguments: Dictionary, context: Dictionary) -> Dictionary:
	var validation := _authorize(context, "delegate_deepseek")
	if not bool(validation.get("ok", false)):
		return validation
	if not arguments.is_empty():
		return _error("invalid_arguments", "delegate_deepseek does not accept arguments.")
	var tool_call_id := str(context.get("tool_call_id", ""))
	if tool_call_id.is_empty():
		return _error("invalid_tool_call", "tool_call_id is required.")
	var request_id := _request_id(context)
	var assistant := get_node_or_null("/root/LLMAssistantService")
	if assistant == null or not assistant.has_method("request_delegated_answer"):
		return _error("not_ready", "DeepSeek assistant is not ready.")
	_deepseek_tool_calls[request_id] = tool_call_id
	_mark_dispatched(request_id, "delegate_deepseek")
	# The Router owns the final history entry for every Qwen request. Suppress the
	# legacy assistant's delegated entry so a DeepSeek hand-off is not recorded twice.
	assistant.call("request_delegated_answer", request_id, str((_requests[request_id] as Dictionary).get("text", "")), _deepseek_context_entries(request_id), false)
	return {"__deferred__": true}


func _execute_authorized_empty_tool(arguments: Dictionary, context: Dictionary, tool_name: String, operation: String) -> Dictionary:
	var validation := _authorize(context, tool_name)
	if not bool(validation.get("ok", false)):
		return validation
	if not arguments.is_empty():
		return _error("invalid_arguments", "%s does not accept arguments." % tool_name)
	return _execute_or_defer_target_tool(_request_id(context), context, operation, {})


func _execute_authorized_page_tool(arguments: Dictionary, context: Dictionary, tool_name: String, operation: String) -> Dictionary:
	var validation := _authorize(context, tool_name)
	if not bool(validation.get("ok", false)):
		return validation
	if arguments.size() != 1 or not arguments.has("page") or typeof(arguments.get("page")) != TYPE_INT or int(arguments.get("page")) < 1:
		return _error("invalid_arguments", "%s requires a positive integer page." % tool_name)
	return _execute_or_defer_target_tool(_request_id(context), context, operation, {"page": int(arguments.get("page"))})


func _move_task_step(arguments: Dictionary, context: Dictionary, tool_name: String, operation: String) -> Dictionary:
	var validation := _authorize(context, tool_name)
	if not bool(validation.get("ok", false)):
		return validation
	if not arguments.is_empty():
		return _error("invalid_arguments", "%s does not accept arguments." % tool_name)
	var snapshot := ((_requests[_request_id(context)] as Dictionary).get("snapshot", {}) as Dictionary).get("task_guide", {}) as Dictionary
	return _execute_or_defer_target_tool(_request_id(context), context, operation, {
		"operation_id": _new_id("operation"),
		"expected_task_id": int(snapshot.get("task_id", 0)),
		"expected_page_index": int(snapshot.get("page_index", 0)),
	})


func _authorize(context: Dictionary, tool_name: String) -> Dictionary:
	var request_id := _request_id(context)
	if request_id.is_empty() or not _requests.has(request_id):
		return _error("permission_denied", "The request is no longer active.")
	var record := _requests[request_id] as Dictionary
	if not (record.get("allowed_tools", PackedStringArray()) as PackedStringArray).has(tool_name):
		return _error("permission_denied", "This tool is not authorized for the current UI state.")
	if str(record.get("status", "")) in ["tool_dispatched", "cancelled", "completed"]:
		return _error("permission_denied", "The request is no longer mutable.")
	return _success({})


func _request_id(context: Dictionary) -> String:
	return str(context.get("request_id", ""))


func _execute_or_defer_target_tool(request_id: String, context: Dictionary, operation: String, arguments: Dictionary) -> Dictionary:
	if not _requests.has(request_id):
		return _error("permission_denied", "The request is no longer active.")
	var record := _requests[request_id] as Dictionary
	var speaker_peer_id := int(record.get("speaker_peer_id", 0))
	_mark_dispatched(request_id, operation)
	if _is_local_target(speaker_peer_id):
		var local_result := _execute_target_tool(operation, arguments)
		_record_verified_ui_result(request_id, operation, local_result)
		return local_result
	if not _is_peer_connected(speaker_peer_id):
		return _error("target_offline", "The speaking client is offline.")
	var tool_call_id := str(context.get("tool_call_id", ""))
	if tool_call_id.is_empty():
		return _error("invalid_tool_call", "tool_call_id is required for remote execution.")
	_operation_to_request[tool_call_id] = request_id
	rpc_id(speaker_peer_id, "_client_execute_task_tool", request_id, tool_call_id, operation, arguments)
	return {"__deferred__": true}


func _mark_dispatched(request_id: String, operation: String) -> void:
	if not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	record["status"] = "tool_dispatched"
	record["last_operation"] = operation
	_requests[request_id] = record
	_record_event("tool_dispatched", request_id, {"operation": operation})
	_publish_interaction_state(int(record.get("speaker_peer_id", SERVER_PEER_ID)), "executing", "正在执行：%s" % _operation_label(operation))


func _operation_label(operation: String) -> String:
	var labels := {
		"album_open": "打开相册",
		"album_close": "关闭相册",
		"album_next": "翻到相册下一页",
		"album_previous": "返回相册上一页",
		"album_goto": "跳转相册页面",
		"guide_open": "打开指导书",
		"guide_close": "关闭指导书",
		"guide_advance": "切换到下一步",
		"guide_previous": "返回上一步",
		"guide_goto": "跳转指导书步骤",
		"guide_replay": "读取当前步骤",
		"delegate_deepseek": "查询实验知识",
	}
	return str(labels.get(operation, "执行操作"))


@rpc("authority", "call_remote", "reliable")
func _client_execute_task_tool(request_id: String, tool_call_id: String, operation: String, arguments: Dictionary) -> void:
	rpc_id(SERVER_PEER_ID, "_server_receive_task_tool_result", request_id, tool_call_id, _execute_target_tool(operation, arguments))


@rpc("any_peer", "call_remote", "reliable")
func _server_receive_task_tool_result(request_id: String, tool_call_id: String, result: Dictionary) -> void:
	if not multiplayer.is_server() or not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	if multiplayer.get_remote_sender_id() != int(record.get("speaker_peer_id", 0)) or str(_operation_to_request.get(tool_call_id, "")) != request_id:
		return
	_operation_to_request.erase(tool_call_id)
	_record_verified_ui_result(request_id, str(record.get("last_operation", "")), result)
	_complete_deferred_tool_call(tool_call_id, result)


func _execute_target_tool(operation: String, arguments: Dictionary) -> Dictionary:
	if operation == "album_open":
		return OpenAlbumAdapterScript.new().execute(arguments)
	if operation == "album_close":
		return OpenAlbumAdapterScript.new().execute_action("close")
	if operation == "album_next":
		return OpenAlbumAdapterScript.new().execute_action("next")
	if operation == "album_goto":
		return OpenAlbumAdapterScript.new().execute_action("goto", arguments)
	if operation == "album_previous":
		return OpenAlbumAdapterScript.new().execute_action("previous")
	if operation == "album_state":
		return OpenAlbumAdapterScript.new().execute_action("state")
	if operation == "guide_open":
		var search_root := get_tree().current_scene if get_tree().current_scene != null else get_tree().root
		var list_view := _find_node_with_method(search_root, "open_task_by_id")
		return list_view.call("open_task_by_id", int(arguments.get("task_id", 0))) if list_view != null else _error("not_ready", "The task list view is not ready.")
	var detail := _resolve_task_detail()
	if detail == null:
		return _error("not_ready", "The task detail view is not ready.")
	if operation == "guide_close":
		return detail.call("close_task_guide")
	if operation == "guide_replay":
		return detail.call("replay_current_task_step_with_result")
	if operation == "guide_advance":
		return detail.call("advance_if_index", str(arguments.get("operation_id", "")), int(arguments.get("expected_task_id", 0)), int(arguments.get("expected_page_index", 0)))
	if operation == "guide_goto":
		return detail.call("go_to_page", int(arguments.get("page", 0)))
	if operation == "guide_previous":
		return detail.call("retreat_if_index", str(arguments.get("operation_id", "")), int(arguments.get("expected_task_id", 0)), int(arguments.get("expected_page_index", 0)))
	return _error("permission_denied", "Unsupported UI operation.")


func _execute_get_snapshot() -> Dictionary:
	var album_result := OpenAlbumAdapterScript.new().execute_action("state")
	var album: Dictionary = {"visible": false}
	if bool(album_result.get("ok", false)):
		album = album_result.get("data", {}) as Dictionary
	var guide: Dictionary = {"visible": false}
	var detail := _resolve_task_detail()
	if detail != null:
		var guide_result: Dictionary = detail.call("get_task_snapshot", true)
		if bool(guide_result.get("ok", false)):
			guide = guide_result.get("data", {}) as Dictionary
			guide["visible"] = true
	guide["can_next"] = bool(guide.get("visible", false)) and int(guide.get("page_index", 0)) < int(guide.get("page_count", 0))
	guide["can_previous"] = bool(guide.get("visible", false)) and int(guide.get("page_index", 0)) > 1
	return _success({"album": album, "task_guide": guide})


func _deepseek_context_entries(request_id: String) -> Array[Dictionary]:
	if not _requests.has(request_id):
		return []
	var snapshot := ((_requests[request_id] as Dictionary).get("snapshot", {}) as Dictionary).get("task_guide", {}) as Dictionary
	if not bool(snapshot.get("visible", false)):
		return []
	var current := snapshot.get("current_step", {}) as Dictionary
	return [{
		"id": "voice-current-task-step",
		"title": str(snapshot.get("task_title", "当前任务")),
		"source": "当前专家任务步骤 / 目标客户端",
		"tags": ["当前任务", "当前步骤", str(current.get("title", ""))],
		"content": "任务：%s\n当前页：%d/%d\n当前步骤：%s\n要求：%s" % [str(snapshot.get("task_title", "当前任务")), int(snapshot.get("page_index", 0)), int(snapshot.get("page_count", 0)), str(current.get("title", "")), str(current.get("info", ""))],
	}]


func _on_deepseek_answer(request_id: String, answer: String) -> void:
	var tool_call_id := str(_deepseek_tool_calls.get(request_id, ""))
	if tool_call_id.is_empty():
		return
	_deepseek_tool_calls.erase(request_id)
	_complete_deferred_tool_call(tool_call_id, _success({"answer": answer}))


func _on_deepseek_error(request_id: String, message: String) -> void:
	var tool_call_id := str(_deepseek_tool_calls.get(request_id, ""))
	if tool_call_id.is_empty():
		return
	_deepseek_tool_calls.erase(request_id)
	_complete_deferred_tool_call(tool_call_id, _error("deepseek_error", message))


func _complete_deferred_tool_call(tool_call_id: String, result: Dictionary) -> void:
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent != null:
		agent.complete_deferred_tool_call(tool_call_id, result)


func _resolve_task_detail() -> Node:
	var global_node := get_node_or_null("/root/Global")
	var detail: Variant = global_node.get("work_list_info_canvas") if global_node != null else null
	return detail as Node if detail is Node and is_instance_valid(detail) else null


func _find_node_with_method(node: Node, method_name: StringName) -> Node:
	if node == null:
		return null
	if node.has_method(method_name):
		return node
	for child in node.get_children():
		var found := _find_node_with_method(child, method_name)
		if found != null:
			return found
	return null


func _on_agent_answer(request_id: String, answer: String) -> void:
	if not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	var final_answer := _verified_answer_or_model_answer(record, answer)
	record["status"] = "completed"
	_requests[request_id] = record
	_record_event("completed", request_id, {"elapsed_msec": Time.get_ticks_msec() - int(record.get("created_msec", Time.get_ticks_msec()))})
	_record_request_history(request_id, record, final_answer, _is_successful_final_result(record))
	_publish_interaction_state(int(record.get("speaker_peer_id", SERVER_PEER_ID)), "idle")
	_publish_answer(final_answer)
	_clear_operations_for_request(request_id)
	_requests.erase(request_id)


func _on_agent_routing_decision(request_id: String, route: String, tool_name: String) -> void:
	if not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	record["qwen_route"] = route
	record["qwen_tool_name"] = tool_name
	_requests[request_id] = record
	_record_event("agent_decision", request_id, {
		"route": route,
		"tool_name": tool_name,
	})


func _on_agent_error(request_id: String, code: String, message: String) -> void:
	if code == "too_late" and _requests.has(request_id):
		return
	_fail_request(request_id, code, message)


func _fail_request(request_id: String, code: String, message: String) -> void:
	var record := _requests.get(request_id, {}) as Dictionary
	_record_event("failed", request_id, {"code": code, "elapsed_msec": Time.get_ticks_msec() - int(record.get("created_msec", Time.get_ticks_msec()))})
	var final_answer := "操作未完成：%s（%s）" % [message, code]
	if not record.is_empty():
		_record_request_history(request_id, record, final_answer, false, code)
		_publish_interaction_state(int(record.get("speaker_peer_id", SERVER_PEER_ID)), "failed", final_answer)
	_publish_answer(final_answer)
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent != null and agent.has_method("abandon_deferred_tool_calls_for_request"):
		agent.call("abandon_deferred_tool_calls_for_request", request_id)
	_clear_operations_for_request(request_id)
	_deepseek_tool_calls.erase(request_id)
	_requests.erase(request_id)


func _clear_operations_for_request(request_id: String) -> void:
	for tool_call_id in _operation_to_request.keys():
		if str(_operation_to_request[tool_call_id]) == request_id:
			_operation_to_request.erase(tool_call_id)


func _publish_answer(answer: String) -> void:
	var voice_chat := get_node_or_null("/root/VoiceChat")
	if voice_chat != null and voice_chat.has_method("publish_assistant_transcript"):
		voice_chat.call("publish_assistant_transcript", answer)


func _publish_interaction_state(speaker_peer_id: int, state: String, text: String = "") -> void:
	assistant_interaction_state_changed.emit(speaker_peer_id, state, text)
	var voice_chat := get_node_or_null("/root/VoiceChat")
	if voice_chat != null and voice_chat.has_method("publish_assistant_interaction_state"):
		voice_chat.call("publish_assistant_interaction_state", speaker_peer_id, state, text)


func _record_request_history(
	request_id: String,
	record: Dictionary,
	answer: String,
	success: bool,
	error_code: String = ""
) -> void:
	var assistant := get_node_or_null("/root/LLMAssistantService")
	if assistant == null or not assistant.has_method("record_external_qa"):
		return
	var operation := str(record.get("last_operation", ""))
	var route := str(record.get("qwen_route", "direct_answer"))
	var tool_name := str(record.get("qwen_tool_name", operation))
	assistant.call("record_external_qa", request_id, str(record.get("text", "")), answer, success, {
		"provider": "local_qwen_agent",
		"route": route,
		"tool_name": tool_name,
		"speaker_peer_id": int(record.get("speaker_peer_id", SERVER_PEER_ID)),
		"error_code": error_code,
	})


func _is_successful_final_result(record: Dictionary) -> bool:
	var verified := record.get("verified_ui_result", {}) as Dictionary
	if verified.is_empty():
		return true
	var result := verified.get("result", {}) as Dictionary
	return bool(result.get("ok", false))


func _record_verified_ui_result(request_id: String, operation: String, result: Dictionary) -> void:
	if not _requests.has(request_id) or operation in ["album_state", "guide_replay", "delegate_deepseek"]:
		return
	var record := _requests[request_id] as Dictionary
	record["verified_ui_result"] = {
		"operation": operation,
		"result": result.duplicate(true),
	}
	_requests[request_id] = record


func _verified_answer_or_model_answer(record: Dictionary, model_answer: String) -> String:
	var verified := record.get("verified_ui_result", {}) as Dictionary
	if verified.is_empty():
		return model_answer
	var operation := str(verified.get("operation", ""))
	var result := verified.get("result", {}) as Dictionary
	if not bool(result.get("ok", false)):
		var error := result.get("error", {}) as Dictionary
		return "操作未完成：%s（%s）" % [str(error.get("message", "工具执行失败。")), str(error.get("code", "tool_failed"))]
	var data := result.get("data", {}) as Dictionary
	var snapshot := data.get("snapshot", {}) as Dictionary
	if operation == "guide_advance":
		var current_step := snapshot.get("current_step", {}) as Dictionary
		var title := str(current_step.get("title", "")).strip_edges()
		var info := str(current_step.get("info", "")).strip_edges()
		var message := "已切换到指导书第 %d 步。" % int(snapshot.get("page_index", 0))
		if not title.is_empty():
			message += "接下来：%s。" % title
		if not info.is_empty():
			message += info
		return message
	if operation == "guide_previous":
		return "已返回指导书第 %d 步。" % int(snapshot.get("page_index", 0))
	if operation == "guide_open":
		return "已打开指导书第 %d 步。" % int(snapshot.get("page_index", 1))
	if operation == "guide_close":
		return "已关闭指导书。"
	if operation == "album_open":
		return "已打开相册第 %d 页。" % int(data.get("page", 1))
	if operation == "album_next":
		return "已切换到相册第 %d 页。" % int(data.get("page", 0))
	if operation == "album_goto":
		return "已切换到相册第 %d 页。" % int(data.get("page", 0))
	if operation == "album_previous":
		return "已返回相册第 %d 页。" % int(data.get("page", 0))
	if operation == "album_close":
		return "已关闭相册。"
	if operation == "guide_goto":
		return "已切换到指导书第 %d 步。" % int(snapshot.get("page_index", 0))
	return model_answer


func _is_local_target(peer_id: int) -> bool:
	return not multiplayer.has_multiplayer_peer() or peer_id == multiplayer.get_unique_id()


func _is_peer_connected(peer_id: int) -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id)


func _new_id(prefix: String) -> String:
	return "%s-%d-%d" % [prefix, Time.get_ticks_usec(), randi()]


func _record_event(event_name: String, request_id: String, details: Dictionary) -> void:
	var event := {"event": event_name, "request_id": request_id, "timestamp_msec": Time.get_ticks_msec()}
	for key in details.keys():
		event[key] = details[key]
	_recent_events.append(event)
	while _recent_events.size() > MAX_DEBUG_EVENTS:
		_recent_events.pop_front()


func _success(data: Dictionary) -> Dictionary:
	return {"ok": true, "data": data, "error": null}


func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": {"code": code, "message": message}}
