extends SceneTree

const AssistantScript := preload("res://Assets/ARSpace/Scripts/AI/llm_assistant.gd")

var _answer_completed := false
var _sources: Array = []
var _failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_assert_project_settings()
	if _failed:
		return
	_assert_voice_chat_contract()
	if _failed:
		return
	_assert_main_menu_entry()
	if _failed:
		return
	_assert_task_detail_entry()
	if _failed:
		return
	await _assert_assistant_runtime_chain()
	if _failed:
		return

	print("LLM assistant feature audit self test passed.")
	quit(0)


func _assert_project_settings() -> void:
	if str(ProjectSettings.get_setting("arspace/llm_assistant/endpoint_url", "")).strip_edges().is_empty():
		_fail("Missing LLM endpoint project setting.")
	if str(ProjectSettings.get_setting("arspace/llm_assistant/model", "")).strip_edges().is_empty():
		_fail("Missing LLM model project setting.")
	if str(ProjectSettings.get_setting("arspace/llm_assistant/api_key_environment_name", "")).strip_edges().is_empty():
		_fail("Missing LLM API key environment setting.")

	var directories: Variant = ProjectSettings.get_setting("arspace/llm_assistant/knowledge_directories", PackedStringArray())
	if typeof(directories) != TYPE_PACKED_STRING_ARRAY or not (directories as PackedStringArray).has("res://Assets/ARSpace/Data/Knowledge"):
		_fail("Knowledge directory project setting does not include bundled assistant knowledge.")


func _assert_voice_chat_contract() -> void:
	var voice_chat := root.get_node_or_null("VoiceChat")
	if voice_chat == null:
		_fail("VoiceChat autoload is missing.")
	if not voice_chat.has_signal("voice_transcript_received"):
		_fail("VoiceChat does not expose voice_transcript_received.")
	if not voice_chat.has_method("get_transcript_history"):
		_fail("VoiceChat does not expose transcript history for assistant UI.")
	if not voice_chat.has_method("get_debug_state"):
		_fail("VoiceChat does not expose debug state for assistant diagnostics.")


func _assert_main_menu_entry() -> void:
	var scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/MainMenuCanvasAR2D.tscn")
	if scene == null:
		_fail("MainMenuCanvasAR2D scene does not load.")
	var scene_root := scene.instantiate()
	root.add_child(scene_root)
	var canvas := scene_root.get_node_or_null("Canvas")
	if canvas == null:
		_fail("Main menu scene missing Canvas node.")
	if canvas.get_node_or_null("WorkTabView/GridContainer/LLMAssistant") == null:
		_fail("Main menu scene missing assistant entry button.")
	if canvas.get_node_or_null("WorkTabView/LLMAssistantView") == null:
		_fail("Main menu scene missing assistant view.")
	if not canvas.has_method("_on_llm_assistant_pressed"):
		_fail("Main menu scene missing assistant open handler.")
	scene_root.queue_free()


func _assert_task_detail_entry() -> void:
	var scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn")
	if scene == null:
		_fail("WorkListInfoCanvas scene does not load.")
	var scene_root := scene.instantiate()
	root.add_child(scene_root)
	var canvas := scene_root.get_node_or_null("Canvas")
	if canvas == null:
		_fail("Task detail scene missing Canvas node.")
	if canvas.get_node_or_null("TopMenuBox/Controller/AssistantButton") == null:
		_fail("Task detail scene missing assistant button.")
	if canvas.get_node_or_null("LLMAssistantView") == null:
		_fail("Task detail scene missing assistant view.")
	if not canvas.has_method("get_current_task_context_entries"):
		_fail("Task detail UI does not expose current task context for assistant.")
	scene_root.queue_free()


func _assert_assistant_runtime_chain() -> void:
	var assistant := AssistantScript.new()
	root.add_child(assistant)
	await process_frame
	assistant.endpoint_url = ""
	assistant.api_key = ""
	assistant.api_key_environment_name = ""
	assistant.require_wake_word = false
	assistant.use_local_fallback_when_unconfigured = true

	var state: Dictionary = assistant.call("get_debug_state")
	if not bool(state.get("voice_connected", false)):
		_fail("Assistant did not connect to VoiceChat autoload.")
	if int(state.get("knowledge_entry_count", 0)) < 9:
		_fail("Assistant did not load bundled manual and domain knowledge.")

	var entries: Array = assistant.knowledge_base.call("get_entries_snapshot")
	if not _has_entry_id(entries, "manual-env-oxygen-pressure-drop"):
		_fail("Astronaut manual oxygen entry is missing from knowledge base.")
	if not _has_entry_id(entries, "manual-sample-box-precheck"):
		_fail("Professional sample-box entry is missing from knowledge base.")
	if not _has_entry_id(entries, "domain-expert-call-before-power-sensitive-action"):
		_fail("Domain expert guidance entry is missing from knowledge base.")
	if not _has_entry_id(entries, "astronaut_manual_excerpt#1"):
		_fail("Astronaut manual text document is missing from knowledge base.")

	assistant.call("set_runtime_context_entries", [{
		"id": "audit-current-task",
		"title": "Current expert task",
		"source": "Current expert task guidance",
		"tags": ["audit", "task"],
		"content": "Before sample box removal, confirm power isolation, anti-static grounding, tool specification, and expert authorization.",
	}])
	assistant.call("set_listening", true)
	assistant.answer_completed.connect(func(_question: String, _answer: String, sources: Array) -> void:
		_answer_completed = true
		_sources = sources.duplicate(true)
	)

	var voice_chat := root.get_node_or_null("VoiceChat")
	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "Crew",
		"text": "What should I confirm before sample box removal?",
		"is_final": true,
		"timestamp_msec": 10,
	})
	await process_frame

	if not _answer_completed:
		_fail("Assistant did not answer a final VoiceChat transcript.")
	if not _has_source(_sources, "Current expert task guidance"):
		_fail("Assistant answer did not include current expert task guidance source.")

	assistant.queue_free()


func _has_entry_id(entries: Array, entry_id: String) -> bool:
	for entry in entries:
		if typeof(entry) == TYPE_DICTIONARY and str((entry as Dictionary).get("id", "")) == entry_id:
			return true
	return false


func _has_source(sources: Array, source_name: String) -> bool:
	for source in sources:
		if typeof(source) == TYPE_DICTIONARY and str((source as Dictionary).get("source", "")) == source_name:
			return true
	return false


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	push_error(message)
	quit(1)
