extends Node

signal voice_enabled_changed(enabled: bool)
signal remote_speaking_changed(peer_id: int, is_speaking: bool)
signal voice_level_changed(peer_id: int, state: Dictionary)
signal voice_transcript_received(data: Dictionary)
signal assistant_wake_requested(speaker_peer_id: int)
signal assistant_capture_ready(speaker_peer_id: int)
signal assistant_capture_failed(speaker_peer_id: int, message: String)
signal assistant_interaction_state_changed(data: Dictionary)
signal transcription_enabled_changed(enabled: bool)
signal dictation_state_changed(session_id: String, state: String, detail: String)
signal dictation_partial_received(session_id: String, text: String)
signal dictation_final_received(session_id: String, text: String)
signal dictation_failed(session_id: String, code: int, message: String)

const SERVER_PEER_ID := 1
const Execution := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_execution.gd")
const SERVER_SOURCE_ID := 1
const ASSISTANT_WAKE_WORD := "助手"
const XR_CLIENT_ARG := "--xr-client"
const GROUND_VR_ARG := "--ground-vr"
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
const TRANSCRIPTION_UPLOAD_CHUNK_MSEC := 100
const DICTATION_MAX_DURATION_MSEC := 15000
const DICTATION_FINALIZE_TIMEOUT_MSEC := 3000
const ASR_PROVIDER_FUNASR := "funasr"
const ASR_PROVIDER_TENCENT := "tencent"
const TENCENT_ASR_ENV_VARS := [
	"TENCENT_ASR_APP_ID",
	"TENCENT_ASR_SECRET_ID",
	"TENCENT_ASR_SECRET_KEY",
]
const VoiceCaptureScript := preload("res://Assets/ARSpace/Scripts/Network/voice_capture.gd")
const VoiceTransportScript := preload("res://Assets/ARSpace/Scripts/Network/voice_transport_enet.gd")
const VoicePlaybackScript := preload("res://Assets/ARSpace/Scripts/Network/voice_playback.gd")
const TencentAsrTranscriberScript := preload("res://Assets/ARSpace/Scripts/Network/tencent_asr_transcriber.gd")
const LocalFunAsrTranscriberScript := preload("res://Assets/ARSpace/Scripts/Network/local_funasr_transcriber.gd")
const RuntimeProfileScript := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const COMMON_ASR_CONFIG_PROPERTIES := [
	"hotword_list",
	"need_vad",
	"vad_silence_time",
	"max_speak_time",
	"packet_duration_msec",
	"max_buffered_audio_msec",
	"connect_timeout_msec",
	"debug_logs",
]
const TENCENT_ASR_CONFIG_PROPERTIES := [
	"engine_model_type",
	"filter_dirty",
	"filter_modal",
	"filter_punc",
	"convert_num_mode",
	"word_info",
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
var is_server_endpoint: bool = false
var voice_endpoint_selected: bool = false

var capture: Node
var transport: Node
var playback: Node
var transcription_config: Node

var selected_input_device: String = "Default"
var selected_output_device: String = "Default"
@export_enum("funasr", "tencent") var asr_provider: String = ASR_PROVIDER_FUNASR
@export var local_asr_endpoint: String = "ws://127.0.0.1:8765/ws/asr"
@export_range(0.001, 0.5, 0.001) var local_asr_speech_threshold: float = 0.012
@export var local_asr_hotwords: String = "智能助手 30"
@export_range(400, 2000, 100) var local_asr_vad_silence_time: int = 600
@export_range(1000, 5000, 100) var local_asr_stable_partial_msec: int = 1800
@export_range(40, 200, 20) var local_asr_packet_duration_msec: int = 100
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
var _assistant_transcript_sequence := 0
var _assistant_command_capture_peers: Dictionary = {}
var _assistant_speech_peers: Dictionary = {}
var transcription_enabled: bool = true
var _peer_transcribers: Dictionary = {}
var _client_transcription_source_sample_rate: int = 48000
var _client_transcription_resample_read_pos: float = 0.0
var _client_transcription_mono_buffer := PackedFloat32Array()
var _client_transcription_pcm_buffer := PackedByteArray()
var _dictation_transcriber: Node
var _dictation_session_id := ""
var _dictation_state := "idle"
var _dictation_started_msec := 0
var _dictation_finalize_deadline_msec := 0
var _dictation_last_text := ""
var _dictation_final_emitted := false
var _dictation_failure_reported := false
var _recognition_epoch := 0
var _manual_wake_pending := false
var _remote_capture_preparing: Dictionary = {}

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

	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler != null and network_handler.has_signal("network_role_selected"):
		network_handler.network_role_selected.connect(_on_network_role_selected)
	if network_handler != null and network_handler.has_signal("network_ready"):
		network_handler.network_ready.connect(_on_network_ready)

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
	_update_dictation_timeout()

func toggle_voice() -> void:
	set_voice_enabled(not voice_enabled)

func set_voice_enabled(enabled: bool) -> void:
	if enabled and not voice_endpoint_selected:
		_log("VoiceChat role is not selected yet. Start server or client before enabling voice.")
		return

	if voice_enabled == enabled:
		if capture != null and not _is_dictation_active():
			capture.set_voice_active(enabled)
		return

	voice_enabled = enabled
	if capture != null:
		capture.set_voice_active(voice_enabled and not _is_dictation_active())

	if transport != null:
		var effective_speaking := voice_enabled and not _is_dictation_active()
		transport.send_speaking_state(effective_speaking)
		if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and multiplayer.is_server():
			for peer_id in multiplayer.get_peers():
				transport.send_server_speaking_state_to_peer(peer_id, effective_speaking)

	if Execution.endpoint_asr() or multiplayer.is_server():
		_set_peer_transcription_active(_get_local_voice_peer_id(), voice_enabled and not _is_dictation_active())
	else:
		_reset_client_transcription_upload()

	voice_enabled_changed.emit(voice_enabled)
	_log("Voice %s" % ("enabled" if voice_enabled else "disabled"))
	_update_debug_controls()

func start_voice_chat() -> void:
	set_voice_enabled(true)

func stop_voice_chat() -> void:
	set_voice_enabled(false)


func get_dictation_readiness() -> Dictionary:
	if _is_dictation_active():
		return {
			"available": false,
			"reason": "busy",
			"message": "已有听写会话正在进行。",
			"state": _dictation_state,
			"session_id": _dictation_session_id,
		}
	if capture == null or not bool(capture.get("is_setup")):
		return {
			"available": false,
			"reason": "capture_unavailable",
			"message": "麦克风采集尚未就绪。",
			"state": _dictation_state,
		}
	var provider := get_asr_provider()
	if provider == ASR_PROVIDER_TENCENT:
		var missing: Array[String] = []
		for environment_name in TENCENT_ASR_ENV_VARS:
			if OS.get_environment(environment_name).strip_edges().is_empty():
				missing.append(environment_name)
		if not missing.is_empty():
			return {
				"available": false,
				"reason": "credentials_missing",
				"message": "腾讯 ASR 环境变量未配置完整。",
				"missing_environment_variables": missing,
				"provider": provider,
				"state": _dictation_state,
			}
	else:
		var endpoint := _get_local_asr_endpoint()
		if endpoint.is_empty() or not endpoint.begins_with("ws://"):
			return {
				"available": false,
				"reason": "endpoint_invalid",
				"message": "本地 FunASR 地址未配置或格式无效。",
				"provider": provider,
				"state": _dictation_state,
			}
	return {
		"available": true,
		"reason": "ready",
		"message": "听写已就绪。",
		"provider": provider,
		"state": _dictation_state,
	}


func begin_local_dictation(session_id: String, purpose: String = "annotation") -> bool:
	var clean_session_id := session_id.strip_edges()
	if clean_session_id.is_empty():
		return false
	var readiness := get_dictation_readiness()
	if not bool(readiness.get("available", false)):
		_dictation_state_changed_for(clean_session_id, "failed", str(readiness.get("message", "听写不可用。")))
		dictation_failed.emit(clean_session_id, ERR_UNAVAILABLE, str(readiness.get("message", "听写不可用。")))
		return false

	_dictation_session_id = clean_session_id
	_dictation_state = "connecting"
	_dictation_started_msec = Time.get_ticks_msec()
	_dictation_finalize_deadline_msec = 0
	_dictation_last_text = ""
	_dictation_final_emitted = false
	_dictation_failure_reported = false
	_begin_recognition_boundary()
	if capture != null:
		capture.set_voice_active(false)
	_publish_local_speaking_state(false)

	_dictation_transcriber = _create_asr_transcriber("AsrDictation")
	_configure_peer_transcriber(_dictation_transcriber)
	_dictation_transcriber.set("need_vad", false)
	_dictation_transcriber.set("max_speak_time", DICTATION_MAX_DURATION_MSEC)
	add_child(_dictation_transcriber)
	var dictation_source := _dictation_transcriber
	_dictation_transcriber.transcribed_msg.connect(
		Callable(self, "_on_dictation_transcribed_msg").bind(clean_session_id, dictation_source)
	)
	_dictation_transcriber.connection_state_changed.connect(
		Callable(self, "_on_dictation_connection_state_changed").bind(clean_session_id, dictation_source)
	)
	_dictation_transcriber.error_occurred.connect(
		Callable(self, "_on_dictation_error").bind(clean_session_id, dictation_source)
	)
	_dictation_state_changed_for(clean_session_id, "connecting", purpose.strip_edges())
	if not bool(_dictation_transcriber.call("start_transcription")):
		if _dictation_session_id == clean_session_id:
			_fail_dictation(ERR_CANT_CONNECT, "无法启动语音识别听写。")
		return false
	return true


func finish_local_dictation(session_id: String) -> bool:
	if not _matches_active_dictation(session_id):
		return false
	if _dictation_state == "finalizing":
		return true
	_dictation_state = "finalizing"
	_dictation_finalize_deadline_msec = Time.get_ticks_msec() + DICTATION_FINALIZE_TIMEOUT_MSEC
	_dictation_state_changed_for(_dictation_session_id, "finalizing", "正在等待最终转写结果。")
	if _dictation_transcriber != null and is_instance_valid(_dictation_transcriber):
		_dictation_transcriber.call("finish_transcription")
	else:
		_fail_dictation(ERR_UNAVAILABLE, "听写连接已经失效。")
		return false
	return true


func cancel_local_dictation(session_id: String) -> bool:
	if not _matches_active_dictation(session_id):
		return false
	var active_session_id := _dictation_session_id
	_dictation_state = "cancelled"
	_dictation_state_changed_for(active_session_id, "cancelled", "听写已取消。")
	_cleanup_dictation(true)
	return true

func toggle_transcription() -> void:
	set_transcription_enabled(not transcription_enabled)

func set_transcription_enabled(enabled: bool) -> void:
	if not Execution.endpoint_asr() and not multiplayer.is_server():
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

	if not Execution.endpoint_asr():
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
		"peer_id": _get_local_voice_peer_id(),
		"connected_peers": multiplayer.get_peers() if multiplayer.has_multiplayer_peer() else [],
		"input_device": AudioServer.get_input_device(),
		"output_device": AudioServer.get_output_device(),
		"selected_input_device": selected_input_device,
		"selected_output_device": selected_output_device,
		"packets_sent": packets_sent,
		"packets_received": packets_received,
		"transcription_enabled": transcription_enabled,
		"asr_provider": get_asr_provider(),
		"transcription": _get_transcription_debug_state(),
		"dictation": {
			"state": _dictation_state,
			"session_id": _dictation_session_id,
			"active": _is_dictation_active(),
			"has_text": not _dictation_last_text.is_empty(),
		},
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
	capture.recognition_frames_captured.connect(_on_local_pcm_frames_captured)

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
	transport.assistant_wake_requested.connect(_on_transport_assistant_wake_requested)
	transport.capture_phase_received.connect(_on_capture_phase_received)
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
	if _is_dictation_active() or not voice_enabled or not multiplayer.has_multiplayer_peer():
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
	if frames.is_empty():
		return
	if is_assistant_speech_active(_get_local_voice_peer_id()):
		_reset_client_transcription_upload()
		return
	if _is_dictation_active():
		if _dictation_transcriber != null and is_instance_valid(_dictation_transcriber):
			_dictation_transcriber.call("push_audio_frames", frames)
		return
	if not voice_enabled:
		return
	if not voice_endpoint_selected or (not Execution.is_local() and not multiplayer.has_multiplayer_peer()):
		return
	if not transcription_enabled:
		return

	if Execution.endpoint_asr() or multiplayer.is_server():
		var peer_id := _get_local_voice_peer_id()
		if _is_peer_mic_open(peer_id):
			_feed_transcription_frames(peer_id, frames)
	else:
		_queue_client_transcription_pcm(frames)

func _on_local_speaking_changed(is_speaking: bool) -> void:
	var peer_id := _get_local_voice_peer_id()
	if _is_dictation_active():
		if multiplayer.is_server():
			_set_voice_level_mic_state(peer_id, false)
		remote_speaking_changed.emit(peer_id, false)
		return
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
	if Execution.endpoint_asr():
		return
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


func _on_transport_assistant_wake_requested(speaker_peer_id: int) -> void:
	if Execution.is_local() or not multiplayer.is_server() or speaker_peer_id <= 0:
		return
	assistant_wake_requested.emit(speaker_peer_id)


func _on_capture_phase_received(peer_id: int, phase: String) -> void:
	if Execution.is_local():
		return
	_remote_capture_preparing[peer_id] = phase == "preparing"
	match phase:
		"preparing": assistant_wake_requested.emit(peer_id)
		"ready": assistant_capture_ready.emit(peer_id)
		"failed": assistant_capture_failed.emit(peer_id, "语音连接失败，请重新听写。")


func _on_assistant_interaction_state_received(data: Dictionary) -> void:
	var target_peer_id := int(data.get("target_peer_id", 0))
	if Execution.is_local() and target_peer_id != _get_local_voice_peer_id():
		return
	var state := str(data.get("state", "idle"))
	_update_assistant_command_capture_state(target_peer_id, state)
	assistant_interaction_state_changed.emit(data.duplicate(true))


func _update_assistant_command_capture_state(target_peer_id: int, state: String) -> void:
	if target_peer_id <= 0:
		return
	if state in ["listening", "connecting"]:
		_assistant_command_capture_peers[target_peer_id] = true
	else:
		_assistant_command_capture_peers.erase(target_peer_id)


func _on_transport_transcription_enabled_received(enabled: bool) -> void:
	if Execution.endpoint_asr() or multiplayer.is_server():
		return
	transcription_enabled = enabled
	if not transcription_enabled:
		_reset_client_transcription_upload()
	transcription_enabled_changed.emit(transcription_enabled)

func _on_network_role_selected(is_server_role: bool, context: String = "") -> void:
	_set_voice_endpoint_role(is_server_role)
	_print_audio_device_state(context if context != "" else "server selected" if is_server_role else "client selected")

func _on_network_ready() -> void:
	if Execution.endpoint_asr():
		# A reconnect can assign a new ENet id. Do not keep a second recognizer
		# alive for the previous id, nor accept its late callbacks as commands.
		var local_id := _get_local_voice_peer_id()
		for previous_id in _peer_transcribers.keys():
			if int(previous_id) != local_id:
				_stop_peer_transcription(int(previous_id))
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
	_remote_capture_preparing.erase(peer_id)
	_log("Voice peer disconnected: %d" % peer_id)
	remove_player(peer_id)
	voice_level_states.erase(peer_id)
	_stop_peer_transcription(peer_id)
	if transport != null:
		transport.call("forget_endpoint_peer", peer_id)

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
	if Execution.is_local():
		if playback != null:
			playback.clear()
		return
	if _is_dictation_active():
		cancel_local_dictation(_dictation_session_id)
	set_voice_enabled(false)
	_stop_all_transcription()
	if playback != null:
		playback.clear()

func _on_server_disconnected() -> void:
	_log("VoiceChat server disconnected")
	if Execution.is_local():
		if playback != null:
			playback.clear()
		return
	_manual_wake_pending = false
	_recognition_epoch += 1
	_remote_capture_preparing.clear()
	_assistant_command_capture_peers.clear()
	if _is_dictation_active():
		cancel_local_dictation(_dictation_session_id)
	set_voice_enabled(false)
	_stop_all_transcription()
	_reset_client_transcription_upload()
	if playback != null:
		playback.clear()

func _update_voice_level_state(delta: float) -> void:
	if not voice_endpoint_selected or capture == null or transport == null:
		return
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler == null or network_handler.get("peer") == null or not multiplayer.has_multiplayer_peer():
		return

	_voice_level_send_accum += delta
	if _voice_level_send_accum < VOICE_LEVEL_SEND_INTERVAL:
		return
	_voice_level_send_accum = 0.0

	var capture_state: Dictionary = capture.get_debug_state()
	var peak := clampf(float(capture_state.get("last_input_peak", 0.0)), 0.0, 1.0)
	var peak_db := clampf(float(capture_state.get("last_input_peak_db", -80.0)), -80.0, 12.0)
	var local_mic_open := voice_enabled and not _is_dictation_active()
	if multiplayer.is_server():
		_store_voice_level_state(_get_local_voice_peer_id(), peak, peak_db, local_mic_open)
	elif multiplayer.has_multiplayer_peer():
		transport.send_voice_level_state(peak, peak_db, local_mic_open)

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


func is_assistant_command_capture_active(peer_id: int) -> bool:
	return _assistant_command_capture_peers.has(peer_id)


func is_assistant_speech_active(peer_id: int) -> bool:
	return _assistant_speech_peers.has(peer_id)


func set_assistant_speech_active(peer_id: int, active: bool) -> void:
	if active:
		_assistant_speech_peers[peer_id] = true
		var transcriber := _peer_transcribers.get(peer_id) as Node
		if is_instance_valid(transcriber):
			transcriber.set_meta("speech_cancelled", true)
		_stop_peer_transcription(peer_id)
	else:
		_assistant_speech_peers.erase(peer_id)
	if peer_id == _get_local_voice_peer_id():
		_reset_client_transcription_upload()


func request_assistant_wake() -> bool:
	if not transcription_enabled:
		return false
	if Execution.endpoint_asr():
		if not Execution.is_local() and (not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer is OfflineMultiplayerPeer or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED):
			publish_assistant_interaction_state(_get_local_voice_peer_id(), "failed", "尚未连接协作 Server，智能助手不可用。")
			return false
		var readiness := get_dictation_readiness()
		if not bool(readiness.get("available", false)):
			publish_assistant_interaction_state(_get_local_voice_peer_id(), "failed", str(readiness.get("message", "麦克风尚未就绪。")))
			return false
	if not voice_enabled and voice_endpoint_selected:
		set_voice_enabled(true)
	if not Execution.endpoint_asr() and multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		if transport == null or not transport.has_method("send_assistant_wake_request"):
			return false
		return bool(transport.call("send_assistant_wake_request"))
	var speaker_peer_id := _get_local_voice_peer_id()
	if speaker_peer_id <= 0:
		speaker_peer_id = SERVER_PEER_ID
	if Execution.endpoint_asr():
		_begin_recognition_boundary(false)
		_manual_wake_pending = true
		# Interrupt local playback immediately; Server cancels its matching
		# speech/confirmation lease when the reliable prepare arrives.
		var speech := get_node_or_null("/root/AssistantSpeech")
		if speech != null and speech.has_method("stop_local_playback"):
			speech.call("stop_local_playback")
		set_assistant_speech_active(speaker_peer_id, false)
		if not Execution.is_local() and transport != null:
			transport.send_capture_phase(_recognition_epoch, "preparing")
		else:
			assistant_wake_requested.emit(speaker_peer_id)
	else:
		assistant_wake_requested.emit(speaker_peer_id)
	if Execution.endpoint_asr():
		# The router cancels TTS before this, so its suppression cannot discard
		# the new session. Buffer only post-click audio while ASR connects.
		_set_peer_transcription_active(speaker_peer_id, true)
	return true


func is_assistant_capture_preparing(peer_id: int = 0) -> bool:
	if peer_id > 0 and peer_id != _get_local_voice_peer_id():
		return bool(_remote_capture_preparing.get(peer_id, false))
	return _manual_wake_pending or bool(_remote_capture_preparing.get(peer_id, false))


func _begin_recognition_boundary(notify_server: bool = true) -> void:
	_recognition_epoch += 1
	_manual_wake_pending = false
	_reset_client_transcription_upload()
	if capture != null and capture.has_method("discard_pending_recognition_audio"):
		capture.call("discard_pending_recognition_audio")
	# Finalize the old ordinary utterance into history, not into the next
	# command. Its callbacks carry the old epoch even if they arrive later.
	_finish_peer_transcription(_get_local_voice_peer_id())
	if notify_server and Execution.endpoint_asr() and not Execution.is_local() and transport != null:
		transport.send_capture_phase(_recognition_epoch, "boundary")


func publish_assistant_transcript(text: String, speaker_name: String = "智能助手", target_peer_id: int = 0) -> void:
	var clean_text := text.strip_edges()
	if clean_text.is_empty():
		return

	_assistant_transcript_sequence += 1
	var data := {
		"speaker_peer_id": 0,
		"speaker_name": speaker_name,
		"text": clean_text,
		"is_final": true,
		"timestamp_msec": Time.get_ticks_msec(),
		"source": "llm_assistant",
		"message_id": "assistant-%d" % _assistant_transcript_sequence,
	}
	if not Execution.is_local() and multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and multiplayer.is_server():
		if target_peer_id > 0 and transport != null:
			transport.send_target_transcript(target_peer_id, data)
		else:
			_broadcast_transcript(data)
	else:
		_on_transport_transcript_received(data)


func publish_assistant_interaction_state(
	target_peer_id: int,
	state: String,
	text: String = "",
	details: Dictionary = {}
) -> void:
	var data := {
		"target_peer_id": target_peer_id,
		"state": state.strip_edges(),
		"text": text.strip_edges(),
		"timestamp_msec": Time.get_ticks_msec(),
	}
	for key in details:
		if not data.has(key):
			data[key] = details[key]
	_update_assistant_command_capture_state(target_peer_id, str(data.get("state", "idle")))
	if not Execution.is_local() and multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and multiplayer.is_server():
		if transport != null and transport.has_method("send_assistant_interaction_state"):
			transport.send_assistant_interaction_state(target_peer_id, data)
		else:
			_on_assistant_interaction_state_received(data)
	else:
		_on_assistant_interaction_state_received(data)


func _set_peer_transcription_active(peer_id: int, active: bool) -> void:
	if is_assistant_speech_active(peer_id):
		return
	if peer_id <= 0:
		return
	if Execution.endpoint_asr() and peer_id != _get_local_voice_peer_id():
		return
	if not Execution.endpoint_asr() and not multiplayer.is_server():
		return
	if not transcription_enabled:
		active = false

	if active:
		var transcriber := _get_peer_transcriber(peer_id)
		if transcriber != null and transcriber.has_method("set_input_active"):
			transcriber.set_input_active(true)
	else:
		_finish_peer_transcription(peer_id)


func get_asr_provider() -> String:
	var environment_provider := OS.get_environment("GODOT_ASR_PROVIDER").strip_edges().to_lower()
	var selected := environment_provider if not environment_provider.is_empty() else asr_provider.strip_edges().to_lower()
	return ASR_PROVIDER_TENCENT if selected == ASR_PROVIDER_TENCENT else ASR_PROVIDER_FUNASR


func _get_local_asr_endpoint() -> String:
	var environment_endpoint := OS.get_environment("LOCAL_ASR_ENDPOINT").strip_edges()
	return environment_endpoint if not environment_endpoint.is_empty() else local_asr_endpoint.strip_edges()


func _create_asr_transcriber(node_name: String) -> Node:
	var transcriber: Node
	if get_asr_provider() == ASR_PROVIDER_TENCENT:
		transcriber = TencentAsrTranscriberScript.new()
	else:
		transcriber = LocalFunAsrTranscriberScript.new()
	transcriber.name = node_name
	return transcriber


func _get_peer_transcriber(peer_id: int) -> Node:
	if _peer_transcribers.has(peer_id):
		var existing := _peer_transcribers[peer_id] as Node
		if existing != null and is_instance_valid(existing):
			return existing
		_peer_transcribers.erase(peer_id)

	var transcriber := _create_asr_transcriber("AsrPeer_%d" % peer_id)
	var utterance_id := int(_transcript_utterance_ids.get(peer_id, 1))
	_transcript_utterance_ids[peer_id] = utterance_id + 1
	transcriber.set_meta("transcript_utterance_id", utterance_id)
	transcriber.set_meta("recognition_epoch", _recognition_epoch)
	_configure_peer_transcriber(transcriber)
	add_child(transcriber)
	transcriber.transcribed_msg.connect(Callable(self, "_on_peer_transcribed_msg").bind(peer_id, transcriber))
	transcriber.connection_state_changed.connect(Callable(self, "_on_peer_transcription_state_changed").bind(peer_id, transcriber))
	transcriber.error_occurred.connect(Callable(self, "_on_peer_transcription_error").bind(peer_id, transcriber))
	_peer_transcribers[peer_id] = transcriber
	return transcriber

func _configure_peer_transcriber(transcriber: Node) -> void:
	if transcription_config == null:
		transcription_config = get_node_or_null("TencentAsrConfig")
	if transcription_config == null:
		return

	for property_name in COMMON_ASR_CONFIG_PROPERTIES:
		transcriber.set(property_name, transcription_config.get(property_name))
	if get_asr_provider() == ASR_PROVIDER_TENCENT:
		for property_name in TENCENT_ASR_CONFIG_PROPERTIES:
			transcriber.set(property_name, transcription_config.get(property_name))
	else:
		transcriber.set("endpoint_url", _get_local_asr_endpoint())
		transcriber.set("speech_threshold", local_asr_speech_threshold)
		transcriber.set("vad_silence_time", local_asr_vad_silence_time)
		transcriber.set("stable_partial_msec", local_asr_stable_partial_msec)
		transcriber.set("packet_duration_msec", local_asr_packet_duration_msec)
		if not local_asr_hotwords.strip_edges().is_empty():
			transcriber.set("hotword_list", local_asr_hotwords)


func _on_dictation_transcribed_msg(is_final: bool, new_text: String, session_id: String, source: Node) -> void:
	if source != _dictation_transcriber or not _matches_active_dictation(session_id):
		return
	var clean_text := new_text.strip_edges()
	if clean_text.is_empty():
		return
	_dictation_last_text = clean_text
	if is_final:
		return
	dictation_partial_received.emit(_dictation_session_id, clean_text)


func _on_dictation_connection_state_changed(state: String, detail: String, session_id: String, source: Node) -> void:
	if source != _dictation_transcriber or not _matches_active_dictation(session_id):
		return
	match state:
		"connected", "open":
			if _dictation_state != "finalizing":
				_dictation_state = "capturing"
				_dictation_state_changed_for(_dictation_session_id, "capturing", "正在录音。")
		"finalizing":
			if _dictation_state == "finalizing":
				_dictation_state_changed_for(_dictation_session_id, "finalizing", "正在识别。")
		"finished":
			_complete_dictation()
		"closed":
			if not _dictation_last_text.is_empty() and _dictation_state == "finalizing":
				_complete_dictation()
			else:
				_fail_dictation(ERR_CONNECTION_ERROR, detail if not detail.strip_edges().is_empty() else "听写连接已关闭。")
		"error":
			_fail_dictation(ERR_CONNECTION_ERROR, detail if not detail.strip_edges().is_empty() else "听写连接发生错误。")


func _on_dictation_error(code: int, message: String, session_id: String, source: Node) -> void:
	if source != _dictation_transcriber or not _matches_active_dictation(session_id) or _dictation_failure_reported:
		return
	_fail_dictation(code, message)


func _update_dictation_timeout() -> void:
	if not _is_dictation_active():
		return
	var now := Time.get_ticks_msec()
	if _dictation_state != "finalizing" and now - _dictation_started_msec >= DICTATION_MAX_DURATION_MSEC:
		finish_local_dictation(_dictation_session_id)
		return
	if _dictation_state == "finalizing" \
			and _dictation_finalize_deadline_msec > 0 \
			and now >= _dictation_finalize_deadline_msec:
		_fail_dictation(ERR_TIMEOUT, "等待最终转写结果超时。")


func _complete_dictation() -> void:
	if not _is_dictation_active():
		return
	if _dictation_last_text.is_empty():
		_fail_dictation(ERR_FILE_CORRUPT, "腾讯 ASR 未返回可用文字。")
		return
	var active_session_id := _dictation_session_id
	if not _dictation_final_emitted:
		_dictation_final_emitted = true
		dictation_final_received.emit(active_session_id, _dictation_last_text)
	_dictation_state = "completed"
	_dictation_state_changed_for(active_session_id, "completed", "听写完成。")
	_cleanup_dictation(false)


func _fail_dictation(code: int, message: String) -> void:
	if not _is_dictation_active() or _dictation_failure_reported:
		return
	_dictation_failure_reported = true
	var active_session_id := _dictation_session_id
	var clean_message := message.strip_edges()
	if clean_message.is_empty():
		clean_message = "听写失败。"
	_dictation_state = "failed"
	_dictation_state_changed_for(active_session_id, "failed", clean_message)
	dictation_failed.emit(active_session_id, code, clean_message)
	_cleanup_dictation(true)


func _cleanup_dictation(cancel_transport: bool) -> void:
	var transcriber := _dictation_transcriber
	_dictation_transcriber = null
	if transcriber != null and is_instance_valid(transcriber):
		if cancel_transport and transcriber.has_method("cancel_transcription"):
			transcriber.call("cancel_transcription")
		transcriber.queue_free()
	_dictation_session_id = ""
	_dictation_started_msec = 0
	_dictation_finalize_deadline_msec = 0
	if capture != null:
		capture.set_voice_active(voice_enabled)
	_publish_local_speaking_state(voice_enabled)
	if multiplayer.is_server():
		_set_peer_transcription_active(
			_get_local_voice_peer_id(),
			voice_enabled and transcription_enabled
		)
	else:
		_reset_client_transcription_upload()


func _publish_local_speaking_state(active: bool) -> void:
	if transport != null and multiplayer.has_multiplayer_peer():
		transport.send_speaking_state(active)
		if multiplayer.is_server():
			for peer_id in multiplayer.get_peers():
				transport.send_server_speaking_state_to_peer(peer_id, active)
	if multiplayer.is_server():
		_set_voice_level_mic_state(_get_local_voice_peer_id(), active)


func _dictation_state_changed_for(session_id: String, state: String, detail: String) -> void:
	dictation_state_changed.emit(session_id, state, detail)


func _matches_active_dictation(session_id: String) -> bool:
	return _is_dictation_active() and session_id.strip_edges() == _dictation_session_id


func _is_dictation_active() -> bool:
	return not _dictation_session_id.is_empty()

func _finish_peer_transcription(peer_id: int) -> void:
	if not _peer_transcribers.has(peer_id):
		return

	var transcriber := _peer_transcribers[peer_id] as Node
	_peer_transcribers.erase(peer_id)
	if transcriber == null or not is_instance_valid(transcriber):
		return
	if transcriber.has_method("finish_transcription"):
		transcriber.call("finish_transcription")
		return
	_cancel_peer_transcriber(transcriber)


func _stop_peer_transcription(peer_id: int) -> void:
	if not _peer_transcribers.has(peer_id):
		return
	var transcriber := _peer_transcribers[peer_id] as Node
	_peer_transcribers.erase(peer_id)
	_cancel_peer_transcriber(transcriber)


func _cancel_peer_transcriber(transcriber: Node) -> void:
	if transcriber == null or not is_instance_valid(transcriber):
		return
	if transcriber.has_method("cancel_transcription"):
		transcriber.call("cancel_transcription")
	elif transcriber.has_method("stop_transcription"):
		transcriber.call("stop_transcription")
	transcriber.queue_free()

func _stop_all_transcription() -> void:
	for peer_id in _peer_transcribers.keys().duplicate():
		_finish_peer_transcription(int(peer_id))

func _feed_transcription_frames(peer_id: int, frames: PackedVector2Array) -> void:
	if is_assistant_speech_active(peer_id):
		return
	var transcriber := _get_peer_transcriber(peer_id)
	if transcriber == null or not transcriber.has_method("push_audio_frames"):
		return
	if transcriber.has_method("set_input_active"):
		transcriber.set_input_active(true)
	transcriber.push_audio_frames(frames)

func _feed_transcription_pcm(peer_id: int, pcm: PackedByteArray) -> void:
	if is_assistant_speech_active(peer_id):
		return
	var transcriber := _get_peer_transcriber(peer_id)
	if transcriber == null or not transcriber.has_method("push_pcm16_audio"):
		return
	if transcriber.has_method("set_input_active"):
		transcriber.set_input_active(true)
	transcriber.push_pcm16_audio(pcm)

func _on_peer_transcribed_msg(is_final: bool, new_text: String, peer_id: int, source: Node = null) -> void:
	if Execution.endpoint_asr() and not Execution.is_local():
		if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer is OfflineMultiplayerPeer or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			return
	if Execution.endpoint_asr() and peer_id != _get_local_voice_peer_id():
		return
	if is_assistant_speech_active(peer_id) or (is_instance_valid(source) and bool(source.get_meta("speech_cancelled", false))):
		return
	var text := new_text.strip_edges()
	if text.is_empty() or (not Execution.endpoint_asr() and not multiplayer.is_server()):
		return

	var utterance_id := int(source.get_meta("transcript_utterance_id", 0)) if source != null else 0
	if utterance_id <= 0:
		utterance_id = int(_transcript_utterance_ids.get(peer_id, 1))
	var data := {
		"speaker_peer_id": peer_id,
		"speaker_name": _get_transcript_speaker_name(peer_id),
		"text": text,
		"is_final": is_final,
		"utterance_id": utterance_id,
		"timestamp_msec": Time.get_ticks_msec(),
		"recognition_epoch": int(source.get_meta("recognition_epoch", _recognition_epoch)) if is_instance_valid(source) else _recognition_epoch,
	}
	data["history_only"] = peer_id == _get_local_voice_peer_id() and int(data["recognition_epoch"]) != _recognition_epoch
	if Execution.endpoint_asr() and not Execution.is_local():
		if not multiplayer.is_server():
			_on_transport_transcript_received(data)
		if transport != null:
			transport.send_endpoint_transcript(data)
	elif Execution.is_local():
		var share_ordinary := not _is_assistant_command_transcript(data)
		_on_transport_transcript_received(data)
		if share_ordinary and transport != null:
			transport.send_endpoint_transcript(data)
	else:
		_broadcast_transcript(data)
	if is_final and source == null:
		_transcript_utterance_ids[peer_id] = utterance_id + 1

func _on_peer_transcription_state_changed(state: String, detail: String, peer_id: int, source: Node = null) -> void:
	if _manual_wake_pending and is_instance_valid(source) and int(source.get_meta("recognition_epoch", -1)) == _recognition_epoch:
		if state == "connected":
			_manual_wake_pending = false
			if not Execution.is_local() and transport != null:
				transport.send_capture_phase(_recognition_epoch, "ready")
			else:
				assistant_capture_ready.emit(peer_id)
		elif state in ["error", "closed"]:
			_manual_wake_pending = false
			if not Execution.is_local() and transport != null:
				transport.send_capture_phase(_recognition_epoch, "failed")
			else:
				assistant_capture_failed.emit(peer_id, detail)
	if state == "error" or state == "closed":
		_log("ASR provider=%s peer=%d state=%s detail=%s" % [get_asr_provider(), peer_id, state, detail])
	if state == "error" and not detail.strip_edges().is_empty():
		_broadcast_transcription_system_message("%s转写错误：%s" % [_get_transcript_speaker_name(peer_id), detail])
	if state in ["finished", "error", "closed"]:
		_release_peer_transcriber(peer_id, source)

func _on_peer_transcription_error(code: int, message: String, peer_id: int, _source: Node = null) -> void:
	_log("ASR provider=%s peer=%d error=%d message=%s" % [get_asr_provider(), peer_id, code, message])
	if message.strip_edges() != "":
		_broadcast_transcription_system_message("%s转写错误：%s" % [_get_transcript_speaker_name(peer_id), message])


func _release_peer_transcriber(peer_id: int, source: Node) -> void:
	if source == null or not is_instance_valid(source):
		return
	if _peer_transcribers.get(peer_id) == source:
		_peer_transcribers.erase(peer_id)
	source.queue_free()

func _broadcast_transcript(data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	if transport != null and transport.has_method("broadcast_transcript"):
		transport.broadcast_transcript(data)
	else:
		_on_transport_transcript_received(data)

func _broadcast_transcription_system_message(message: String) -> void:
	var text := message.strip_edges()
	if text.is_empty():
		return
	var data := {
		"speaker_peer_id": 0,
		"speaker_name": "系统",
		"text": text,
		"is_final": true,
		"timestamp_msec": Time.get_ticks_msec(),
	}
	if Execution.endpoint_asr():
		_on_transport_transcript_received(data)
	elif multiplayer.is_server():
		_broadcast_transcript(data)

func _broadcast_transcription_enabled() -> void:
	if not multiplayer.is_server():
		return
	if transport != null and transport.has_method("broadcast_transcription_enabled"):
		transport.broadcast_transcription_enabled(transcription_enabled)

func _store_transcript_data(data: Dictionary) -> void:
	if bool(data.get("is_final", false)) and not _is_assistant_command_transcript(data):
		voice_transcript_history.append(data.duplicate(true))
		while voice_transcript_history.size() > 80:
			voice_transcript_history.pop_front()


func _is_assistant_command_transcript(data: Dictionary) -> bool:
	if bool(data.get("history_only", false)):
		return false
	var speaker_peer_id := int(data.get("speaker_peer_id", 0))
	if speaker_peer_id <= 0:
		return false
	if _assistant_command_capture_peers.has(speaker_peer_id):
		return true
	return str(data.get("text", "")).find(ASSISTANT_WAKE_WORD) >= 0

func _get_transcript_speaker_name(peer_id: int) -> String:
	return "服务端" if peer_id == SERVER_PEER_ID else "客户端%d" % peer_id

func _is_peer_mic_open(peer_id: int) -> bool:
	if peer_id == _get_local_voice_peer_id():
		return voice_enabled and not _is_dictation_active()
	var state: Dictionary = voice_level_states.get(peer_id, {})
	return bool(state.get("mic_open", false))

func _get_open_mic_peer_ids() -> Array:
	var ids: Array = []
	var local_peer_id := _get_local_voice_peer_id()
	if local_peer_id > 0 and voice_enabled and not _is_dictation_active():
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
	if Execution.endpoint_asr():
		return Execution.local_peer_id(multiplayer)
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return SERVER_PEER_ID if voice_endpoint_selected and is_server_endpoint else 0

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
	is_server_endpoint = is_server_role
	is_vr_mode = _is_vr_mode_requested()
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
	var profile = RuntimeProfileScript.current()
	if profile != null and profile.is_valid():
		return profile.uses_xr()
	if OS.has_feature("android") or _has_cmdline_arg(GROUND_VR_ARG):
		return true
	var role := _get_arg_value(VOICE_ROLE_ARG).to_lower()
	return role in ["client", "vr"] or _has_cmdline_arg(XR_CLIENT_ARG) or _has_xr_mode_on_arg()

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
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler == null or network_handler.get("peer") == null:
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
