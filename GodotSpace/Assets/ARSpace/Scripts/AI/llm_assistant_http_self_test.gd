extends SceneTree

const AssistantScript := preload("res://Assets/ARSpace/Scripts/AI/llm_assistant.gd")
const PORT := 19082

var _server := TCPServer.new()
var _client: StreamPeerTCP
var _request_text := ""
var _responded := false
var _completed := false
var _failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var listen_error := _server.listen(PORT, "127.0.0.1")
	if listen_error != OK:
		_fail("Unable to start local mock LLM server: %s" % error_string(listen_error))
		return

	var assistant := AssistantScript.new()
	root.add_child(assistant)
	assistant.endpoint_url = "http://127.0.0.1:%d/v1/chat/completions" % PORT
	assistant.model = "mock-chat-model"
	assistant.api_key = "mock-key"
	assistant.api_key_environment_name = ""
	assistant.use_local_fallback_when_unconfigured = false
	assistant.require_wake_word = false
	assistant.call("_setup_knowledge_base")
	assistant.call("_setup_http_request")
	assistant.call("set_runtime_context_entries", [{
		"id": "mock-http-context",
		"title": "在线请求体知识",
		"source": "当前专家任务步骤",
		"tags": ["在线请求", "上下文"],
		"content": "在线请求体知识：当前步骤需要确认样品盒锁紧状态和目标力矩。",
	}])
	assistant.call("_append_conversation_turn", "user", "专家", "上一问：样品盒拆装前确认了什么")

	assistant.answer_completed.connect(func(_question: String, answer: String, sources: Array) -> void:
		if answer.strip_edges() != "mock answer\n1. first step" or sources.is_empty():
			_fail("Mock LLM answer was not converted to plain text correctly.")
			return
		_completed = true
	)
	assistant.answer_failed.connect(func(_question: String, message: String) -> void:
		_fail("Mock LLM request failed: %s" % message)
	)

	assistant.ask("在线请求体需要包含哪些上下文")
	var deadline_msec := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline_msec and not _completed and not _failed:
		_poll_mock_server()
		await process_frame

	_server.stop()
	if _failed:
		return
	if not _completed:
		_fail("Mock LLM request timed out. received_bytes=%d responded=%s" % [_request_text.to_utf8_buffer().size(), str(_responded)])
		return
	if _request_text.find("在线请求体知识") == -1:
		_fail("Mock LLM request body did not include retrieved knowledge.")
		return
	if _request_text.find("近期对话") == -1 or _request_text.find("上一问") == -1:
		_fail("Mock LLM request body did not include recent conversation.")
		return
	if _request_text.find("Authorization: Bearer mock-key") == -1:
		_fail("Mock LLM request did not include the configured Authorization header.")
		return
	if _request_text.find("Output plain text only") == -1:
		_fail("Mock LLM request did not include the plain-text output instruction.")
		return

	print("LLM assistant HTTP self test passed.")
	quit(0)


func _poll_mock_server() -> void:
	if _client == null and _server.is_connection_available():
		_client = _server.take_connection()
	if _client == null:
		return
	_client.poll()
	var available := _client.get_available_bytes()
	if available > 0:
		_request_text += _client.get_utf8_string(available)
	if not _responded and _has_complete_request(_request_text):
		_responded = true
		_send_mock_response()


func _has_complete_request(request_text: String) -> bool:
	var header_end := request_text.find("\r\n\r\n")
	if header_end == -1:
		return false
	var content_length := 0
	for raw_line in request_text.substr(0, header_end).split("\r\n"):
		var line := str(raw_line)
		if line.to_lower().begins_with("content-length:"):
			content_length = int(line.get_slice(":", 1).strip_edges())
	var body := request_text.substr(header_end + 4)
	return body.to_utf8_buffer().size() >= content_length


func _send_mock_response() -> void:
	var body := JSON.stringify({
		"choices": [{
			"message": {
				"content": "**mock answer**\n- 1. first step",
			},
		}],
	})
	var response := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [
		body.to_utf8_buffer().size(),
		body,
	]
	_client.put_data(response.to_utf8_buffer())


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	_server.stop()
	push_error(message)
	quit(1)
