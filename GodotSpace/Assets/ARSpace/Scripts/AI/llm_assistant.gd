class_name LLMAssistant
extends Node

signal answer_started(question: String)
signal answer_completed(question: String, answer: String, sources: Array)
signal answer_failed(question: String, message: String)
signal delegated_answer_completed(request_id: String, answer: String)
signal delegated_answer_failed(request_id: String, message: String)
signal partial_transcript_received(speaker: String, text: String)
signal final_transcript_received(speaker: String, text: String)
signal qa_history_changed()

const KnowledgeBaseScript := preload("res://Assets/ARSpace/Scripts/AI/llm_knowledge_base.gd")
const SETTING_ENDPOINT_URL := "arspace/llm_assistant/endpoint_url"
const SETTING_MODEL := "arspace/llm_assistant/model"
const SETTING_API_KEY_ENVIRONMENT_NAME := "arspace/llm_assistant/api_key_environment_name"
const SETTING_REQUIRE_WAKE_WORD := "arspace/llm_assistant/require_wake_word"
const SETTING_WAKE_WORDS := "arspace/llm_assistant/wake_words"
const SETTING_MAX_CONTEXT_ENTRIES := "arspace/llm_assistant/max_context_entries"
const SETTING_USE_LOCAL_FALLBACK := "arspace/llm_assistant/use_local_fallback_when_unconfigured"
const SETTING_KNOWLEDGE_BASE_PATH := "arspace/llm_assistant/knowledge_base_path"
const SETTING_KNOWLEDGE_DIRECTORIES := "arspace/llm_assistant/knowledge_directories"
const SETTING_MAX_CONVERSATION_TURNS := "arspace/llm_assistant/max_conversation_turns"
const LLM_CALL_LOG_DIRECTORY := "user://llm_assistant_logs"
const LLM_CALL_LOG_PATH := "user://llm_assistant_logs/deepseek_calls.jsonl"

@export_group("Knowledge")
@export_file("*.json") var knowledge_base_path: String = "res://Assets/ARSpace/Data/llm_knowledge_base.json"
@export_dir var knowledge_base_directory: String = "res://Assets/ARSpace/Data/Knowledge"
@export var additional_knowledge_directories: PackedStringArray = PackedStringArray(["res://Assets/StreamingAssets/Knowledge", "user://llm_knowledge"])
@export_range(1, 12, 1) var max_context_entries: int = 5

@export_group("LLM")
@export var endpoint_url: String = "https://api.openai.com/v1/chat/completions"
@export var model: String = "gpt-4.1-mini"
@export var api_key: String = ""
@export var api_key_environment_name: String = "OPENAI_API_KEY"
@export_range(0.0, 1.0, 0.05) var temperature: float = 0.2
@export_range(256, 4096, 64) var max_tokens: int = 700
@export var use_local_fallback_when_unconfigured: bool = true

@export_group("Voice Trigger")
@export var auto_answer_final_transcripts: bool = true
@export var require_wake_word: bool = true
@export var wake_words: PackedStringArray = ["助手", "智能助手", "LLM"]
@export var listen_on_ready: bool = true
@export_range(0, 12, 1) var max_conversation_turns: int = 6
@export_range(1, 80, 1) var max_qa_history_items: int = 20

var knowledge_base: Node
var _http_request: HTTPRequest
var _voice_chat: Node
var _active_question := ""
var _active_sources: Array = []
var _active_conversation_context := ""
var _pending_questions: Array[Dictionary] = []
var _conversation_history: Array[Dictionary] = []
var _qa_history: Array[Dictionary] = []
var _listening_enabled := false
var _active_request_log_id := ""
var _active_request_started_msec := 0
var _external_transcript_router_enabled := false
var _active_delegate_request_id := ""
var _active_record_history := true
var _external_qa_request_ids: Dictionary = {}


func _ready() -> void:
	_apply_project_settings()
	_setup_knowledge_base()
	_setup_http_request()
	connect_voice_chat()
	set_listening(listen_on_ready)


func connect_voice_chat(voice_chat: Node = null) -> void:
	if _voice_chat != null and is_instance_valid(_voice_chat):
		var callback := Callable(self, "_on_voice_transcript_received")
		if _voice_chat.has_signal("voice_transcript_received") \
				and _voice_chat.is_connected("voice_transcript_received", callback):
			_voice_chat.disconnect("voice_transcript_received", callback)

	if voice_chat == null and not is_inside_tree():
		return
	_voice_chat = voice_chat if voice_chat != null else get_node_or_null("/root/VoiceChat")
	if _voice_chat == null:
		return
	var callback := Callable(self, "_on_voice_transcript_received")
	if _voice_chat.has_signal("voice_transcript_received") \
			and not _voice_chat.is_connected("voice_transcript_received", callback):
		_voice_chat.connect("voice_transcript_received", callback)


func set_listening(enabled: bool) -> void:
	_listening_enabled = enabled
	if enabled and (_voice_chat == null or not is_instance_valid(_voice_chat)):
		connect_voice_chat()


func is_listening() -> bool:
	return _listening_enabled


func set_runtime_context_entries(entries: Array) -> void:
	if knowledge_base != null and knowledge_base.has_method("set_runtime_entries"):
		knowledge_base.call("set_runtime_entries", entries)


func get_knowledge_entry_count() -> int:
	return int(knowledge_base.call("get_entry_count")) if knowledge_base != null and knowledge_base.has_method("get_entry_count") else 0


func get_debug_state() -> Dictionary:
	return {
		"knowledge_entry_count": get_knowledge_entry_count(),
		"knowledge_last_error": str(knowledge_base.call("get_last_error")) if knowledge_base != null and knowledge_base.has_method("get_last_error") else "",
		"knowledge_base_path": knowledge_base_path,
		"knowledge_directories": _get_configured_knowledge_directories(),
		"knowledge_source_summary": knowledge_base.call("get_source_summary") if knowledge_base != null and knowledge_base.has_method("get_source_summary") else {},
		"voice_connected": _voice_chat != null and is_instance_valid(_voice_chat),
		"listening": _listening_enabled,
		"require_wake_word": require_wake_word,
		"wake_words": wake_words,
		"endpoint_configured": not endpoint_url.strip_edges().is_empty(),
		"model": model,
		"api_key_configured": not _get_api_key().is_empty(),
		"local_fallback_enabled": use_local_fallback_when_unconfigured,
		"active_question": _active_question,
		"pending_question_count": _pending_questions.size(),
		"conversation_turn_count": _conversation_history.size(),
		"qa_history_count": _qa_history.size(),
		"voice_debug": _get_voice_debug_state(),
	}


func ask(question: String) -> void:
	var clean_question := question.strip_edges()
	if clean_question.is_empty():
		return

	var sources := _search_sources(clean_question)
	_append_conversation_turn("user", "提问", clean_question)
	var conversation_context := _format_conversation_history()
	if _active_question != "":
		_pending_questions.append({
			"question": clean_question,
			"sources": sources,
			"conversation_context": conversation_context,
		})
		return

	_begin_question(clean_question, sources, conversation_context)


func request_delegated_answer(
	request_id: String,
	question: String,
	runtime_entries: Array[Dictionary] = [],
	record_history: bool = true
) -> void:
	var clean_request_id := request_id.strip_edges()
	var clean_question := question.strip_edges()
	if clean_request_id.is_empty() or clean_question.is_empty():
		return
	var sources := _search_sources(clean_question)
	for entry in runtime_entries:
		if typeof(entry) == TYPE_DICTIONARY:
			sources.append(entry)
	if _active_question != "":
		_pending_questions.append({
			"question": clean_question,
			"sources": sources,
			"conversation_context": "",
			"delegate_request_id": clean_request_id,
			"record_history": record_history,
		})
		return
	_begin_question(clean_question, sources, "", clean_request_id, record_history)


func _begin_question(
	clean_question: String,
	sources: Array,
	conversation_context: String,
	delegate_request_id: String = "",
	record_history: bool = true
) -> void:
	_active_question = clean_question
	_active_sources = sources.duplicate(true)
	_active_conversation_context = conversation_context
	_active_delegate_request_id = delegate_request_id
	_active_record_history = record_history
	answer_started.emit(clean_question)

	var api_key_value := _get_api_key()
	if endpoint_url.strip_edges().is_empty() or model.strip_edges().is_empty() or api_key_value.is_empty():
		if use_local_fallback_when_unconfigured:
			_complete_with_local_fallback(clean_question, _active_sources)
		else:
			_fail_active_question("LLM 服务未配置。请设置 OPENAI_API_KEY 或在节点上配置 endpoint_url/api_key。")
		return

	var request_body := _build_chat_completion_request(clean_question, _active_sources, _active_conversation_context)
	_active_request_log_id = _new_llm_call_log_id()
	_active_request_started_msec = Time.get_ticks_msec()
	_log_llm_call({
		"event": "request",
		"id": _active_request_log_id,
		"timestamp": Time.get_datetime_string_from_system(false, true),
		"endpoint_url": endpoint_url,
		"model": model,
		"question": clean_question,
		"sources": _summarize_sources_for_log(_active_sources),
		"request_body": request_body,
	})
	var headers := [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key_value,
	]
	var error := _http_request.request(endpoint_url, headers, HTTPClient.METHOD_POST, JSON.stringify(request_body))
	if error != OK:
		_log_llm_call({
			"event": "error",
			"id": _active_request_log_id,
			"timestamp": Time.get_datetime_string_from_system(false, true),
			"endpoint_url": endpoint_url,
			"model": model,
			"question": clean_question,
			"error_stage": "request_start",
			"error": error_string(error),
		})
		_fail_active_question("LLM 请求启动失败：%s" % error_string(error))


func _new_llm_call_log_id() -> String:
	return "%d-%d" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]


func _log_llm_call(record: Dictionary) -> void:
	var make_dir_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LLM_CALL_LOG_DIRECTORY))
	if make_dir_error != OK:
		push_warning("Unable to create LLM call log directory: %s" % error_string(make_dir_error))
		return

	var file: FileAccess = null
	if FileAccess.file_exists(LLM_CALL_LOG_PATH):
		file = FileAccess.open(LLM_CALL_LOG_PATH, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(LLM_CALL_LOG_PATH, FileAccess.WRITE)

	if file == null:
		push_warning("Unable to open LLM call log file: %s" % LLM_CALL_LOG_PATH)
		return

	file.store_line(JSON.stringify(record))
	file.close()


func _summarize_sources_for_log(sources: Array) -> Array:
	var summary: Array = []
	for source in sources:
		if typeof(source) != TYPE_DICTIONARY:
			continue
		var item := source as Dictionary
		summary.append({
			"id": str(item.get("id", "")),
			"title": str(item.get("title", "")),
			"source": str(item.get("source", "")),
			"score": float(item.get("score", 0.0)),
		})
	return summary


func _search_sources(question: String) -> Array:
	return knowledge_base.call("search", question, max_context_entries) if knowledge_base != null and knowledge_base.has_method("search") else []


func _get_voice_debug_state() -> Dictionary:
	if _voice_chat == null or not is_instance_valid(_voice_chat):
		return {}
	if not _voice_chat.has_method("get_debug_state"):
		return {}
	var state: Dictionary = _voice_chat.call("get_debug_state")
	var transcription: Dictionary = state.get("transcription", {}) if typeof(state.get("transcription", {})) == TYPE_DICTIONARY else {}
	return {
		"voice_enabled": bool(state.get("voice_enabled", false)),
		"voice_endpoint_selected": bool(state.get("voice_endpoint_selected", false)),
		"network_role": str(state.get("network_role", "")),
		"transcription_enabled": bool(state.get("transcription_enabled", false)),
		"transcription_active_peer_count": int(transcription.get("active_peer_count", 0)),
		"transcription_last_error": str(transcription.get("last_error_message", "")),
	}


func cancel_pending_requests() -> void:
	_pending_questions.clear()
	_active_question = ""
	_active_sources = []
	_active_conversation_context = ""
	_active_request_log_id = ""
	_active_request_started_msec = 0
	if _http_request != null and _http_request.has_method("cancel_request"):
		_http_request.call("cancel_request")


func submit_transcript_data(data: Dictionary) -> void:
	_handle_transcript_data(data, false)


func set_external_transcript_router_enabled(enabled: bool) -> void:
	_external_transcript_router_enabled = enabled


func get_qa_history() -> Array:
	return _qa_history.duplicate(true)


func record_external_qa(
	request_id: String,
	question: String,
	answer: String,
	success: bool,
	metadata: Dictionary = {}
) -> bool:
	var clean_request_id := request_id.strip_edges()
	if clean_request_id.is_empty() or _external_qa_request_ids.has(clean_request_id):
		return false
	_external_qa_request_ids[clean_request_id] = true
	while _external_qa_request_ids.size() > max_qa_history_items * 4:
		_external_qa_request_ids.erase(_external_qa_request_ids.keys().front())
	_record_qa_item(question, answer, [], success, metadata)
	return true


func _setup_knowledge_base() -> void:
	knowledge_base = KnowledgeBaseScript.new()
	knowledge_base.name = "KnowledgeBase"
	knowledge_base.knowledge_base_path = knowledge_base_path
	knowledge_base.knowledge_base_directory = knowledge_base_directory
	knowledge_base.additional_knowledge_directories = additional_knowledge_directories
	knowledge_base.max_results = max_context_entries
	add_child(knowledge_base)
	if knowledge_base.has_method("load_entries"):
		knowledge_base.call("load_entries")


func _apply_project_settings() -> void:
	knowledge_base_path = str(ProjectSettings.get_setting(SETTING_KNOWLEDGE_BASE_PATH, knowledge_base_path)).strip_edges()
	endpoint_url = str(ProjectSettings.get_setting(SETTING_ENDPOINT_URL, endpoint_url)).strip_edges()
	model = str(ProjectSettings.get_setting(SETTING_MODEL, model)).strip_edges()
	api_key_environment_name = str(ProjectSettings.get_setting(SETTING_API_KEY_ENVIRONMENT_NAME, api_key_environment_name)).strip_edges()
	require_wake_word = bool(ProjectSettings.get_setting(SETTING_REQUIRE_WAKE_WORD, require_wake_word))
	max_context_entries = int(ProjectSettings.get_setting(SETTING_MAX_CONTEXT_ENTRIES, max_context_entries))
	use_local_fallback_when_unconfigured = bool(ProjectSettings.get_setting(SETTING_USE_LOCAL_FALLBACK, use_local_fallback_when_unconfigured))
	max_conversation_turns = int(ProjectSettings.get_setting(SETTING_MAX_CONVERSATION_TURNS, max_conversation_turns))

	var configured_wake_words = ProjectSettings.get_setting(SETTING_WAKE_WORDS, wake_words)
	if typeof(configured_wake_words) == TYPE_PACKED_STRING_ARRAY:
		wake_words = configured_wake_words
	elif typeof(configured_wake_words) == TYPE_ARRAY:
		var words := PackedStringArray()
		for word in configured_wake_words:
			words.append(str(word))
		wake_words = words

	var configured_directories = ProjectSettings.get_setting(SETTING_KNOWLEDGE_DIRECTORIES, _get_configured_knowledge_directories())
	var directories := _packed_string_array_from_variant(configured_directories)
	if not directories.is_empty():
		knowledge_base_directory = directories[0]
		additional_knowledge_directories = PackedStringArray()
		for index in range(1, directories.size()):
			additional_knowledge_directories.append(directories[index])


func _get_configured_knowledge_directories() -> PackedStringArray:
	var directories := PackedStringArray()
	if not knowledge_base_directory.strip_edges().is_empty():
		directories.append(knowledge_base_directory)
	for directory_path in additional_knowledge_directories:
		var clean_path := str(directory_path).strip_edges()
		if not clean_path.is_empty() and not directories.has(clean_path):
			directories.append(clean_path)
	return directories


func _packed_string_array_from_variant(value: Variant) -> PackedStringArray:
	if typeof(value) == TYPE_PACKED_STRING_ARRAY:
		return value
	var result := PackedStringArray()
	if typeof(value) != TYPE_ARRAY:
		return result
	for item in value:
		var text := str(item).strip_edges()
		if not text.is_empty():
			result.append(text)
	return result


func _setup_http_request() -> void:
	_http_request = HTTPRequest.new()
	_http_request.name = "LLMHttpRequest"
	_http_request.timeout = 45.0
	add_child(_http_request)
	_http_request.request_completed.connect(_on_http_request_completed)


func _on_voice_transcript_received(data: Dictionary) -> void:
	if _external_transcript_router_enabled:
		return
	_handle_transcript_data(data, true)


func _handle_transcript_data(data: Dictionary, require_listening: bool) -> void:
	if str(data.get("source", "")) == "llm_assistant":
		return
	if require_listening and not _listening_enabled:
		return
	var speaker := str(data.get("speaker_name", "语音"))
	var text := str(data.get("text", "")).strip_edges()
	if text.is_empty():
		return

	if bool(data.get("is_final", false)):
		final_transcript_received.emit(speaker, text)
		if auto_answer_final_transcripts and _should_answer(text):
			var question := _strip_wake_word(text)
			_append_conversation_turn("user", speaker, question)
			ask(question)
		else:
			_append_conversation_turn("user", speaker, text)
	else:
		partial_transcript_received.emit(speaker, text)


func _should_answer(text: String) -> bool:
	if not require_wake_word:
		return true
	for word in wake_words:
		if text.find(str(word)) != -1:
			return true
	return false


func _strip_wake_word(text: String) -> String:
	var result := text.strip_edges()
	for word in wake_words:
		var wake_word := str(word)
		if result.begins_with(wake_word):
			result = result.substr(wake_word.length()).strip_edges()
	return result


func _build_chat_completion_request(question: String, sources: Array, conversation_context: String) -> Dictionary:
	var context := _format_sources_for_prompt(sources)
	var conversation := conversation_context.strip_edges()
	if conversation.is_empty():
		conversation = "暂无近期对话。"
	return {
		"model": model,
		"temperature": temperature,
		"max_tokens": max_tokens,
		"messages": [
			{
				"role": "system",
				"content": "你是航天任务专家指导场景中的智能助手。只根据给定的航天员手册、专业领域知识和当前任务上下文回答；结论要简洁、可执行，并给出来源条目。涉及风险时先提示复核传感器、确认状态、升级上报，不要编造手册外事实。没有足够依据时明确要求专家席确认。",
			},
			{
				"role": "system",
				"content": "Output plain text only. Do not use Markdown, code fences, tables, headings with #, bold, italics, block quotes, or bullet symbols. Write for a simple plain-text dialog box. Use short paragraphs. If steps are needed, use simple numbered lines like 1. 2. 3. Keep each line concise and readable.",
			},
			{
				"role": "user",
				"content": "可用知识：\n%s\n\n近期对话：\n%s\n\n航天员/专家语音问题：%s" % [context, conversation, question],
			},
		],
	}


func _format_sources_for_prompt(sources: Array) -> String:
	if sources.is_empty():
		return "暂无命中的本地知识条目。"

	var lines: Array[String] = []
	for index in range(sources.size()):
		var source: Dictionary = sources[index]
		lines.append("%d. 来源：%s；标题：%s\n%s" % [
			index + 1,
			str(source.get("source", "知识库")),
			str(source.get("title", "未命名条目")),
			str(source.get("content", "")),
		])
	return "\n\n".join(lines)


func _append_conversation_turn(role: String, speaker: String, text: String) -> void:
	var clean_text := text.strip_edges()
	if clean_text.is_empty() or max_conversation_turns <= 0:
		return
	if not _conversation_history.is_empty():
		var last := _conversation_history[_conversation_history.size() - 1]
		if str(last.get("role", "")) == role and str(last.get("content", "")) == clean_text:
			return
	_conversation_history.append({
		"role": role,
		"speaker": speaker,
		"content": clean_text.substr(0, 800),
	})
	while _conversation_history.size() > max_conversation_turns:
		_conversation_history.pop_front()


func _record_qa_item(
	question: String,
	answer: String,
	sources: Array,
	success: bool,
	metadata: Dictionary = {}
) -> void:
	var clean_question := question.strip_edges()
	var clean_answer := answer.strip_edges()
	if clean_question.is_empty() and clean_answer.is_empty():
		return
	var item := {
		"question": clean_question,
		"answer": clean_answer,
		"sources": sources.duplicate(true),
		"success": success,
		"timestamp_msec": Time.get_ticks_msec(),
		"timestamp": Time.get_datetime_string_from_system(false, true),
	}
	if not metadata.is_empty():
		item["metadata"] = metadata.duplicate(true)
	_qa_history.append(item)
	while _qa_history.size() > max_qa_history_items:
		_qa_history.pop_front()
	qa_history_changed.emit()


func _publish_assistant_transcript(message: String) -> void:
	var clean_message := message.strip_edges()
	if clean_message.is_empty():
		return
	if _voice_chat == null and not is_inside_tree():
		return
	if _voice_chat == null or not is_instance_valid(_voice_chat):
		connect_voice_chat()
	if _voice_chat == null or not _voice_chat.has_method("publish_assistant_transcript"):
		return
	_voice_chat.call("publish_assistant_transcript", clean_message, "智能助手")


func _format_conversation_history() -> String:
	if _conversation_history.is_empty() or max_conversation_turns <= 0:
		return ""
	var lines: Array[String] = []
	for item in _conversation_history:
		var speaker := str(item.get("speaker", ""))
		var content := str(item.get("content", "")).strip_edges()
		if content.is_empty():
			continue
		lines.append("%s：%s" % [speaker if not speaker.is_empty() else str(item.get("role", "对话")), content])
	return "\n".join(lines)


func _on_http_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _active_question.is_empty():
		return
	var response_body := body.get_string_from_utf8()
	_log_llm_call({
		"event": "response",
		"id": _active_request_log_id,
		"timestamp": Time.get_datetime_string_from_system(false, true),
		"endpoint_url": endpoint_url,
		"model": model,
		"question": _active_question,
		"result": result,
		"response_code": response_code,
		"duration_msec": Time.get_ticks_msec() - _active_request_started_msec,
		"response_body": response_body,
	})
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail_active_question("LLM 请求失败：%s" % result)
		return
	if response_code < 200 or response_code >= 300:
		_fail_active_question("LLM 服务返回 HTTP %d：%s" % [response_code, body.get_string_from_utf8()])
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail_active_question("LLM 响应不是有效 JSON。")
		return

	var content := _format_plain_text_answer(_extract_answer_text(parsed as Dictionary)).strip_edges()
	if content.is_empty():
		_fail_active_question("LLM 响应为空。")
		return

	_complete_active_question(content)


func _extract_answer_text(payload: Dictionary) -> String:
	var choices: Array = payload.get("choices", [])
	if not choices.is_empty() and typeof(choices[0]) == TYPE_DICTIONARY:
		var choice := choices[0] as Dictionary
		var message = choice.get("message", {})
		if typeof(message) == TYPE_DICTIONARY:
			return str((message as Dictionary).get("content", ""))
		return str(choice.get("text", ""))
	return str(payload.get("output_text", ""))


func _format_plain_text_answer(answer: String) -> String:
	var text := answer.replace("\r\n", "\n").replace("\r", "\n").strip_edges()
	text = text.replace("```", "")
	text = text.replace("**", "")
	text = text.replace("__", "")
	text = text.replace("`", "")

	var output_lines: Array[String] = []
	var previous_blank := false
	for raw_line in text.split("\n"):
		var line := str(raw_line).strip_edges()
		line = _strip_markdown_line_prefix(line)
		line = line.replace("[", "").replace("]", "")
		line = line.replace("(", "（").replace(")", "）")
		if line.is_empty():
			if not previous_blank and not output_lines.is_empty():
				output_lines.append("")
			previous_blank = true
			continue
		output_lines.append(line)
		previous_blank = false

	while not output_lines.is_empty() and output_lines[output_lines.size() - 1].is_empty():
		output_lines.pop_back()
	return "\n".join(output_lines)


func _strip_markdown_line_prefix(line: String) -> String:
	while line.begins_with("#"):
		line = line.substr(1).strip_edges()
	while line.begins_with(">"):
		line = line.substr(1).strip_edges()

	var bullet_prefixes := PackedStringArray(["- ", "* ", "+ ", "• "])
	for prefix in bullet_prefixes:
		if line.begins_with(prefix):
			return line.substr(prefix.length()).strip_edges()
	return line


func _complete_with_local_fallback(question: String, sources: Array) -> void:
	var answer := "当前未配置在线 LLM，已使用本地知识库生成建议。\n"
	if sources.is_empty():
		answer += "未检索到相关手册条目，请切换到专家确认流程，并补充问题关键词：%s" % question
	else:
		answer += "问题：%s\n\n建议：\n" % question
		for index in range(min(sources.size(), 3)):
			var source := sources[index] as Dictionary
			answer += "%d. %s\n" % [index + 1, str(source.get("content", ""))]
		answer += "\n依据："
		var labels: Array[String] = []
		for source in sources:
			if typeof(source) != TYPE_DICTIONARY:
				continue
			var item := source as Dictionary
			labels.append("%s / %s" % [str(item.get("source", "知识库")), str(item.get("title", "未命名条目"))])
		answer += "；".join(labels)
	_complete_active_question(answer)


func _complete_active_question(answer: String) -> void:
	var question := _active_question
	var sources := _active_sources.duplicate(true)
	_append_conversation_turn("assistant", "智能助手", answer)
	if _active_record_history:
		_record_qa_item(question, answer, sources, true)
	_active_question = ""
	_active_sources = []
	_active_conversation_context = ""
	_active_request_log_id = ""
	_active_request_started_msec = 0
	var delegate_request_id := _active_delegate_request_id
	_active_delegate_request_id = ""
	_active_record_history = true
	if not delegate_request_id.is_empty():
		delegated_answer_completed.emit(delegate_request_id, answer)
		_start_next_pending_question()
		return
	answer_completed.emit(question, answer, sources)
	_publish_assistant_transcript(answer)
	_start_next_pending_question()


func _fail_active_question(message: String) -> void:
	var question := _active_question
	if _active_record_history:
		_record_qa_item(question, message, [], false)
	_active_question = ""
	_active_sources = []
	_active_conversation_context = ""
	_active_request_log_id = ""
	_active_request_started_msec = 0
	var delegate_request_id := _active_delegate_request_id
	_active_delegate_request_id = ""
	_active_record_history = true
	if not delegate_request_id.is_empty():
		delegated_answer_failed.emit(delegate_request_id, message)
		_start_next_pending_question()
		return
	answer_failed.emit(question, message)
	_publish_assistant_transcript(message)
	_start_next_pending_question()


func _start_next_pending_question() -> void:
	if _pending_questions.is_empty():
		return
	var next_item: Dictionary = _pending_questions.pop_front()
	var next_question := str(next_item.get("question", "")).strip_edges()
	if next_question.is_empty():
		_start_next_pending_question()
		return
	var next_sources = next_item.get("sources", [])
	_begin_question(
		next_question,
		next_sources if typeof(next_sources) == TYPE_ARRAY else [],
		str(next_item.get("conversation_context", "")),
		str(next_item.get("delegate_request_id", "")),
		bool(next_item.get("record_history", true))
	)


func _get_api_key() -> String:
	var explicit_key := api_key.strip_edges()
	if not explicit_key.is_empty():
		return explicit_key
	if api_key_environment_name.strip_edges().is_empty():
		return ""
	return OS.get_environment(api_key_environment_name).strip_edges()
