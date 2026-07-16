extends SceneTree

const VIEW_PATH := "res://Assets/ARSpace/Scripts/WorkListCanvas/WorkListUIView.gd"
const ITEM_PATH := "res://Assets/ARSpace/Scripts/WorkListCanvas/WorkListItem.gd"


func _initialize() -> void:
	var failures: PackedStringArray = []
	var view_source := FileAccess.get_file_as_string(VIEW_PATH)
	var item_source := FileAccess.get_file_as_string(ITEM_PATH)
	var task_pattern := RegEx.new()
	task_pattern.compile("da_result\\.list\\.append\\(WorkListData\\.new\\((\\d+)")
	var task_matches := task_pattern.search_all(view_source)
	if task_matches.size() != 5:
		failures.append("The Unity baseline must expose exactly tasks 1-5; tasks 6-8 must be absent.")
	for index in range(task_matches.size()):
		var task_id := int(task_matches[index].get_string(1))
		if task_id != index + 1:
			failures.append("Task ids must stay consecutive from 1 through 5.")
	if view_source.count("info_data_result.list.append(WorkListInfoData.new(") != 20:
		failures.append("Task 1 must remain configured with exactly 20 steps.")
	if view_source.count("\t\tfalse\n\t))") != 4:
		failures.append("Tasks 2-5 must remain explicit unconfigured placeholders.")
	if not item_source.contains("if not item_data.is_configured:") \
	or not item_source.contains("未配置"):
		failures.append("Selecting a placeholder must report that the task is unconfigured.")
	for removed_id in range(6, 9):
		if view_source.contains("WorkListData.new(%d," % removed_id):
			failures.append("Task %d must not be present in the active Godot catalog." % removed_id)

	if failures.is_empty():
		print("WORK_LIST_BASELINE_SELF_TEST PASS")
		quit(0)
		return
	for failure in failures:
		push_error("WORK_LIST_BASELINE_SELF_TEST: %s" % failure)
	quit(1)
