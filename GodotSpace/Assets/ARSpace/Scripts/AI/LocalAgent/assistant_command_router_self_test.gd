extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var router := root.get_node_or_null("AssistantCommandRouter")
	if not _check(router != null, "AssistantCommandRouter autoload is missing."):
		return
	if not _check(router.classify_text("任何语句") == "QWEN_FIRST", "Router must not use keyword intent routing."):
		return
	if not _check(router.call("route_transcript_for_test", {"text": "随便一句话", "is_final": true}).is_empty(), "Non-wake speech was routed."):
		return
	if not _check(router.call("_strip_required_wake_word", "我想问一下，助手，打开相册") == "打开相册", "Mid-utterance wake word did not preserve the command suffix."):
		return
	if not _check(router.call("_strip_required_wake_word", "智能助手。").is_empty(), "Wake-only final punctuation was treated as a command."):
		return
	var interaction_states: Array[String] = []
	router.assistant_interaction_state_changed.connect(func(_peer_id: int, state: String, _text: String) -> void:
		interaction_states.append(state)
	)
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 91, "text": "我先说一句，助手", "is_final": false})
	if not _check((router.get_debug_state() as Dictionary).get("wake_session_count", 0) == 1, "Wake-only partial transcript did not start a listening session."):
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 91, "text": "我先说一句，助手，取消", "is_final": true})
	if not _check((router.get_debug_state() as Dictionary).get("wake_session_count", 0) == 0, "Local wake-session cancellation did not clear the listening state."):
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 92, "text": "智能助手。", "is_final": true})
	if not _check((router.get_debug_state() as Dictionary).get("wake_session_count", 0) == 1, "Wake-only final transcript did not keep listening for the next utterance."):
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 93, "text": "取消", "is_final": true})
	if not _check((router.get_debug_state() as Dictionary).get("wake_session_count", 0) == 0, "The utterance after a wake-only final transcript was ignored."):
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 94, "text": "智能助手。", "is_final": true})
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 95, "text": "打开工作", "is_final": false})
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 95, "text": "打开工作清单", "is_final": true})
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 96, "text": "第二项", "is_final": false})
	var wake_sessions := router.get("_wake_sessions") as Dictionary
	var accumulated_session := wake_sessions.get(1, {}) as Dictionary
	if not _check(str(accumulated_session.get("command", "")) == "打开工作清单 第二项", "Command capture did not retain multiple ASR utterances."):
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 97, "text": "取消", "is_final": true})
	if not _check((router.get_debug_state() as Dictionary).get("wake_session_count", 0) == 0, "Cancellation did not stop an accumulated command."):
		return
	if not _check(interaction_states.has("listening") and interaction_states.has("idle"), "Wake interaction states were not published."):
		return
	var voice_chat := root.get_node_or_null("VoiceChat")
	if not _check(voice_chat != null and voice_chat.has_signal("assistant_wake_requested"), "VoiceChat manual wake signal is missing."):
		return
	voice_chat.assistant_wake_requested.emit(1)
	var manual_wake_sessions := router.get("_wake_sessions") as Dictionary
	if not _check(manual_wake_sessions.has(1), "Manual wake did not create a peer-scoped listening session."):
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 1, "text": "取消", "is_final": true})
	if not _check(not (router.get("_wake_sessions") as Dictionary).has(1), "Manual wake session did not accept the next utterance."):
		return
	var confirmation_routes: Array[String] = []
	router.command_routed.connect(func(request_id: String, _intent: String, _peer_id: int) -> void:
		confirmation_routes.append(request_id)
	)
	var confirmation_requests := router.get("_requests") as Dictionary
	confirmation_requests["confirmation-prompt"] = {
		"speaker_peer_id": 1,
		"status": "agent_running",
		"text": "打开工作文档",
		"snapshot": {},
		"allowed_tools": PackedStringArray(["open_task_guide"]),
		"created_msec": Time.get_ticks_msec(),
	}
	router.call("_on_agent_routing_decision", "confirmation-prompt", "confirm_action", "clarify_ui_target")
	router.call("_on_agent_answer", "confirmation-prompt", "当前最接近的是打开工作清单，你是想执行它吗？")
	var confirmation_session := (router.get("_wake_sessions") as Dictionary).get(1, {}) as Dictionary
	if not _check(bool(confirmation_session.get("confirmation", false)), "A confirmable suggestion did not reopen peer-scoped listening."):
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 2, "text": "是的", "is_final": true})
	if not _check(confirmation_routes.size() == 1, "A final confirmation was not routed immediately without another wake word."):
		return
	if not _check(not (router.get("_wake_sessions") as Dictionary).has(1), "Confirmation listening remained open after submission."):
		return
	var assistant := root.get_node_or_null("LLMAssistantService")
	if not _check(assistant != null and assistant.has_method("record_external_qa"), "LLMAssistant external history API is missing."):
		return
	var history_before := (assistant.call("get_qa_history") as Array).size()
	if not _check(bool(assistant.call("record_external_qa", "history-self-test", "测试问题", "测试答案", true, {"provider": "test"})), "External Qwen history was not recorded."):
		return
	if not _check(not bool(assistant.call("record_external_qa", "history-self-test", "测试问题", "重复答案", true, {})), "Duplicate external Qwen history was not suppressed."):
		return
	if not _check((assistant.call("get_qa_history") as Array).size() == history_before + 1, "External Qwen history count is incorrect."):
		return
	var picture_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/PictureCanvas.tscn")
	if not _check(picture_scene != null, "Picture album scene did not load."):
		return
	var picture_root := picture_scene.instantiate()
	root.add_child(picture_root)
	await process_frame
	var album_view := picture_root.get_node_or_null("Canvas")
	if not _check(album_view != null and bool((album_view.call("open_album", 1, false) as Dictionary).get("ok", false)), "Picture album did not open."):
		return
	var album_requests := router.get("_requests") as Dictionary
	album_requests["album-close-request"] = {
		"speaker_peer_id": 1, "status": "agent_running", "snapshot": {},
		"allowed_tools": PackedStringArray(["close_album"]),
	}
	var closed: Dictionary = router.call("_tool_close_album", {}, {"request_id": "album-close-request", "tool_call_id": "album-close-tool"})
	if not _check(bool(closed.get("ok", false)) and not bool(album_view.visible), "Authorized close-album tool failed."):
		return
	album_view.page_count = 3
	album_view.page_index = 2
	album_view.visible = true
	album_requests["album-previous-request"] = {
		"speaker_peer_id": 1, "status": "agent_running",
		"snapshot": {"album": album_view.call("get_album_snapshot"), "task_guide": {"visible": false}},
		"allowed_tools": PackedStringArray(["previous_album_page"]),
	}
	var album_previous: Dictionary = router.call("_tool_previous_album_page", {}, {"request_id": "album-previous-request", "tool_call_id": "album-previous-tool"})
	if not _check(bool(album_previous.get("ok", false)) and int(album_view.page_index) == 1, "Authorized previous-album-page tool moved in the wrong direction."):
		return
	album_view.page_count = 6
	album_requests["album-goto-request"] = {
		"speaker_peer_id": 1, "status": "agent_running",
		"snapshot": {"album": album_view.call("get_album_snapshot"), "task_guide": {"visible": false}},
		"allowed_tools": PackedStringArray(["go_to_album_page"]),
	}
	var fractional_album_goto: Dictionary = router.call("_tool_go_to_album_page", {"page": 5.5}, {"request_id": "album-goto-request", "tool_call_id": "album-goto-fractional-tool"})
	if not _check(_error_code(fractional_album_goto) == "invalid_arguments" and int(album_view.page_index) == 1, "Fractional album page was not rejected."):
		return
	# Godot's JSON parser represents protocol numbers as floats. An integral
	# value must survive the real WebSocket path even though direct calls use ints.
	var album_goto: Dictionary = router.call("_tool_go_to_album_page", {"page": 5.0}, {"request_id": "album-goto-request", "tool_call_id": "album-goto-tool"})
	if not _check(bool(album_goto.get("ok", false)) and int(album_view.page_index) == 5, "Authorized direct album page jump did not reach page 5."):
		return

	var detail_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn")
	var list_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn")
	if not _check(detail_scene != null and list_scene != null, "Task UI scenes did not load."):
		return
	var detail_root := detail_scene.instantiate()
	var list_view := list_scene.instantiate()
	root.add_child(detail_root)
	root.add_child(list_view)
	await process_frame
	var opened: Dictionary = list_view.call("open_task_by_id", 1)
	if not _check(bool(opened.get("ok", false)), "Task guide did not open."):
		return
	var detail_view := detail_root.get_node_or_null("Canvas")
	var task_snapshot: Dictionary = (detail_view.call("get_task_snapshot", true) as Dictionary).get("data", {})
	task_snapshot["visible"] = true
	task_snapshot["can_next"] = true
	task_snapshot["can_previous"] = false
	var snapshot := {"album": {"visible": false}, "task_guide": task_snapshot}
	var requests := router.get("_requests") as Dictionary
	var first_page_tools := router.call("_allowed_tools_for_snapshot", snapshot) as PackedStringArray
	if not _check(first_page_tools.has("next_task_step") and not first_page_tools.has("previous_task_step"), "First-page tool authorization did not match factual navigation state."):
		return
	var sorted_tools := first_page_tools.duplicate()
	sorted_tools.sort()
	if not _check(first_page_tools == sorted_tools, "Allowed tools contain ordering-based routing hints."):
		return
	if not _check(not snapshot.has("ui_routing_hint"), "Snapshot still contains a semantic UI routing hint."):
		return

	requests["read-request"] = {
		"speaker_peer_id": 1, "status": "agent_running", "snapshot": snapshot,
		"allowed_tools": PackedStringArray(["get_current_task_step"]),
	}
	var read_result: Dictionary = router.call("_tool_get_current_task_step", {}, {"request_id": "read-request", "tool_call_id": "read-tool"})
	if not _check(bool(read_result.get("ok", false)), "Read-only task tool failed."):
		return
	if not _check(int(detail_view.page_index) == 1, "Read-only task tool changed the page."):
		return
	var unauthorized: Dictionary = router.call("_tool_next_task_step", {}, {"request_id": "read-request", "tool_call_id": "bad-tool"})
	if not _check(_error_code(unauthorized) == "permission_denied", "Unavailable state-changing tool was accepted."):
		return

	requests["advance-request"] = {
		"speaker_peer_id": 1, "status": "agent_running", "snapshot": snapshot,
		"allowed_tools": PackedStringArray(["next_task_step"]),
	}
	var advanced: Dictionary = router.call("_tool_next_task_step", {}, {"request_id": "advance-request", "tool_call_id": "advance-tool"})
	if not _check(bool(advanced.get("ok", false)), "Authorized task advance failed."):
		return
	if not _check(int(detail_view.page_index) == 2, "Authorized task advance did not move exactly one page."):
		return

	requests["stale-request"] = {
		"speaker_peer_id": 1, "status": "agent_running", "snapshot": snapshot,
		"allowed_tools": PackedStringArray(["next_task_step"]),
	}
	var stale: Dictionary = router.call("_tool_next_task_step", {}, {"request_id": "stale-request", "tool_call_id": "stale-tool"})
	if not _check(_error_code(stale) == "stale_state", "Stale precondition advanced the task twice."):
		return
	if not _check(int(detail_view.page_index) == 2, "Stale retry changed the task page."):
		return

	requests["back-request"] = {
		"speaker_peer_id": 1, "status": "agent_running",
		"snapshot": {"album": {"visible": false}, "task_guide": (detail_view.call("get_task_snapshot", true) as Dictionary).get("data", {})},
		"allowed_tools": PackedStringArray(["previous_task_step"]),
	}
	var back_snapshot: Dictionary = ((requests["back-request"] as Dictionary).get("snapshot", {}) as Dictionary).get("task_guide", {})
	back_snapshot["visible"] = true
	var moved_back: Dictionary = router.call("_tool_previous_task_step", {}, {"request_id": "back-request", "tool_call_id": "back-tool"})
	if not _check(bool(moved_back.get("ok", false)) and int(detail_view.page_index) == 1, "Authorized previous-step tool failed."):
		return
	requests["decision-request"] = {
		"speaker_peer_id": 1, "status": "agent_running", "snapshot": snapshot,
		"allowed_tools": PackedStringArray(["previous_task_step"]),
	}
	router.call("_on_agent_routing_decision", "decision-request", "tool", "previous_task_step")
	var decision_record := requests["decision-request"] as Dictionary
	if not _check(str(decision_record.get("qwen_tool_name", "")) == "previous_task_step", "Qwen routing metadata was not retained for diagnostics."):
		return
	requests["goto-request"] = {
		"speaker_peer_id": 1, "status": "agent_running", "snapshot": {},
		"allowed_tools": PackedStringArray(["go_to_task_guide_page"]),
	}
	var jumped: Dictionary = router.call("_tool_go_to_task_guide_page", {"page": 2.0}, {"request_id": "goto-request", "tool_call_id": "goto-tool"})
	if not _check(bool(jumped.get("ok", false)) and int(detail_view.page_index) == 2, "Authorized direct task-guide page jump failed."):
		return
	var verified_success: String = router.call("_verified_answer_or_model_answer", {
		"verified_ui_result": {"operation": "guide_advance", "result": {"ok": true, "data": {"snapshot": {"page_index": 3}}, "error": null}},
	}, "模型文字")
	if not _check(verified_success == "已切换到工作清单第 3 步。", "Verified UI result did not use the default work-checklist name."):
		return
	var verified_open: String = router.call("_verified_answer_or_model_answer", {
		"verified_ui_result": {"operation": "guide_open", "result": {"ok": true, "data": {"snapshot": {"page_index": 1}}, "error": null}},
	}, "模型文字")
	if not _check(verified_open == "已打开工作清单第 1 步。", "Open confirmation did not use the default work-checklist name."):
		return
	var verified_failure: String = router.call("_verified_answer_or_model_answer", {
		"verified_ui_result": {"operation": "guide_advance", "result": {"ok": false, "data": {}, "error": {"code": "already_last_step", "message": "Already at last step."}}},
	}, "已完成")
	if not _check(verified_failure.find("操作未完成") == 0, "Failed UI result was reported as success."):
		return
	requests["knowledge-evidence-request"] = {
		"speaker_peer_id": 1,
		"status": "agent_running",
		"text": "这一页我要用的力矩有多大",
		"snapshot": {
			"task_guide": {
				"visible": true,
				"task_title": "无容器样品实验流程",
				"page_index": 17,
				"page_count": 20,
				"current_step": {
					"title": "17.固定机构",
					"info": "使用2.5N·m的力矩锁紧6颗M6螺钉。",
				},
			},
		},
		"allowed_tools": PackedStringArray(["query_task_knowledge"]),
	}
	var evidence_result: Dictionary = router.call(
		"_tool_query_task_knowledge",
		{},
		{"request_id": "knowledge-evidence-request", "tool_call_id": "knowledge-evidence-tool"}
	)
	var evidence_entries := (evidence_result.get("data", {}) as Dictionary).get("entries", []) as Array
	var evidence_entry := evidence_entries[0] as Dictionary if evidence_entries.size() == 1 else {}
	if not _check(
		bool(evidence_result.get("ok", false))
		and evidence_entries.size() == 1
		and str(evidence_entry.get("content", "")).find("2.5N·m") >= 0
		and not evidence_entry.has("source")
		and not evidence_entry.has("trust")
		and not evidence_entry.has("priority"),
		"Knowledge tool did not return the current page as synchronous evidence."
	):
		return
	if not _check(
		str((requests["knowledge-evidence-request"] as Dictionary).get("last_operation", "")) == "query_task_knowledge",
		"Knowledge request did not record the renamed protocol operation."
	):
		return

	var router_debug: Dictionary = router.get_debug_state()
	for event_value in router_debug.get("recent_events", []):
		var event := event_value as Dictionary
		if not _check(not event.has("speaker_peer_id") and not event.has("text"), "Router debug event leaked speaker or transcript data."):
			return
	print("Assistant command Router self test passed.")
	quit(0)


func _error_code(result: Dictionary) -> String:
	var error_value: Variant = result.get("error", {})
	return str((error_value as Dictionary).get("code", "")) if typeof(error_value) == TYPE_DICTIONARY else ""


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
