extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var speech := root.get_node("AssistantSpeech")
	var router := root.get_node("AssistantCommandRouter")
	var voice := root.get_node("VoiceChat")
	speech.enabled = true
	var completed: Array[String] = []
	speech.speech_finished.connect(func(_peer, id, success):
		if success:
			completed.append(id)
	)
	var records := router.get("_requests") as Dictionary
	records["real-tts-smoke"] = {"speaker_peer_id": 1, "text": "打开工作手册", "qwen_route": "confirm_action", "created_msec": Time.get_ticks_msec()}
	router.call("_on_agent_answer", "real-tts-smoke", "你是否想打开工作清单？请回答是或不是。")
	var deadline := Time.get_ticks_msec() + 30000
	var observed_pcm := false
	var observed_prefetch := false
	var player := speech.get("_player") as AudioStreamPlayer
	while completed.is_empty() and Time.get_ticks_msec() < deadline:
		if player.stream is AudioStreamWAV:
			var wave_stream := player.stream as AudioStreamWAV
			observed_pcm = wave_stream.data.size() > 1000 and wave_stream.mix_rate in [8000, 24000]
		if bool(speech.get("_playing_segment")) and (bool(speech.get("_fetching")) or speech.get("_next_stream") != null):
			observed_prefetch = true
		await process_frame
	var session := (router.get("_wake_sessions") as Dictionary).get(1, {}) as Dictionary
	if completed != ["real-tts-smoke"] or not observed_pcm or not observed_prefetch or not bool(session.get("confirmation", false)) or not str(session.get("speech_id", "")).is_empty() or voice.is_assistant_speech_active(1):
		push_error("Real TTS -> Godot playback -> confirmation smoke failed: " + str(speech.last_error))
		quit(1)
		return
	print("Real TTS -> Godot PCM playback -> confirmation smoke passed (headless audio, not Pico hardware).")
	quit(0)
