extends SceneTree

const Execution := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_execution.gd")
const CaptureScript := preload("res://Assets/ARSpace/Scripts/Network/voice_capture.gd")
var failures: Array[String] = []

class FakeAsr extends Node:
	signal transcribed_msg(final: bool, text: String)
	signal connection_state_changed(state: String, detail: String)
	signal error_occurred(code: int, message: String)
	var finish_count := 0
	var chunks := 0
	func set_input_active(_active: bool) -> void:
		pass
	func finish_transcription() -> void:
		finish_count += 1
	func cancel_transcription() -> void:
		pass
	func push_audio_frames(_frames: PackedVector2Array) -> void:
		chunks += 1

class FakeCapture extends Node:
	var is_setup := true
	var boundaries := 0
	func set_voice_active(_active: bool) -> void:
		pass
	func discard_pending_recognition_audio() -> void:
		boundaries += 1

class FakeVoice extends "res://Assets/ARSpace/Scripts/Network/voice_chat.gd":
	func _ready() -> void:
		capture = FakeCapture.new()
		add_child(capture)
		voice_endpoint_selected = true
		voice_enabled = true
		set_process(false)
	func _create_asr_transcriber(node_name: String) -> Node:
		var result := FakeAsr.new()
		result.name = node_name
		return result


func _init() -> void:
	ProjectSettings.set_setting("arspace/local_agent/execution_mode", "local")
	call_deferred("_run")


func _run() -> void:
	var old_voice := root.get_node("VoiceChat")
	root.remove_child(old_voice)
	old_voice.queue_free()
	var voice := FakeVoice.new()
	voice.name = "VoiceChat"
	root.add_child(voice)
	var router := root.get_node("AssistantCommandRouter")
	voice.voice_transcript_received.connect(router._on_voice_transcript_received)
	voice.assistant_wake_requested.connect(router._on_assistant_wake_requested)
	voice.assistant_capture_ready.connect(router._on_capture_ready)
	voice.assistant_capture_failed.connect(router._on_capture_failed)
	var old_asr: Node = voice._get_peer_transcriber(1)
	voice._client_transcription_pcm_buffer = PackedByteArray([1, 2])
	voice._client_transcription_mono_buffer = PackedFloat32Array([0.5])
	_check(voice.request_assistant_wake(), "Button wake rejected")
	_check(old_asr.finish_count == 1, "Previous ordinary speech was not finalized")
	_check(voice.capture.boundaries == 1, "Capture boundary missing")
	_check(voice._client_transcription_pcm_buffer.is_empty() and voice._client_transcription_mono_buffer.is_empty(), "Old upload/resampler buffers survived")
	_check(bool(router._wake_sessions[1].get("capture_preparing", false)), "Countdown started before ASR ready")
	old_asr.transcribed_msg.emit(true, "智能助手打开相册：这是点击前的话")
	_check(str(router._wake_sessions[1]["command"]).is_empty(), "Late old final entered new command")
	_check(voice.voice_transcript_history.size() == 1, "Old ordinary utterance was lost instead of saved to history")
	var new_asr: Node = voice._peer_transcribers[1]
	voice._on_local_pcm_frames_captured(PackedVector2Array([Vector2(0.1, 0.1)]))
	_check(new_asr.chunks == 1, "Post-click speech lost while connecting")
	new_asr.connection_state_changed.emit("connected", "fake")
	_check(not bool(router._wake_sessions[1].get("capture_preparing", false)), "Ready did not start the listening countdown")
	new_asr.transcribed_msg.emit(false, "打开工作清单")
	_check(router._wake_sessions[1]["command"] == "打开工作清单", "New speech not accepted")
	router._wake_sessions[1]["confirmation"] = true
	router._wake_sessions[1]["history_interaction"] = {"id": "original", "confirmation_id": "confirm-original"}
	voice.request_assistant_wake()
	_check(router._wake_sessions[1]["history_interaction"]["confirmation_id"] == "confirm-original", "Retry lost confirmation context")
	new_asr.transcribed_msg.emit(false, "旧的迟到结果")
	_check(router._wake_sessions[1]["command"] == "", "Retry accepted stale partial")
	var retry_asr: Node = voice._peer_transcribers[1]
	retry_asr.connection_state_changed.emit("error", "unavailable")
	_check(router._wake_sessions[1]["history_interaction"]["id"] == "original", "ASR failure lost confirmation")
	router._wake_sessions.clear()
	voice._manual_wake_pending = false
	var epoch := voice._recognition_epoch
	router._on_voice_transcript_received({"speaker_peer_id": 1, "utterance_id": 900, "text": "智能助手，打开工作清单", "is_final": false})
	_check(router._wake_sessions[1]["command"] == "打开工作清单" and voice._recognition_epoch == epoch, "Voice wake lost inline command")
	router._wake_sessions.clear()
	router._on_voice_transcript_received({"speaker_peer_id": 99, "text": "智能助手打开相册", "is_final": true})
	_check(router._wake_sessions.is_empty(), "Other peer woke local assistant")
	voice._on_server_disconnected()
	_check(voice.voice_enabled, "Ground disconnect disabled local ASR")
	var agent := root.get_node("LocalAgentClient")
	agent._on_network_role_selected(false)
	_check(agent._is_enabled(), "ENet Client role disabled direct Gateway connection")
	var denied: Dictionary = agent.execute_tool_call_for_test("blocked", "shared_scene_mutation", {})
	_check(not bool(denied.get("ok", false)), "Local mode allowed unaudited shared-scene tool")
	_check(not router._is_local_target(99), "Remote peer treated as local")
	var capture := CaptureScript.new()
	var received: Array = []
	capture.recognition_frames_captured.connect(func(frames: PackedVector2Array): received.append(frames))
	capture._recognition_skip_frames = 3
	capture._emit_recognition_frames(PackedVector2Array([Vector2.ONE, Vector2.ONE]))
	capture._emit_recognition_frames(PackedVector2Array([Vector2.ONE, Vector2.ZERO]))
	_check(received.size() == 1 and (received[0] as PackedVector2Array) == PackedVector2Array([Vector2.ZERO]), "Capture did not trim precisely at boundary")
	capture.free()
	var asr := preload("res://Assets/ARSpace/Scripts/Network/local_funasr_transcriber.gd").new()
	asr._pcm_buffer.resize(100000)
	asr._trim_buffered_pcm()
	_check(asr._pcm_buffer.is_empty() and not asr._last_error_message.is_empty(), "ASR silently truncated the start of buffered speech")
	asr.free()
	for failure in failures:
		push_error(failure)
	print("Local endpoint self-test passed." if failures.is_empty() else "Local endpoint self-test FAILED.")
	quit(0 if failures.is_empty() else 1)


func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
