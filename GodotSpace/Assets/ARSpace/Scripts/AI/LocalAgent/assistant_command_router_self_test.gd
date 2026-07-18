extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var router := root.get_node_or_null("AssistantCommandRouter")
	if not _check(router != null, "AssistantCommandRouter autoload is missing."):
		return
	if not _check(router.classify_text("下一步应该做什么") == "READ_ONLY", "Next-step question was not read-only."):
		return
	if not _check(router.classify_text("进入下一步") == "ADVANCE_STEP", "Explicit advance was not writable."):
		return
	if not _check(router.classify_text("这一步做完了，继续") == "ADVANCE_STEP", "Completion command was not writable."):
		return
	if not _check(router.classify_text("不要进入下一步") == "GENERAL", "Negated advance was authorized."):
		return
	if not _check(router.classify_text("如果进入下一步会怎么样") == "READ_ONLY", "Conditional next-step phrase obtained write permission."):
		return
	if not _check(router.classify_text("可以进入下一步吗") == "READ_ONLY", "Permission question obtained write permission."):
		return
	if not _check(router.classify_text("我当前这一步做完了") != "ADVANCE_STEP", "Completion statement without continue obtained write permission."):
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
	var snapshot_result: Dictionary = detail_view.call("get_task_snapshot", true)
	var snapshot := snapshot_result.get("data", {}) as Dictionary

	var requests := router.get("_requests") as Dictionary
	requests["read-request"] = {
		"speaker_peer_id": 1,
		"intent": "READ_ONLY",
		"status": "agent_running",
		"snapshot": snapshot.duplicate(true),
	}
	var read_result: Dictionary = router.call(
		"_tool_get_current_task_step", {}, {"request_id": "read-request", "tool_call_id": "read-tool"}
	)
	if not _check(bool(read_result.get("ok", false)), "Read-only task tool failed."):
		return
	if not _check(int(detail_view.page_index) == 1, "Read-only task tool changed the page."):
		return
	var unauthorized: Dictionary = router.call(
		"_tool_next_task_step", {}, {"request_id": "read-request", "tool_call_id": "bad-tool"}
	)
	if not _check(_error_code(unauthorized) == "permission_denied", "Read request obtained write permission."):
		return

	requests["advance-request"] = {
		"speaker_peer_id": 1,
		"intent": "ADVANCE_STEP",
		"status": "agent_running",
		"snapshot": snapshot.duplicate(true),
	}
	var advanced: Dictionary = router.call(
		"_tool_next_task_step", {}, {"request_id": "advance-request", "tool_call_id": "advance-tool"}
	)
	if not _check(bool(advanced.get("ok", false)), "Authorized task advance failed."):
		return
	if not _check(int(detail_view.page_index) == 2, "Authorized task advance did not move exactly one page."):
		return

	requests["stale-request"] = {
		"speaker_peer_id": 1,
		"intent": "ADVANCE_STEP",
		"status": "agent_running",
		"snapshot": snapshot.duplicate(true),
	}
	var stale: Dictionary = router.call(
		"_tool_next_task_step", {}, {"request_id": "stale-request", "tool_call_id": "stale-tool"}
	)
	if not _check(_error_code(stale) == "stale_state", "Stale precondition advanced the task twice."):
		return
	if not _check(int(detail_view.page_index) == 2, "Stale retry changed the task page."):
		return

	requests["too-late-request"] = {
		"speaker_peer_id": 1,
		"intent": "ADVANCE_STEP",
		"status": "agent_running",
		"snapshot": snapshot.duplicate(true),
	}
	router.call("_on_agent_error", "too-late-request", "too_late", "Already dispatched")
	if not _check(router.get_request_debug_state("too-late-request").get("status", "") == "tool_dispatched", "too_late incorrectly discarded an in-flight operation."):
		return

	requests["spoofed-snapshot"] = {
		"speaker_peer_id": 99,
		"intent": "READ_ONLY",
		"status": "preparing",
		"snapshot": {},
	}
	router.call("_server_receive_task_snapshot", "spoofed-snapshot", {
		"ok": true,
		"data": {"task_id": 1, "page_index": 19},
		"error": null,
	})
	if not _check((router.get_request_debug_state("spoofed-snapshot").get("snapshot", {}) as Dictionary).is_empty(), "Snapshot from the wrong peer was accepted."):
		return

	requests["snapshot-timeout"] = {
		"speaker_peer_id": 99,
		"intent": "READ_ONLY",
		"status": "preparing",
		"snapshot": {},
	}
	router.call("_expire_snapshot_request", "snapshot-timeout", 0.01)
	await create_timer(0.03).timeout
	if not _check(router.get_request_debug_state("snapshot-timeout").is_empty(), "Timed-out snapshot request was not removed."):
		return

	var page_before_cancel := int(detail_view.page_index)
	requests["cancelled-request"] = {
		"speaker_peer_id": 1,
		"intent": "ADVANCE_STEP",
		"status": "agent_running",
		"snapshot": (detail_view.call("get_task_snapshot", true) as Dictionary).get("data", {}),
	}
	router.call("_on_agent_error", "cancelled-request", "cancelled", "Cancelled before dispatch")
	var cancelled_tool: Dictionary = router.call(
		"_tool_next_task_step", {}, {"request_id": "cancelled-request", "tool_call_id": "cancelled-tool"}
	)
	if not _check(_error_code(cancelled_tool) == "permission_denied", "Cancelled request retained write permission."):
		return
	if not _check(int(detail_view.page_index) == page_before_cancel, "Cancelled request changed the task page."):
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
