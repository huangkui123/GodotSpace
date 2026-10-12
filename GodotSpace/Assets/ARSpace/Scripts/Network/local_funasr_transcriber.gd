class_name LocalFunAsrTranscriber
extends Node

signal transcribed_msg(is_final: bool, new_text: String)
signal connection_state_changed(state: String, detail: String)
signal error_occurred(code: int, message: String)

const TARGET_SAMPLE_RATE := 16000
const BYTES_PER_SAMPLE := 2
const DEFAULT_ENDPOINT := "ws://127.0.0.1:8765/ws/asr"

@export_group("Local FunASR")
@export var endpoint_url: String = DEFAULT_ENDPOINT
@export_range(0.001, 0.5, 0.001) var speech_threshold: float = 0.012

@export_group("Recognition")
@export var hotword_list: String = "智能助手 30"
@export var need_vad: bool = true
@export_range(400, 5000, 100) var vad_silence_time: int = 600
@export_range(1000, 90000, 1000) var max_speak_time: int = 15000
@export_range(1000, 5000, 100) var stable_partial_msec: int = 1800

@export_group("Streaming")
@export_range(40, 200, 20) var packet_duration_msec: int = 100
@export_range(1000, 6000, 500) var max_buffered_audio_msec: int = 3000
@export_range(1000, 15000, 500) var connect_timeout_msec: int = 5000
@export var debug_logs: bool = false

var _peer: WebSocketPeer
var _input_active := false
var _start_sent := false
var _ready_for_audio := false
var _finish_requested := false
var _finish_sent := false
var _finished_received := false
var _connection_started_msec := 0
var _source_sample_rate := 48000
var _resample_read_pos := 0.0
var _mono_buffer := PackedFloat32Array()
var _pcm_buffer := PackedByteArray()
var _last_error_message := ""
var _last_close_detail := ""
var _last_transcript_text := ""
var _final_transcript_received := false
var _packets_sent := 0
var _bytes_sent := 0
var _last_endpoint_reason := ""


func _ready() -> void:
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
	var endpoint := _resolved_endpoint()
	if endpoint.is_empty() or not endpoint.begins_with("ws://"):
		_emit_error(ERR_INVALID_PARAMETER, "Local FunASR endpoint must be a ws:// URL.")
		return false
	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = 262144
	var error := _peer.connect_to_url(endpoint)
	if error != OK:
		_peer = null
		_emit_error(error, "Unable to connect to Local FunASR.")
		return false
	_input_active = true
	_start_sent = false
	_ready_for_audio = false
	_finish_requested = false
	_finish_sent = false
	_finished_received = false
	_connection_started_msec = Time.get_ticks_msec()
	_source_sample_rate = max(1, int(AudioServer.get_mix_rate()))
	_last_error_message = ""
	_last_close_detail = ""
	_last_transcript_text = ""
	_final_transcript_received = false
	_packets_sent = 0
	_bytes_sent = 0
	_last_endpoint_reason = ""
	_clear_audio_buffers()
	set_process(true)
	connection_state_changed.emit("connecting", endpoint)
	return true


func stop_transcription() -> void:
	cancel_transcription()


func finish_transcription() -> void:
	if _peer == null:
		return
	_input_active = false
	_finish_requested = true
	_flush_audio_packets(true)
	_send_finish_if_ready()


func cancel_transcription() -> void:
	_input_active = false
	_finish_requested = false
	if _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_peer.send_text(JSON.stringify({"type": "cancel"}))
	_reset_connection(false)


func push_audio_frames(frames: PackedVector2Array) -> void:
	if not _input_active or _peer == null or frames.is_empty():
		return
	_append_resampled_pcm(frames)
	_flush_audio_packets(false)


func push_pcm16_audio(pcm: PackedByteArray) -> void:
	if not _input_active or _peer == null or pcm.is_empty():
		return
	_pcm_buffer.append_array(pcm)
	if not _ready_for_audio:
		_trim_buffered_pcm()
		return
	_flush_audio_packets(false)


func get_debug_state() -> Dictionary:
	return {
		"provider": "funasr",
		"active": _input_active,
		"ready": _ready_for_audio,
		"endpoint": _resolved_endpoint(),
		"source_sample_rate": _source_sample_rate,
		"target_sample_rate": TARGET_SAMPLE_RATE,
		"buffered_pcm_bytes": _pcm_buffer.size(),
		"connection_state": _connection_state_name(),
		"last_error_message": _last_error_message,
		"last_close_detail": _last_close_detail,
		"last_transcript_text": _last_transcript_text,
		"final_transcript_received": _final_transcript_received,
		"packets_sent": _packets_sent,
		"bytes_sent": _bytes_sent,
		"finish_requested": _finish_requested,
		"finish_sent": _finish_sent,
		"last_endpoint_reason": _last_endpoint_reason,
	}


func _process(_delta: float) -> void:
	if _peer == null:
		set_process(false)
		return
	_peer.poll()
	# A server may send the final transcript and immediately close the socket.
	# Drain queued packets before branching on STATE_CLOSED or the final result is
	# lost in the same poll cycle.
	_drain_packets()
	if _peer == null:
		return
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _start_sent:
			_send_start()
		if _ready_for_audio:
			_flush_audio_packets(false)
			_send_finish_if_ready()
	elif state == WebSocketPeer.STATE_CLOSED:
		_last_close_detail = "%d %s" % [_peer.get_close_code(), _peer.get_close_reason()]
		if not _finished_received and not _last_error_message:
			_emit_fallback_final_if_needed()
			connection_state_changed.emit("closed", _last_close_detail)
		_reset_connection(false)
	elif Time.get_ticks_msec() - _connection_started_msec > connect_timeout_msec:
		_emit_error(ERR_TIMEOUT, "Local FunASR connection timed out.")
		_reset_connection(false)


func _send_start() -> void:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var message := {
		"type": "start",
		"sample_rate": TARGET_SAMPLE_RATE,
		"format": "pcm_s16le",
		"need_vad": need_vad,
		"vad_silence_msec": vad_silence_time,
		"max_speak_msec": max_speak_time,
		"stable_partial_msec": stable_partial_msec,
		"speech_threshold": speech_threshold,
		"hotwords": hotword_list,
	}
	var error := _peer.send_text(JSON.stringify(message))
	if error != OK:
		_emit_error(error, "Unable to start Local FunASR stream.")
		_reset_connection(false)
		return
	_start_sent = true


func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		if not _peer.was_string_packet():
			continue
		var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY:
			_handle_message(parsed as Dictionary)


func _handle_message(message: Dictionary) -> void:
	if debug_logs:
		print("Local FunASR recv: " + JSON.stringify(message))
	match str(message.get("type", "")):
		"ready":
			_ready_for_audio = true
			_last_error_message = ""
			connection_state_changed.emit("connected", str(message.get("model", "FunASR")))
		"transcript":
			var text := str(message.get("text", "")).strip_edges()
			if not text.is_empty():
				var is_final := bool(message.get("is_final", false))
				_last_transcript_text = text
				if is_final:
					_final_transcript_received = true
					_last_endpoint_reason = str(message.get("endpoint_reason", ""))
				transcribed_msg.emit(is_final, text)
		"finished":
			_finished_received = true
			_emit_fallback_final_if_needed()
			connection_state_changed.emit("finished", "Local FunASR")
			_reset_connection(false)
		"error":
			_emit_error(ERR_CANT_CONNECT, str(message.get("message", "Local FunASR error.")))
			_reset_connection(false)


func _emit_fallback_final_if_needed() -> void:
	if _final_transcript_received or _last_transcript_text.is_empty():
		return
	_final_transcript_received = true
	transcribed_msg.emit(true, _last_transcript_text)


func _send_finish_if_ready() -> void:
	if not _finish_requested or _finish_sent or not _ready_for_audio or _peer == null:
		return
	if not _pcm_buffer.is_empty():
		return
	var error := _peer.send_text(JSON.stringify({"type": "finish"}))
	if error != OK:
		_emit_error(error, "Unable to finish Local FunASR stream.")
		_reset_connection(false)
		return
	_finish_sent = true
	connection_state_changed.emit("finalizing", "Local FunASR")


func _flush_audio_packets(flush_remainder: bool) -> void:
	if _peer == null or not _ready_for_audio or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var packet_bytes := _packet_bytes()
	while _pcm_buffer.size() >= packet_bytes:
		var packet := _pcm_buffer.slice(0, packet_bytes)
		_pcm_buffer = _pcm_buffer.slice(packet_bytes)
		if not _send_audio_packet(packet):
			return
	if flush_remainder and not _pcm_buffer.is_empty():
		var remainder := _pcm_buffer
		_pcm_buffer = PackedByteArray()
		_send_audio_packet(remainder)


func _send_audio_packet(packet: PackedByteArray) -> bool:
	if _peer == null:
		return false
	var error := _peer.send(packet, WebSocketPeer.WRITE_MODE_BINARY)
	if error != OK:
		_emit_error(error, "Unable to send audio to Local FunASR.")
		_reset_connection(false)
		return false
	_packets_sent += 1
	_bytes_sent += packet.size()
	return true


func _append_resampled_pcm(frames: PackedVector2Array) -> void:
	for frame in frames:
		_mono_buffer.append((frame.x + frame.y) * 0.5)
	var ratio := float(_source_sample_rate) / float(TARGET_SAMPLE_RATE)
	while _resample_read_pos + 1.0 < float(_mono_buffer.size()):
		var index := int(_resample_read_pos)
		var fraction := _resample_read_pos - float(index)
		var sample := lerpf(_mono_buffer[index], _mono_buffer[index + 1], fraction)
		_append_pcm16(sample)
		_resample_read_pos += ratio
	var consumed := int(_resample_read_pos)
	if consumed > 0:
		_mono_buffer = _mono_buffer.slice(consumed)
		_resample_read_pos -= float(consumed)


func _append_pcm16(sample: float) -> void:
	var pcm := int(round(clampf(sample, -1.0, 1.0) * 32767.0))
	_pcm_buffer.append(pcm & 0xff)
	_pcm_buffer.append((pcm >> 8) & 0xff)


func _trim_buffered_pcm() -> void:
	var max_bytes := int(float(TARGET_SAMPLE_RATE * BYTES_PER_SAMPLE * max_buffered_audio_msec) / 1000.0)
	if _pcm_buffer.size() > max_bytes:
		# Dropping the beginning can change the meaning of a command (including
		# losing a negation). Fail visibly instead of submitting truncated speech.
		_emit_error(ERR_OUT_OF_MEMORY, "语音连接过慢，录音缓冲区已满，请重新听写。")
		_reset_connection(false)


func _packet_bytes() -> int:
	return int(float(TARGET_SAMPLE_RATE * BYTES_PER_SAMPLE * packet_duration_msec) / 1000.0)


func _resolved_endpoint() -> String:
	var environment_endpoint := OS.get_environment("LOCAL_ASR_ENDPOINT").strip_edges()
	return environment_endpoint if not environment_endpoint.is_empty() else endpoint_url.strip_edges()


func _connection_state_name() -> String:
	if _peer == null:
		return "closed"
	match _peer.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			return "connecting"
		WebSocketPeer.STATE_OPEN:
			return "open"
		WebSocketPeer.STATE_CLOSING:
			return "closing"
		_:
			return "closed"


func _emit_error(code: int, message: String) -> void:
	_last_error_message = message
	connection_state_changed.emit("error", message)
	error_occurred.emit(code, message)


func _clear_audio_buffers() -> void:
	_resample_read_pos = 0.0
	_mono_buffer.clear()
	_pcm_buffer.clear()


func _reset_connection(emit_closed: bool) -> void:
	if _peer != null:
		_peer.close(1000, "Local FunASR closed")
	_peer = null
	_input_active = false
	_ready_for_audio = false
	_start_sent = false
	_finish_requested = false
	_finish_sent = false
	_clear_audio_buffers()
	set_process(false)
	if emit_closed:
		connection_state_changed.emit("closed", _last_close_detail)
