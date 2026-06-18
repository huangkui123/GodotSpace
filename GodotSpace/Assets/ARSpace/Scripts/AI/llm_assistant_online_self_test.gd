extends SceneTree

const AssistantScript := preload("res://Assets/ARSpace/Scripts/AI/llm_assistant.gd")
const RUN_ONLINE_ENV := "LLM_ASSISTANT_RUN_ONLINE_TEST"

var _finished := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var assistant := AssistantScript.new()
	root.add_child(assistant)
	assistant.call("_apply_project_settings")

	if OS.get_environment(RUN_ONLINE_ENV).strip_edges() != "1":
		print("LLM online self test skipped. Set %s=1 to run a real endpoint check." % RUN_ONLINE_ENV)
		quit(0)
		return

	var env_name: String = str(assistant.get("api_key_environment_name"))
	var explicit_key := str(assistant.get("api_key")).strip_edges()
	var environment_key := OS.get_environment(str(env_name)).strip_edges()
	if explicit_key.is_empty() and environment_key.is_empty():
		print("LLM online self test skipped. API key is not configured in %s." % str(env_name))
		quit(0)
		return

	assistant.use_local_fallback_when_unconfigured = false
	assistant.require_wake_word = false
	assistant.max_tokens = min(int(assistant.get("max_tokens")), 256)
	assistant.call("_setup_knowledge_base")
	assistant.call("_setup_http_request")

	assistant.answer_completed.connect(func(question: String, answer: String, sources: Array) -> void:
		print("online_answer_completed question=%s answer_len=%d sources=%d" % [question, answer.length(), sources.size()])
		if answer.strip_edges().is_empty() or sources.is_empty():
			_fail("LLM online self test returned an empty answer or no sources.")
			return
		_finished = true
		print("LLM online self test passed.")
		quit(0)
	)
	assistant.answer_failed.connect(func(question: String, message: String) -> void:
		_fail("online_answer_failed question=%s message=%s" % [question, message])
	)

	assistant.ask("氧气分压缓慢下降时优先检查什么")
	await create_timer(45.0).timeout

	if not _finished:
		_fail("LLM online self test timed out.")


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error(message)
	quit(1)
