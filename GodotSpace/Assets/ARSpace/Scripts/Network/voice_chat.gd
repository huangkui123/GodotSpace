extends Node

signal voice_enabled_changed(enabled: bool)
signal remote_speaking_changed(peer_id: int, is_speaking: bool)
signal voice_level_changed(peer_id: int, state: Dictionary)
signal voice_transcript_received(data: Dictionary)
signal assistant_interaction_state_changed(data: Dictionary)
signal transcription_enabled_changed(enabled: bool)

const SERVER_PEER_ID := 1
const SERVER_SOURCE_ID := 1
const XR_CLIENT_ARG := "--xr-client"
const XR_MODE_ARG := "--xr-mode"
const VOICE_ROLE_ARG := "--voice-role="
const VOICE_TEST_TONE_ARG := "--voice-test-tone"
const VOICE_DEBUG_ARG := "--voice-debug"
const VOICE_LOG_PATH_ARG := "--voice-log-path="
const DEFAULT_VOICE_LOG_PATH := "user://voice_chat_debug.log"
const VOICE_LEVEL_SEND_INTERVAL := 0.1
const SERVER_VOLUME_PANEL_UPDATE_INTERVAL := 0.1
const VOICE_LEVEL_STALE_SECONDS := 1.5
const VOICE_LEVEL_MIN_DB := -60.0
const VOICE_LEVEL_MAX_DB := 0.0
const TRANSCRIPTION_TARGET_SAMPLE_RATE := 16000
const TRANSCRIPTION_BYTES_PER_SAMPLE := 2
const TRANSCRIPTION_UPLOAD_CHUNK_MSEC := 200
const VoiceCaptureScript := preload("res://Assets/ARSpace/Scripts/Network/voice_capture.gd")
const VoiceTransportScript := preload("res://Assets/ARSpace/Scripts/Network/voice_transport_enet.gd")
const VoicePlaybackScript := preload("res://Assets/ARSpace/Scripts/Network/voice_playback.gd")
const TencentAsrTranscriberScript := preload("res://Assets/ARSpace/Scripts/Network/tencent_asr_transcriber.gd")
const TENCENT_ASR_CONFIG_PROPERTIES := [
	"app_id",
	"secret_id",
	"secret_key",
	"use_environment_credentials",
	"engine_model_type",
	"hotword_list",
	"need_vad",
	"vad_silence_time",
	"max_speak_time",
	"filter_dirty",
	"filter_modal",
	"filter_punc",
	"convert_num_mode",
	"word_info",
	"packet_duration_msec",
	"max_buffered_audio_msec",
	"debug_logs",
]
const VR_INPUT_DEVICE_HINTS := [
	"PicoStreamingMicrophone",
	"PicoStreaming",
	"Pico Streaming Speaker",
	"Headset Microphone (Oculus Virtual Audio Device)",
	"Pico Streaming",
	"Oculus Virtual Audio",
]
const VR_OUTPUT_DEVICE_HINTS := [
	"Pico Streaming Speaker",
	"Oculus Virtual Audio Device",
	"Pico Streaming",
	"Oculus Virtual Audio",
]
const PC_INPUT_DEVICE_HINTS := [
	"Realtek(R) Audio",
	"Microphone Array (Realtek",
	"Realtek",
	"AirPods",
]
const PC_OUTPUT_DEVICE_HINTS := [
	"Realtek(R) Audio",
	"Speakers (Realtek",
	"Realtek",
	"AirPods",
]

var voice_enabled: bool = false
var voice_players: Dictionary = {}
var packets_received: int = 0
var packets_sent: int = 0
var is_vr_mode: bool = false
var voice_endpoint_selected: bool = false

var capture: Node
var transport: Node
var playback: Node
var transcription_config: Node

var selected_input_device: String = "Default"
var selected_output_device: String = "Default"
@export var voice_debug_enabled: bool = false
@export var voice_debug_controls_enabled: bool = false
@export var voice_debug_shortcuts_enabled: bool = false
var debug_voice_stats: bool = false
var debug_voice_stats_to_error_console: bool = false
var _debug_log_accum: float = 0.0
var _last_debug_signature: String = ""
var _output_test_player: AudioStreamPlayer
var _output_test_playback: AudioStreamGeneratorPlayback
var _output_test_remaining_frames: int = 0
var _output_test_phase: float = 0.0
var _mic_monitor_player: AudioStreamPlayer
var _manual_input_device: String = ""
var _manual_output_device: String = ""
var voice_log_path: String = DEFAULT_VOICE_LOG_PATH
var _debug_controls_layer: CanvasLayer
var _debug_status_label: Label
var _silent_input_seconds: float = 0.0
var _silent_input_warning_key: String = ""
var _remote_playback_seconds: float = 0.0
var _remote_playback_warning_key: String = ""
var voice_level_states: Dictionary = {}
var _voice_level_send_accum: float = 0.0
var voice_transcript_history: Array = []
var _transcript_utterance_ids: Dictionary = {}
var transcription_enabled: bool = true
var _peer_transcribers: Dictionary = {}
var _client_transcription_source_sample_rate: int = 48000
var _client_transcription_resample_read_pos: float = 0.0
var _client_transcription_mono_buffer := PackedFloat32Array()
var _client_transcription_pcm_buffer := PackedByteArray()

func _ready() -> void:
	if _has_cmdline_arg(VOICE_DEBUG_ARG):
		voice_debug_enabled = true
		voice_debug_controls_enabled = true
		voice_debug_shortcuts_enabled = true
		debug_voice_stats = true

	voice_log_path = _get_arg_value(VOICE_LOG_PATH_ARG)
	if voice_log_path == "":
		voice_log_path = DEFAULT_VOICE_LOG_PATH

	_request_runtime_audio_permissions()
	_setup_components()
	_connect_multiplayer_signals()

	if NetworkHandler.has_signal("network_role_selected"):
		NetworkHandler.network_role_selected.connect(_on_network_role_selected)
	if NetworkHandler.has_signal("network_ready"):
		NetworkHandler.network_ready.connect(_on_network_ready)

	_select_voice_role_from_args()
	_log("VoiceChat initialized with two-voip components. %s Log: %s" % [
		"Mode: %s." % _get_voice_mode_label() if voice_endpoint_selected else "Waiting for server/client selection.",
		ProjectSettings.globalize_path(voice_log_path),
	])
	_log("VoiceChat debug keys: Shift+1 output tone, Shift+2 direct-capture monitor note, Shift+3 cycle input, Shift+4 cycle output. mix_rate=%s" % AudioServer.get_mix_rate())

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_voice"):
		toggle_voice()
		get_viewport().set_input_as_handled()
	elif voice_debug_shortcuts_enabled:
		if _is_shift_digit_pressed(event, KEY_1):
			play_output_test_tone()
			get_viewport().set_input_as_handled()
		elif _is_shift_digit_pressed(event, KEY_2):
			play_microphone_monitor_test()
			get_viewport().set_input_as_handled()
		elif _is_shift_digit_pressed(event, KEY_3):
			cycle_voice_input_device()
			get_viewport().set_input_as_handled()
		elif _is_shift_digit_pressed(event, KEY_4):
			cycle_voice_output_device()
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	_pump_output_test_tone()
	_update_voice_level_state(delta)
	_log_voice_pipeline_state(delta)

func toggle_voice() -> void:
	set_voice_enabled(not voice_enabled)

func set_voice_enabled(enabled: bool) -> void:
	if enabled and not voice_endpoint_selected:
		_log("VoiceChat role is not selected yet. Start server or client before enabling voice.")
		return

	if voice_enabled == enabled:
		if capture != null:
			capture.set_voice_active(enabled)
		return

	voice_enabled = enabled
	if capture != null:
		capture.set_voice_active(voice_enabled)

	if transport != null:
		transport.send_speaking_state(voice_enabled)
		if multiplayer.is_server():
			for peer_id in multiplayer.get_peers():
				transport.send_server_speaking_state_to_peer(peer_id, voice_enabled)

	if multiplayer.is_server():
		_set_peer_transcription_active(_get_local_voice_peer_id(), voice_enabled)
	else:
		_reset_client_transcription_upload()

	voice_enabled_changed.emit(voice_enabled)
	_log("Voice %s" % ("enabled" if voice_enabled else "disabled"))
	_update_debug_controls()

func start_voice_chat() -> void:
	set_voice_enabled(true)

func stop_voice_chat() -> void:
	set_voice_enabled(false)

func toggle_transcription() -> void:
	set_transcription_enabled(not transcription_enabled)

func set_transcription_enabled(enabled: bool) -> void:
	if not multiplayer.is_server():
		return
	if transcription_enabled == enabled:
		return

	transcription_enabled = enabled
	if not transcription_enabled:
		_stop_all_transcription()
		_reset_client_transcription_upload()
	else:
		for peer_id in _get_open_mic_peer_ids():
			_set_peer_transcription_active(int(peer_id), true)

	_broadcast_transcription_enabled()
	transcription_enabled_changed.emit(transcription_enabled)
	_log("Transcription %s" % ("enabled" if transcription_enabled else "disabled"))

func remove_player(peer_id: int) -> void:
	if playback != null:
		playback.remove_source(peer_id)

func play_output_test_tone(duration_seconds: float = 1.5, frequency_hz: float = 880.0) -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = AudioServer.get_mix_rate()
	generator.buffer_length = 0.25

	if _output_test_player != null and is_instance_valid(_output_test_player):
		_output_test_player.queue_free()

	_output_test_player = AudioStreamPlayer.new()
	_output_test_player.name = "VoiceOutputTestTone"
	_output_test_player.stream = generator
	_output_test_player.bus = "Master"
	_output_test_player.volume_db = -8.0
	add_child(_output_test_player)
	_output_test_player.play()
	_output_test_playback = _output_test_player.get_stream_playback()
	_output_test_remaining_frames = int(duration_seconds * generator.mix_rate)
	_output_test_phase = 0.0
	_log("Voice output test tone started output=%s bus=Master duration=%.2fs frequency=%.1fHz" % [
		AudioServer.get_output_device(),
		duration_seconds,
		frequency_hz,
	])
	_pump_output_test_tone(frequency_hz)

func play_microphone_monitor_test(duration_seconds: float = 0.0) -> void:
	if capture != null:
		var capture_state: Dictionary = capture.get_debug_state()
		if str(capture_state.get("capture_mode", "")) == "AudioStreamMicrophone.mix_audio":
			_log("Voice microphone monitor is unavailable while direct voice capture owns the microphone. Use Voice pipeline in_peak_db/opus_peak_db for input verification.")
			return

	if _mic_monitor_player != null and is_instance_valid(_mic_monitor_player):
		_stop_microphone_monitor_test()
		return

	_mic_monitor_player = AudioStreamPlayer.new()
	_mic_monitor_player.name = "VoiceMicrophoneMonitorTest"
	_mic_monitor_player.stream = AudioStreamMicrophone.new()
	_mic_monitor_player.bus = "Master"
	_mic_monitor_player.volume_db = -12.0
	add_child(_mic_monitor_player)
	_mic_monitor_player.play()
	var duration_label := "continuous" if duration_seconds <= 0.0 else "%.2fs" % duration_seconds
	_log("Voice microphone monitor started input=%s output=%s duration=%s" % [
		AudioServer.get_input_device(),
		AudioServer.get_output_device(),
		duration_label,
	])
	if duration_seconds > 0.0:
		get_tree().create_timer(duration_seconds).timeout.connect(_stop_microphone_monitor_test)
	_update_debug_controls()

func _stop_microphone_monitor_test() -> void:
	if _mic_monitor_player != null and is_instance_valid(_mic_monitor_player):
		_mic_monitor_player.stop()
		_mic_monitor_player.queue_free()
	_mic_monitor_player = null
	_log("Voice microphone monitor stopped input=%s" % AudioServer.get_input_device())
	_update_debug_controls()

func cycle_voice_input_device() -> void:
	var devices := AudioServer.get_input_device_list()
	if devices.size() == 0:
		_log("Voice input cycle failed: no input devices")
		return

	var current := AudioServer.get_input_device()
	var index := devices.find(current)
	if index == -1:
		index = 0
	else:
		index = (index + 1) % devices.size()

	_manual_input_device = devices[index]
	selected_input_device = _manual_input_device
	AudioServer.input_device = _manual_input_device
	if capture != null and capture.has_method("restart_for_device_change"):
		capture.restart_for_device_change()
	_log("Voice input device cycled input=%s" % AudioServer.get_input_device())
	_print_audio_device_state("input cycled")
	_update_debug_controls()

func cycle_voice_output_device() -> void:
	var devices := AudioServer.get_output_device_list()
	if devices.size() == 0:
		_log("Voice output cycle failed: no output devices")
		return

	var current := AudioServer.get_output_device()
	var index := devices.find(current)
	if index == -1:
		index = 0
	else:
		index = (index + 1) % devices.size()

	_manual_output_device = devices[index]
	selected_output_device = _manual_output_device
	AudioServer.output_device = _manual_output_device
	_log("Voice output device cycled selected=%s actual=%s" % [_manual_output_device, AudioServer.get_output_device()])
	_print_audio_device_state("output cycled")
	_update_debug_controls()

func get_debug_state() -> Dictionary:
	return {
		"voice_enabled": voice_enabled,
		"voice_endpoint_selected": voice_endpoint_selected,
		"is_vr_mode": is_vr_mode,
		"network_role": _get_network_role(),
		"peer_id": multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0,
		"connected_peers": multiplayer.get_peers() if multiplayer.has_multiplayer_peer() else [],
		"input_device": AudioServer.get_input_device(),
		"output_device": AudioServer.get_output_device(),
		"selected_input_device": selected_input_device,
		"selected_output_device": selected_output_device,
		"packets_sent": packets_sent,
		"packets_received": packets_received,
		"transcription_enabled": transcription_enabled,
		"transcription": _get_transcription_debug_state(),
		"voice_level_states": voice_level_states.duplicate(true),
		"capture": capture.get_debug_state() if capture != null else {},
		"transport": transport.get_debug_state() if transport != null else {},
		"playback": playback.get_debug_state() if playback != null else {},
	}


func _get_transcription_debug_state() -> Dictionary:
	var peers: Array[Dictionary] = []
	var last_error := ""
	for peer_id in _peer_transcribers.keys():
		var transcriber := _peer_transcribers[peer_id] as Node
		if transcriber == null or not is_instance_valid(transcriber) or not transcriber.has_method("get_debug_state"):
			continue
		var state: Dictionary = transcriber.call("get_debug_state")
		state["peer_id"] = int(peer_id)
		peers.append(state)
		var error_text := str(state.get("last_error_message", ""))
		if not error_text.is_empty():
			last_error = error_text
	return {
		"active_peer_count": peers.size(),
		"peers": peers,
		"last_error_message": last_error,
	}

func get_preferred_pc_input_device() -> String:
	return _select_audio_device(AudioServer.get_input_device_list(), PC_INPUT_DEVICE_HINTS, _manual_input_device, "input")

func get_preferred_pc_output_device() -> String:
	return _select_audio_device(AudioServer.get_output_device_list(), PC_OUTPUT_DEVICE_HINTS, _manual_output_device, "output")

func set_pc_audio_devices(input_device: String, output_device: String) -> void:
	set_audio_devices(input_device, output_device)

func get_preferred_input_device() -> String:
	return get_preferred_input_device_for_mode(_is_vr_mode_requested())

func get_preferred_output_device() -> String:
	return get_preferred_output_device_for_mode(_is_vr_mode_requested())

func get_preferred_input_device_for_mode(vr_mode: bool) -> String:
	var hints := VR_INPUT_DEVICE_HINTS if vr_mode else PC_INPUT_DEVICE_HINTS
	return _select_audio_device(AudioServer.get_input_device_list(), hints, _manual_input_device, "input")

func get_preferred_output_device_for_mode(vr_mode: bool) -> String:
	var hints := VR_OUTPUT_DEVICE_HINTS if vr_mode else PC_OUTPUT_DEVICE_HINTS
	return _select_audio_device(AudioServer.get_output_device_list(), hints, _manual_output_device, "output")

func set_audio_devices(input_device: String, output_device: String) -> void:
	_manual_input_device = input_device
	_manual_output_device = output_device
	selected_input_device = input_device
	selected_output_device = output_device

	if voice_endpoint_selected:
		_apply_audio_device_profile()
		if capture != null and capture.has_method("restart_for_device_change"):
			capture.restart_for_device_change()

func _setup_components() -> void:
	capture = get_node_or_null("VoiceCapture")
	if capture == null:
		capture = VoiceCaptureScript.new()
		capture.name = "VoiceCapture"
		add_child(capture)
	capture.opus_packet_captured.connect(_on_local_opus_packet_captured)
	capture.speaking_changed.connect(_on_local_speaking_changed)
	capture.pcm_frames_captured.connect(_on_local_pcm_frames_captured)

	transport = get_node_or_null("VoiceTransportENet")
	if transport == null:
		transport = VoiceTransportScript.new()
		transport.name = "VoiceTransportENet"
		add_child(transport)
	transport.server_voice_packet_received.connect(_on_server_voice_packet_received)
	transport.downlink_voice_packet_received.connect(_on_downlink_voice_packet_received)
	transport.speaking_state_received.connect(_on_remote_speaking_state_received)
	transport.voice_level_received.connect(_on_voice_level_received)
	transport.transcription_pcm_received.connect(_on_transcription_pcm_received)
	transport.transcript_received.connect(_on_transport_transcript_received)
	transport.assistant_interaction_state_received.connect(_on_assistant_interaction_state_received)
	transport.transcription_enabled_received.connect(_on_transport_transcription_enabled_received)

	playback = get_node_or_null("VoicePlayback")
	if playback == null:
		playback = VoicePlaybackScript.new()
		playback.name = "VoicePlayback"
		add_child(playback)
	voice_players = playback.players

	transcription_config = get_node_or_null("TencentAsrConfig")

func _connect_multiplayer_signals() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_local_opus_packet_captured(packet: PackedByteArray) -> void:
	if not voice_enabled or not multiplayer.has_multiplayer_peer():
		return

	if multiplayer.is_server():
		for peer_id in multiplayer.get_peers():
			if transport.send_downlink_voice_packet(peer_id, packet):
				packets_sent += 1
	else:
		if transport.send_voice_packet(packet):
			packets_sent += 1

func _on_server_voice_packet_received(sender_peer_id: int, packet: PackedByteArray) -> void:
	if not multiplayer.is_server() or packet.size() == 0:
		return

	packets_received += 1
	if sender_peer_id == multiplayer.get_unique_id():
		return

	playback.push_source_packet(sender_peer_id, packet)

func _on_downlink_voice_packet_received(packet: PackedByteArray) -> void:
	if multiplayer.is_server() or packet.size() == 0:
		return

	packets_received += 1
	playback.push_source_packet(SERVER_SOURCE_ID, packet)

func _on_local_pcm_frames_captured(frames: PackedVector2Array) -> void:
	if not voice_enabled or frames.is_empty():
		return
	if not voice_endpoint_selected or not multiplayer.has_multiplayer_peer():
		return
	if not transcription_enabled:
		return

	if multiplayer.is_server():
		var peer_id := _get_local_voice_peer_id()
		if _is_peer_mic_open(peer_id):
			_feed_transcription_frames(peer_id, frames)
	else:
		_queue_client_transcription_pcm(frames)

func _on_local_speaking_changed(is_speaking: bool) -> void:
	var peer_id := _get_local_voice_peer_id()
	if multiplayer.is_server():
		_set_voice_level_mic_state(peer_id, is_speaking)
		_set_peer_transcription_active(peer_id, is_speaking)
	remote_speaking_changed.emit(peer_id, is_speaking)

func _on_remote_speaking_state_received(peer_id: int, is_speaking: bool) -> void:
	if multiplayer.is_server():
		_set_voice_level_mic_state(peer_id, is_speaking)
		_set_peer_transcription_active(peer_id, is_speaking)
	remote_speaking_changed.emit(peer_id, is_speaking)

func _on_voice_level_received(peer_id: int, peak: float, peak_db: float, mic_open: bool) -> void:
	if not multiplayer.is_server():
		return
	_store_voice_level_state(peer_id, peak, peak_db, mic_open)
	_set_peer_transcription_active(peer_id, mic_open)

func _on_transcription_pcm_received(sender_peer_id: int, pcm: PackedByteArray) -> void:
	if not multiplayer.is_server() or pcm.is_empty():
		return
	if not transcription_enabled:
		return
	if sender_peer_id <= 0 or sender_peer_id == _get_local_voice_peer_id():
		return
	if not _is_peer_mic_open(sender_peer_id):
		return
	_feed_transcription_pcm(sender_peer_id, pcm)

func _on_transport_transcript_received(data: Dictionary) -> void:
	_store_transcript_data(data)
	voice_transcript_received.emit(data.duplicate(true))


func _on_assistant_interaction_state_received(data: Dictionary) -> void:
	assistant_interaction_state_changed.emit(data.duplicate(true))


func _on_transport_transcription_enabled_received(enabled: bool) -> void:
	if multiplayer.is_server():
		return
	transcription_enabled = enabled
	if not transcription_enabled:
		_reset_client_transcription_upload()
	transcription_enabled_changed.emit(transcription_enabled)

func _on_network_role_selected(is_server_role: bool, context: String = "") -> void:
	_set_voice_endpoint_role(is_server_role)
	_print_audio_device_state(context if context != "" else "server selected" if is_server_role else "client selected")

func _on_network_ready() -> void:
	if transport != null and voice_enabled:
		transport.send_speaking_state(true)
	if voice_endpoint_selected:
		_apply_audio_device_profile()
	if multiplayer.is_server():
		_set_voice_level_mic_state(SERVER_PEER_ID, voice_enabled)
		_set_peer_transcription_active(SERVER_PEER_ID, voice_enabled)
		_broadcast_transcription_enabled()
	_log("VoiceChat network ready")

func _on_peer_connected(peer_id: int) -> void:
	_log("Voice peer connected: %d" % peer_id)
	if multiplayer.is_server() and transport != null:
		transport.send_server_speaking_state_to_peer(peer_id, voice_enabled)
		transport.send_transcription_enabled_to_peer(peer_id, transcription_enabled)
	if multiplayer.is_server():
		_set_voice_level_mic_state(peer_id, false)

func _on_peer_disconnected(peer_id: int) -> void:
	_log("Voice peer disconnected: %d" % peer_id)
	remove_player(peer_id)
	voice_level_states.erase(peer_id)
	_stop_peer_transcription(peer_id)

func _on_connected_to_server() -> void:
	_log("VoiceChat connected to server")
	if not voice_endpoint_selected:
		_on_network_role_selected(false)
	else:
		_apply_audio_device_profile()
	if transport != null and voice_enabled:
		transport.send_speaking_state(true)

func _on_connection_failed() -> void:
	_log("VoiceChat connection failed")
	set_voice_enabled(false)
	_stop_all_transcription()
	if playback != null:
		playback.clear()

func _on_server_disconnected() -> void:
	_log("VoiceChat server disconnected")
	set_voice_enabled(false)
	_stop_all_transcription()
	_reset_client_transcription_upload()
	if playback != null:
		playback.clear()

func _update_voice_level_state(delta: float) -> void:
	if not voice_endpoint_selected or capture == null or transport == null:
		return

	_voice_level_send_accum += delta
	if _voice_level_send_accum < VOICE_LEVEL_SEND_INTERVAL:
		return
	_voice_level_send_accum = 0.0

	var capture_state: Dictionary = capture.get_debug_state()
	var peak := clampf(float(capture_state.get("last_input_peak", 0.0)), 0.0, 1.0)
	var peak_db := clampf(float(capture_state.get("last_input_peak_db", -80.0)), -80.0, 12.0)
	if multiplayer.is_server():
		_store_voice_level_state(_get_local_voice_peer_id(), peak, peak_db, voice_enabled)
	elif multiplayer.has_multiplayer_peer():
		transport.send_voice_level_state(peak, peak_db, voice_enabled)

func _store_voice_level_state(peer_id: int, peak: float, peak_db: float, mic_open: bool) -> void:
	if peer_id <= 0:
		return

	var now := Time.get_ticks_msec()
	var state: Dictionary = voice_level_states.get(peer_id, {})
	state["peer_id"] = peer_id
	state["peak"] = clampf(peak, 0.0, 1.0)
	state["peak_db"] = clampf(peak_db, -80.0, 12.0)
	state["mic_open"] = mic_open
	state["has_level"] = true
	state["level_updated_msec"] = now
	state["state_updated_msec"] = now
	voice_level_states[peer_id] = state
	voice_level_changed.emit(peer_id, state.duplicate(true))

func _set_voice_level_mic_state(peer_id: int, mic_open: bool) -> void:
	if peer_id <= 0:
		return

	var now := Time.get_ticks_msec()
	var state: Dictionary = voice_level_states.get(peer_id, {})
	state["peer_id"] = peer_id
	state["peak"] = state.get("peak", 0.0)
	state["peak_db"] = state.get("peak_db", -80.0)
	state["mic_open"] = mic_open
	state["has_level"] = state.get("has_level", false)
	state["state_updated_msec"] = now
	voice_level_states[peer_id] = state
	voice_level_changed.emit(peer_id, state.duplicate(true))

func get_transcript_history() -> Array:
	return voice_transcript_history.duplicate(true)

func publish_assistant_transcript(text: String, speaker_name: String = "智能助手") -> void:
	var clean_text := text.strip_edges()
	if clean_text.is_empty():
		return

	var data := {
		"speaker_peer_id": 0,
		"speaker_name": speaker_name,
		"text": clean_text,
		"is_final": true,
		"timestamp_msec": Time.get_ticks_msec(),
		"source": "llm_assistant",
	}
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_broadcast_transcript(data)
	else:
		_on_transport_transcript_received(data)


func publish_assistant_interaction_state(target_peer_id: int, state: String, text: String = "") -> void:
	var data := {
		"target_peer_id": target_peer_id,
		"state": state.strip_edges(),
		"text": text.strip_edges(),
		"timestamp_msec": Time.get_ticks_msec(),
	}
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		if transport != null and transport.has_method("send_assistant_interaction_state"):
			transport.send_assistant_interaction_state(target_peer_id, data)
		else:
			_on_assistant_interaction_state_received(data)
	else:
		_on_assistant_interaction_state_received(data)


func _set_peer_transcription_active(peer_id: int, active: bool) -> void:
	if not multiplayer.is_server() or peer_id <= 0:
		return
	if not transcription_enabled:
		active = false

	if active:
		var transcriber := _get_peer_transcriber(peer_id)
		if transcriber != null and transcriber.has_method("set_input_active"):
			transcriber.set_input_active(true)
	else:
		_stop_peer_transcription(peer_id)

func _get_peer_transcriber(peer_id: int) -> Node:
	if _peer_transcribers.has(peer_id):
		var existing := _peer_transcribers[peer_id] as Node
		if existing != null and is_instance_valid(existing):
			return existing
		_peer_transcribers.erase(peer_id)

	var transcriber := TencentAsrTranscriberScript.new()
	transcriber.name = "TencentAsrPeer_%d" % peer_id
	_configure_peer_transcriber(transcriber)
	add_child(transcriber)
	transcriber.transcribed_msg.connect(Callable(self, "_on_peer_transcribed_msg").bind(peer_id))
	transcriber.connection_state_changed.connect(Callable(self, "_on_peer_transcription_state_changed").bind(peer_id))
	transcriber.error_occurred.connect(Callable(self, "_on_peer_transcription_error").bind(peer_id))
	_peer_transcribers[peer_id] = transcriber
	return transcriber

func _configure_peer_transcriber(transcriber: Node) -> void:
	if transcription_config == null:
		transcription_config = get_node_or_null("TencentAsrConfig")
	if transcription_config == null:
		return

	for property_name in TENCENT_ASR_CONFIG_PROPERTIES:
		transcriber.set(property_name, transcription_config.get(property_name))

func _stop_peer_transcription(peer_id: int) -> void:
	if not _peer_transcribers.has(peer_id):
		return

	var transcriber := _peer_transcribers[peer_id] as Node
	_peer_transcribers.erase(peer_id)
	if transcriber == null or not is_instance_valid(transcriber):
		return
	if transcriber.has_method("stop_transcription"):
		transcriber.stop_transcription()
	transcriber.queue_free()

func _stop_all_transcription() -> void:
	for peer_id in _peer_transcribers.keys().duplicate():
		_stop_peer_transcription(int(peer_id))

func _feed_transcription_frames(peer_id: int, frames: PackedVector2Array) -> void:
	var transcriber := _get_peer_transcriber(peer_id)
	if transcriber == null or not transcriber.has_method("push_audio_frames"):
		return
	if transcriber.has_method("set_input_active"):
		transcriber.set_input_active(true)
	transcriber.push_audio_frames(frames)

func _feed_transcription_pcm(peer_id: int, pcm: PackedByteArray) -> void:
	var transcriber := _get_peer_transcriber(peer_id)
	if transcriber == null or not transcriber.has_method("push_pcm16_audio"):
		return
	if transcriber.has_method("set_input_active"):
		transcriber.set_input_active(true)
	transcriber.push_pcm16_audio(pcm)

func _on_peer_transcribed_msg(is_final: bool, new_text: String, peer_id: int) -> void:
	var text := new_text.strip_edges()
	if text.is_empty() or not multiplayer.is_server():
		return

	var utterance_id := int(_transcript_utterance_ids.get(peer_id, 1))
	var data := {
		"speaker_peer_id": peer_id,
		"speaker_name": _get_transcript_speaker_name(peer_id),
		"text": text,
		"is_final": is_final,
		"utterance_id": utterance_id,
		"timestamp_msec": Time.get_ticks_msec(),
	}
	_broadcast_transcript(data)
	if is_final:
		_transcript_utterance_ids[peer_id] = utterance_id + 1

func _on_peer_transcription_state_changed(state: String, detail: String, peer_id: int) -> void:
	if state == "error" or state == "closed":
		_log("Tencent ASR peer=%d state=%s detail=%s" % [peer_id, state, detail])
	if state == "error" and not detail.strip_edges().is_empty():
		_broadcast_transcription_system_message("%s转写错误：%s" % [_get_transcript_speaker_name(peer_id), detail])

func _on_peer_transcription_error(code: int, message: String, peer_id: int) -> void:
	_log("Tencent ASR peer=%d error=%d message=%s" % [peer_id, code, message])
	if message.strip_edges() != "":
		_broadcast_transcription_system_message("%s转写错误：%s" % [_get_transcript_speaker_name(peer_id), message])

func _broadcast_transcript(data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	if transport != null and transport.has_method("broadcast_transcript"):
		transport.broadcast_transcript(data)
	else:
		_on_transport_transcript_received(data)

func _broadcast_transcription_system_message(message: String) -> void:
	var text := message.strip_edges()
	if text.is_empty() or not multiplayer.is_server():
		return
	_broadcast_transcript({
		"speaker_peer_id": 0,
		"speaker_name": "系统",
		"text": text,
		"is_final": true,
		"timestamp_msec": Time.get_ticks_msec(),
	})

func _broadcast_transcription_enabled() -> void:
	if not multiplayer.is_server():
		return
	if transport != null and transport.has_method("broadcast_transcription_enabled"):
		transport.broadcast_transcription_enabled(transcription_enabled)

func _store_transcript_data(data: Dictionary) -> void:
	if bool(data.get("is_final", false)):
		voice_transcript_history.append(data.duplicate(true))
		while voice_transcript_history.size() > 80:
			voice_transcript_history.pop_front()

func _get_transcript_speaker_name(peer_id: int) -> String:
	return "服务端" if peer_id == SERVER_PEER_ID else "客户端%d" % peer_id

func _is_peer_mic_open(peer_id: int) -> bool:
	if peer_id == _get_local_voice_peer_id():
		return voice_enabled
	var state: Dictionary = voice_level_states.get(peer_id, {})
	return bool(state.get("mic_open", false))

func _get_open_mic_peer_ids() -> Array:
	var ids: Array = []
	var local_peer_id := _get_local_voice_peer_id()
	if local_peer_id > 0 and voice_enabled:
		ids.append(local_peer_id)
	for peer_id in voice_level_states.keys():
		var id := int(peer_id)
		var state: Dictionary = voice_level_states.get(peer_id, voice_level_states.get(id, {}))
		if id > 0 and not ids.has(id) and bool(state.get("mic_open", false)):
			ids.append(id)
	return ids

func _queue_client_transcription_pcm(frames: PackedVector2Array) -> void:
	if transport == null or not transport.has_method("send_transcription_pcm"):
		return

	_append_client_resampled_pcm(frames)
	var chunk_bytes := _get_client_transcription_upload_bytes()
	while _client_transcription_pcm_buffer.size() >= chunk_bytes:
		var packet := _client_transcription_pcm_buffer.slice(0, chunk_bytes)
		_client_transcription_pcm_buffer = _client_transcription_pcm_buffer.slice(chunk_bytes)
		transport.send_transcription_pcm(packet)

func _append_client_resampled_pcm(frames: PackedVector2Array) -> void:
	if _client_transcription_source_sample_rate <= 0:
		_client_transcription_source_sample_rate = max(1, int(AudioServer.get_mix_rate()))

	for frame in frames:
		_client_transcription_mono_buffer.append((frame.x + frame.y) * 0.5)

	var ratio := float(_client_transcription_source_sample_rate) / float(TRANSCRIPTION_TARGET_SAMPLE_RATE)
	while _client_transcription_resample_read_pos + 1.0 < float(_client_transcription_mono_buffer.size()):
		var index := int(_client_transcription_resample_read_pos)
		var fraction := _client_transcription_resample_read_pos - float(index)
		var sample := lerpf(_client_transcription_mono_buffer[index], _client_transcription_mono_buffer[index + 1], fraction)
		_append_client_pcm16_sample(sample)
		_client_transcription_resample_read_pos += ratio

	var consumed := int(_client_transcription_resample_read_pos)
	if consumed > 0:
		_client_transcription_mono_buffer = _client_transcription_mono_buffer.slice(consumed)
		_client_transcription_resample_read_pos -= float(consumed)

func _append_client_pcm16_sample(sample: float) -> void:
	var clamped := clampf(sample, -1.0, 1.0)
	var pcm := int(round(clamped * 32767.0))
	if clamped <= -1.0:
		pcm = -32768
	if pcm < 0:
		pcm += 65536
	_client_transcription_pcm_buffer.append(pcm & 0xff)
	_client_transcription_pcm_buffer.append((pcm >> 8) & 0xff)

func _get_client_transcription_upload_bytes() -> int:
	return int(float(TRANSCRIPTION_TARGET_SAMPLE_RATE * TRANSCRIPTION_BYTES_PER_SAMPLE * TRANSCRIPTION_UPLOAD_CHUNK_MSEC) / 1000.0)

func _reset_client_transcription_upload() -> void:
	_client_transcription_source_sample_rate = max(1, int(AudioServer.get_mix_rate()))
	_client_transcription_resample_read_pos = 0.0
	_client_transcription_mono_buffer.clear()
	_client_transcription_pcm_buffer.clear()

func _get_local_voice_peer_id() -> int:
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return SERVER_PEER_ID if voice_endpoint_selected and not is_vr_mode else 0

func _request_runtime_audio_permissions() -> void:
	if OS.has_feature("android") and OS.has_method("request_permissions"):
		OS.request_permissions()

func _select_voice_role_from_args() -> void:
	var role := _get_arg_value(VOICE_ROLE_ARG).to_lower()
	if role == "server" or role == "pc":
		_set_voice_endpoint_role(true)
		return
	if role == "client" or role == "vr":
		_set_voice_endpoint_role(false)
		return
	if _is_vr_mode_requested():
		_set_voice_endpoint_role(false)

func _set_voice_endpoint_role(is_server_role: bool) -> void:
	voice_endpoint_selected = true
	is_vr_mode = not is_server_role
	_apply_audio_device_profile()
	_setup_capture_after_device_selection()
	_ensure_debug_controls()
	_update_debug_controls()
	if voice_debug_enabled and _has_cmdline_arg(VOICE_TEST_TONE_ARG):
		play_output_test_tone()

func _setup_capture_after_device_selection() -> void:
	if capture == null:
		return

	capture.setup()
	var capture_state: Dictionary = capture.get_debug_state()
	_log("Voice capture setup input=%s selected_input=%s capture_mode=%s mic_playing=%s" % [
		AudioServer.get_input_device(),
		selected_input_device,
		capture_state.get("capture_mode", ""),
		capture_state.get("microphone_playing", false),
	])
	_log("Voice capture opus config=%s" % str(capture_state.get("configured_opus_properties", {})))
	_log("Voice capture pipeline=AudioStreamMicrophone.mix_audio->standalone Opus")

func _apply_audio_device_profile() -> void:
	if not voice_endpoint_selected:
		return

	var input_override := _get_arg_value("--voice-input=")
	var output_override := _get_arg_value("--voice-output=")
	var input_hints := VR_INPUT_DEVICE_HINTS if is_vr_mode else PC_INPUT_DEVICE_HINTS
	var output_hints := VR_OUTPUT_DEVICE_HINTS if is_vr_mode else PC_OUTPUT_DEVICE_HINTS

	if _manual_input_device != "":
		input_override = _manual_input_device
	if _manual_output_device != "":
		output_override = _manual_output_device

	selected_input_device = _select_audio_device(AudioServer.get_input_device_list(), input_hints, input_override, "input")
	selected_output_device = _select_audio_device(AudioServer.get_output_device_list(), output_hints, output_override, "output")
	AudioServer.input_device = selected_input_device
	AudioServer.output_device = selected_output_device
	if AudioServer.has_method("set_input_device_active"):
		AudioServer.call("set_input_device_active", true)

func _select_audio_device(devices: PackedStringArray, hints: Array, override_value: String, kind: String) -> String:
	if override_value != "":
		if devices.has(override_value):
			return override_value
		push_warning("VoiceChat %s device override not found: %s" % [kind, override_value])

	for hint in hints:
		var matched := _find_device_by_hint(devices, str(hint))
		if matched != "":
			return matched

	if devices.has("Default"):
		return "Default"
	return devices[0] if devices.size() > 0 else "Default"

func _find_device_by_hint(devices: PackedStringArray, hint: String) -> String:
	var normalized_hint := hint.to_lower()
	for device in devices:
		if str(device).to_lower().find(normalized_hint) != -1:
			return str(device)
	return ""

func _get_arg_value(prefix: String) -> String:
	for arg in OS.get_cmdline_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""

func _is_vr_mode_requested() -> bool:
	if OS.has_feature("android"):
		return true

	var role := _get_arg_value(VOICE_ROLE_ARG).to_lower()
	if role == "client" or role == "vr":
		return true
	if role == "server" or role == "pc":
		return false
	return _has_cmdline_arg(XR_CLIENT_ARG) or _has_xr_mode_on_arg()

func _has_xr_mode_on_arg() -> bool:
	var args := OS.get_cmdline_args()
	for i in range(args.size()):
		var arg := str(args[i]).to_lower()
		if arg == XR_MODE_ARG and i + 1 < args.size():
			return str(args[i + 1]).to_lower() == "on"
		if arg.begins_with(XR_MODE_ARG + "="):
			return arg.get_slice("=", 1).to_lower() == "on"
	return false

func _has_cmdline_arg(target: String) -> bool:
	for arg in OS.get_cmdline_args():
		if arg == target:
			return true
	return false

func _print_audio_device_state(context: String) -> void:
	var role := _get_network_role()

	_log("VoiceChat audio devices [%s] role=%s mode=%s" % [context, role, _get_voice_mode_label()])
	_log("  input: %s" % AudioServer.get_input_device())
	_log("  output: %s" % AudioServer.get_output_device())
	_log("  selected input: %s" % selected_input_device)
	_log("  selected output: %s" % selected_output_device)
	_log("  available inputs: %s" % str(AudioServer.get_input_device_list()))
	_log("  available outputs: %s" % str(AudioServer.get_output_device_list()))
	_update_debug_controls()

func _ensure_debug_controls() -> void:
	if not voice_debug_controls_enabled:
		return
	if DisplayServer.get_name() == "headless":
		return
	if not OS.has_feature("editor") and not OS.has_feature("debug"):
		return
	if _debug_controls_layer != null and is_instance_valid(_debug_controls_layer):
		return

	_debug_controls_layer = CanvasLayer.new()
	_debug_controls_layer.name = "VoiceDebugControls"
	_debug_controls_layer.layer = 128
	add_child(_debug_controls_layer)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.position = Vector2(12.0, 12.0)
	panel.custom_minimum_size = Vector2(520.0, 36.0)
	_debug_controls_layer.add_child(panel)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)

	_add_debug_button(row, "语音", "toggle_voice")
	_add_debug_button(row, "测试音", "play_output_test_tone")
	_add_debug_button(row, "麦克风", "play_microphone_monitor_test")
	_add_debug_button(row, "输入", "cycle_voice_input_device")
	_add_debug_button(row, "输出", "cycle_voice_output_device")

	_debug_status_label = Label.new()
	_debug_status_label.name = "Status"
	_debug_status_label.custom_minimum_size = Vector2(230.0, 0.0)
	row.add_child(_debug_status_label)

func _add_debug_button(parent: Container, text: String, method_name: String) -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(58.0, 28.0)
	button.pressed.connect(Callable(self, method_name))
	parent.add_child(button)

func _update_debug_controls() -> void:
	if _debug_status_label == null or not is_instance_valid(_debug_status_label):
		return
	var monitor_state := "监听" if _mic_monitor_player != null and is_instance_valid(_mic_monitor_player) else ""
	var voice_state := "开" if voice_enabled else "关"
	_debug_status_label.text = "%s %s %s %s" % [
		_get_network_role(),
		_get_voice_mode_label(),
		voice_state,
		monitor_state,
	]

func _log_voice_pipeline_state(delta: float) -> void:
	if not debug_voice_stats:
		return
	if not voice_endpoint_selected:
		return

	_debug_log_accum += delta
	if _debug_log_accum < 1.0:
		return
	_debug_log_accum = 0.0

	if capture == null or transport == null or playback == null:
		return

	var capture_state: Dictionary = capture.get_debug_state()
	var transport_state: Dictionary = transport.get_debug_state()
	var playback_state: Dictionary = playback.get_debug_state()
	var master_peak_db := _get_bus_peak_db("Master")
	var mic_peak_db := float(capture_state.get("last_input_peak_db", -80.0))
	var playback_peak_db := float(playback_state.get("last_playback_peak_db", -80.0))
	var microphone_playing := bool(capture_state.get("microphone_playing", false))
	_update_silent_input_warning(capture_state)
	_update_remote_playback_warning(playback_state, playback_peak_db, master_peak_db)
	var signature := "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%.1f|%.1f|%.1f|%.1f|%.1f" % [
		voice_enabled,
		microphone_playing,
		capture_state.get("input_device", ""),
		capture_state.get("packets_captured", 0),
		packets_sent,
		packets_received,
		playback_state.get("packets_enqueued", 0),
		playback_state.get("packets_pushed", 0),
		playback_state.get("queued_packets", 0),
		playback_state.get("player_count", 0),
		transport_state.get("uplink_packets_sent", 0),
		transport_state.get("uplink_packets_received", 0),
		transport_state.get("downlink_packets_sent", 0),
		transport_state.get("downlink_packets_received", 0),
		capture_state.get("capture_frames_available", 0),
		capture_state.get("pending_audio_frames", 0),
		capture_state.get("frames_read_total", 0),
		capture_state.get("frames_encoded_total", 0),
		float(capture_state.get("last_input_peak_db", -80.0)),
		float(capture_state.get("last_opus_chunk_peak_db", -80.0)),
		playback_peak_db,
		mic_peak_db,
		master_peak_db,
	]

	if not voice_enabled and signature == _last_debug_signature:
		return
	_last_debug_signature = signature

	_log("Voice pipeline role=%s mode=%s input=%s enabled=%s mic_live=%s cap=%s frames=%s pending=%s read=%s encoded=%s in_peak_db=%.1f opus_peak_db=%.1f play_peak_db=%.1f mic_peak_db=%.1f sent=%s recv=%s enqueued=%s pushed=%s queued=%s dropped=%s players=%s master_peak_db=%.1f up=%s/%s down=%s/%s" % [
		_get_network_role(),
		_get_voice_mode_label(),
		capture_state.get("input_device", ""),
		voice_enabled,
		microphone_playing,
		capture_state.get("packets_captured", 0),
		capture_state.get("capture_frames_available", 0),
		capture_state.get("pending_audio_frames", 0),
		capture_state.get("frames_read_total", 0),
		capture_state.get("frames_encoded_total", 0),
		float(capture_state.get("last_input_peak_db", -80.0)),
		float(capture_state.get("last_opus_chunk_peak_db", -80.0)),
		playback_peak_db,
		mic_peak_db,
		packets_sent,
		packets_received,
		playback_state.get("packets_enqueued", 0),
		playback_state.get("packets_pushed", 0),
		playback_state.get("queued_packets", 0),
		playback_state.get("packets_dropped", 0),
		playback_state.get("player_count", 0),
		master_peak_db,
		transport_state.get("uplink_packets_sent", 0),
		transport_state.get("uplink_packets_received", 0),
		transport_state.get("downlink_packets_sent", 0),
		transport_state.get("downlink_packets_received", 0),
	])

func _update_silent_input_warning(capture_state: Dictionary) -> void:
	if not voice_enabled:
		_silent_input_seconds = 0.0
		return

	var frames_encoded := int(capture_state.get("frames_encoded_total", 0))
	var input_peak_db := float(capture_state.get("last_input_peak_db", -80.0))
	if frames_encoded <= 0 or input_peak_db > -75.0:
		_silent_input_seconds = 0.0
		return

	_silent_input_seconds += 1.0
	if _silent_input_seconds < 3.0:
		return

	var key := "%s|%s" % [_get_network_role(), capture_state.get("input_device", "")]
	if key == _silent_input_warning_key:
		return
	_silent_input_warning_key = key
	var actual_input := str(capture_state.get("input_device", ""))
	if _is_pico_device_name(actual_input) or _is_pico_device_name(selected_input_device):
		_log("Voice input appears silent for %.1fs. actual_input=%s selected_input=%s mode=%s. The selected PICO virtual microphone is delivering zero PCM to Godot; restart/reconnect PICO Business Streaming, confirm the headset microphone is enabled, then retest this exact input." % [
			_silent_input_seconds,
			actual_input,
			selected_input_device,
			_get_voice_mode_label(),
		])
	else:
		_log("Voice input appears silent for %.1fs. actual_input=%s selected_input=%s mode=%s. Check Windows microphone routing/permissions or choose another input device." % [
			_silent_input_seconds,
			actual_input,
			selected_input_device,
			_get_voice_mode_label(),
		])

func _update_remote_playback_warning(playback_state: Dictionary, playback_peak_db: float, master_peak_db: float) -> void:
	if not voice_enabled:
		_remote_playback_seconds = 0.0
		return

	var pushed := int(playback_state.get("packets_pushed", 0))
	var players := int(playback_state.get("player_count", 0))
	if packets_received <= 0 or pushed <= 0 or players <= 0 or playback_peak_db <= -60.0:
		_remote_playback_seconds = 0.0
		return

	_remote_playback_seconds += 1.0
	if _remote_playback_seconds < 2.0:
		return

	var actual_output := AudioServer.get_output_device()
	var key := "%s|%s|%s" % [_get_network_role(), actual_output, selected_output_device]
	if key == _remote_playback_warning_key:
		return
	_remote_playback_warning_key = key

	if DisplayServer.get_name() != "headless" and master_peak_db <= -75.0:
		_log("Voice remote playback decoded non-silent audio but Master bus is silent. output=%s selected_output=%s play_peak_db=%.1f master_peak_db=%.1f pushed=%d. Check Master bus mute/effects and output routing." % [
			actual_output,
			selected_output_device,
			playback_peak_db,
			master_peak_db,
			pushed,
		])
	elif _is_pico_device_name(actual_output) or _is_pico_device_name(selected_output_device):
		_log("Voice remote playback is non-silent inside Godot and routed to PICO output. output=%s selected_output=%s play_peak_db=%.1f master_peak_db=%.1f pushed=%d. If the headset is silent, the remaining boundary is PICO Business Streaming HMD audio session or Windows output routing." % [
			actual_output,
			selected_output_device,
			playback_peak_db,
			master_peak_db,
			pushed,
		])
	else:
		_log("Voice remote playback is non-silent inside Godot. output=%s selected_output=%s play_peak_db=%.1f master_peak_db=%.1f pushed=%d." % [
			actual_output,
			selected_output_device,
			playback_peak_db,
			master_peak_db,
			pushed,
		])

func _is_pico_device_name(device_name: String) -> bool:
	var lower_name := device_name.to_lower()
	return lower_name.find("pico") != -1 or lower_name.find("business streaming") != -1

func _get_bus_peak_db(bus_name: String) -> float:
	if DisplayServer.get_name() == "headless":
		return -80.0

	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index == -1:
		return -80.0
	var left := AudioServer.get_bus_peak_volume_left_db(bus_index, 0)
	var right := AudioServer.get_bus_peak_volume_right_db(bus_index, 0)
	return max(left, right)

func _is_shift_digit_pressed(event: InputEvent, keycode: int) -> bool:
	var key_event := event as InputEventKey
	if key_event == null:
		return false
	return key_event.pressed \
		and not key_event.echo \
		and key_event.shift_pressed \
		and not key_event.ctrl_pressed \
		and not key_event.alt_pressed \
		and not key_event.meta_pressed \
		and (
			key_event.physical_keycode == keycode \
			or key_event.keycode == keycode \
			or key_event.key_label == keycode
		)

func _pump_output_test_tone(frequency_hz: float = 880.0) -> void:
	if _output_test_playback == null or _output_test_remaining_frames <= 0:
		return

	var frames_to_push = min(_output_test_playback.get_frames_available(), _output_test_remaining_frames)
	var mix_rate := AudioServer.get_mix_rate()
	var increment := frequency_hz / mix_rate
	for i in range(frames_to_push):
		var sample := sin(_output_test_phase * TAU) * 0.35
		_output_test_playback.push_frame(Vector2(sample, sample))
		_output_test_phase = fmod(_output_test_phase + increment, 1.0)

	_output_test_remaining_frames -= frames_to_push
	if _output_test_remaining_frames <= 0:
		_log("Voice output test tone finished output=%s" % AudioServer.get_output_device())
		if _output_test_player != null and is_instance_valid(_output_test_player):
			_output_test_player.queue_free()
		_output_test_player = null
		_output_test_playback = null

func _get_network_role() -> String:
	if NetworkHandler.peer == null:
		return "offline"
	return "server" if multiplayer.is_server() else "client"

func _get_voice_mode_label() -> String:
	if not voice_endpoint_selected:
		return "unselected"
	return "VR" if is_vr_mode else "PC"

func _log(message: String) -> void:
	if not voice_debug_enabled:
		return
	print(message)
	if debug_voice_stats_to_error_console and message.begins_with("Voice pipeline"):
		printerr(message)
	_append_voice_log(message)

func _append_voice_log(message: String) -> void:
	var file: FileAccess
	if FileAccess.file_exists(voice_log_path):
		file = FileAccess.open(voice_log_path, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(voice_log_path, FileAccess.WRITE)

	if file == null:
		return

	file.store_line("%s %s" % [Time.get_datetime_string_from_system(), message])
