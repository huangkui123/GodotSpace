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
	for case_value in cases:
		if typeof(case_value) != TYPE_DICTIONARY:
			failures.append("non-dictionary case")
			continue
		var case := case_value as Dictionary
		var text := str(case.get("text", ""))
		var actual := str(router.classify_text(text))
		if actual != "QWEN_FIRST":
			failures.append("keyword routing was still active for: %s" % text)

	if not failures.is_empty():
		_fail("Intent regression failures (%d): %s" % [failures.size(), "; ".join(failures.slice(0, 8))])
		return
	print("Qwen-first routing regression passed: %d legacy keyword cases did not grant write permission." % cases.size())
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
