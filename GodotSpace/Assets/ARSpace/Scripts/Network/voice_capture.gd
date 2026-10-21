class_name VoiceCapture
extends Node

signal opus_packet_captured(packet: PackedByteArray)
signal speaking_changed(is_speaking: bool)
signal pcm_frames_captured(frames: PackedVector2Array)
signal recognition_frames_captured(frames: PackedVector2Array)

const OPUS_EFFECT_CLASS := "AudioEffectOpusChunked"

@export var opus_sample_rate: int = 48000
@export var opus_frame_size: int = 960
@export var opus_bitrate: int = 24000
@export var opus_complexity: int = 5
@export var audio_sample_chunks: int = 50
@export var max_mix_frames_per_process: int = 4096
@export var synthetic_input_enabled: bool = false
@export var synthetic_frequency_hz: float = 220.0
@export var synthetic_peak: float = 0.35

var opus_effect: Object
var microphone_stream: AudioStreamMicrophone
var microphone_playback: AudioStreamPlayback
var pending_audio_frames: PackedVector2Array = PackedVector2Array()
var ptt_active: bool = false
var packets_captured: int = 0
var chunks_dropped_while_inactive: int = 0
var last_input_peak: float = 0.0
var last_input_peak_db: float = -80.0
var last_opus_chunk_peak: float = 0.0
var last_opus_chunk_peak_db: float = -80.0
var frames_read_total: int = 0
var frames_encoded_total: int = 0
var is_setup: bool = false
var configured_opus_properties: Dictionary = {}
var capture_mode: String = "AudioStreamMicrophone.mix_audio"

var _mix_frame_accumulator: float = 0.0
var _synthetic_phase: float = 0.0
var _last_mix_msec: int = 0
var _recognition_skip_frames: int = 0


func discard_pending_recognition_audio() -> void:
	# Exclude already queued capture frames from ASR only. Opus/live voice keeps
	# receiving them. Do not restart WASAPI or flush the shared voice encoder.
	var elapsed := maxf(0.0, float(Time.get_ticks_msec() - _last_mix_msec) / 1000.0) if _last_mix_msec > 0 else 0.0
	_recognition_skip_frames = int(ceil(_mix_frame_accumulator + elapsed * _get_audio_sample_rate()))


func _emit_recognition_frames(frames: PackedVector2Array) -> void:
	var skip := mini(_recognition_skip_frames, frames.size())
	_recognition_skip_frames -= skip
	if skip < frames.size():
		recognition_frames_captured.emit(frames.slice(skip))

func _ready() -> void:
	set_process(false)

func _new_opus_effect() -> Object:
	if not ClassDB.class_exists(OPUS_EFFECT_CLASS):
		return null
	return ClassDB.instantiate(OPUS_EFFECT_CLASS)

func setup() -> void:
	if is_setup:
		return

	if not synthetic_input_enabled:
		_start_microphone_playback()
	opus_effect = _new_opus_effect()
	if opus_effect == null:
		push_error("%s is unavailable. Voice capture cannot encode Opus packets." % OPUS_EFFECT_CLASS)
		_stop_microphone_playback()
		return
	_configure_opus_effect()
	_clear_opus_buffers()
	pending_audio_frames.clear()
	is_setup = true
	set_process(true)

func restart_for_device_change() -> void:
	set_process(false)
	_stop_microphone_playback()
	is_setup = false
	_mix_frame_accumulator = 0.0
	_last_mix_msec = 0
	_recognition_skip_frames = 0
	_clear_opus_buffers()
	_clear_debug_peaks()
	pending_audio_frames.clear()
	setup()

func set_voice_active(active: bool) -> void:
	if ptt_active == active:
		if not active:
			_clear_opus_buffers()
			pending_audio_frames.clear()
		return

	ptt_active = active
	pending_audio_frames.clear()
	_clear_opus_buffers()
	if active:
		_reset_opus_encoder_state()
	else:
		_clear_debug_peaks()
	speaking_changed.emit(ptt_active)

func set_ptt_active(active: bool) -> void:
	set_voice_active(active)

func set_synthetic_input_enabled(enabled: bool) -> void:
	synthetic_input_enabled = enabled
	_synthetic_phase = 0.0
	_clear_debug_peaks()

func _process(delta: float) -> void:
	if opus_effect == null:
		return

	if not synthetic_input_enabled:
		_ensure_microphone_playback_running()
	_read_microphone_frames(delta)

	if not ptt_active:
		pending_audio_frames.clear()
		_clear_opus_buffers()
		return

	_push_pending_audio_chunks()
	_emit_available_opus_packets()

func _start_microphone_playback() -> void:
	microphone_stream = AudioStreamMicrophone.new()
	microphone_playback = microphone_stream.instantiate_playback()
	_ensure_microphone_playback_running()

func _stop_microphone_playback() -> void:
	if microphone_playback != null and microphone_playback.is_playing():
		microphone_playback.stop()
	microphone_playback = null
	microphone_stream = null

func _ensure_microphone_playback_running() -> void:
	if microphone_playback == null:
		_start_microphone_playback()
		return
	if not microphone_playback.is_playing():
		microphone_playback.start()

func _read_microphone_frames(delta: float) -> void:
	if synthetic_input_enabled:
		_read_synthetic_frames(delta)
		return

	if microphone_playback == null or not microphone_playback.is_playing():
		return

	var frames_to_mix := _get_frames_to_mix(delta)
	if frames_to_mix <= 0:
		return

	var frames: PackedVector2Array = microphone_playback.mix_audio(1.0, frames_to_mix)
	if frames.is_empty():
		return

	frames_read_total += frames.size()
	_sample_input_peak_from(frames)
	pcm_frames_captured.emit(frames)
	_emit_recognition_frames(frames)
	if ptt_active:
		pending_audio_frames.append_array(frames)

func _read_synthetic_frames(delta: float) -> void:
	var frames_to_mix := _get_frames_to_mix(delta)
	if frames_to_mix <= 0:
		return

	var audio_sample_rate := _get_audio_sample_rate()
	var frames := PackedVector2Array()
	frames.resize(frames_to_mix)
	var increment := synthetic_frequency_hz / float(audio_sample_rate)
	for i in range(frames_to_mix):
		var t := _synthetic_phase
		var sample := (sin(TAU * t) * 0.75 + sin(TAU * t * 3.0) * 0.25) * synthetic_peak
		frames[i] = Vector2(sample, sample)
		_synthetic_phase = fmod(_synthetic_phase + increment, 1.0)

	frames_read_total += frames.size()
	_sample_input_peak_from(frames)
	pcm_frames_captured.emit(frames)
	_emit_recognition_frames(frames)
	if ptt_active:
		pending_audio_frames.append_array(frames)

func _get_frames_to_mix(delta: float) -> int:
	_last_mix_msec = Time.get_ticks_msec()
	var audio_sample_rate := _get_audio_sample_rate()
	_mix_frame_accumulator += max(delta, 0.0) * float(audio_sample_rate)

	var frames_to_mix := int(_mix_frame_accumulator)
	if frames_to_mix <= 0:
		return 0

	frames_to_mix = min(frames_to_mix, max_mix_frames_per_process)
	_mix_frame_accumulator -= float(frames_to_mix)
	return frames_to_mix

func _configure_opus_effect() -> void:
	if opus_effect == null:
		return

	var audio_sample_rate := _get_audio_sample_rate()
	var audio_frame_size := int(round(float(audio_sample_rate) * float(opus_frame_size) / float(opus_sample_rate)))

	configured_opus_properties.clear()
	_set_property_if_present(opus_effect, "opussamplerate", opus_sample_rate)
	_set_property_if_present(opus_effect, "opusframesize", opus_frame_size)
	_set_property_if_present(opus_effect, "opusbitrate", opus_bitrate)
	_set_property_if_present(opus_effect, "opuscomplexity", opus_complexity)
	_set_property_if_present(opus_effect, "opusoptimizeforvoice", true)
	_set_property_if_present(opus_effect, "audiosamplerate", audio_sample_rate)
	_set_property_if_present(opus_effect, "audiosamplesize", audio_frame_size)
	_set_property_if_present(opus_effect, "audiosamplechunks", audio_sample_chunks)
	_clear_opus_buffers()
	_reset_opus_encoder_state()

func _get_audio_sample_rate() -> int:
	var audio_sample_rate := int(AudioServer.get_mix_rate())
	if audio_sample_rate <= 0:
		audio_sample_rate = opus_sample_rate
	return audio_sample_rate

func _set_property_if_present(target: Object, property_name: String, value) -> bool:
	for property in target.get_property_list():
		if str(property.get("name", "")) == property_name:
			target.set(property_name, value)
			configured_opus_properties[property_name] = target.get(property_name)
			return true
	return false

func _push_pending_audio_chunks() -> void:
	var audio_frame_size := int(configured_opus_properties.get("audiosamplesize", opus_frame_size))
	if audio_frame_size <= 0:
		audio_frame_size = opus_frame_size

	while pending_audio_frames.size() >= audio_frame_size:
		var audio_chunk := pending_audio_frames.slice(0, audio_frame_size)
		pending_audio_frames = pending_audio_frames.slice(audio_frame_size)
		opus_effect.call("push_chunk", audio_chunk)
		frames_encoded_total += audio_chunk.size()

func _emit_available_opus_packets() -> void:
	while _opus_chunk_available():
		_sample_opus_chunk_peak()
		var packet: PackedByteArray = opus_effect.call("read_opus_packet", PackedByteArray())
		opus_effect.call("drop_chunk")
		if packet.size() > 0:
			packets_captured += 1
			opus_packet_captured.emit(packet)

func _clear_opus_buffers() -> void:
	if opus_effect == null:
		return

	while _opus_chunk_available():
		opus_effect.call("drop_chunk")
		chunks_dropped_while_inactive += 1

func _reset_opus_encoder_state() -> void:
	if opus_effect == null:
		return
	if _get_method_arg_count(opus_effect, "resetencoder") == 0:
		opus_effect.call("resetencoder")
	else:
		opus_effect.call("resetencoder", true)

func _sample_input_peak_from(frames: PackedVector2Array) -> void:
	var peak := 0.0
	for frame in frames:
		peak = max(peak, max(abs(frame.x), abs(frame.y)))
	last_input_peak = peak
	last_input_peak_db = linear_to_db(peak) if peak > 0.0 else -80.0

func _sample_opus_chunk_peak() -> void:
	var peak := _get_opus_chunk_max(false, false)
	last_opus_chunk_peak = peak
	last_opus_chunk_peak_db = linear_to_db(peak) if peak > 0.0 else -80.0

func _get_opus_chunk_max(rms: bool, resampled: bool) -> float:
	if opus_effect == null:
		return 0.0
	if _get_method_arg_count(opus_effect, "chunk_max") == 0:
		return float(opus_effect.call("chunk_max"))
	return float(opus_effect.call("chunk_max", rms, resampled))

func _opus_chunk_available() -> bool:
	return opus_effect != null and bool(opus_effect.call("chunk_available"))

func _get_method_arg_count(target: Object, method_name: String) -> int:
	for method in target.get_method_list():
		if str(method.get("name", "")) == method_name:
			return (method.get("args", []) as Array).size()
	return -1

func _clear_debug_peaks() -> void:
	last_input_peak = 0.0
	last_input_peak_db = -80.0
	last_opus_chunk_peak = 0.0
	last_opus_chunk_peak_db = -80.0

func get_debug_state() -> Dictionary:
	return {
		"voice_active": ptt_active,
		"is_setup": is_setup,
		"capture_mode": "Synthetic PCM" if synthetic_input_enabled else capture_mode,
		"synthetic_input_enabled": synthetic_input_enabled,
		"packets_captured": packets_captured,
		"chunks_dropped_while_inactive": chunks_dropped_while_inactive,
		"audio_mix_rate": AudioServer.get_mix_rate(),
		"configured_opus_properties": configured_opus_properties.duplicate(),
		"has_opus_effect": opus_effect != null,
		"has_microphone_playback": microphone_playback != null,
		"microphone_playing": microphone_playback != null and microphone_playback.is_playing(),
		"input_device": AudioServer.get_input_device(),
		"opus_chunk_available": _opus_chunk_available(),
		"capture_frames_available": 0,
		"pending_audio_frames": pending_audio_frames.size(),
		"frames_read_total": frames_read_total,
		"frames_encoded_total": frames_encoded_total,
		"last_input_peak": last_input_peak,
		"last_input_peak_db": last_input_peak_db,
		"last_opus_chunk_peak": last_opus_chunk_peak,
		"last_opus_chunk_peak_db": last_opus_chunk_peak_db,
	}
