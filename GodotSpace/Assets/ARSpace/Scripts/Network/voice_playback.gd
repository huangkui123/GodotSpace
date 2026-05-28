class_name VoicePlayback
extends Node

@export var playback_bus: String = "Master"

var players: Dictionary = {}
var packets_pushed: int = 0

func push_source_packet(source_peer_id: int, packet: PackedByteArray) -> void:
	if packet.size() == 0:
		return

	var player := get_or_create_player(source_peer_id)
	if player.stream is AudioStreamOpusChunked:
		player.stream.push_opus_packet(packet, 0, 0)
		packets_pushed += 1

func get_or_create_player(source_peer_id: int) -> AudioStreamPlayer:
	if players.has(source_peer_id) and is_instance_valid(players[source_peer_id]):
		return players[source_peer_id]

	var player := AudioStreamPlayer.new()
	player.name = "VoiceSource_%d" % source_peer_id
	player.stream = AudioStreamOpusChunked.new()
	player.bus = playback_bus
	player.autoplay = true
	player.mix_target = AudioStreamPlayer.MIX_TARGET_STEREO
	add_child(player)
	player.play()
	players[source_peer_id] = player
	return player

func set_source_muted(source_peer_id: int, muted: bool) -> void:
	if not players.has(source_peer_id):
		return

	var player: AudioStreamPlayer = players[source_peer_id]
	if is_instance_valid(player):
		player.volume_db = -80.0 if muted else 0.0

func remove_source(source_peer_id: int) -> void:
	if not players.has(source_peer_id):
		return

	var player: AudioStreamPlayer = players[source_peer_id]
	if is_instance_valid(player):
		player.queue_free()
	players.erase(source_peer_id)

func clear() -> void:
	for source_peer_id in players.keys().duplicate():
		remove_source(source_peer_id)

func get_debug_state() -> Dictionary:
	return {
		"playback_bus": playback_bus,
		"packets_pushed": packets_pushed,
		"player_count": players.size(),
		"player_ids": players.keys(),
	}
