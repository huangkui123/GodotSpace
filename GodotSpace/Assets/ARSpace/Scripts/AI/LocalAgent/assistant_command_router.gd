extends Node

signal command_routed(request_id: String, intent: String, speaker_peer_id: int)

const INTENT_OPEN_ALBUM := "OPEN_ALBUM"
const INTENT_OPEN_GUIDE := "OPEN_GUIDE"
const INTENT_READ_STEP := "READ_ONLY"
const INTENT_ADVANCE_STEP := "ADVANCE_STEP"
const INTENT_EXPLAIN_STEP := "EXPLAIN_STEP"
const INTENT_GENERAL := "GENERAL"
const SERVER_PEER_ID := 1
const SNAPSHOT_TIMEOUT_SECONDS := 3.0
const OpenAlbumAdapterScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/open_album_tool_adapter.gd")

var _requests: Dictionary = {}
var _operation_to_request: Dictionary = {}


func _ready() -> void:
	var voice_chat := get_node_or_null("/root/VoiceChat")
	if voice_chat != null and voice_chat.has_signal("voice_transcript_received"):
		voice_chat.voice_transcript_received.connect(_on_voice_transcript_received)
	var assistant := get_node_or_null("/root/LLMAssistantService")
	if assistant != null and assistant.has_method("set_external_transcript_router_enabled"):
		assistant.call("set_external_transcript_router_enabled", true)
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent != null:
		agent.replace_tool("open_album", Callable(self, "_tool_open_album"))
		agent.register_tool("open_task_guide", Callable(self, "_tool_open_task_guide"))
		agent.register_tool("get_current_task_step", Callable(self, "_tool_get_current_task_step"))
		agent.register_tool("next_task_step", Callable(self, "_tool_next_task_step"))
		agent.assistant_final_received.connect(_on_agent_answer)
		agent.run_error_received.connect(_on_agent_error)


func classify_text(text: String) -> String:
	var clean := text.strip_edges()
	if clean.is_empty():
		return INTENT_GENERAL
	if _contains_any(clean, ["不要", "不用", "别", "无需"]):
		return INTENT_GENERAL
	if clean.find("相册") >= 0 and _contains_any(clean, ["打开", "调出", "显示", "看看"]):
		return INTENT_OPEN_ALBUM
	if _contains_any(clean, ["这一步怎么", "当前步骤怎么", "当前步骤需要做什么", "这步怎么", "如何完成这一步"]):
		return INTENT_EXPLAIN_STEP
	if clean.find("下一步") >= 0:
		if clean.ends_with("吗") or clean.ends_with("？") or clean.ends_with("?"):
			return INTENT_READ_STEP
		if _contains_any(clean, ["如果", "假如", "是否", "能不能", "可以吗", "会不会", "他说", "这句话"]):
			return INTENT_READ_STEP
		if _contains_any(clean, ["是什么", "做什么", "应该", "该怎么", "怎么做", "告诉我"]):
			return INTENT_READ_STEP
		if _contains_any(clean, ["进入", "切换", "前往", "继续", "开始"]):
			return INTENT_ADVANCE_STEP
	if _contains_any(clean, ["这一步做完了", "本步完成", "当前步骤完成"]):
		if _contains_any(clean, ["继续", "下一步", "往下"]):
			return INTENT_ADVANCE_STEP
	if _contains_any(clean, ["指导书", "任务流程", "操作指南"]):
		if _contains_any(clean, ["打开", "调出", "显示", "查看"]):
			return INTENT_OPEN_GUIDE
	if _contains_any(clean, ["当前步骤", "现在这一步", "我在哪一步"]):
		return INTENT_READ_STEP
	return INTENT_GENERAL


func route_transcript_for_test(data: Dictionary) -> String:
	return _route_final_transcript(data)


func get_request_debug_state(request_id: String) -> Dictionary:
	return (_requests.get(request_id, {}) as Dictionary).duplicate(true)


func _on_voice_transcript_received(data: Dictionary) -> void:
	if not bool(data.get("is_final", false)) or str(data.get("source", "")) == "llm_assistant":
		return
	_route_final_transcript(data)


func _route_final_transcript(data: Dictionary) -> String:
	var text := str(data.get("text", "")).strip_edges()
	if text.is_empty():
		return ""
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return ""
	var speaker_peer_id := int(data.get("speaker_peer_id", SERVER_PEER_ID))
	if speaker_peer_id <= 0:
		speaker_peer_id = SERVER_PEER_ID
	var intent := classify_text(text)
	if intent == INTENT_GENERAL:
		var assistant := get_node_or_null("/root/LLMAssistantService")
		if assistant != null and assistant.has_method("submit_transcript_data"):
			assistant.call("submit_transcript_data", data)
		return ""

	var request_id := _new_id("request")
	_requests[request_id] = {
		"speaker_peer_id": speaker_peer_id,
		"intent": intent,
		"text": text,
		"status": "preparing",
		"snapshot": {},
	}
	command_routed.emit(request_id, intent, speaker_peer_id)
	if intent in [INTENT_READ_STEP, INTENT_ADVANCE_STEP, INTENT_EXPLAIN_STEP]:
		_request_target_snapshot(request_id, speaker_peer_id)
	else:
		_submit_agent_request(request_id)
	return request_id


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
		var error := result.get("error", {}) as Dictionary
		_fail_request(request_id, str(error.get("code", "no_active_task")), str(error.get("message", "No active task guide.")))
		return
	var record := _requests[request_id] as Dictionary
	record["snapshot"] = (result.get("data", {}) as Dictionary).duplicate(true)
	_requests[request_id] = record
	if str(record.get("intent", "")) == INTENT_EXPLAIN_STEP:
		_ask_deepseek_with_snapshot(request_id)
	else:
		_submit_agent_request(request_id)


func _expire_snapshot_request(request_id: String) -> void:
	await get_tree().create_timer(SNAPSHOT_TIMEOUT_SECONDS).timeout
	if not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	if str(record.get("status", "")) == "preparing":
		_fail_request(request_id, "tool_timeout", "Timed out waiting for the target client task state.")


func _submit_agent_request(request_id: String) -> void:
	if not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	var intent := str(record.get("intent", ""))
	var allowed_tools := PackedStringArray()
	if intent == INTENT_OPEN_ALBUM:
		allowed_tools.append("open_album")
	elif intent == INTENT_OPEN_GUIDE:
		allowed_tools.append("open_task_guide")
	elif intent == INTENT_READ_STEP:
		allowed_tools.append("get_current_task_step")
	elif intent == INTENT_ADVANCE_STEP:
		allowed_tools.append("next_task_step")
	else:
		_fail_request(request_id, "permission_denied", "No tool is authorized for this request.")
		return
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent == null or not agent.submit_user_message(
		request_id,
		str(record.get("text", "")),
		(record.get("snapshot", {}) as Dictionary).duplicate(true),
		allowed_tools
	):
		_fail_request(request_id, "target_offline", "The Local Agent Gateway is not connected.")
		return
	record["status"] = "agent_running"
	_requests[request_id] = record


func _tool_open_task_guide(arguments: Dictionary, context: Dictionary) -> Dictionary:
	var request_id := str(context.get("request_id", ""))
	var validation := _validate_tool_authorization(request_id, INTENT_OPEN_GUIDE)
	if not bool(validation.get("ok", false)):
		return validation
	if int(arguments.get("task_id", 0)) != 1:
		return _error("invalid_arguments", "Only task_id 1 is enabled.")
	return _execute_or_defer_target_tool(request_id, context, "open", {"task_id": 1})


func _tool_open_album(arguments: Dictionary, context: Dictionary) -> Dictionary:
	var request_id := str(context.get("request_id", ""))
	var validation := _validate_tool_authorization(request_id, INTENT_OPEN_ALBUM)
	if not bool(validation.get("ok", false)):
		return validation
	return _execute_or_defer_target_tool(request_id, context, "album", arguments)


func _tool_get_current_task_step(_arguments: Dictionary, context: Dictionary) -> Dictionary:
	var request_id := str(context.get("request_id", ""))
	var validation := _validate_tool_authorization(request_id, INTENT_READ_STEP)
	if not bool(validation.get("ok", false)):
		return validation
	var record := _requests[request_id] as Dictionary
	return _success((record.get("snapshot", {}) as Dictionary).duplicate(true))


func _tool_next_task_step(_arguments: Dictionary, context: Dictionary) -> Dictionary:
	var request_id := str(context.get("request_id", ""))
	var validation := _validate_tool_authorization(request_id, INTENT_ADVANCE_STEP)
	if not bool(validation.get("ok", false)):
		return validation
	var record := _requests[request_id] as Dictionary
	var snapshot := record.get("snapshot", {}) as Dictionary
	var operation_id := _new_id("operation")
	return _execute_or_defer_target_tool(request_id, context, "advance", {
		"operation_id": operation_id,
		"expected_task_id": int(snapshot.get("task_id", 0)),
		"expected_page_index": int(snapshot.get("page_index", 0)),
	})


func _validate_tool_authorization(request_id: String, expected_intent: String) -> Dictionary:
	if not _requests.has(request_id):
		return _error("permission_denied", "The request is no longer active.")
	var record := _requests[request_id] as Dictionary
	if str(record.get("intent", "")) != expected_intent:
		return _error("permission_denied", "The Router did not authorize this state transition.")
	if str(record.get("status", "")) in ["tool_dispatched", "cancelled", "completed"]:
		return _error("permission_denied", "The request is no longer mutable.")
	return _success({})


func _execute_or_defer_target_tool(
	request_id: String,
	context: Dictionary,
	operation: String,
	arguments: Dictionary
) -> Dictionary:
	var record := _requests[request_id] as Dictionary
	var speaker_peer_id := int(record.get("speaker_peer_id", 0))
	record["status"] = "tool_dispatched"
	_requests[request_id] = record
	if _is_local_target(speaker_peer_id):
		return _execute_target_tool(operation, arguments)
	if not _is_peer_connected(speaker_peer_id):
		return _error("target_offline", "The speaking client is offline.")
	var tool_call_id := str(context.get("tool_call_id", ""))
	if tool_call_id.is_empty():
		return _error("invalid_tool_call", "tool_call_id is required for remote execution.")
	_operation_to_request[tool_call_id] = request_id
	rpc_id(speaker_peer_id, "_client_execute_task_tool", request_id, tool_call_id, operation, arguments)
	return {"__deferred__": true}


@rpc("authority", "call_remote", "reliable")
func _client_execute_task_tool(
	request_id: String,
	tool_call_id: String,
	operation: String,
	arguments: Dictionary
) -> void:
	var result := _execute_target_tool(operation, arguments)
	rpc_id(SERVER_PEER_ID, "_server_receive_task_tool_result", request_id, tool_call_id, result)


@rpc("any_peer", "call_remote", "reliable")
func _server_receive_task_tool_result(
	request_id: String,
	tool_call_id: String,
	result: Dictionary
) -> void:
	if not multiplayer.is_server() or not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	if multiplayer.get_remote_sender_id() != int(record.get("speaker_peer_id", 0)):
		return
	if str(_operation_to_request.get(tool_call_id, "")) != request_id:
		return
	_operation_to_request.erase(tool_call_id)
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent != null:
		agent.complete_deferred_tool_call(tool_call_id, result)


func _execute_target_tool(operation: String, arguments: Dictionary) -> Dictionary:
	if operation == "album":
		return OpenAlbumAdapterScript.new().execute(arguments)
	if operation == "open":
		var search_root := get_tree().current_scene if get_tree().current_scene != null else get_tree().root
		var list_view := _find_node_with_method(search_root, "open_task_by_id")
		return list_view.call("open_task_by_id", int(arguments.get("task_id", 0))) if list_view != null else _error(
			"not_ready", "The task list view is not ready."
		)
	if operation == "advance":
		var detail := _resolve_task_detail()
		return detail.call(
			"advance_if_index",
			str(arguments.get("operation_id", "")),
			int(arguments.get("expected_task_id", 0)),
			int(arguments.get("expected_page_index", 0))
		) if detail != null else _error("not_ready", "The task detail view is not ready.")
	return _error("permission_denied", "Unsupported task operation.")


func _execute_get_snapshot() -> Dictionary:
	var detail := _resolve_task_detail()
	return detail.call("get_task_snapshot", true) if detail != null else _error(
		"not_ready", "The task detail view is not ready."
	)


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


func _ask_deepseek_with_snapshot(request_id: String) -> void:
	var record := _requests[request_id] as Dictionary
	var snapshot := record.get("snapshot", {}) as Dictionary
	var current := snapshot.get("current_step", {}) as Dictionary
	var entry := {
		"id": "voice-current-task-step",
		"title": str(snapshot.get("task_title", "当前任务")),
		"source": "当前专家任务步骤 / 目标客户端",
		"tags": ["当前任务", "当前步骤", str(current.get("title", ""))],
		"content": "任务：%s\n当前页：%d/%d\n当前步骤：%s\n要求：%s" % [
			str(snapshot.get("task_title", "当前任务")),
			int(snapshot.get("page_index", 0)),
			int(snapshot.get("page_count", 0)),
			str(current.get("title", "")),
			str(current.get("info", "")),
		],
	}
	var assistant := get_node_or_null("/root/LLMAssistantService")
	if assistant == null:
		_fail_request(request_id, "not_ready", "DeepSeek assistant is not ready.")
		return
	assistant.call("set_runtime_context_entries", [entry])
	assistant.call("ask", str(record.get("text", "")))
	_requests.erase(request_id)


func _on_agent_answer(request_id: String, answer: String) -> void:
	if not _requests.has(request_id):
		return
	var record := _requests[request_id] as Dictionary
	record["status"] = "completed"
	_requests[request_id] = record
	_publish_answer(answer)
	_clear_operations_for_request(request_id)
	_requests.erase(request_id)


func _on_agent_error(request_id: String, code: String, message: String) -> void:
	if code == "too_late" and _requests.has(request_id):
		var active_record := _requests[request_id] as Dictionary
		active_record["status"] = "tool_dispatched"
		_requests[request_id] = active_record
		return
	if _requests.has(request_id):
		var record := _requests[request_id] as Dictionary
		record["status"] = "cancelled" if code == "cancelled" else "failed"
		_requests[request_id] = record
	_fail_request(request_id, code, message)


func _fail_request(request_id: String, code: String, message: String) -> void:
	_publish_answer("操作未完成：%s（%s）" % [message, code])
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent != null and agent.has_method("abandon_deferred_tool_calls_for_request"):
		agent.call("abandon_deferred_tool_calls_for_request", request_id)
	_clear_operations_for_request(request_id)
	_requests.erase(request_id)


func _clear_operations_for_request(request_id: String) -> void:
	for tool_call_id in _operation_to_request.keys():
		if str(_operation_to_request[tool_call_id]) == request_id:
			_operation_to_request.erase(tool_call_id)


func _publish_answer(answer: String) -> void:
	var voice_chat := get_node_or_null("/root/VoiceChat")
	if voice_chat != null and voice_chat.has_method("publish_assistant_transcript"):
		voice_chat.call("publish_assistant_transcript", answer)


func _is_local_target(peer_id: int) -> bool:
	return not multiplayer.has_multiplayer_peer() or peer_id == multiplayer.get_unique_id()


func _is_peer_connected(peer_id: int) -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id)


func _contains_any(text: String, patterns: Array[String]) -> bool:
	for pattern in patterns:
		if text.find(pattern) >= 0:
			return true
	return false


func _new_id(prefix: String) -> String:
	return "%s-%d-%d" % [prefix, Time.get_ticks_usec(), randi()]


func _success(data: Dictionary) -> Dictionary:
	return {"ok": true, "data": data, "error": null}


func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "data": {}, "error": {"code": code, "message": message}}
