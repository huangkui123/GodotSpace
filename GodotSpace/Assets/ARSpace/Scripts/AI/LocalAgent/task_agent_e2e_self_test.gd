extends SceneTree

var _answer_count := 0
var _run_error := ""
var _answers: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var client := root.get_node_or_null("LocalAgentClient")
	var voice_chat := root.get_node_or_null("VoiceChat")
	if not _check(client != null and voice_chat != null, "Required Agent autoloads are missing."):
		return
	client.assistant_final_received.connect(func(_request_id: String, answer: String) -> void:
		_answer_count += 1
		_answers.append(answer)
	)
	client.run_error_received.connect(func(_request_id: String, code: String, message: String) -> void:
		_run_error = "%s: %s" % [code, message]
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
		"text": "下一步应该做什么",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(1):
		return
	if not _check(int(detail_view.page_index) == 1, "Read-only next-step question changed the task page."):
		return

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "进入下一步",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(2):
		return
	if not _check(int(detail_view.page_index) == 2, "Explicit advance did not move exactly one page."):
		var router := root.get_node_or_null("AssistantCommandRouter")
		push_error("Live Agent diagnostics: answers=%s router=%s" % [
			_answers,
			router.get_debug_state() if router != null else {},
		])
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


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
