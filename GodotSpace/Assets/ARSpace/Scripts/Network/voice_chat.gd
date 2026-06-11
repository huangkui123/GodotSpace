extends Node

signal voice_enabled_changed(enabled: bool)
signal remote_speaking_changed(peer_id: int, is_speaking: bool)
signal voice_level_changed(peer_id: int, state: Dictionary)

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
const VoiceCaptureScript := preload("res://Assets/ARSpace/Scripts/Network/voice_capture.gd")
const VoiceTransportScript := preload("res://Assets/ARSpace/Scripts/Network/voice_transport_enet.gd")
const VoicePlaybackScript := preload("res://Assets/ARSpace/Scripts/Network/voice_playback.gd")
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

var _xr_toggle_was_pressed: bool = false
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
var _server_volume_panel_update_accum: float = 0.0
var _server_volume_layer: CanvasLayer
var _server_volume_rows_container: VBoxContainer
var _server_volume_rows: Dictionary = {}

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
	_poll_vr_voice_toggle()
	_pump_output_test_tone()
	_update_voice_level_state(delta)
	_update_server_volume_panel(delta)
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

	voice_enabled_changed.emit(voice_enabled)
	_log("Voice %s" % ("enabled" if voice_enabled else "disabled"))
	_update_debug_controls()

func start_voice_chat() -> void:
	set_voice_enabled(true)

func stop_voice_chat() -> void:
	set_voice_enabled(false)

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
		"voice_level_states": voice_level_states.duplicate(true),
		"capture": capture.get_debug_state() if capture != null else {},
		"transport": transport.get_debug_state() if transport != null else {},
		"playback": playback.get_debug_state() if playback != null else {},
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
	capture = VoiceCaptureScript.new()
	capture.name = "VoiceCapture"
	add_child(capture)
	capture.opus_packet_captured.connect(_on_local_opus_packet_captured)
	capture.speaking_changed.connect(_on_local_speaking_changed)

	transport = VoiceTransportScript.new()
	transport.name = "VoiceTransportENet"
	add_child(transport)
	transport.server_voice_packet_received.connect(_on_server_voice_packet_received)
	transport.downlink_voice_packet_received.connect(_on_downlink_voice_packet_received)
	transport.speaking_state_received.connect(_on_remote_speaking_state_received)
	transport.voice_level_received.connect(_on_voice_level_received)

	playback = VoicePlaybackScript.new()
	playback.name = "VoicePlayback"
	add_child(playback)
	voice_players = playback.players

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

func _on_local_speaking_changed(is_speaking: bool) -> void:
	var peer_id := _get_local_voice_peer_id()
	if multiplayer.is_server():
		_set_voice_level_mic_state(peer_id, is_speaking)
	remote_speaking_changed.emit(peer_id, is_speaking)

func _on_remote_speaking_state_received(peer_id: int, is_speaking: bool) -> void:
	if multiplayer.is_server():
		_set_voice_level_mic_state(peer_id, is_speaking)
	remote_speaking_changed.emit(peer_id, is_speaking)

func _on_voice_level_received(peer_id: int, peak: float, peak_db: float, mic_open: bool) -> void:
	if not multiplayer.is_server():
		return
	_store_voice_level_state(peer_id, peak, peak_db, mic_open)

func _on_network_role_selected(is_server_role: bool, context: String = "") -> void:
	_set_voice_endpoint_role(is_server_role)
	_print_audio_device_state(context if context != "" else "server selected" if is_server_role else "client selected")

func _on_network_ready() -> void:
	if transport != null and voice_enabled:
		transport.send_speaking_state(true)
	if voice_endpoint_selected:
		_apply_audio_device_profile()
	if multiplayer.is_server():
		_ensure_server_volume_panel()
		_set_voice_level_mic_state(SERVER_PEER_ID, voice_enabled)
	_log("VoiceChat network ready")

func _on_peer_connected(peer_id: int) -> void:
	_log("Voice peer connected: %d" % peer_id)
	if multiplayer.is_server() and transport != null:
		transport.send_server_speaking_state_to_peer(peer_id, voice_enabled)
	if multiplayer.is_server():
		_set_voice_level_mic_state(peer_id, false)
		_ensure_server_volume_panel()

func _on_peer_disconnected(peer_id: int) -> void:
	_log("Voice peer disconnected: %d" % peer_id)
	remove_player(peer_id)
	voice_level_states.erase(peer_id)
	_remove_server_volume_row(peer_id)

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
	_hide_server_volume_panel()
	if playback != null:
		playback.clear()

func _on_server_disconnected() -> void:
	_log("VoiceChat server disconnected")
	set_voice_enabled(false)
	_hide_server_volume_panel()
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

func _get_local_voice_peer_id() -> int:
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return SERVER_PEER_ID if voice_endpoint_selected and not is_vr_mode else 0

func _ensure_server_volume_panel() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if not voice_endpoint_selected or is_vr_mode:
		return
	if _server_volume_layer != null and is_instance_valid(_server_volume_layer):
		_server_volume_layer.visible = true
		return

	_server_volume_layer = CanvasLayer.new()
	_server_volume_layer.name = "ServerVoiceLevels"
	_server_volume_layer.layer = 96
	add_child(_server_volume_layer)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.position = Vector2(12.0, 12.0)
	panel.custom_minimum_size = Vector2(420.0, 0.0)
	_server_volume_layer.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	var title := Label.new()
	title.name = "Title"
	title.text = "SERVER VOICE LEVELS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)
	_add_server_volume_header_label(header, "PEER", 96.0, HORIZONTAL_ALIGNMENT_LEFT)
	_add_server_volume_header_label(header, "MIC", 68.0, HORIZONTAL_ALIGNMENT_CENTER)
	_add_server_volume_header_label(header, "LEVEL", 150.0, HORIZONTAL_ALIGNMENT_CENTER)
	_add_server_volume_header_label(header, "DB", 68.0, HORIZONTAL_ALIGNMENT_RIGHT)

	_server_volume_rows_container = VBoxContainer.new()
	_server_volume_rows_container.name = "Rows"
	_server_volume_rows_container.add_theme_constant_override("separation", 4)
	column.add_child(_server_volume_rows_container)

func _add_server_volume_header_label(parent: Container, text: String, width: float, alignment: HorizontalAlignment) -> void:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0.0)
	label.horizontal_alignment = alignment
	parent.add_child(label)

func _hide_server_volume_panel() -> void:
	if _server_volume_layer != null and is_instance_valid(_server_volume_layer):
		_server_volume_layer.visible = false

func _update_server_volume_panel(delta: float) -> void:
	if not voice_endpoint_selected or is_vr_mode:
		_hide_server_volume_panel()
		return
	if DisplayServer.get_name() == "headless":
		return
	if not multiplayer.is_server():
		_hide_server_volume_panel()
		return

	_ensure_server_volume_panel()
	if _server_volume_layer == null or not is_instance_valid(_server_volume_layer):
		return

	_server_volume_panel_update_accum += delta
	if _server_volume_panel_update_accum < SERVER_VOLUME_PANEL_UPDATE_INTERVAL:
		return
	_server_volume_panel_update_accum = 0.0

	var peer_ids := _get_server_volume_peer_ids()
	_sync_server_volume_rows(peer_ids)
	var now := Time.get_ticks_msec()
	for peer_id in peer_ids:
		_update_server_volume_row(int(peer_id), now)

func _get_server_volume_peer_ids() -> Array:
	var ids: Array = [SERVER_PEER_ID]
	if multiplayer.has_multiplayer_peer():
		for peer_id in multiplayer.get_peers():
			if not ids.has(peer_id):
				ids.append(peer_id)

	for peer_id in voice_level_states.keys():
		var id := int(peer_id)
		if id == SERVER_PEER_ID or (multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(id)):
			if not ids.has(id):
				ids.append(id)

	ids.sort()
	return ids

func _sync_server_volume_rows(peer_ids: Array) -> void:
	if _server_volume_rows_container == null or not is_instance_valid(_server_volume_rows_container):
		return

	for peer_id in _server_volume_rows.keys().duplicate():
		if not peer_ids.has(int(peer_id)):
			_remove_server_volume_row(int(peer_id))

	for peer_id in peer_ids:
		var id := int(peer_id)
		if not _server_volume_rows.has(id):
			_create_server_volume_row(id)

func _create_server_volume_row(peer_id: int) -> void:
	if _server_volume_rows_container == null or not is_instance_valid(_server_volume_rows_container):
		return

	var row := HBoxContainer.new()
	row.name = "Peer_%d" % peer_id
	row.custom_minimum_size = Vector2(390.0, 28.0)
	row.add_theme_constant_override("separation", 8)
	_server_volume_rows_container.add_child(row)

	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(96.0, 0.0)
	name_label.text = _get_voice_panel_peer_label(peer_id)
	row.add_child(name_label)

	var mic_label := Label.new()
	mic_label.custom_minimum_size = Vector2(68.0, 0.0)
	mic_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(mic_label)

	var meter := ProgressBar.new()
	meter.custom_minimum_size = Vector2(150.0, 18.0)
	meter.min_value = 0.0
	meter.max_value = 1.0
	meter.step = 0.01
	meter.show_percentage = false
	meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(meter)

	var db_label := Label.new()
	db_label.custom_minimum_size = Vector2(68.0, 0.0)
	db_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(db_label)

	_server_volume_rows[peer_id] = {
		"root": row,
		"name": name_label,
		"mic": mic_label,
		"meter": meter,
		"db": db_label,
	}

func _remove_server_volume_row(peer_id: int) -> void:
	if not _server_volume_rows.has(peer_id):
		return

	var row_state: Dictionary = _server_volume_rows[peer_id]
	var row := row_state.get("root") as Node
	if row != null and is_instance_valid(row):
		row.queue_free()
	_server_volume_rows.erase(peer_id)

func _update_server_volume_row(peer_id: int, now_msec: int) -> void:
	if not _server_volume_rows.has(peer_id):
		return

	var row_state: Dictionary = _server_volume_rows[peer_id]
	var name_label := row_state.get("name") as Label
	var mic_label := row_state.get("mic") as Label
	var meter := row_state.get("meter") as ProgressBar
	var db_label := row_state.get("db") as Label
	var state: Dictionary = voice_level_states.get(peer_id, {})
	var has_state := not state.is_empty()
	var has_level := bool(state.get("has_level", false))
	var level_updated_msec := int(state.get("level_updated_msec", 0))
	var level_is_fresh := has_level and level_updated_msec > 0 and float(now_msec - level_updated_msec) / 1000.0 <= VOICE_LEVEL_STALE_SECONDS
	var mic_open := bool(state.get("mic_open", false))

	if name_label != null:
		name_label.text = _get_voice_panel_peer_label(peer_id)

	if mic_label != null:
		if has_state:
			mic_label.text = "ON" if mic_open else "OFF"
			mic_label.modulate = Color(0.3, 1.0, 0.45) if mic_open else Color(0.9, 0.9, 0.9)
		else:
			mic_label.text = "NO DATA"
			mic_label.modulate = Color(1.0, 0.85, 0.35)

	if meter != null:
		meter.value = _voice_db_to_meter_value(float(state.get("peak_db", -80.0))) if level_is_fresh else 0.0

	if db_label != null:
		db_label.text = "%.1f dB" % float(state.get("peak_db", -80.0)) if level_is_fresh else "-- dB"

func _get_voice_panel_peer_label(peer_id: int) -> String:
	return "SERVER" if peer_id == SERVER_PEER_ID else "CLIENT %d" % peer_id

func _voice_db_to_meter_value(peak_db: float) -> float:
	if peak_db <= VOICE_LEVEL_MIN_DB:
		return 0.0
	return clampf((peak_db - VOICE_LEVEL_MIN_DB) / (VOICE_LEVEL_MAX_DB - VOICE_LEVEL_MIN_DB), 0.0, 1.0)

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
	if is_server_role:
		_ensure_server_volume_panel()
	else:
		_hide_server_volume_panel()
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

	_add_debug_button(row, "Voice", "toggle_voice")
	_add_debug_button(row, "Tone", "play_output_test_tone")
	_add_debug_button(row, "Mic", "play_microphone_monitor_test")
	_add_debug_button(row, "In", "cycle_voice_input_device")
	_add_debug_button(row, "Out", "cycle_voice_output_device")

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
	var monitor_state := "MON" if _mic_monitor_player != null and is_instance_valid(_mic_monitor_player) else ""
	var voice_state := "ON" if voice_enabled else "OFF"
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

func _poll_vr_voice_toggle() -> void:
	if not voice_endpoint_selected or not is_vr_mode:
		return

	var pressed := _is_vr_voice_toggle_pressed()
	if pressed and not _xr_toggle_was_pressed:
		toggle_voice()
	_xr_toggle_was_pressed = pressed

func _is_vr_voice_toggle_pressed() -> bool:
	var tracker := XRServer.get_tracker("right_hand")
	if tracker == null:
		return false

	return _tracker_input_pressed(tracker, "primary") or _tracker_input_pressed(tracker, "ax_button")

func _tracker_input_pressed(tracker: XRPositionalTracker, input_name: String) -> bool:
	var value = tracker.get_input(input_name)
	match typeof(value):
		TYPE_BOOL:
			return value
		TYPE_INT, TYPE_FLOAT:
			return float(value) > 0.5
		_:
			return false

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
