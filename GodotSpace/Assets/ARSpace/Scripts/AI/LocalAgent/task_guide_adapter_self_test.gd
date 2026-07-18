extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var detail_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn")
	if not _check(detail_scene != null, "WorkListInfoCanvas scene did not load."):
		return
	var detail_root := detail_scene.instantiate()
	root.add_child(detail_root)
	await process_frame
	var detail_view := detail_root.get_node_or_null("Canvas")
	if not _check(detail_view != null, "WorkListInfoCanvas is missing Canvas."):
		return

	var list_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn")
	if not _check(list_scene != null, "WorkListView scene did not load."):
		return
	var list_view := list_scene.instantiate()
	root.add_child(list_view)
	await process_frame

	var opened: Dictionary = list_view.call("open_task_by_id", 1)
	if not _check(bool(opened.get("ok", false)), "Enabled task guide did not open."):
		return
	var opened_snapshot := _snapshot_from_result(opened)
	if not _check(int(opened_snapshot.get("task_id", 0)) == 1, "Opened task ID was not preserved."):
		return
	if not _check(int(opened_snapshot.get("page_index", 0)) == 1, "Task guide did not start at page 1."):
		return
	if not _check(_step_number(opened_snapshot, "current_step") == 1, "Current step snapshot is incorrect."):
		return
	if not _check(_step_number(opened_snapshot, "next_step_preview") == 2, "Next-step preview is incorrect."):
		return

	var disabled: Dictionary = list_view.call("open_task_by_id", 2)
	if not _check(_error_code(disabled) == "permission_denied", "Disabled task guide was not rejected."):
		return
	var missing: Dictionary = list_view.call("open_task_by_id", 999)
	if not _check(_error_code(missing) == "not_found", "Unknown task guide was not rejected."):
		return

	var query: Dictionary = detail_view.call("get_task_snapshot", true)
	if not _check(bool(query.get("ok", false)), "Current task snapshot query failed."):
		return
	if not _check(int(_snapshot_from_result(query).get("page_index", 0)) == 1, "Read-only query changed the page."):
		return

	var advanced: Dictionary = detail_view.call("advance_if_index", "operation-1", 1, 1)
	if not _check(bool(advanced.get("ok", false)), "Atomic task advance failed."):
		return
	if not _check(int(_snapshot_from_result(advanced).get("page_index", 0)) == 2, "Task did not advance exactly one page."):
		return

	var replayed: Dictionary = detail_view.call("advance_if_index", "operation-1", 1, 1)
	if not _check(_error_code(replayed) == "stale_state", "Replayed precondition advanced the task twice."):
		return
	if not _check(int(_snapshot_from_result(replayed).get("page_index", 0)) == 2, "Stale retry changed the current page."):
		return

	var wrong_task: Dictionary = detail_view.call("advance_if_index", "operation-2", 2, 2)
	if not _check(_error_code(wrong_task) == "wrong_task", "Wrong task precondition was accepted."):
		return

	detail_view.call("last_page")
	var last_snapshot: Dictionary = _snapshot_from_result(detail_view.call("get_task_snapshot", true))
	var last_page := int(last_snapshot.get("page_index", 0))
	var at_end: Dictionary = detail_view.call("advance_if_index", "operation-last", 1, last_page)
	if not _check(_error_code(at_end) == "already_last_step", "Last-step boundary was not enforced."):
		return

	detail_view.visible = false
	var hidden: Dictionary = detail_view.call("get_task_snapshot", true)
	if not _check(_error_code(hidden) == "no_active_task", "Hidden task guide remained active."):
		return
	var reopened: Dictionary = list_view.call("open_task_by_id", 1)
	if not _check(bool(reopened.get("ok", false)), "Closed task guide did not reopen."):
		return
	if not _check(int(_snapshot_from_result(reopened).get("page_index", 0)) == 1, "Reopened task guide did not reset to page 1."):
		return
	var idempotent: Dictionary = list_view.call("open_task_by_id", 1)
	if not _check(not bool((idempotent.get("data", {}) as Dictionary).get("changed", true)), "Repeated open was not idempotent."):
		return

	print("Task guide adapter self test passed.")
	quit(0)


func _snapshot_from_result(result: Dictionary) -> Dictionary:
	var data_value: Variant = result.get("data", {})
	if typeof(data_value) != TYPE_DICTIONARY:
		return {}
	var data := data_value as Dictionary
	var snapshot_value: Variant = data.get("snapshot", data)
	return snapshot_value as Dictionary if typeof(snapshot_value) == TYPE_DICTIONARY else {}


func _step_number(snapshot: Dictionary, key: String) -> int:
	var step_value: Variant = snapshot.get(key, {})
	return int((step_value as Dictionary).get("step", 0)) if typeof(step_value) == TYPE_DICTIONARY else 0


func _error_code(result: Dictionary) -> String:
	var error_value: Variant = result.get("error", {})
	return str((error_value as Dictionary).get("code", "")) if typeof(error_value) == TYPE_DICTIONARY else ""


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false
