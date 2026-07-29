extends SceneTree


var _answer_completed := false
var _task_source_seen := false
var _current_step_source_seen := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn")
	if scene == null:
		_fail("Unable to load WorkListInfoCanvas scene.")
		return

	var scene_root := scene.instantiate()
	root.add_child(scene_root)
	await process_frame

	var canvas := scene_root.get_node_or_null("Canvas")
	if canvas == null:
		_fail("WorkListInfoCanvas missing Canvas node.")
		return
	if not canvas.has_method("_on_llm_assistant_pressed"):
		_fail("WorkListInfoUIView missing assistant open handler.")
		return

	var button := canvas.get_node_or_null("TopMenuBox/Controller/AssistantButton")
	if button == null:
		_fail("Task detail scene missing AssistantButton.")
		return

	var assistant_view := canvas.get_node_or_null("LLMAssistantView")
	if assistant_view == null or not assistant_view.has_method("start_assistant"):
		_fail("Task detail scene missing LLMAssistantView.")
		return

	var task_result := WorkListInfoDataResult.new("样品盒拆装任务", [
		WorkListInfoData.new(1, 1, "", "拆装前确认", "复述专家口令，确认实验柜断电、防静电手环有效，并核对工具规格和目标力矩。"),
		WorkListInfoData.new(2, 1, "", "拆下样品盒", "当前步骤需要保持防静电接地，使用指定工具按目标力矩松开固定螺钉，发现卡滞应暂停并请求专家席确认。"),
	])
	var opened: Dictionary = canvas.call("open_task", 1, task_result)
	if not bool(opened.get("ok", false)):
		_fail("Task guide did not open through its public API.")
		return

	var assistant: Node = root.get_node_or_null("LLMAssistantService")
	if assistant == null:
		_fail("LLMAssistantService autoload is unavailable.")
		return
	assistant.endpoint_url = ""
	assistant.api_key = ""
	assistant.api_key_environment_name = ""
	assistant.require_wake_word = true
	assistant.wake_words = PackedStringArray(["助手"])
	assistant.use_local_fallback_when_unconfigured = true
	assistant.max_tokens = 384
	assistant.max_prompt_context_chars = 1200
	assistant.request_timeout_seconds = 90.0
	assistant.answer_completed.connect(func(_question: String, answer: String, sources: Array) -> void:
		_answer_completed = not answer.strip_edges().is_empty()
		_task_source_seen = _has_source(sources, "当前专家任务指导")
		_current_step_source_seen = _has_source(sources, "当前专家任务步骤")
	)

	var state: Dictionary = assistant.call("get_debug_state")
	if not bool(state.get("voice_connected", false)):
		_fail("Assistant did not connect to the VoiceChat autoload.")
		return
	if not bool(state.get("listening", false)):
		_fail("Assistant service is not listening without opening the assistant panel.")
		return
	var http_request := assistant.get("_http_request") as HTTPRequest
	if http_request == null or not is_equal_approx(http_request.timeout, 90.0):
		_fail("DeepSeek HTTP timeout does not preserve the Gateway timeout margin.")
		return
	var bounded_request := assistant.call("_build_chat_completion_request", "这一步在讲什么", [{
		"source": "当前专家任务步骤",
		"title": "当前步骤优先",
		"content": "当前步骤关键内容。" + "长".repeat(3000),
	}, {
		"source": "普通知识库",
		"title": "低优先级条目",
		"content": "低优先级内容。" + "长".repeat(3000),
	}], "历史".repeat(1000)) as Dictionary
	var bounded_messages := bounded_request.get("messages", []) as Array
	var bounded_user_message := str((bounded_messages[2] as Dictionary).get("content", ""))
	if int(bounded_request.get("max_tokens", 0)) != 384 \
			or bounded_user_message.length() > 1400 \
			or bounded_user_message.find("当前步骤关键内容") == -1:
		_fail("DeepSeek prompt did not enforce its context budget or prioritize current task context.")
		return

	var voice_chat := root.get_node_or_null("VoiceChat")
	if voice_chat == null or not voice_chat.has_signal("voice_transcript_received"):
		_fail("VoiceChat autoload is unavailable for transcript signal test.")
		return
	if not voice_chat.has_method("publish_assistant_transcript"):
		_fail("VoiceChat does not expose assistant transcript publishing.")
		return
	# This UI test exercises the legacy assistant panel in isolation. Production
	# transcripts are owned by AssistantCommandRouter and covered by its own tests.
	assistant.call("set_external_transcript_router_enabled", false)
	var router := root.get_node_or_null("AssistantCommandRouter")
	if router != null:
		var router_callback := Callable(router, "_on_voice_transcript_received")
		if voice_chat.is_connected("voice_transcript_received", router_callback):
			voice_chat.disconnect("voice_transcript_received", router_callback)

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手 样品盒拆装前需要确认什么",
		"is_final": true,
		"timestamp_msec": 1,
	})
	if not _answer_completed or not _task_source_seen:
		_fail("Task detail assistant did not answer from VoiceChat before opening the assistant panel.")
		return
	if not _last_voice_history_item_is_assistant_reply(voice_chat):
		_fail("Task detail assistant did not publish its reply to VoiceChat transcript history.")
		return

	canvas.call("_on_llm_assistant_pressed")
	if not assistant_view.visible:
		_fail("Assistant history panel did not become visible from task detail.")
		return
	var history: Array = assistant.call("get_qa_history")
	if history.is_empty():
		_fail("Assistant history panel has no question/answer history to display.")
		return
	var history_count := history.size()
	if not bool(assistant.call("record_external_qa", "external-history-ui-test", "Qwen 工具调用是否完成", "已完成并记录到历史窗口。", true, {"provider": "local_qwen_agent"})):
		_fail("Qwen external history entry was not accepted.")
		return
	await process_frame
	history = assistant.call("get_qa_history")
	if history.size() != history_count + 1:
		_fail("Qwen external history entry was not appended exactly once.")
		return
	var history_transcript := assistant_view.get_node_or_null("Transcript") as RichTextLabel
	if history_transcript == null or history_transcript.get_parsed_text().find("已完成并记录到历史窗口") == -1:
		_fail("Assistant history window did not refresh for the Qwen external entry.")
		return

	_answer_completed = false
	_current_step_source_seen = false
	canvas.call("_on_next_pressed")
	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": 1,
		"speaker_name": "航天员",
		"text": "助手 当前步骤需要做什么",
		"is_final": true,
		"timestamp_msec": 2,
	})
	if not _answer_completed or not _current_step_source_seen:
		_fail("Task detail assistant did not use VoiceChat transcript with current step context after paging.")
		return

	canvas.call("_on_llm_assistant_back_pressed")
	state = assistant.call("get_debug_state")
	if assistant_view.visible or not bool(state.get("listening", false)):
		_fail("Assistant history panel back action should hide the panel without stopping the service.")
		return

	print("LLM assistant task UI self test passed.")
	quit(0)


func _has_source(sources: Array, source_name: String) -> bool:
	for source in sources:
		if typeof(source) == TYPE_DICTIONARY and str((source as Dictionary).get("source", "")).find(source_name) != -1:
			return true
	return false


func _last_voice_history_item_is_assistant_reply(voice_chat: Node) -> bool:
	if not voice_chat.has_method("get_transcript_history"):
		return false
	var history: Array = voice_chat.call("get_transcript_history")
	if history.is_empty():
		return false
	var item = history[history.size() - 1]
	if typeof(item) != TYPE_DICTIONARY:
		return false
	var data := item as Dictionary
	return str(data.get("speaker_name", "")) == "智能助手" \
			and str(data.get("source", "")) == "llm_assistant" \
			and not str(data.get("text", "")).strip_edges().is_empty() \
			and bool(data.get("is_final", false))


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
