class_name VoiceTransportENet
extends Node

signal server_voice_packet_received(sender_peer_id: int, packet: PackedByteArray)
signal downlink_voice_packet_received(packet: PackedByteArray)
signal speaking_state_received(peer_id: int, is_speaking: bool)
signal voice_level_received(peer_id: int, peak: float, peak_db: float, mic_open: bool)
signal transcription_pcm_received(sender_peer_id: int, pcm: PackedByteArray)
signal transcript_received(data: Dictionary)
signal assistant_wake_requested(speaker_peer_id: int)
signal capture_phase_received(peer_id: int, phase: String)
signal assistant_interaction_state_received(data: Dictionary)
signal transcription_enabled_received(enabled: bool)

const SERVER_PEER_ID := 1
const Execution := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_execution.gd")
var _endpoint_transcript_limits: Dictionary = {}
var _capture_epochs: Dictionary = {}
var _capture_phases: Dictionary = {}
var _capture_rate: Dictionary = {}


func forget_endpoint_peer(peer_id: int) -> void:
	_endpoint_transcript_limits.erase(peer_id)
	_capture_epochs.erase(peer_id)
	_capture_phases.erase(peer_id)
	_capture_rate.erase(peer_id)


func _registered_sender(sender: int) -> bool:
	if sender <= 1 or not multiplayer.get_peers().has(sender):
		return false
	var network := get_node_or_null("/root/NetworkHandler")
	return network != null and str(network.call("get_peer_role", sender)) in ["sky", "ground_vr"]


func send_capture_phase(epoch: int, phase: String) -> void:
	if not Execution.endpoint_asr() or not _has_connected_client_peer():
		return
	if multiplayer.is_server():
		_accept_capture_phase(1, epoch, phase)
	else:
		rpc_id(1, "_server_capture_phase", epoch, phase)


@rpc("any_peer", "call_remote", "reliable", 3)
func _server_capture_phase(epoch: int, phase: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if multiplayer.is_server() and _registered_sender(sender):
		_accept_capture_phase(sender, epoch, phase)


func _accept_capture_phase(sender: int, epoch: int, phase: String) -> void:
	if not Execution.endpoint_asr() or epoch < 0 or epoch > 2147483647:
		return
	var previous := int(_capture_epochs.get(sender, -1))
	if epoch < previous or not phase in ["boundary", "preparing", "ready", "failed"]:
		return
	if phase in ["ready", "failed"] and (epoch != previous or _capture_phases.get(sender) != "preparing"):
		return
	if epoch == previous and phase in ["boundary", "preparing"]:
		return
	var now := Time.get_ticks_msec()
	var rate: Dictionary = _capture_rate.get(sender, {"start": now, "count": 0})
	if now - int(rate["start"]) > 1000:
		rate = {"start": now, "count": 0}
	rate["count"] = int(rate["count"]) + 1
	_capture_rate[sender] = rate
	if int(rate["count"]) > 20:
		return
	_capture_epochs[sender] = epoch
	_capture_phases[sender] = phase
	capture_phase_received.emit(sender, phase)


func send_endpoint_transcript(data: Dictionary) -> void:
	if not Execution.endpoint_asr() or not _has_connected_client_peer():
		return
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return
	if multiplayer.is_server():
		_relay_endpoint_transcript(SERVER_PEER_ID, data)
	else:
		rpc_id(SERVER_PEER_ID, "_server_endpoint_transcript", data)


@rpc("any_peer", "call_remote", "reliable", 3)
func _server_endpoint_transcript(data: Dictionary) -> void:
	if not Execution.endpoint_asr() or not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _registered_sender(sender):
		return
	_relay_endpoint_transcript(sender, data)


func _relay_endpoint_transcript(sender: int, data: Dictionary) -> void:
	if typeof(data.get("text")) != TYPE_STRING or typeof(data.get("is_final")) != TYPE_BOOL or typeof(data.get("utterance_id")) != TYPE_INT:
		return
	var text := str(data.get("text", "")).strip_edges()
	if text.is_empty() or text.length() > 4000 or data.size() > 12:
		return
	if typeof(data.get("recognition_epoch", 0)) != TYPE_INT or typeof(data.get("history_only", false)) != TYPE_BOOL:
		return
	if int(data.get("recognition_epoch", 0)) < 0 or int(data.get("recognition_epoch", 0)) > 2147483647:
		return
	# Rebuild untrusted client data; neither speaker identity nor assistant
	# source/control metadata can be supplied by a remote peer.
	var now := Time.get_ticks_msec()
	var limit: Dictionary = _endpoint_transcript_limits.get(sender, {"start": now, "count": 0})
	if now - int(limit["start"]) >= 1000:
		limit = {"start": now, "count": 0}
	limit["count"] = int(limit["count"]) + 1
	_endpoint_transcript_limits[sender] = limit
	if int(limit["count"]) > 20:
		return
	var epoch := int(data.get("recognition_epoch", 0))
	var stale := bool(data.get("history_only", false)) or epoch < int(_capture_epochs.get(sender, 0))
	if epoch > int(_capture_epochs.get(sender, 0)):
		_capture_epochs[sender] = epoch
		_capture_phases[sender] = "boundary"
	var safe := {
		"speaker_peer_id": sender,
		"speaker_name": "服务端" if sender == 1 else "客户端%d" % sender,
		"text": text,
		"is_final": bool(data.get("is_final", false)),
		"utterance_id": maxi(0, int(data.get("utterance_id", 0))),
		"timestamp_msec": now,
		"history_only": Execution.is_local() or stale,
		"recognition_epoch": epoch,
	}
	var voice := get_node_or_null("/root/VoiceChat")
	var command := voice != null and bool(voice.call("_is_assistant_command_transcript", safe))
	if sender != SERVER_PEER_ID or not Execution.is_local():
		transcript_received.emit(safe.duplicate(true))
	if command:
		return
	# The Server router has now seen the authoritative text. Other clients
	# receive display-only copies and cannot activate an assistant with them.
	safe["history_only"] = true
	for peer_id in multiplayer.get_peers():
		if peer_id != sender:
			transcript_packets_sent += 1
			rpc_id(peer_id, "_client_voice_transcript", safe)


func send_target_transcript(target: int, data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	if target == 1:
		transcript_received.emit(data.duplicate(true))
	elif multiplayer.get_peers().has(target):
		rpc_id(target, "_client_voice_transcript", data)

var uplink_packets_sent: int = 0
var uplink_packets_received: int = 0
var downlink_packets_sent: int = 0
var downlink_packets_received: int = 0
var speaking_states_sent: int = 0
var speaking_states_received: int = 0
var voice_level_states_sent: int = 0
var voice_level_states_received: int = 0
var transcription_pcm_packets_sent: int = 0
var transcription_pcm_packets_received: int = 0
var transcript_packets_sent: int = 0
var transcript_packets_received: int = 0
var assistant_wake_requests_sent: int = 0
var assistant_wake_requests_received: int = 0
var assistant_interaction_packets_sent: int = 0
var assistant_interaction_packets_received: int = 0
var transcription_state_packets_sent: int = 0
var transcription_state_packets_received: int = 0

func send_voice_packet(packet: PackedByteArray) -> bool:
	if packet.size() == 0 or not _has_connected_client_peer():
		return false

	uplink_packets_sent += 1
	rpc_id(SERVER_PEER_ID, "_server_voice_packet", packet)
	return true

func send_downlink_voice_packet(target_peer_id: int, packet: PackedByteArray) -> bool:
	if packet.size() == 0 or not multiplayer.is_server() or target_peer_id <= 0:
		return false

	downlink_packets_sent += 1
	rpc_id(target_peer_id, "_client_downlink_voice_packet", packet)
	return true

func send_speaking_state(is_speaking: bool) -> void:
	if not _has_connected_client_peer():
		return
	if multiplayer.is_server():
		speaking_state_received.emit(multiplayer.get_unique_id(), is_speaking)
		return

	if not _has_connected_client_peer():
		return

	speaking_states_sent += 1
	rpc_id(SERVER_PEER_ID, "_server_speaking_state", is_speaking)

func send_voice_level_state(peak: float, peak_db: float, mic_open: bool) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.is_server():
		voice_level_states_sent += 1
		voice_level_received.emit(multiplayer.get_unique_id(), peak, peak_db, mic_open)
		return

	if not _has_connected_client_peer():
		return

	voice_level_states_sent += 1
	rpc_id(SERVER_PEER_ID, "_server_voice_level_state", peak, peak_db, mic_open)

func send_transcription_pcm(pcm: PackedByteArray) -> bool:
	if pcm.size() == 0 or not _has_connected_client_peer() or multiplayer.is_server():
		return false

	transcription_pcm_packets_sent += 1
	rpc_id(SERVER_PEER_ID, "_server_transcription_pcm", pcm)
	return true

func send_server_speaking_state_to_peer(target_peer_id: int, is_speaking: bool) -> void:
	if not multiplayer.is_server() or target_peer_id <= 0:
		return

	speaking_states_sent += 1
	rpc_id(target_peer_id, "_client_speaking_state", SERVER_PEER_ID, is_speaking)

func broadcast_transcript(data: Dictionary) -> void:
	if not multiplayer.is_server():
		return

	transcript_received.emit(data.duplicate(true))
	for peer_id in multiplayer.get_peers():
		transcript_packets_sent += 1
		rpc_id(peer_id, "_client_voice_transcript", data)


func send_assistant_wake_request() -> bool:
	if multiplayer.is_server() or not _has_connected_client_peer():
		return false
	assistant_wake_requests_sent += 1
	rpc_id(SERVER_PEER_ID, "_server_assistant_wake_request")
	return true


func send_assistant_interaction_state(target_peer_id: int, data: Dictionary) -> void:
	if not multiplayer.is_server() or target_peer_id <= 0:
		return
	if target_peer_id == SERVER_PEER_ID:
		assistant_interaction_state_received.emit(data.duplicate(true))
		return
	assistant_interaction_packets_sent += 1
	rpc_id(target_peer_id, "_client_assistant_interaction_state", data)

func broadcast_transcription_enabled(enabled: bool) -> void:
	if not multiplayer.is_server():
		return

	transcription_enabled_received.emit(enabled)
	for peer_id in multiplayer.get_peers():
		send_transcription_enabled_to_peer(peer_id, enabled)

func send_transcription_enabled_to_peer(target_peer_id: int, enabled: bool) -> void:
	if not multiplayer.is_server() or target_peer_id <= 0:
		return

	transcription_state_packets_sent += 1
	rpc_id(target_peer_id, "_client_transcription_enabled", enabled)

@rpc("any_peer", "call_remote", "unreliable", 1)
func _server_voice_packet(packet: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return

	uplink_packets_received += 1
	server_voice_packet_received.emit(multiplayer.get_remote_sender_id(), packet)

@rpc("authority", "call_remote", "unreliable", 1)
func _client_downlink_voice_packet(packet: PackedByteArray) -> void:
	if multiplayer.is_server():
		return

	downlink_packets_received += 1
	downlink_voice_packet_received.emit(packet)

@rpc("any_peer", "call_remote", "reliable", 2)
func _server_speaking_state(is_speaking: bool) -> void:
	if not multiplayer.is_server():
		return

	speaking_states_received += 1
	speaking_state_received.emit(multiplayer.get_remote_sender_id(), is_speaking)

@rpc("any_peer", "call_remote", "unreliable", 2)
func _server_voice_level_state(peak: float, peak_db: float, mic_open: bool) -> void:
	if not multiplayer.is_server():
		return

	voice_level_states_received += 1
	voice_level_received.emit(multiplayer.get_remote_sender_id(), peak, peak_db, mic_open)

@rpc("any_peer", "call_remote", "unreliable", 3)
func _server_transcription_pcm(pcm: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return

	transcription_pcm_packets_received += 1
	transcription_pcm_received.emit(multiplayer.get_remote_sender_id(), pcm)


@rpc("any_peer", "call_remote", "reliable", 3)
func _server_assistant_wake_request() -> void:
	if not multiplayer.is_server():
		return
	var speaker_peer_id := multiplayer.get_remote_sender_id()
	if speaker_peer_id <= 0:
		return
	assistant_wake_requests_received += 1
	assistant_wake_requested.emit(speaker_peer_id)

@rpc("authority", "call_remote", "reliable", 2)
func _client_speaking_state(peer_id: int, is_speaking: bool) -> void:
	if multiplayer.is_server():
		return

	speaking_states_received += 1
	speaking_state_received.emit(peer_id, is_speaking)

@rpc("authority", "call_remote", "reliable", 3)
func _client_voice_transcript(data: Dictionary) -> void:
	if multiplayer.is_server():
		return

	transcript_packets_received += 1
	transcript_received.emit(data.duplicate(true))


@rpc("authority", "call_remote", "reliable", 3)
func _client_assistant_interaction_state(data: Dictionary) -> void:
	if Execution.is_local() or multiplayer.is_server():
		return
	assistant_interaction_packets_received += 1
	assistant_interaction_state_received.emit(data.duplicate(true))

@rpc("authority", "call_remote", "reliable", 3)
func _client_transcription_enabled(enabled: bool) -> void:
	if multiplayer.is_server():
		return

	transcription_state_packets_received += 1
	transcription_enabled_received.emit(enabled)

func _has_connected_client_peer() -> bool:
	return multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func get_debug_state() -> Dictionary:
	return {
		"uplink_packets_sent": uplink_packets_sent,
		"uplink_packets_received": uplink_packets_received,
		"downlink_packets_sent": downlink_packets_sent,
		"downlink_packets_received": downlink_packets_received,
		"speaking_states_sent": speaking_states_sent,
		"speaking_states_received": speaking_states_received,
		"voice_level_states_sent": voice_level_states_sent,
		"voice_level_states_received": voice_level_states_received,
		"transcription_pcm_packets_sent": transcription_pcm_packets_sent,
		"transcription_pcm_packets_received": transcription_pcm_packets_received,
		"transcript_packets_sent": transcript_packets_sent,
		"transcript_packets_received": transcript_packets_received,
		"assistant_wake_requests_sent": assistant_wake_requests_sent,
		"assistant_wake_requests_received": assistant_wake_requests_received,
		"assistant_interaction_packets_sent": assistant_interaction_packets_sent,
		"assistant_interaction_packets_received": assistant_interaction_packets_received,
		"transcription_state_packets_sent": transcription_state_packets_sent,
		"transcription_state_packets_received": transcription_state_packets_received,
		"has_peer": multiplayer.has_multiplayer_peer(),
		"is_server": multiplayer.has_multiplayer_peer() and multiplayer.is_server(),
	}
