extends SceneTree

const SpeechScript = preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/assistant_speech.gd")
class MockSpeech extends SpeechScript:
	var starts: Array[String] = []
	var auto_finish := false
	func _request_segment() -> void:
		starts.append(_local_id)
		if auto_finish:
			_finish_local(true)

var _failed := false


func _init() -> void:
	if OS.get_cmdline_user_args().has("--speech-server") or OS.get_cmdline_user_args().has("--speech-client"):
		ProjectSettings.set_setting("arspace/local_agent/execution_mode", "server_relay")
	call_deferred("_run")


func _install_mock() -> Node:
	var old := root.get_node("AssistantSpeech")
	root.remove_child(old)
	old.free()
	var speech := MockSpeech.new()
	speech.name = "AssistantSpeech"
	root.add_child(speech)
	speech.enabled = true
	root.get_node("AssistantCommandRouter").call("_connect_speech")
	return speech


func _run() -> void:
	var speech := _install_mock()
	var args := OS.get_cmdline_user_args()
	if args.has("--speech-server") or args.has("--speech-client"):
		await _network_test(speech, args.has("--speech-server"))
		return
	var router := root.get_node("AssistantCommandRouter")
	var voice := root.get_node("VoiceChat")
	var states: Array[String] = []
	router.assistant_interaction_state_changed.connect(func(_peer, state, _text): states.append(state))
	_check(SpeechScript.split_text("第一句。第二句！").size() == 2, "Sentence splitting failed")
	_check(SpeechScript.split_text("字".repeat(400))[0].length() <= 160, "Segment size unbounded")
	_check(SpeechScript.split_text("力矩为 2.5 N·m。请勿超过。") == ["力矩为 2.5 N·m。", "请勿超过。"], "Decimal or unit split")
	_check(SpeechScript.split_text("他说：“不要超过。”接下来确认。") == ["他说：“不要超过。”", "接下来确认。"], "Closing quote detached")
	var long_sentence := "说明".repeat(24) + "，" + "要求".repeat(25) + "。"
	_check(SpeechScript.split_text(long_sentence)[0].ends_with("，"), "Long sentence ignored clause boundary")
	var numeric_boundary := "字".repeat(63) + "2.5 N·m" + "字".repeat(20)
	_check(SpeechScript.split_text(numeric_boundary)[0].ends_with("2.5 N·m"), "Length limit split numeric token")
	var thousands := "字".repeat(30) + "12,500" + "字".repeat(70)
	_check(SpeechScript.split_text(thousands)[0].contains("12,500"), "Thousands separator treated as clause boundary")
	_check(SpeechScript.split_text("字".repeat(62) + "12,500" + "字".repeat(20))[0].ends_with("12,500"), "Hard limit split thousands token")
	var english := "Please check the installation instructions before proceeding with the next operation."
	_check(SpeechScript.split_text(english)[0].length() <= 64, "English spaces did not bound segment length")
	_check(not speech.speak_for_peer(1, "bad", "字".repeat(4001)), "Oversized text accepted")
	var records := router.get("_requests") as Dictionary
	records["confirm-test"] = {"speaker_peer_id": 1, "text": "打开工作手册", "qwen_route": "confirm_action", "created_msec": Time.get_ticks_msec()}
	router.call("_on_agent_answer", "confirm-test", "你是否想打开工作清单？")
	await process_frame
	var sessions := router.get("_wake_sessions") as Dictionary
	_check(str(sessions[1].get("speech_id", "")) == "confirm-test", "Confirmation timer wasn't paused")
	await create_timer(10.1).timeout
	_check(sessions.has(1), "Confirmation expired while speech was still playing")
	_check(states.back() == "speaking", "Speaking UI state missing")
	_check(voice.is_assistant_speech_active(1) and not voice.is_assistant_speech_active(2), "ASR isolation failed")
	speech.call("_complete_peer", 2, "confirm-test", true)
	_check((speech.get("_pending") as Dictionary).has(1), "Wrong peer completed speech")
	speech.call("_client_speak", "confirm-test", "重复")
	_check(speech.starts.size() == 1, "Duplicate reply played")
	speech.call("_finish_local", true)
	await create_timer(0.35).timeout
	_check(states.back() == "listening", "Confirmation did not resume after playback")
	_check(not voice.is_assistant_speech_active(1), "ASR suppression leaked")
	var history_id := str((sessions[1]["history_interaction"] as Dictionary)["id"])
	records["confirm-retry"] = {"speaker_peer_id": 1, "text": "打开工作手册", "qwen_route": "confirm_action", "created_msec": Time.get_ticks_msec()}
	router.call("_on_agent_answer", "confirm-retry", "你是否想打开工作清单？")
	await process_frame
	history_id = str((sessions[1]["history_interaction"] as Dictionary)["id"])
	router.call("_on_assistant_wake_requested", 1)
	_check(bool(sessions[1]["confirmation"]), "Interrupt lost confirmation mode")
	_check(str(sessions[1]["history_interaction"]["id"]) == history_id, "Interrupt lost confirmation history")
	await create_timer(0.35).timeout
	_check(states.back() == "listening", "Late playback completion overwrote listening")
	_check(not voice.is_assistant_speech_active(1), "Interrupt didn't release ASR")
	# Failed synthesis must resume confirmation just like successful playback.
	records["confirm-failure"] = {"speaker_peer_id": 1, "text": "打开工作手册", "qwen_route": "confirm_action", "created_msec": Time.get_ticks_msec()}
	router.call("_on_agent_answer", "confirm-failure", "你是否想打开工作清单？")
	await process_frame
	speech.call("_on_audio_received", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), PackedByteArray([1]), "confirm-failure")
	await create_timer(0.35).timeout
	_check(states.back() == "listening", "Invalid audio blocked confirmation")
	_check(not voice.is_assistant_speech_active(1), "Failure leaked ASR suppression")
	# Simulate network reset changing the local ID before the disconnect callback.
	speech.set("_suppressed_local_peer", 12345)
	voice.set_assistant_speech_active(12345, true)
	ProjectSettings.set_setting("arspace/local_agent/execution_mode", "server_relay")
	speech.call("_on_server_disconnected")
	_check(not voice.is_assistant_speech_active(12345), "Disconnect leaked old peer suppression")
	ProjectSettings.set_setting("arspace/local_agent/execution_mode", "local")
	speech.set("_local_id", "local-survives-ground")
	speech.call("_on_server_disconnected")
	_check(str(speech.get("_local_id")) == "local-survives-ground", "Ground disconnect interrupted local TTS")
	# Buffered audio must not survive cancellation or a stale response.
	speech.set("_next_stream", AudioStreamWAV.new())
	speech.set("_fetching", true)
	speech.set("_playing_segment", true)
	speech.call("_abort_local")
	_check(speech.get("_next_stream") == null and not speech.get("_fetching") and not speech.get("_playing_segment"), "Prefetch state leaked on abort")
	speech.call("_on_audio_received", HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(["X-Audio-Format: pcm_s16le", "X-Sample-Rate: 24000"]), PackedByteArray([1, 0]), "obsolete")
	_check(speech.get("_next_stream") == null, "Stale response resurrected playback")
	# A prefetched response must not replace the stream currently being played.
	speech.set("_local_id", "buffer-test")
	var queued: Array[String] = ["第一句。", "第二句。"]
	speech.set("_parts", queued)
	var pcm := PackedByteArray()
	pcm.resize(96000)
	var pcm_headers := PackedStringArray(["X-Audio-Format: pcm_s16le", "X-Sample-Rate: 24000"])
	speech.call("_on_audio_received", HTTPRequest.RESULT_SUCCESS, 200, pcm_headers, pcm, "buffer-test")
	var first_stream = speech.get("_player").stream
	speech.call("_on_audio_received", HTTPRequest.RESULT_SUCCESS, 200, pcm_headers, pcm, "buffer-test")
	_check(speech.get("_player").stream == first_stream and speech.get("_next_stream") != null, "Prefetch interrupted current sentence")
	speech.get("_player").stop()
	speech.call("_on_segment_finished")
	_check(speech.get("_player").stream != first_stream and speech.get("_next_stream") == null, "Buffered sentence did not advance")
	speech.call("_abort_local")
	print("Assistant speech self test passed." if not _failed else "Assistant speech self test FAILED.")
	quit(1 if _failed else 0)


func _network_test(speech: Node, server: bool) -> void:
	var network := root.get_node("NetworkHandler")
	speech.auto_finish = true
	var finished: Array[String] = []
	speech.speech_finished.connect(func(_peer, id, _success): finished.append(id))
	_check(network.start_server() if server else network.start_client("127.0.0.1"), "Network startup failed")
	var deadline := Time.get_ticks_msec() + 15000
	if server:
		while root.multiplayer.get_peers().size() < 2 and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(root.multiplayer.get_peers().size() == 2, "Need two Clients")
		for peer in root.multiplayer.get_peers():
			_check(speech.speak_for_peer(peer, "speech-%d" % peer, "工作清单已打开。"), "Remote speech rejected")
			speech.rpc_id(peer, "_client_speak", "speech-%d" % peer, "重复消息")
		while finished.size() < 2 and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(finished.size() == 2, "Client completion acknowledgement missing")
		_check(speech.starts.is_empty(), "Server played Client audio")
		await create_timer(1.0).timeout
	else:
		while speech.starts.is_empty() and Time.get_ticks_msec() < deadline:
			await process_frame
		# NetworkHandler resets the peer to offline ID 1 when Server exits.
		var expected := "speech-%d" % root.multiplayer.get_unique_id()
		await create_timer(0.6).timeout
		_check(speech.starts == [expected], "Cross-client or duplicate playback: starts=%s expected=%s" % [speech.starts, expected])
	print("Assistant speech multi-client test passed." if not _failed else "Assistant speech multi-client test FAILED.")
	quit(1 if _failed else 0)


func _check(ok: bool, message: String) -> bool:
	if not ok:
		_failed = true
		push_error(message)
	return ok
