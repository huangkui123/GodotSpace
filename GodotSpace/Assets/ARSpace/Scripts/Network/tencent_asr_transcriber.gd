class_name TencentAsrTranscriber
extends Node

signal transcribed_msg(is_final: bool, new_text: String)
signal connection_state_changed(state: String, detail: String)
signal error_occurred(code: int, message: String)

const HOST := "asr.cloud.tencent.com"
const PORT := 443
const TARGET_SAMPLE_RATE := 16000
const BYTES_PER_SAMPLE := 2
const ENV_APP_ID := "TENCENT_ASR_APP_ID"
const ENV_SECRET_ID := "TENCENT_ASR_SECRET_ID"
const ENV_SECRET_KEY := "TENCENT_ASR_SECRET_KEY"
const WS_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const STATE_CLOSED := "closed"
const STATE_TCP_CONNECTING := "tcp_connecting"
const STATE_TLS_HANDSHAKE := "tls_handshake"
const STATE_WS_HANDSHAKE := "ws_handshake"
const STATE_OPEN := "open"

const OPCODE_TEXT := 0x1
const OPCODE_BINARY := 0x2
const OPCODE_CLOSE := 0x8
const OPCODE_PING := 0x9
const OPCODE_PONG := 0xA

@export_group("Tencent Cloud ASR")
@export var engine_model_type: String = "16k_zh_en"
@export var hotword_list: String = ""

@export_group("Recognition")
@export var need_vad: bool = true
@export_range(500, 2000, 100) var vad_silence_time: int = 1000
@export_range(5000, 90000, 1000) var max_speak_time: int = 15000
@export_range(0, 2, 1) var filter_dirty: int = 0
@export_range(0, 2, 1) var filter_modal: int = 0
@export_range(0, 1, 1) var filter_punc: int = 0
@export_range(0, 3, 1) var convert_num_mode: int = 1
@export_range(0, 2, 1) var word_info: int = 0

@export_group("Streaming")
@export_range(40, 200, 40) var packet_duration_msec: int = 200
@export_range(1000, 6000, 500) var max_buffered_audio_msec: int = 3000
@export_range(1000, 15000, 500) var connect_timeout_msec: int = 5000
@export var debug_logs: bool = false

var _tcp: StreamPeerTCP
var _tls: StreamPeerTLS
var _rng := RandomNumberGenerator.new()
var _crypto := Crypto.new()
var _input_active := false
var _handshake_ok := false
var _connection_state := STATE_CLOSED
var _voice_id := ""
var _source_sample_rate := 48000
var _resample_read_pos := 0.0
var _mono_buffer := PackedFloat32Array()
var _pcm_buffer := PackedByteArray()
var _http_response_buffer := PackedByteArray()
var _ws_read_buffer := PackedByteArray()
var _last_error_message := ""
var _last_close_detail := ""
var _credential_source := ""
var _packets_sent := 0
var _bytes_sent := 0
var _finish_requested := false
var _end_sent := false
var _connection_started_msec := 0


func _ready() -> void:
	_rng.randomize()
	set_process(false)


func set_input_active(active: bool) -> void:
	if _input_active == active:
		return
	if active:
		start_transcription()
	else:
		stop_transcription()


func start_transcription() -> bool:
	cancel_transcription()

	var credentials := _get_credentials()
	if str(credentials.get("app_id", "")).is_empty() \
			or str(credentials.get("secret_id", "")).is_empty() \
			or str(credentials.get("secret_key", "")).is_empty():
		_emit_error(0, "Tencent ASR credentials are missing.")
		return false

	_source_sample_rate = max(1, int(AudioServer.get_mix_rate()))
	_voice_id = _make_voice_id()
	_handshake_ok = false
	_input_active = true
	_last_error_message = ""
	_last_close_detail = ""
	_packets_sent = 0
	_bytes_sent = 0
	_finish_requested = false
	_end_sent = false
	_connection_started_msec = Time.get_ticks_msec()
	_clear_audio_buffers()
	_http_response_buffer.clear()
	_ws_read_buffer.clear()

	var path := _build_websocket_path(credentials, _voice_id)
	var request := _build_websocket_request(path)
	_tcp = StreamPeerTCP.new()
	_tls = StreamPeerTLS.new()
	var error := _tcp.connect_to_host(HOST, PORT)
	if error != OK:
		_emit_error(error, "Unable to connect Tencent ASR TCP endpoint.")
		_reset_connection(false)
		return false

	_connection_state = STATE_TCP_CONNECTING
	_http_response_buffer = request
	set_process(true)
	connection_state_changed.emit("connecting", _voice_id)
	return true


func stop_transcription() -> void:
	cancel_transcription()


func finish_transcription() -> void:
	if _connection_state == STATE_CLOSED:
		return
	_input_active = false
	_finish_requested = true
	_send_end_if_ready()


func cancel_transcription() -> void:
	if _connection_state == STATE_CLOSED:
		_input_active = false
		_finish_requested = false
		_end_sent = false
		return
	_input_active = false
	_finish_requested = false
	if _connection_state == STATE_OPEN:
		_send_ws_frame(OPCODE_CLOSE, PackedByteArray())
	_reset_connection(true)


func push_audio_frames(frames: PackedVector2Array) -> void:
	if not _input_active or _connection_state == STATE_CLOSED or frames.is_empty():
		return
	_append_resampled_pcm(frames)
	_flush_audio_packets(false)


func push_pcm16_audio(pcm: PackedByteArray) -> void:
	if not _input_active or _connection_state == STATE_CLOSED or pcm.is_empty():
		return
	_pcm_buffer.append_array(pcm)
	if not _handshake_ok:
		_trim_buffered_pcm()
		return
	_flush_audio_packets(false)


func get_debug_state() -> Dictionary:
	return {
		"active": _input_active,
		"handshake_ok": _handshake_ok,
		"voice_id": _voice_id,
		"source_sample_rate": _source_sample_rate,
		"target_sample_rate": TARGET_SAMPLE_RATE,
		"buffered_pcm_bytes": _pcm_buffer.size(),
		"connection_state": _connection_state,
		"engine_model_type": engine_model_type,
		"last_error_message": _last_error_message,
		"last_close_detail": _last_close_detail,
		"credential_source": _credential_source,
		"packets_sent": _packets_sent,
		"bytes_sent": _bytes_sent,
		"finish_requested": _finish_requested,
		"end_sent": _end_sent,
	}


func _process(_delta: float) -> void:
	if _connection_state != STATE_CLOSED \
			and _connection_state != STATE_OPEN \
			and Time.get_ticks_msec() - _connection_started_msec > connect_timeout_msec:
		_emit_error(ERR_TIMEOUT, "Tencent ASR connection timed out.")
		_reset_connection(false)
		return
	match _connection_state:
		STATE_TCP_CONNECTING:
			_process_tcp_connect()
		STATE_TLS_HANDSHAKE:
			_process_tls_handshake()
		STATE_WS_HANDSHAKE:
			_process_websocket_handshake()
		STATE_OPEN:
			_process_websocket_open()
		_:
			set_process(false)


func _process_tcp_connect() -> void:
	if _tcp == null:
		_reset_connection(false)
		return

	_tcp.poll()
	var status := _tcp.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		var error := _tls.connect_to_stream(_tcp, HOST, TLSOptions.client())
		if error != OK:
			_emit_error(error, "Unable to start Tencent ASR TLS handshake.")
			_reset_connection(false)
			return
		_connection_state = STATE_TLS_HANDSHAKE
	elif status == StreamPeerTCP.STATUS_ERROR:
		_emit_error(-1, "Tencent ASR TCP connection failed.")
		_reset_connection(false)


func _process_tls_handshake() -> void:
	if _tls == null:
		_reset_connection(false)
		return

	_tls.poll()
	var status := _tls.get_status()
	if status == StreamPeerTLS.STATUS_CONNECTED:
		var request := _http_response_buffer
		_http_response_buffer = PackedByteArray()
		var error := _tls.put_data(request)
		if error != OK:
			_emit_error(error, "Unable to send Tencent ASR WebSocket handshake.")
			_reset_connection(false)
			return
		_connection_state = STATE_WS_HANDSHAKE
	elif status == StreamPeerTLS.STATUS_ERROR or status == StreamPeerTLS.STATUS_ERROR_HOSTNAME_MISMATCH:
		_emit_error(status, "Tencent ASR TLS handshake failed.")
		_reset_connection(false)


func _process_websocket_handshake() -> void:
	if _tls != null:
		_tls.poll()
	if not _read_tls_bytes(_http_response_buffer):
		return

	var header_end := _find_header_end(_http_response_buffer)
	if header_end < 0:
		return

	var header_bytes := _http_response_buffer.slice(0, header_end)
	var remaining := _http_response_buffer.slice(header_end + 4)
	_http_response_buffer.clear()
	_ws_read_buffer.append_array(remaining)

	var header_text := header_bytes.get_string_from_utf8()
	if debug_logs:
		print("Tencent ASR handshake response: " + header_text)
	if not header_text.begins_with("HTTP/1.1 101"):
		_emit_error(-1, "Tencent ASR WebSocket handshake failed: " + header_text.get_slice("\r\n", 0))
		_reset_connection(false)
		return

	_connection_state = STATE_OPEN
	connection_state_changed.emit("open", _voice_id)
	_process_ws_frames()


func _process_websocket_open() -> void:
	if _tls == null:
		_reset_connection(false)
		return

	_tls.poll()
	var status := _tls.get_status()
	if status == StreamPeerTLS.STATUS_DISCONNECTED:
		_last_close_detail = "transport disconnected"
		connection_state_changed.emit("closed", _last_close_detail)
		_reset_connection(false)
		return
	if status == StreamPeerTLS.STATUS_ERROR:
		_last_close_detail = "transport error"
		connection_state_changed.emit("closed", _last_close_detail)
		_reset_connection(false)
		return

	_read_tls_bytes(_ws_read_buffer)
	_process_ws_frames()
	if _connection_state == STATE_OPEN and _input_active and _handshake_ok:
		_flush_audio_packets(false)


func _read_tls_bytes(target: PackedByteArray) -> bool:
	if _tls == null:
		return false

	var available := _tls.get_available_bytes()
	if available <= 0:
		return false

	var read_result: Array = _tls.get_data(available)
	var error := int(read_result[0])
	if error != OK:
		_emit_error(error, "Unable to read Tencent ASR TLS data.")
		_reset_connection(false)
		return false

	var bytes: PackedByteArray = read_result[1]
	target.append_array(bytes)
	return true


func _process_ws_frames() -> void:
	while true:
		if _ws_read_buffer.size() < 2:
			return

		var first := int(_ws_read_buffer[0])
		var second := int(_ws_read_buffer[1])
		var opcode := first & 0x0f
		var masked := (second & 0x80) != 0
		var payload_length := second & 0x7f
		var offset := 2

		if payload_length == 126:
			if _ws_read_buffer.size() < offset + 2:
				return
			payload_length = (int(_ws_read_buffer[offset]) << 8) | int(_ws_read_buffer[offset + 1])
			offset += 2
		elif payload_length == 127:
			if _ws_read_buffer.size() < offset + 8:
				return
			payload_length = 0
			for i in range(8):
				payload_length = (payload_length << 8) | int(_ws_read_buffer[offset + i])
			offset += 8

		var mask_key := PackedByteArray()
		if masked:
			if _ws_read_buffer.size() < offset + 4:
				return
			mask_key = _ws_read_buffer.slice(offset, offset + 4)
			offset += 4

		if _ws_read_buffer.size() < offset + payload_length:
			return

		var payload := _ws_read_buffer.slice(offset, offset + payload_length)
		_ws_read_buffer = _ws_read_buffer.slice(offset + payload_length)
		if masked:
			for i in range(payload.size()):
				payload[i] = payload[i] ^ mask_key[i % 4]

		match opcode:
			OPCODE_TEXT:
				_handle_text_message(payload.get_string_from_utf8())
			OPCODE_CLOSE:
				_handle_close_frame(payload)
				return
			OPCODE_PING:
				_send_ws_frame(OPCODE_PONG, payload)
			OPCODE_PONG:
				pass
			OPCODE_BINARY:
				pass


func _handle_text_message(message: String) -> void:
	if debug_logs:
		print("Tencent ASR recv: " + message)

	var parsed = JSON.parse_string(message)
	if typeof(parsed) != TYPE_DICTIONARY:
		return

	var data: Dictionary = parsed
	var code := int(data.get("code", 0))
	if code != 0:
		_emit_error(code, str(data.get("message", "Tencent ASR error.")))
		_send_ws_frame(OPCODE_CLOSE, PackedByteArray())
		_reset_connection(false)
		return

	if not _handshake_ok:
		_handshake_ok = true
		_last_error_message = ""
		connection_state_changed.emit("connected", str(data.get("message", "success")))

	if data.has("result"):
		var result: Dictionary = data.get("result", {})
		var text := str(result.get("voice_text_str", "")).strip_edges()
		if not text.is_empty():
			var slice_type := int(result.get("slice_type", -1))
			transcribed_msg.emit(slice_type == 2, text)

	_send_end_if_ready()

	if int(data.get("final", 0)) == 1:
		connection_state_changed.emit("finished", _voice_id)
		_reset_connection(false)


func _handle_close_frame(payload: PackedByteArray) -> void:
	var code := 1005
	var reason := ""
	if payload.size() >= 2:
		code = (int(payload[0]) << 8) | int(payload[1])
	if payload.size() > 2:
		reason = payload.slice(2).get_string_from_utf8()
	_last_close_detail = "%s %s" % [code, reason]
	connection_state_changed.emit("closed", _last_close_detail)
	_reset_connection(false)


func _append_resampled_pcm(frames: PackedVector2Array) -> void:
	for frame in frames:
		_mono_buffer.append((frame.x + frame.y) * 0.5)

	var ratio := float(_source_sample_rate) / float(TARGET_SAMPLE_RATE)
	while _resample_read_pos + 1.0 < float(_mono_buffer.size()):
		var index := int(_resample_read_pos)
		var fraction := _resample_read_pos - float(index)
		var sample := lerpf(_mono_buffer[index], _mono_buffer[index + 1], fraction)
		_append_pcm16_sample(sample)
		_resample_read_pos += ratio

	var consumed := int(_resample_read_pos)
	if consumed > 0:
		_mono_buffer = _mono_buffer.slice(consumed)
		_resample_read_pos -= float(consumed)

	if not _handshake_ok:
		_trim_buffered_pcm()


func _append_pcm16_sample(sample: float) -> void:
	var clamped := clampf(sample, -1.0, 1.0)
	var pcm := int(round(clamped * 32767.0))
	if clamped <= -1.0:
		pcm = -32768
	if pcm < 0:
		pcm += 65536
	_pcm_buffer.append(pcm & 0xff)
	_pcm_buffer.append((pcm >> 8) & 0xff)


func _flush_audio_packets(force: bool) -> void:
	if _connection_state != STATE_OPEN or not _handshake_ok:
		_trim_buffered_pcm()
		return

	var packet_bytes := _get_packet_bytes()
	while _pcm_buffer.size() >= packet_bytes:
		if not _send_pcm_packet(_pcm_buffer.slice(0, packet_bytes)):
			return
		_pcm_buffer = _pcm_buffer.slice(packet_bytes)

	if force and _pcm_buffer.size() > 0:
		_send_pcm_packet(_pcm_buffer)
		_pcm_buffer.clear()


func _send_end_if_ready() -> void:
	if not _finish_requested or _end_sent:
		return
	if _connection_state != STATE_OPEN or not _handshake_ok:
		return
	_flush_audio_packets(true)
	if _send_ws_text(JSON.stringify({"type": "end"})):
		_end_sent = true
		connection_state_changed.emit("finalizing", _voice_id)


func _send_pcm_packet(packet: PackedByteArray) -> bool:
	if not _send_ws_frame(OPCODE_BINARY, packet):
		return false
	_packets_sent += 1
	_bytes_sent += packet.size()
	return true


func _send_ws_text(text: String) -> bool:
	return _send_ws_frame(OPCODE_TEXT, text.to_utf8_buffer())


func _send_ws_frame(opcode: int, payload: PackedByteArray) -> bool:
	if _tls == null or _connection_state == STATE_CLOSED:
		return false

	var frame := PackedByteArray()
	frame.append(0x80 | (opcode & 0x0f))
	var length := payload.size()
	if length <= 125:
		frame.append(0x80 | length)
	elif length <= 65535:
		frame.append(0x80 | 126)
		frame.append((length >> 8) & 0xff)
		frame.append(length & 0xff)
	else:
		frame.append(0x80 | 127)
		for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
			frame.append((length >> shift) & 0xff)

	var mask_key := PackedByteArray()
	for i in range(4):
		mask_key.append(_rng.randi_range(0, 255))
	frame.append_array(mask_key)

	for i in range(payload.size()):
		frame.append(payload[i] ^ mask_key[i % 4])

	var error := _tls.put_data(frame)
	if error != OK:
		_emit_error(error, "Unable to send Tencent ASR WebSocket frame.")
		return false
	return true


func _trim_buffered_pcm() -> void:
	var max_bytes := int(float(TARGET_SAMPLE_RATE * BYTES_PER_SAMPLE * max_buffered_audio_msec) / 1000.0)
	if _pcm_buffer.size() > max_bytes:
		_pcm_buffer = _pcm_buffer.slice(_pcm_buffer.size() - max_bytes)


func _get_packet_bytes() -> int:
	return int(float(TARGET_SAMPLE_RATE * BYTES_PER_SAMPLE * packet_duration_msec) / 1000.0)


func _build_websocket_path(credentials: Dictionary, voice_id: String) -> String:
	var now := int(Time.get_unix_time_from_system())
	var app_id_text := str(credentials["app_id"])
	var params := {
		"engine_model_type": engine_model_type,
		"expired": str(now + 86400),
		"filter_dirty": str(filter_dirty),
		"filter_modal": str(filter_modal),
		"filter_punc": str(filter_punc),
		"needvad": "1" if need_vad else "0",
		"nonce": str(_rng.randi_range(100000000, 2147483647)),
		"secretid": str(credentials["secret_id"]),
		"timestamp": str(now),
		"voice_format": "1",
		"voice_id": voice_id,
		"convert_num_mode": str(convert_num_mode),
		"word_info": str(word_info),
	}
	if need_vad:
		params["vad_silence_time"] = str(vad_silence_time)
		params["max_speak_time"] = str(max_speak_time)
	if not hotword_list.strip_edges().is_empty():
		params["hotword_list"] = hotword_list.strip_edges()

	var signed_query := _build_query(params, false)
	var sign_source := "%s/asr/v2/%s?%s" % [HOST, app_id_text, signed_query]
	var digest := _crypto.hmac_digest(
			HashingContext.HASH_SHA1,
			str(credentials["secret_key"]).to_utf8_buffer(),
			sign_source.to_utf8_buffer()
	)
	params["signature"] = Marshalls.raw_to_base64(digest)
	return "/asr/v2/%s?%s" % [app_id_text, _build_query(params, true)]


func _build_websocket_request(path: String) -> PackedByteArray:
	var key := _make_websocket_key()
	var request := "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % [path, HOST, key]
	return request.to_utf8_buffer()


func _make_websocket_key() -> String:
	var bytes := PackedByteArray()
	for i in range(16):
		bytes.append(_rng.randi_range(0, 255))
	return Marshalls.raw_to_base64(bytes)


func _build_query(params: Dictionary, url_encode_values: bool) -> String:
	var keys := params.keys()
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		var key_text := str(key)
		var value_text := str(params[key])
		if url_encode_values:
			parts.append("%s=%s" % [key_text.uri_encode(), value_text.uri_encode()])
		else:
			parts.append("%s=%s" % [key_text, value_text])
	return "&".join(parts)


func _get_credentials() -> Dictionary:
	_credential_source = "environment"
	var resolved_app_id := OS.get_environment(ENV_APP_ID).strip_edges()
	var resolved_secret_id := OS.get_environment(ENV_SECRET_ID).strip_edges()
	var resolved_secret_key := OS.get_environment(ENV_SECRET_KEY).strip_edges()
	return {
		"app_id": resolved_app_id,
		"secret_id": resolved_secret_id,
		"secret_key": resolved_secret_key,
	}


func _make_voice_id() -> String:
	return "%s_%s_%s" % [
		str(Time.get_ticks_msec()),
		str(_rng.randi_range(100000, 999999)),
		str(_rng.randi_range(100000, 999999)),
	]


func _find_header_end(buffer: PackedByteArray) -> int:
	for i in range(max(0, buffer.size() - 3)):
		if int(buffer[i]) == 13 and int(buffer[i + 1]) == 10 and int(buffer[i + 2]) == 13 and int(buffer[i + 3]) == 10:
			return i
	return -1


func _clear_audio_buffers() -> void:
	_resample_read_pos = 0.0
	_mono_buffer.clear()
	_pcm_buffer.clear()


func _reset_connection(emit_stopped: bool) -> void:
	_close_transport()
	_connection_state = STATE_CLOSED
	_handshake_ok = false
	_input_active = false
	_finish_requested = false
	_end_sent = false
	_connection_started_msec = 0
	_http_response_buffer.clear()
	_ws_read_buffer.clear()
	_clear_audio_buffers()
	set_process(false)
	if emit_stopped:
		connection_state_changed.emit("stopped", "")


func _close_transport() -> void:
	if _tls != null and _tls.has_method("disconnect_from_stream"):
		_tls.disconnect_from_stream()
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tls = null
	_tcp = null


func _emit_error(code: int, message: String) -> void:
	_last_error_message = "%s (%s)" % [message, code]
	push_warning("Tencent ASR: " + _last_error_message)
	error_occurred.emit(code, _last_error_message)
	connection_state_changed.emit("error", _last_error_message)
