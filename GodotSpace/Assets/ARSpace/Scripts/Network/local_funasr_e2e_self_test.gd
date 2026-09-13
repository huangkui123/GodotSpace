extends SceneTree

const TRANSCRIBER_SCRIPT := preload("res://Assets/ARSpace/Scripts/Network/local_funasr_transcriber.gd")
const PACKET_MSEC := 100
const PACKET_BYTES := 3200
const TIMEOUT_MSEC := 30000

var _connected := false
var _finished := false
var _final_text := ""
var _error := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var wav_path := OS.get_environment("LOCAL_ASR_TEST_WAV").strip_edges()
	var expected_text := "欢迎大家来体验达摩院"
	var auto_vad := false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--local-asr-test-wav="):
			wav_path = argument.trim_prefix("--local-asr-test-wav=").strip_edges()
		elif argument.begins_with("--local-asr-expected="):
			expected_text = argument.trim_prefix("--local-asr-expected=").strip_edges()
		elif argument == "--local-asr-auto-vad":
			auto_vad = true
	if wav_path.is_empty():
		_fail("LOCAL_ASR_TEST_WAV or --local-asr-test-wav is required.")
		return
	var wav := FileAccess.get_file_as_bytes(wav_path)
	var pcm := _extract_wav_pcm(wav)
	if pcm.is_empty():
		_fail("Unable to extract PCM16 data from %s." % wav_path)
		return

	var transcriber := TRANSCRIBER_SCRIPT.new()
	transcriber.name = "LocalFunAsrE2E"
	transcriber.need_vad = auto_vad
	transcriber.debug_logs = true
	transcriber.transcribed_msg.connect(func(is_final: bool, text: String) -> void:
		if is_final:
			_final_text = text.strip_edges()
	)
	transcriber.connection_state_changed.connect(func(state: String, _detail: String) -> void:
		if state == "connected":
			_connected = true
		elif state == "finished":
			_finished = true
	)
	transcriber.error_occurred.connect(func(_code: int, message: String) -> void:
		_error = message
	)
	root.add_child(transcriber)
	if not transcriber.start_transcription():
		_fail("Local FunASR transcriber did not start.")
		return

	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not _connected and _error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _error.is_empty():
		_fail(_error)
		return
	if not _connected:
		_fail("Local FunASR did not connect before timeout.")
		return

	if auto_vad:
		var silence := PackedByteArray()
		silence.resize(32000 * 3)
		pcm.append_array(silence)
	for offset in range(0, pcm.size(), PACKET_BYTES):
		if _finished or not _error.is_empty():
			break
		transcriber.push_pcm16_audio(pcm.slice(offset, mini(offset + PACKET_BYTES, pcm.size())))
		await create_timer(float(PACKET_MSEC) / 1000.0).timeout
	if not auto_vad:
		transcriber.finish_transcription()
	deadline = Time.get_ticks_msec() + TIMEOUT_MSEC
	while not _finished and _error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _error.is_empty():
		_fail(_error)
		return
	if not _finished:
		_fail("Local FunASR did not finish before timeout.")
		return
	if expected_text.is_empty() or _final_text.find(expected_text) == -1:
		_fail("Unexpected Local FunASR final transcript: %s" % _final_text)
		return
	print("Godot Local FunASR end-to-end self-test passed: %s" % _final_text)
	quit(0)


func _extract_wav_pcm(wav: PackedByteArray) -> PackedByteArray:
	if wav.size() < 44 or wav.slice(0, 4).get_string_from_ascii() != "RIFF":
		return PackedByteArray()
	var offset := 12
	while offset + 8 <= wav.size():
		var chunk_name := wav.slice(offset, offset + 4).get_string_from_ascii()
		var chunk_size := _read_u32_le(wav, offset + 4)
		var data_start := offset + 8
		if chunk_name == "data" and data_start + chunk_size <= wav.size():
			return wav.slice(data_start, data_start + chunk_size)
		offset = data_start + chunk_size + (chunk_size % 2)
	return PackedByteArray()


func _read_u32_le(bytes: PackedByteArray, offset: int) -> int:
	return (
		int(bytes[offset])
		| (int(bytes[offset + 1]) << 8)
		| (int(bytes[offset + 2]) << 16)
		| (int(bytes[offset + 3]) << 24)
	)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
