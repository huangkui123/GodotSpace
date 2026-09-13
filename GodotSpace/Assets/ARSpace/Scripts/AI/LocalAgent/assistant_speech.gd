extends Node

signal speech_finished(peer_id: int, request_id: String, success: bool)
signal local_speech_changed(active: bool)

const MAX_TEXT := 4000
const MAX_AUDIO_BYTES := 4 * 1024 * 1024
const REQUEST_TIMEOUT := 180_000
const TARGET_SEGMENT_CHARS := 64
var enabled := true
var endpoint := "http://127.0.0.1:8767/v1/speech"
var last_error := ""
var _pending: Dictionary = {}
var _seen: Array[String] = []
var _local_id := ""
var _suppressed_local_peer := 0
var _parts: Array[String] = []
var _http: HTTPRequest
var _player: AudioStreamPlayer
var _retries := 0
var _deadline := 0
var _stopping := false
var _fetching := false
var _playing_segment := false
var _next_stream: AudioStreamWAV


func _ready() -> void:
	enabled = bool(ProjectSettings.get_setting("arspace/assistant_speech/enabled", true))
	if DisplayServer.get_name() == "headless" and OS.get_environment("GODOTSPACE_TTS_HEADLESS") != "1":
		enabled = false
	endpoint = str(ProjectSettings.get_setting("arspace/assistant_speech/endpoint_url", endpoint))
	var override := OS.get_environment("GODOTSPACE_TTS_ENDPOINT").strip_edges()
	if not override.is_empty():
		endpoint = override
	_player = AudioStreamPlayer.new()
	_player.name = "AssistantSpeechPlayer"
	_player.volume_db = float(ProjectSettings.get_setting("arspace/assistant_speech/volume_db", -3.0))
	add_child(_player)
	_player.finished.connect(_on_segment_finished)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not _local_id.is_empty() and now > _deadline:
		last_error = "Speech playback timed out"
		_finish_local(false)
	for peer in _pending.keys().duplicate():
		if now > int(_pending[peer]["deadline"]):
			cancel_for_peer(int(peer))


func speak_for_peer(peer_id: int, request_id: String, text: String) -> bool:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return false
	if peer_id <= 0 or request_id.is_empty() or request_id.length() > 128 or text.strip_edges().is_empty() or text.length() > MAX_TEXT:
		return false
	if _is_local(peer_id) and not enabled:
		return false
	if not _is_local(peer_id) and not multiplayer.get_peers().has(peer_id):
		return false
	cancel_for_peer(peer_id)
	_pending[peer_id] = {"id": request_id, "deadline": Time.get_ticks_msec() + REQUEST_TIMEOUT}
	_set_suppressed(peer_id, true)
	# Always defer local completion so the caller can register its waiting state.
	if _is_local(peer_id):
		_client_speak.call_deferred(request_id, text)
	else:
		rpc_id(peer_id, "_client_speak", request_id, text)
	return true


func cancel_for_peer(peer_id: int) -> void:
	if not _pending.has(peer_id):
		return
	var request_id := str(_pending[peer_id]["id"])
	if _is_local(peer_id):
		if _local_id == request_id:
			_finish_local(false)
			return
	elif multiplayer.get_peers().has(peer_id):
		rpc_id(peer_id, "_client_cancel", request_id)
	_complete_peer(peer_id, request_id, false)


@rpc("authority", "call_remote", "reliable")
func _client_speak(request_id: String, text: String) -> void:
	if request_id.is_empty() or request_id.length() > 128 or text.length() > MAX_TEXT:
		return
	if _seen.has(request_id):
		return
	_seen.append(request_id)
	if _seen.size() > 128:
		_seen.pop_front()
	# Ignore a deferred local command cancelled before it started.
	if _is_authority() and (not _pending.has(_local_peer()) or str(_pending[_local_peer()]["id"]) != request_id):
		return
	if not _local_id.is_empty():
		_abort_local()
	_local_id = request_id
	_stopping = false
	_deadline = Time.get_ticks_msec() + REQUEST_TIMEOUT
	_parts = split_text(text)
	_suppressed_local_peer = _local_peer()
	_set_suppressed(_suppressed_local_peer, true)
	local_speech_changed.emit(true)
	if not enabled or _parts.is_empty():
		_finish_local(false)
		return
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	_http.body_size_limit = MAX_AUDIO_BYTES
	add_child(_http)
	_http.request_completed.connect(_on_audio_received.bind(request_id))
	_retries = 0
	_request_segment()


static func split_text(text: String) -> Array[String]:
	var result: Array[String] = []
	var part := ""
	var index := 0
	while index < text.length():
		var character := text[index]
		part += character
		index += 1
		var boundary := character in ["。", "！", "？", "\n", "；", "!", "?", ";"]
		# An English full stop is a boundary only at end/whitespace, not in 2.5.
		boundary = boundary or (character == "." and (index == text.length() or text[index] in [" ", "\n", "\t"]))
		if boundary:
			while index < text.length() and text[index] in ["”", "’", "）", ")", "\"", "！", "？", "!", "?"]:
				part += text[index]
				index += 1
			_append_chunks(result, part)
			part = ""
	_append_chunks(result, part)
	return result


static func _append_chunks(result: Array[String], sentence: String) -> void:
	var remaining := sentence.strip_edges()
	while remaining.length() > TARGET_SEGMENT_CHARS:
		var cut := -1
		var space_cut := -1
		for index in range(24, TARGET_SEGMENT_CHARS):
			if remaining[index] in ["，", ",", "、", "：", ":"]:
				if remaining[index] in [",", ":"] and remaining[index - 1].is_valid_int() and remaining[index + 1].is_valid_int():
					continue
				cut = index + 1
			elif remaining[index] in [" ", "\t"] and not remaining[index - 1].is_valid_int():
				space_cut = index + 1
		if cut < 0:
			cut = space_cut
		if cut < 0:
			cut = TARGET_SEGMENT_CHARS
			# Don't cut a numeric/Latin token or separate its following unit.
			while cut < mini(remaining.length(), 500) and _token_character(remaining[cut - 1]) and _token_character(remaining[cut]):
				cut += 1
		result.append(remaining.left(cut))
		remaining = remaining.substr(cut).strip_edges()
	if not remaining.is_empty():
		result.append(remaining)


static func _token_character(character: String) -> bool:
	return character in "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.,:_+-·%/ "


func _request_segment() -> void:
	if _local_id.is_empty() or _stopping:
		return
	if _fetching or _next_stream != null:
		return
	if _parts.is_empty():
		if not _playing_segment:
			_finish_local(true)
		return
	_fetching = true
	var error := _http.request(endpoint, PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, JSON.stringify({"text": _parts[0]}))
	if error != OK:
		_fetching = false
		last_error = "Cannot reach local speech service"
		_finish_local(false)


func _on_audio_received(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, request_id: String) -> void:
	if request_id != _local_id or _stopping:
		return
	# A cancelled HTTP request does not stop an in-flight native CPU synthesis.
	if code == 429 and _retries < 60:
		_retries += 1
		await get_tree().create_timer(0.5).timeout
		if request_id == _local_id and not _stopping:
			_fetching = false
			_request_segment()
		return
	_fetching = false
	var rate := 0
	var format_ok := false
	for header in headers:
		if header.to_lower().begins_with("x-sample-rate:"):
			rate = header.get_slice(":", 1).strip_edges().to_int()
		if header.to_lower().begins_with("x-audio-format:"):
			format_ok = header.get_slice(":", 1).strip_edges() == "pcm_s16le"
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or not format_ok or rate < 8000 or rate > 48000 or body.is_empty() or body.size() % 2 != 0 or body.size() > MAX_AUDIO_BYTES:
		last_error = "Local speech unavailable or invalid PCM response (%d)" % code
		push_warning(last_error)
		_finish_local(false)
		return
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = body
	_parts.pop_front()
	_retries = 0
	_next_stream = stream
	_play_buffered_segment()


func _play_buffered_segment() -> void:
	if _playing_segment or _next_stream == null or _stopping or _local_id.is_empty():
		return
	_player.stream = _next_stream
	_next_stream = null
	_playing_segment = true
	_player.play()
	# At most one segment ahead; no second simultaneous inference request.
	_request_segment.call_deferred()


func _on_segment_finished() -> void:
	if _local_id.is_empty() or _stopping:
		return
	_playing_segment = false
	if _next_stream != null:
		_play_buffered_segment()
	else:
		_request_segment()


func _finish_local(success: bool) -> void:
	if _local_id.is_empty() or _stopping:
		return
	_stopping = true
	var finished_id := _local_id
	_player.stop()
	if _http != null:
		_http.cancel_request()
	# Leave a short acoustic tail guard; don't turn the entire microphone off.
	await get_tree().create_timer(0.25).timeout
	if _local_id != finished_id:
		return
	_abort_local()
	if _is_authority():
		_complete_peer(_local_peer(), finished_id, success)
	elif multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		rpc_id(1, "_server_finished", finished_id, success)


func _abort_local() -> void:
	if _http != null:
		_http.cancel_request()
		_http.queue_free()
		_http = null
	if _player != null:
		_player.stop()
		_player.stream = null
	_parts.clear()
	_next_stream = null
	_fetching = false
	_playing_segment = false
	_local_id = ""
	_stopping = false
	if _suppressed_local_peer > 0:
		_set_suppressed(_suppressed_local_peer, false)
	_suppressed_local_peer = 0
	local_speech_changed.emit(false)


@rpc("authority", "call_remote", "reliable")
func _client_cancel(request_id: String) -> void:
	if _local_id == request_id:
		_finish_local(false)


@rpc("any_peer", "call_remote", "reliable")
func _server_finished(request_id: String, success: bool) -> void:
	if multiplayer.is_server():
		_complete_peer(multiplayer.get_remote_sender_id(), request_id, success)


func _complete_peer(peer_id: int, request_id: String, success: bool) -> void:
	if not _pending.has(peer_id) or str(_pending[peer_id]["id"]) != request_id:
		return
	_pending.erase(peer_id)
	_set_suppressed(peer_id, false)
	speech_finished.emit(peer_id, request_id, success)


func _set_suppressed(peer_id: int, active: bool) -> void:
	var voice := get_node_or_null("/root/VoiceChat")
	if voice != null:
		voice.call("set_assistant_speech_active", peer_id, active)


func _on_peer_disconnected(peer_id: int) -> void:
	if _pending.has(peer_id):
		_complete_peer(peer_id, str(_pending[peer_id]["id"]), false)


func _on_server_disconnected() -> void:
	_abort_local()
	_seen.clear()


func _exit_tree() -> void:
	_abort_local()
	for peer in _pending:
		_set_suppressed(int(peer), false)


func _local_peer() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1


func _is_local(peer_id: int) -> bool:
	return peer_id == _local_peer()


func _is_authority() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()
