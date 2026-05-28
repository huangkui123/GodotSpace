class_name VoiceRouterServer
extends Node

signal session_state_changed(state: Dictionary)

const MODE_CREW_ROOM := "crew_room"
const MODE_EXPERT_ONLY := "expert_only"
const MODE_PRIVATE_TO_PEER := "private_to_peer"
const ROLE_EXPERT := "expert"
const ROLE_ASTRONAUT := "astronaut"

const VoicePlaybackScript := preload("res://Assets/ARSpace/Scripts/Network/voice_playback.gd")

var transport: Node
var monitor_playback: Node
var participants: Dictionary = {}
var channel_mode: String = MODE_CREW_ROOM
var private_target_peer_id: int = 0
var server_peer_id: int = 1
var active: bool = false
var monitor_solo_peer_id: int = 0

var _target_mixers: Dictionary = {}
var voice_packets_handled: int = 0
var mix_packets_pushed: int = 0
var downlink_packets_generated: int = 0

func setup(p_transport: Node) -> void:
	transport = p_transport
	monitor_playback = VoicePlaybackScript.new()
	monitor_playback.name = "ExpertMonitorPlayback"
	monitor_playback.playback_bus = "Master"
	add_child(monitor_playback)
	set_process(true)

func activate(p_server_peer_id: int) -> void:
	active = true
	server_peer_id = p_server_peer_id
	register_participant(server_peer_id, "Ground Expert", ROLE_EXPERT)

func deactivate() -> void:
	active = false
	_cleanup_all_mixers()
	participants.clear()
	if monitor_playback != null:
		monitor_playback.clear()

func register_participant(peer_id: int, display_name: String = "", role: String = ROLE_ASTRONAUT) -> void:
	if peer_id <= 0:
		return
	var state: Dictionary = participants.get(peer_id, {})
	state["peer_id"] = peer_id
	state["display_name"] = display_name if display_name != "" else "Peer %d" % peer_id
	state["role"] = role
	state["muted"] = state.get("muted", false)
	state["speaking"] = state.get("speaking", false)
	participants[peer_id] = state
	if role == ROLE_ASTRONAUT:
		_ensure_target_mixer(peer_id)
	_emit_state()

func unregister_participant(peer_id: int) -> void:
	participants.erase(peer_id)
	if monitor_playback != null:
		monitor_playback.remove_source(peer_id)
	_cleanup_target_mixer(peer_id)
	for target_id in _target_mixers.keys():
		var mixer: Dictionary = _target_mixers[target_id]
		var players: Dictionary = mixer.get("players", {})
		if players.has(peer_id):
			var player: AudioStreamPlayer = players[peer_id]
			if is_instance_valid(player):
				player.queue_free()
			players.erase(peer_id)
	_emit_state()

func set_channel_mode(mode: String, private_peer_id: int = 0) -> void:
	if not [MODE_CREW_ROOM, MODE_EXPERT_ONLY, MODE_PRIVATE_TO_PEER].has(mode):
		push_warning("Unknown voice channel mode: " + mode)
		return
	channel_mode = mode
	private_target_peer_id = private_peer_id
	_emit_state()

func set_participant_muted(peer_id: int, muted: bool) -> void:
	if not participants.has(peer_id):
		return
	participants[peer_id]["muted"] = muted
	if monitor_playback != null:
		monitor_playback.set_source_muted(peer_id, muted)
	_emit_state()

func set_monitor_solo(peer_id: int) -> void:
	monitor_solo_peer_id = peer_id
	_apply_monitor_solo()

func clear_monitor_solo() -> void:
	monitor_solo_peer_id = 0
	_apply_monitor_solo()

func set_participant_speaking(peer_id: int, is_speaking: bool) -> void:
	if not participants.has(peer_id):
		register_participant(peer_id)
	participants[peer_id]["speaking"] = is_speaking
	_emit_state()

func handle_voice_packet(source_peer_id: int, packet: PackedByteArray) -> void:
	if not active or packet.size() == 0:
		return
	voice_packets_handled += 1
	if not participants.has(source_peer_id):
		var role := ROLE_EXPERT if source_peer_id == server_peer_id else ROLE_ASTRONAUT
		register_participant(source_peer_id, "", role)
	if participants[source_peer_id].get("muted", false):
		return

	if source_peer_id != server_peer_id and monitor_playback != null:
		monitor_playback.push_source_packet(source_peer_id, packet)
		_apply_monitor_solo_to_source(source_peer_id)

	for target_peer_id in participants.keys():
		if participants[target_peer_id].get("role", ROLE_ASTRONAUT) != ROLE_ASTRONAUT:
			continue
		if _should_route_to_target(source_peer_id, target_peer_id):
			_push_packet_to_target_mix(target_peer_id, source_peer_id, packet)

func get_session_state() -> Dictionary:
	return {
		"channel_mode": channel_mode,
		"private_target_peer_id": private_target_peer_id,
		"monitor_solo_peer_id": monitor_solo_peer_id,
		"participants": participants.duplicate(true),
	}

func _process(_delta: float) -> void:
	if not active or transport == null:
		return
	for target_peer_id in _target_mixers.keys():
		var mixer: Dictionary = _target_mixers[target_peer_id]
		var opus: AudioEffectOpusChunked = mixer.get("opus")
		if opus == null:
			continue
		while opus.chunk_available():
			var packet := opus.read_opus_packet(PackedByteArray())
			opus.drop_chunk()
			if packet.size() > 0:
				downlink_packets_generated += 1
				transport.send_downlink_voice_packet(target_peer_id, packet)

func _should_route_to_target(source_peer_id: int, target_peer_id: int) -> bool:
	if source_peer_id == target_peer_id:
		return false
	match channel_mode:
		MODE_CREW_ROOM:
			return true
		MODE_EXPERT_ONLY:
			return source_peer_id == server_peer_id
		MODE_PRIVATE_TO_PEER:
			return source_peer_id == server_peer_id and target_peer_id == private_target_peer_id
		_:
			return false

func _push_packet_to_target_mix(target_peer_id: int, source_peer_id: int, packet: PackedByteArray) -> void:
	var player := _get_mix_source_player(target_peer_id, source_peer_id)
	if player.stream is AudioStreamOpusChunked:
		player.stream.push_opus_packet(packet, 0, 0)
		mix_packets_pushed += 1

func _ensure_target_mixer(target_peer_id: int) -> void:
	if _target_mixers.has(target_peer_id):
		return

	var bus_name := "VoiceMix_%d" % target_peer_id
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index == -1:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, bus_name)

	AudioServer.set_bus_mute(bus_index, false)
	AudioServer.set_bus_volume_db(bus_index, -80.0)

	var opus := _find_opus_effect(bus_index)
	if opus == null:
		opus = AudioEffectOpusChunked.new()
		AudioServer.add_bus_effect(bus_index, opus)
		AudioServer.set_bus_effect_enabled(bus_index, AudioServer.get_bus_effect_count(bus_index) - 1, true)

	_target_mixers[target_peer_id] = {
		"bus_name": bus_name,
		"opus": opus,
		"players": {},
	}

func _get_mix_source_player(target_peer_id: int, source_peer_id: int) -> AudioStreamPlayer:
	_ensure_target_mixer(target_peer_id)
	var mixer: Dictionary = _target_mixers[target_peer_id]
	var players: Dictionary = mixer["players"]
	if players.has(source_peer_id) and is_instance_valid(players[source_peer_id]):
		return players[source_peer_id]

	var player := AudioStreamPlayer.new()
	player.name = "Mix_%d_From_%d" % [target_peer_id, source_peer_id]
	player.stream = AudioStreamOpusChunked.new()
	player.bus = mixer["bus_name"]
	player.autoplay = true
	player.mix_target = AudioStreamPlayer.MIX_TARGET_STEREO
	add_child(player)
	player.play()
	players[source_peer_id] = player
	return player

func _cleanup_target_mixer(target_peer_id: int) -> void:
	if not _target_mixers.has(target_peer_id):
		return
	var mixer: Dictionary = _target_mixers[target_peer_id]
	var players: Dictionary = mixer.get("players", {})
	for source_peer_id in players.keys():
		var player: AudioStreamPlayer = players[source_peer_id]
		if is_instance_valid(player):
			player.queue_free()
	var bus_index := AudioServer.get_bus_index(mixer.get("bus_name", ""))
	if bus_index != -1:
		AudioServer.remove_bus(bus_index)
	_target_mixers.erase(target_peer_id)

func _cleanup_all_mixers() -> void:
	for target_peer_id in _target_mixers.keys().duplicate():
		_cleanup_target_mixer(target_peer_id)

func _find_opus_effect(bus_index: int) -> AudioEffectOpusChunked:
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		var effect := AudioServer.get_bus_effect(bus_index, i)
		if effect is AudioEffectOpusChunked:
			return effect as AudioEffectOpusChunked
	return null

func _emit_state() -> void:
	session_state_changed.emit(get_session_state())

func get_debug_state() -> Dictionary:
	return {
		"active": active,
		"participants": participants.duplicate(true),
		"target_mixers": _target_mixers.keys(),
		"voice_packets_handled": voice_packets_handled,
		"mix_packets_pushed": mix_packets_pushed,
		"downlink_packets_generated": downlink_packets_generated,
		"monitor": monitor_playback.get_debug_state() if monitor_playback != null else {},
	}

func _apply_monitor_solo() -> void:
	if monitor_playback == null:
		return
	for peer_id in monitor_playback.players.keys():
		_apply_monitor_solo_to_source(peer_id)

func _apply_monitor_solo_to_source(peer_id: int) -> void:
	if monitor_playback == null:
		return
	var muted: bool = bool(participants.get(peer_id, {}).get("muted", false))
	if monitor_solo_peer_id != 0 and peer_id != monitor_solo_peer_id:
		muted = true
	monitor_playback.set_source_muted(peer_id, muted)
