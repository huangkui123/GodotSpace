extends SceneTree

const FIXTURE_PATH := "res://Assets/ARSpace/Scripts/AI/LocalAgent/task_intent_v1.json"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var router := root.get_node_or_null("AssistantCommandRouter")
	if router == null:
		_fail("AssistantCommandRouter autoload is missing.")
		return
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.READ)
	if file == null:
		_fail("Unable to open task_intent_v1 fixture.")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("task_intent_v1 is not valid JSON.")
		return
	var cases: Array = (parsed as Dictionary).get("cases", [])
	if cases.size() < 100:
		_fail("task_intent_v1 must contain at least 100 cases, found %d." % cases.size())
		return

	var failures: Array[String] = []
	var write_count := 0
	var unauthorized_write_count := 0
	for case_value in cases:
		if typeof(case_value) != TYPE_DICTIONARY:
			failures.append("non-dictionary case")
			continue
		var case := case_value as Dictionary
		var text := str(case.get("text", ""))
		var expected := str(case.get("expected", ""))
		var actual := str(router.classify_text(text))
		if actual == "ADVANCE_STEP":
			write_count += 1
		if expected == "NO_WRITE":
			if actual == "ADVANCE_STEP":
				unauthorized_write_count += 1
				failures.append("unauthorized write: %s" % text)
		elif actual != expected:
			failures.append("%s expected %s, got %s" % [text, expected, actual])

	if not failures.is_empty():
		_fail("Intent regression failures (%d): %s" % [failures.size(), "; ".join(failures.slice(0, 8))])
		return
	if unauthorized_write_count != 0:
		_fail("Unauthorized write rate was %d/%d." % [unauthorized_write_count, cases.size()])
		return
	print("Task intent regression passed: %d cases, %d authorized writes, 0 unauthorized writes." % [cases.size(), write_count])
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
