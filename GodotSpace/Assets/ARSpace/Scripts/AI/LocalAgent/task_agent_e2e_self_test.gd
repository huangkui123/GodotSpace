extends SceneTree

var _answer_count := 0
var _run_error := ""
var _answers: Array[String] = []
var _routes: Array[String] = []
var _tools: Array[String] = []
const LOCAL_AGENT_ENDPOINT_SETTING := "arspace/local_agent/endpoint_url"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	ProjectSettings.set_setting("arspace/local_agent/enabled", true)
	var client := root.get_node_or_null("LocalAgentClient")
	var voice_chat := root.get_node_or_null("VoiceChat")
	var assistant := root.get_node_or_null("LLMAssistantService")
	if not _check(client != null and voice_chat != null and assistant != null, "Required Agent autoloads are missing."):
		return
	var mock_gateway_port := _mock_gateway_port()
	if mock_gateway_port > 0:
		ProjectSettings.set_setting(
			LOCAL_AGENT_ENDPOINT_SETTING,
			"ws://127.0.0.1:%d/ws/godot" % mock_gateway_port
		)
		client.call("_disable_connection")
		client.call("_try_connect")
	# The task-knowledge path must remain independent of legacy online-LLM settings.
	assistant.endpoint_url = "https://invalid.example.test/chat/completions"
	assistant.api_key = "must-not-be-used"
	assistant.api_key_environment_name = ""
	assistant.use_local_fallback_when_unconfigured = false
	client.assistant_final_received.connect(func(_request_id: String, answer: String) -> void:
		_answer_count += 1
		_answers.append(answer)
	)
	client.run_error_received.connect(func(_request_id: String, code: String, message: String) -> void:
		_run_error = "%s: %s" % [code, message]
	)
	client.assistant_routing_decision_received.connect(func(_request_id: String, route: String, tool_name: String) -> void:
		_routes.append(route)
		_tools.append(tool_name)
	)

	var detail_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn")
	var list_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn")
	var detail_root := detail_scene.instantiate()
	var list_view := list_scene.instantiate()
	root.add_child(detail_root)
	root.add_child(list_view)
	await process_frame
	var opened: Dictionary = list_view.call("open_task_by_id", 1)
	if not _check(bool(opened.get("ok", false)), "Task guide did not open."):
		return
	var detail_view := detail_root.get_node_or_null("Canvas")

	var connect_deadline := Time.get_ticks_msec() + 15_000
	while not client.is_connected_to_gateway() and Time.get_ticks_msec() < connect_deadline:
		await process_frame
	if not _check(client.is_connected_to_gateway(), "Local Agent did not connect to the mock Gateway."):
		return

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手，这一步我做完了，接下来需要做什么",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(1):
		return
	if not _check(int(detail_view.page_index) == 2, "Completion request did not advance exactly one task step."):
		return

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手，工作清单翻到下一页",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(2):
		return
	if not _check(int(detail_view.page_index) == 3, "Next-step request did not move exactly one additional page."):
		var router := root.get_node_or_null("AssistantCommandRouter")
		push_error("Live Agent diagnostics: answers=%s router=%s" % [
			_answers,
			router.get_debug_state() if router != null else {},
		])
		return

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手，翻到上一页",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(3):
		return
	if not _check(int(detail_view.page_index) == 2, "Previous-page request did not move the task guide backward exactly one page."):
		var router := root.get_node_or_null("AssistantCommandRouter")
		push_error("Previous-page diagnostics: answers=%s router=%s" % [
			_answers,
			router.get_debug_state() if router != null else {},
		])
		return
	var page_17_result: Dictionary = detail_view.call("go_to_page", 17)
	if not _check(bool(page_17_result.get("ok", false)) and int(detail_view.page_index) == 17, "Could not prepare task page 17 for knowledge verification."):
		return
	var current_snapshot_result: Dictionary = detail_view.call("get_task_snapshot", true)
	var current_snapshot := current_snapshot_result.get("data", {}) as Dictionary
	var expected_step_title := str((current_snapshot.get("current_step", {}) as Dictionary).get("title", ""))
	if not _check(not expected_step_title.is_empty(), "Current task snapshot has no step title for knowledge verification."):
		return

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手，这一页要用多大力矩",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(4):
		return
	if not _check(_answers[3].find(expected_step_title) != -1, "Current-page explanation did not cite the active task-step evidence."):
		return
	if not _check(_answers[3].find("2.5N·m") != -1, "Page-17 knowledge answer did not contain the grounded torque value."):
		return
	if not _check(_routes.size() >= 4 and _routes[-1] == "knowledge_qa", "Knowledge request did not publish the knowledge_qa route."):
		return
	if not _check(_tools.size() >= 4 and _tools[-1] == "query_task_knowledge", "Knowledge request did not execute query_task_knowledge."):
		return

	print("Task Agent voice-to-tool end-to-end self test passed.")
	quit(0)


func _wait_for_answers(expected: int) -> bool:
	var deadline := Time.get_ticks_msec() + 45_000
	while _answer_count < expected and _run_error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _run_error.is_empty():
		return _check(false, "Gateway returned %s" % _run_error)
	return _check(_answer_count >= expected, "Timed out waiting for Agent answer %d." % expected)


func _mock_gateway_port() -> int:
	const PREFIX := "--mock-gateway-port="
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(PREFIX):
			return int(argument.trim_prefix(PREFIX))
	return 0


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
