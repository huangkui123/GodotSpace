extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/MainMenuCanvasAR2D.tscn")
	if scene == null:
		_fail("Unable to load MainMenuCanvasAR2D scene.")
		return

	var scene_root := scene.instantiate()
	root.add_child(scene_root)
	await process_frame

	var canvas := scene_root.get_node_or_null("Canvas")
	if canvas == null:
		_fail("Main menu scene missing Canvas node.")
		return
	if not canvas.has_method("_on_llm_assistant_pressed"):
		_fail("Main menu Canvas missing LLM assistant open handler.")
		return
	if not canvas.has_method("_on_llm_back_button_pressed"):
		_fail("Main menu Canvas missing LLM assistant back handler.")
		return

	var work_list_view := canvas.get_node_or_null("WorkTabView/WorkListView")
	if work_list_view == null or not work_list_view.has_method("get_task_context_entries"):
		_fail("Main menu missing task catalog provider for LLM assistant.")
		return

	var assistant_button := canvas.get_node_or_null("WorkTabView/GridContainer/LLMAssistant")
	if assistant_button == null:
		_fail("Main menu missing LLM assistant entry button.")
		return

	var assistant_view := canvas.get_node_or_null("WorkTabView/LLMAssistantView")
	if assistant_view == null or not assistant_view.has_method("start_assistant"):
		_fail("Main menu missing LLM assistant view.")
		return
	var assistant := root.get_node_or_null("LLMAssistantService")
	if assistant == null:
		_fail("LLMAssistantService autoload is unavailable.")
		return
	var state: Dictionary = assistant.call("get_debug_state")
	if not bool(state.get("listening", false)):
		_fail("LLM assistant service should listen before opening the history panel.")
		return

	canvas.call("_on_llm_assistant_pressed")
	if not assistant_view.visible:
		_fail("Main menu did not show assistant view from entry button handler.")
		return
	state = assistant.call("get_debug_state")
	if not bool(state.get("listening", false)):
		_fail("Main menu history panel should not stop assistant listening.")
		return

	canvas.call("_on_llm_back_button_pressed")
	state = assistant.call("get_debug_state")
	if assistant_view.visible or not bool(state.get("listening", false)):
		_fail("Main menu back handler should hide history without stopping assistant service.")
		return

	print("LLM assistant menu entry self test passed.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
