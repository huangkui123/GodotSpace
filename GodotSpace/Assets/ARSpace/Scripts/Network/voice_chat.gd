extends Node

signal voice_enabled_changed(enabled: bool)
signal remote_speaking_changed(peer_id: int, is_speaking: bool)

const SERVER_PEER_ID := 1
const SERVER_SOURCE_ID := 1
const VoiceCaptureScript := preload("res://Assets/ARSpace/Scripts/Network/voice_capture.gd")
const VoiceTransportScript := preload("res://Assets/ARSpace/Scripts/Network/voice_transport_enet.gd")
const VoicePlaybackScript := preload("res://Assets/ARSpace/Scripts/Network/voice_playback.gd")

var voice_enabled: bool = false
var voice_players: Dictionary = {}
var packets_received: int = 0
var packets_sent: int = 0
var is_vr_mode: bool = false

var capture: Node
var transport: Node
var playback: Node

var _xr_toggle_was_pressed: bool = false

func _ready() -> void:
	_detect_vr_mode()
	_print_audio_device_state("startup")
	_request_runtime_audio_permissions()
	_setup_components()
	_connect_multiplayer_signals()

	if NetworkHandler.has_signal("network_ready"):
		NetworkHandler.network_ready.connect(_on_network_ready)

	print("VoiceChat initialized with two-voip components. Mode: %s" % ("VR" if is_vr_mode else "PC"))

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_voice"):
		toggle_voice()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	_poll_vr_voice_toggle()

func toggle_voice() -> void:
	set_voice_enabled(not voice_enabled)

func set_voice_enabled(enabled: bool) -> void:
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
	print("Voice %s" % ("enabled" if voice_enabled else "disabled"))

func start_voice_chat() -> void:
	set_voice_enabled(true)

func stop_voice_chat() -> void:
	set_voice_enabled(false)

func remove_player(peer_id: int) -> void:
	if playback != null:
		playback.remove_source(peer_id)

func get_debug_state() -> Dictionary:
	return {
		"voice_enabled": voice_enabled,
		"is_vr_mode": is_vr_mode,
		"is_server": multiplayer.is_server(),
		"peer_id": multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0,
		"connected_peers": multiplayer.get_peers() if multiplayer.has_multiplayer_peer() else [],
		"packets_sent": packets_sent,
		"packets_received": packets_received,
		"capture": capture.get_debug_state() if capture != null else {},
		"transport": transport.get_debug_state() if transport != null else {},
		"playback": playback.get_debug_state() if playback != null else {},
	}

func _setup_components() -> void:
	capture = VoiceCaptureScript.new()
	capture.name = "VoiceCapture"
	add_child(capture)
	capture.opus_packet_captured.connect(_on_local_opus_packet_captured)
	capture.speaking_changed.connect(_on_local_speaking_changed)
	capture.setup()

	transport = VoiceTransportScript.new()
	transport.name = "VoiceTransportENet"
	add_child(transport)
	transport.server_voice_packet_received.connect(_on_server_voice_packet_received)
	transport.downlink_voice_packet_received.connect(_on_downlink_voice_packet_received)
	transport.speaking_state_received.connect(_on_remote_speaking_state_received)

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
			transport.send_downlink_voice_packet(peer_id, packet)
			packets_sent += 1
	else:
		transport.send_voice_packet(packet)
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
	remote_speaking_changed.emit(multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 0, is_speaking)

func _on_remote_speaking_state_received(peer_id: int, is_speaking: bool) -> void:
	remote_speaking_changed.emit(peer_id, is_speaking)

func _on_network_ready() -> void:
	if transport != null and voice_enabled:
		transport.send_speaking_state(true)
	_print_audio_device_state("network ready")
	print("VoiceChat network ready")

func _on_peer_connected(peer_id: int) -> void:
	print("Voice peer connected: %d" % peer_id)
	if multiplayer.is_server() and transport != null:
		transport.send_server_speaking_state_to_peer(peer_id, voice_enabled)

func _on_peer_disconnected(peer_id: int) -> void:
	print("Voice peer disconnected: %d" % peer_id)
	remove_player(peer_id)

func _on_connected_to_server() -> void:
	print("VoiceChat connected to server")
	_print_audio_device_state("client connected")
	if transport != null and voice_enabled:
		transport.send_speaking_state(true)

func _on_connection_failed() -> void:
	print("VoiceChat connection failed")
	set_voice_enabled(false)
	if playback != null:
		playback.clear()

func _on_server_disconnected() -> void:
	print("VoiceChat server disconnected")
	set_voice_enabled(false)
	if playback != null:
		playback.clear()

func _detect_vr_mode() -> void:
	var args := OS.get_cmdline_args()
	if "--vr" in args:
		is_vr_mode = true
		return
	if "--pc" in args:
		is_vr_mode = false
		return

	var xr_interface := XRServer.primary_interface
	is_vr_mode = xr_interface != null and xr_interface.is_initialized()

func _request_runtime_audio_permissions() -> void:
	if OS.has_feature("android") and OS.has_method("request_permissions"):
		OS.request_permissions()

func _print_audio_device_state(context: String) -> void:
	var role := "offline"
	if multiplayer.has_multiplayer_peer():
		role = "server" if multiplayer.is_server() else "client"

	print("VoiceChat audio devices [%s] role=%s mode=%s" % [context, role, "VR" if is_vr_mode else "PC"])
	print("  input: %s" % AudioServer.get_input_device())
	print("  output: %s" % AudioServer.get_output_device())
	print("  available inputs: %s" % str(AudioServer.get_input_device_list()))
	print("  available outputs: %s" % str(AudioServer.get_output_device_list()))

func _poll_vr_voice_toggle() -> void:
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
