class_name VoiceTransportENet
extends Node

signal server_voice_packet_received(sender_peer_id: int, packet: PackedByteArray)
signal downlink_voice_packet_received(packet: PackedByteArray)
signal speaking_state_received(peer_id: int, is_speaking: bool)
signal voice_level_received(peer_id: int, peak: float, peak_db: float, mic_open: bool)
signal transcription_pcm_received(sender_peer_id: int, pcm: PackedByteArray)
signal transcript_received(data: Dictionary)
signal assistant_interaction_state_received(data: Dictionary)
signal transcription_enabled_received(enabled: bool)

const SERVER_PEER_ID := 1

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
	if not multiplayer.has_multiplayer_peer():
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
	if multiplayer.is_server():
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
		"assistant_interaction_packets_sent": assistant_interaction_packets_sent,
		"assistant_interaction_packets_received": assistant_interaction_packets_received,
		"transcription_state_packets_sent": transcription_state_packets_sent,
		"transcription_state_packets_received": transcription_state_packets_received,
		"has_peer": multiplayer.has_multiplayer_peer(),
		"is_server": multiplayer.has_multiplayer_peer() and multiplayer.is_server(),
	}
