extends SceneTree

const TRANSCRIBER_SCRIPT := preload("res://Assets/ARSpace/Scripts/Network/tencent_asr_transcriber.gd")
const VOICE_SCENE_PATH := "res://Assets/ARSpace/Scenes/voice_chat_service.tscn"

var _failures: Array[String] = []


class MockTranscriber extends Node:
	var cancel_count: int = 0
	var audio_push_count: int = 0
	var input_active_calls: Array[bool] = []

	func cancel_transcription() -> void:
		cancel_count += 1

	func push_audio_frames(_frames: PackedVector2Array) -> void:
		audio_push_count += 1

	func set_input_active(active: bool) -> void:
		input_active_calls.append(active)


class MockCapture extends Node:
	var active_calls: Array[bool] = []
	var is_setup: bool = true

	func set_voice_active(active: bool) -> void:
		active_calls.append(active)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_secret_hygiene()
	_check_transcriber_lifecycle_api()
	_check_voice_chat_dictation_api()
	await _check_dictation_state_machine()
	if _failures.is_empty():
		print("Voice dictation self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _check_secret_hygiene() -> void:
	var scene_text := FileAccess.get_file_as_string(VOICE_SCENE_PATH)
	_expect(not scene_text.is_empty(), "VoiceChat scene must be readable.")
	_expect(scene_text.find("app_id =") == -1, "VoiceChat scene must not store a Tencent app id.")
	_expect(scene_text.find("secret_id =") == -1, "VoiceChat scene must not store a Tencent secret id.")
	_expect(scene_text.find("secret_key =") == -1, "VoiceChat scene must not store a Tencent secret key.")


func _check_transcriber_lifecycle_api() -> void:
	var transcriber := TRANSCRIBER_SCRIPT.new()
	_expect(transcriber.has_method("start_transcription"), "Transcriber must expose start_transcription().")
	_expect(transcriber.has_method("finish_transcription"), "Transcriber must expose finish_transcription().")
	_expect(transcriber.has_method("cancel_transcription"), "Transcriber must expose cancel_transcription().")
	transcriber.finish_transcription()
	transcriber.cancel_transcription()
	var state: Dictionary = transcriber.get_debug_state()
	_expect(str(state.get("credential_source", "")).is_empty(), "Credentials must not be resolved before a transcription starts.")
	transcriber.free()


func _check_voice_chat_dictation_api() -> void:
	var voice_chat := root.get_node_or_null("VoiceChat")
	_expect(voice_chat != null, "VoiceChat autoload must exist.")
	if voice_chat == null:
		return
	for method_name in [
		"get_dictation_readiness",
		"begin_local_dictation",
		"finish_local_dictation",
		"cancel_local_dictation",
	]:
		_expect(voice_chat.has_method(method_name), "VoiceChat must expose %s()." % method_name)
	for signal_name in [
		"dictation_state_changed",
		"dictation_partial_received",
		"dictation_final_received",
		"dictation_failed",
	]:
		_expect(voice_chat.has_signal(signal_name), "VoiceChat must expose %s." % signal_name)
	var readiness: Dictionary = voice_chat.get_dictation_readiness()
	_expect(readiness.has("available"), "Dictation readiness must include available.")
	_expect(readiness.has("reason"), "Dictation readiness must include reason.")


func _check_dictation_state_machine() -> void:
	var voice_chat := root.get_node_or_null("VoiceChat")
	if voice_chat == null:
		return
	_expect(str(voice_chat.get("_dictation_session_id")).is_empty(), "Dictation self-test requires an idle VoiceChat.")
	if not str(voice_chat.get("_dictation_session_id")).is_empty():
		return

	var original_capture = voice_chat.get("capture")
	var original_transport = voice_chat.get("transport")
	var original_voice_enabled: bool = bool(voice_chat.get("voice_enabled"))
	var original_endpoint_selected: bool = bool(voice_chat.get("voice_endpoint_selected"))
	var original_server_endpoint: bool = bool(voice_chat.get("is_server_endpoint"))
	var original_peer_transcribers: Dictionary = voice_chat.get("_peer_transcribers")
	var original_history: Array = voice_chat.get("voice_transcript_history").duplicate(true)
	var mock_capture := MockCapture.new()
	voice_chat.add_child(mock_capture)
	voice_chat.set("capture", mock_capture)
	voice_chat.set("transport", null)
	voice_chat.set("voice_enabled", true)
	voice_chat.set("voice_endpoint_selected", true)
	voice_chat.set("is_server_endpoint", true)

	var states: Array[Dictionary] = []
	var finals: Array[Dictionary] = []
	var failures: Array[Dictionary] = []
	var ordinary_transcripts: Array[Dictionary] = []
	var state_callback := func(session_id: String, state: String, detail: String) -> void:
		states.append({"session_id": session_id, "state": state, "detail": detail})
	var final_callback := func(session_id: String, text: String) -> void:
		finals.append({"session_id": session_id, "text": text})
	var failure_callback := func(session_id: String, code: int, message: String) -> void:
		failures.append({"session_id": session_id, "code": code, "message": message})
	var transcript_callback := func(data: Dictionary) -> void:
		ordinary_transcripts.append(data.duplicate(true))
	voice_chat.connect("dictation_state_changed", state_callback)
	voice_chat.connect("dictation_final_received", final_callback)
	voice_chat.connect("dictation_failed", failure_callback)
	voice_chat.connect("voice_transcript_received", transcript_callback)

	var normal_asr := MockTranscriber.new()
	normal_asr.name = "MockNormalAsr"
	voice_chat.add_child(normal_asr)
	voice_chat.set("_peer_transcribers", {1: normal_asr})
	var success_transcriber := _arm_dictation(voice_chat, "success", "finalizing", "已完成说明")
	voice_chat.call("_on_local_pcm_frames_captured", PackedVector2Array([Vector2(0.1, 0.1)]))
	_expect(success_transcriber.audio_push_count == 1, "Active dictation should receive local PCM frames.")
	_expect(normal_asr.audio_push_count == 0, "Normal ASR must receive no PCM during dictation.")
	voice_chat.call("_complete_dictation")
	_expect(_contains_session(finals, "success"), "Successful dictation must emit one final result.")
	_expect(_contains_state(states, "success", "completed"), "Successful dictation must reach completed.")
	_expect(not mock_capture.active_calls.is_empty() and mock_capture.active_calls[-1], "Voice capture must resume after dictation.")
	_expect(not normal_asr.input_active_calls.is_empty() and normal_asr.input_active_calls[-1], "Normal ASR must resume after dictation.")

	_arm_dictation(voice_chat, "failure", "capturing", "")
	voice_chat.call("_fail_dictation", ERR_CANT_CONNECT, "simulated failure")
	_expect(_contains_failure(failures, "failure", ERR_CANT_CONNECT), "Failed dictation must emit its session-scoped error.")
	_expect(_contains_state(states, "failure", "failed"), "Failed dictation must reach failed.")

	_arm_dictation(voice_chat, "timeout", "finalizing", "")
	voice_chat.set("_dictation_finalize_deadline_msec", Time.get_ticks_msec() - 1)
	voice_chat.call("_update_dictation_timeout")
	_expect(_contains_failure(failures, "timeout", ERR_TIMEOUT), "Finalization timeout must emit ERR_TIMEOUT.")

	_arm_dictation(voice_chat, "cancel", "capturing", "")
	_expect(bool(voice_chat.call("cancel_local_dictation", "cancel")), "Cancellation must accept the active session id.")
	_expect(_contains_state(states, "cancel", "cancelled"), "Cancelled dictation must reach cancelled.")

	var current_transcriber := _arm_dictation(voice_chat, "current", "capturing", "current text")
	var old_transcriber := MockTranscriber.new()
	voice_chat.add_child(old_transcriber)
	voice_chat.call("_on_dictation_transcribed_msg", true, "late old text", "old", old_transcriber)
	voice_chat.call("_on_dictation_connection_state_changed", "finished", "", "old", old_transcriber)
	voice_chat.call("_on_dictation_error", ERR_CONNECTION_ERROR, "late old error", "old", old_transcriber)
	voice_chat.call("_on_dictation_transcribed_msg", true, "same id from stale source", "current", old_transcriber)
	_expect(str(voice_chat.get("_dictation_last_text")) == "current text", "Late callbacks must not mutate the active session.")
	_expect(not _contains_session(finals, "old"), "Late callbacks must not emit an old final result.")
	_expect(voice_chat.get("_dictation_transcriber") == current_transcriber, "A stale source must not replace the active transcriber.")
	voice_chat.call("cancel_local_dictation", "current")
	old_transcriber.queue_free()

	_expect(ordinary_transcripts.is_empty(), "Dictation must not emit ordinary voice transcripts to the LLM path.")
	_expect(voice_chat.get("voice_transcript_history") == original_history, "Dictation must not alter ordinary transcript history.")

	voice_chat.disconnect("dictation_state_changed", state_callback)
	voice_chat.disconnect("dictation_final_received", final_callback)
	voice_chat.disconnect("dictation_failed", failure_callback)
	voice_chat.disconnect("voice_transcript_received", transcript_callback)
	voice_chat.set("_peer_transcribers", original_peer_transcribers)
	voice_chat.set("capture", original_capture)
	voice_chat.set("transport", original_transport)
	voice_chat.set("voice_enabled", original_voice_enabled)
	voice_chat.set("voice_endpoint_selected", original_endpoint_selected)
	voice_chat.set("is_server_endpoint", original_server_endpoint)
	voice_chat.set("_dictation_session_id", "")
	voice_chat.set("_dictation_state", "idle")
	if is_instance_valid(normal_asr):
		normal_asr.queue_free()
	if is_instance_valid(mock_capture):
		mock_capture.queue_free()
	await process_frame


func _arm_dictation(voice_chat: Node, session_id: String, state: String, text: String) -> MockTranscriber:
	var transcriber := MockTranscriber.new()
	transcriber.name = "MockDictation_%s" % session_id
	voice_chat.add_child(transcriber)
	voice_chat.set("_dictation_transcriber", transcriber)
	voice_chat.set("_dictation_session_id", session_id)
	voice_chat.set("_dictation_state", state)
	voice_chat.set("_dictation_started_msec", Time.get_ticks_msec())
	voice_chat.set("_dictation_finalize_deadline_msec", 0)
	voice_chat.set("_dictation_last_text", text)
	voice_chat.set("_dictation_final_emitted", false)
	voice_chat.set("_dictation_failure_reported", false)
	return transcriber


func _contains_session(events: Array[Dictionary], session_id: String) -> bool:
	for event in events:
		if str(event.get("session_id", "")) == session_id:
			return true
	return false


func _contains_state(events: Array[Dictionary], session_id: String, state: String) -> bool:
	for event in events:
		if str(event.get("session_id", "")) == session_id and str(event.get("state", "")) == state:
			return true
	return false


func _contains_failure(events: Array[Dictionary], session_id: String, code: int) -> bool:
	for event in events:
		if str(event.get("session_id", "")) == session_id and int(event.get("code", 0)) == code:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
