extends SceneTree

const AssistantScript := preload("res://Assets/ARSpace/Scripts/AI/llm_assistant.gd")

var _completed := false
var _snapshot_source_seen := false
var _wrong_source_seen := false


func _init() -> void:
	var assistant := AssistantScript.new()
	root.add_child(assistant)
	assistant.endpoint_url = ""
	assistant.api_key = ""
	assistant.api_key_environment_name = ""
	assistant.use_local_fallback_when_unconfigured = true
	assistant.call("_setup_knowledge_base")
	assistant.call("_setup_http_request")

	assistant.answer_completed.connect(func(_question: String, answer: String, sources: Array) -> void:
		_completed = not answer.strip_edges().is_empty()
		_snapshot_source_seen = _has_source(sources, "队列快照步骤")
		_wrong_source_seen = _has_source(sources, "切换后的步骤")
	)

	assistant.call("set_runtime_context_entries", [{
		"id": "queued-step-a",
		"title": "队列快照步骤",
		"source": "队列快照步骤",
		"tags": ["当前步骤", "队列", "样品盒"],
		"content": "当前步骤：样品盒固定螺钉松开。需要保持防静电接地，并按目标力矩松开固定螺钉。",
	}])
	assistant.set("_active_question", "busy")
	assistant.call("ask", "当前步骤样品盒固定螺钉需要怎么处理")

	var state: Dictionary = assistant.call("get_debug_state")
	if int(state.get("pending_question_count", 0)) != 1:
		_fail("Queued question was not recorded.")
		return

	assistant.call("set_runtime_context_entries", [{
		"id": "queued-step-b",
		"title": "切换后的步骤",
		"source": "切换后的步骤",
		"tags": ["当前步骤", "队列", "样品盒"],
		"content": "当前步骤：样品盒复位验收。需要确认安装到位并复述验收读数。",
	}])
	assistant.set("_active_question", "")
	assistant.set("_active_sources", [])
	assistant.call("_start_next_pending_question")

	if not _completed or not _snapshot_source_seen or _wrong_source_seen:
		_fail("Queued question did not keep its source snapshot.")
		return

	print("LLM assistant queue self test passed.")
	quit(0)


func _has_source(sources: Array, source_name: String) -> bool:
	for source in sources:
		if typeof(source) == TYPE_DICTIONARY and str((source as Dictionary).get("source", "")).find(source_name) != -1:
			return true
	return false


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
