extends SceneTree

const VIEW_SCENE_PATH := "res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn"


class WorkInfoSpy extends Control:
	var refresh_count: int = 0

	func on_refresh_data_change_view(_result: WorkListInfoDataResult) -> void:
		refresh_count += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: PackedStringArray = []
	var view_scene := load(VIEW_SCENE_PATH) as PackedScene
	if view_scene == null:
		_failures_and_quit(PackedStringArray(["Unable to load the real WorkListView scene."]))
		return

	var view := view_scene.instantiate()
	root.add_child(view)
	await process_frame

	var tasks: Array = view.get("_info_save_list")
	if tasks.size() != 5:
		failures.append("The Unity baseline must expose exactly tasks 1-5; tasks 6-8 must be absent.")
	for index in range(tasks.size()):
		var task := tasks[index] as WorkListData
		if task == null:
			failures.append("Task %d runtime data is missing or has the wrong type." % (index + 1))
			continue
		if task.id != index + 1:
			failures.append("Task ids must stay consecutive from 1 through 5.")

	var task_one: WorkListData = null
	if not tasks.is_empty():
		task_one = tasks[0] as WorkListData
	if task_one == null or not task_one.is_configured:
		failures.append("Task 1 must be configured at runtime.")
	elif task_one.step_count_text != "共20步" \
	or task_one.info_data_result == null or task_one.info_data_result.list.size() != 20:
		failures.append("Task 1 must remain configured with exactly 20 steps.")
	else:
		for step_index in range(task_one.info_data_result.list.size()):
			var step := task_one.info_data_result.list[step_index] as WorkListInfoData
			if step == null or step.step != step_index + 1:
				failures.append("Task 1 steps must stay consecutive from 1 through 20.")
				break

	for task_index in range(1, tasks.size()):
		var placeholder := tasks[task_index] as WorkListData
		if placeholder == null or placeholder.is_configured:
			failures.append("Tasks 2-5 must remain explicit unconfigured placeholders.")
		elif placeholder.info_data_result != null or placeholder.step_count_text != "未配置":
			failures.append("Unconfigured tasks must not expose step data or a configured step count.")

	var item_nodes: Array = view.get("info_")
	if item_nodes.size() != 5 or tasks.size() != 5:
		failures.append("The real WorkListView scene must expose exactly five runtime item controls.")
	else:
		for item_index in range(item_nodes.size()):
			var item: Node = item_nodes[item_index]
			if item == null or item.get("item_data") != tasks[item_index]:
				failures.append("Runtime item %d was not bound to its task data." % (item_index + 1))

	var first_task_reference: WorkListData = task_one
	view.call("sample_data_init")
	var tasks_after_repeat: Array = view.get("_info_save_list")
	if tasks_after_repeat.size() != 5 or tasks_after_repeat[0] != first_task_reference:
		failures.append("Repeated baseline initialization must be idempotent.")

	if item_nodes.size() >= 2 and tasks.size() >= 2:
		var title_label := item_nodes[1].get_node_or_null("Title") as Label
		var count_label := item_nodes[1].get_node_or_null("Num") as Label
		if title_label == null or not title_label.text.contains("未配置") \
		or count_label == null or count_label.text != "未配置":
			failures.append("Unconfigured runtime items must display their placeholder state.")

		var global := root.get_node_or_null("Global")
		if global == null:
			failures.append("Global autoload is unavailable for placeholder selection validation.")
			view.queue_free()
			await process_frame
			_failures_and_quit(failures)
			return
		var previous_work_info: Node = global.get("work_list_info_canvas")
		var work_info_spy := WorkInfoSpy.new()
		work_info_spy.visible = false
		root.add_child(work_info_spy)
		global.set("work_list_info_canvas", work_info_spy)
		var selection := {"count": 0, "task_id": 0, "title": ""}
		item_nodes[1].connect("unconfigured_task_selected",
			func(task_id: int, task_title: String) -> void:
				selection["count"] = int(selection["count"]) + 1
				selection["task_id"] = task_id
				selection["title"] = task_title
		)
		item_nodes[1].emit_signal("pressed")
		if work_info_spy.visible or work_info_spy.refresh_count != 0:
			failures.append("Selecting an unconfigured task must not open or refresh task steps.")
		if int(selection["count"]) != 1 or int(selection["task_id"]) != 2 \
		or str(selection["title"]) != (tasks[1] as WorkListData).title:
			failures.append("Selecting an unconfigured task must emit the explicit rejection signal.")
		global.set("work_list_info_canvas", previous_work_info)
		work_info_spy.queue_free()

	view.queue_free()
	await process_frame
	if failures.is_empty():
		print("WORK_LIST_BASELINE_SELF_TEST PASS")
		quit(0)
		return
	_failures_and_quit(failures)


func _failures_and_quit(failures: PackedStringArray) -> void:
	for failure in failures:
		push_error("WORK_LIST_BASELINE_SELF_TEST: %s" % failure)
	quit(1)
