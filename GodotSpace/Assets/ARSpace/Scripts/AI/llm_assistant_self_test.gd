extends SceneTree

const AssistantScript := preload("res://Assets/ARSpace/Scripts/AI/llm_assistant.gd")

class FakeVoiceChat:
	extends Node
	signal voice_transcript_received(data: Dictionary)


var _completed := false
var _failed := false
var _final_transcript_seen := false
var _task_context_completed := false

func _init() -> void:
	var assistant := AssistantScript.new()
	root.add_child(assistant)
	assistant.endpoint_url = ""
	assistant.api_key = ""
	assistant.api_key_environment_name = ""
	assistant.require_wake_word = true
	assistant.wake_words = PackedStringArray(["助手"])
	assistant.call("_setup_knowledge_base")
	assistant.call("_setup_http_request")
	var knowledge_count := int(assistant.call("get_knowledge_entry_count"))
	print("knowledge_count=%d" % knowledge_count)
	if knowledge_count < 9:
		push_error("LLM assistant knowledge base did not load JSON and text documents.")
		quit(1)
		return
	if not _verify_external_knowledge_directory(assistant):
		push_error("LLM assistant did not load external recursive knowledge directories.")
		quit(1)
		return

	assistant.answer_completed.connect(func(question: String, answer: String, sources: Array) -> void:
		print("answer_completed question=%s answer_len=%d sources=%d" % [question, answer.length(), sources.size()])
		if question.find("氧气分压") != -1:
			_completed = not answer.strip_edges().is_empty() and not sources.is_empty()
		if question.find("样品盒") != -1:
			_task_context_completed = not answer.strip_edges().is_empty() and _has_source(sources, "当前专家任务指导")
	)
	assistant.answer_failed.connect(func(question: String, message: String) -> void:
		print("answer_failed question=%s message=%s" % [question, message])
		_failed = true
	)
	assistant.final_transcript_received.connect(func(_speaker: String, text: String) -> void:
		_final_transcript_seen = text.find("氧气分压") != -1
	)

	var fake_voice_chat := FakeVoiceChat.new()
	root.add_child(fake_voice_chat)
	assistant.call("connect_voice_chat", fake_voice_chat)
	assistant.call("set_listening", true)
	fake_voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手 氧气分压缓慢下降时优先检查什么",
		"is_final": true,
		"timestamp_msec": 0,
	})

	if _failed or not _completed or not _final_transcript_seen:
		push_error("LLM assistant self test failed.")
		quit(1)
		return
	var state_after_first_answer: Dictionary = assistant.call("get_debug_state")
	if int(state_after_first_answer.get("conversation_turn_count", 0)) < 2:
		push_error("LLM assistant did not keep recent conversation history.")
		quit(1)
		return

	assistant.call("set_runtime_context_entries", [{
		"id": "current-task-test",
		"title": "样品盒拆装任务",
		"source": "当前专家任务指导",
		"tags": ["当前任务", "专家指导", "样品盒", "断电"],
		"content": "当前任务：样品盒拆装。步骤：1. 复述专家口令；2. 确认实验柜断电；3. 确认防静电手环佩戴有效；4. 核对工具规格和目标力矩。",
	}])
	fake_voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手 样品盒拆装前需要确认什么",
		"is_final": true,
		"timestamp_msec": 1,
	})

	if _failed or not _task_context_completed:
		push_error("LLM assistant task context self test failed.")
		quit(1)
		return

	print("LLM assistant self test passed.")
	quit(0)


func _has_source(sources: Array, source_name: String) -> bool:
	for source in sources:
		if typeof(source) == TYPE_DICTIONARY and str((source as Dictionary).get("source", "")).find(source_name) != -1:
			return true
	return false


func _verify_external_knowledge_directory(assistant: Node) -> bool:
	var base_dir := "user://llm_knowledge_self_test"
	var nested_dir := base_dir.path_join("manuals")
	DirAccess.make_dir_recursive_absolute(nested_dir)
	var file_path := nested_dir.path_join("external_field_note.txt")
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("现场外部知识条目\n\n外部手册要求：进行外部知识测试时，应确认递归目录已被智能助手加载。")
	file.close()

	assistant.knowledge_base_directory = "res://Assets/ARSpace/Data/Knowledge"
	assistant.additional_knowledge_directories = PackedStringArray([base_dir])
	assistant.knowledge_base.additional_knowledge_directories = PackedStringArray([base_dir])
	assistant.knowledge_base.call("load_entries")
	var results: Array = assistant.knowledge_base.call("search", "外部知识测试 递归目录", 5)
	var summary: Dictionary = assistant.knowledge_base.call("get_source_summary")
	var static_sources: Dictionary = summary.get("static_sources", {}) if typeof(summary.get("static_sources", {})) == TYPE_DICTIONARY else {}
	var source_seen := false
	for source in static_sources.keys():
		if str(source).find("external_field_note.txt") != -1:
			source_seen = true
	for item in results:
		if source_seen and typeof(item) == TYPE_DICTIONARY and str((item as Dictionary).get("content", "")).find("递归目录") != -1:
			return true
	return false
