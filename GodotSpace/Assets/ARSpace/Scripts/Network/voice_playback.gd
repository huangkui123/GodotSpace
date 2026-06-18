class_name VoicePlayback
extends Node

const OPUS_STREAM_CLASS := "AudioStreamOpusChunked"

@export var playback_bus: String = "Master"
@export var max_queued_packets_per_source: int = 120
@export var opus_sample_rate: int = 48000
@export var opus_frame_size: int = 960
@export var audio_sample_chunks: int = 50

var players: Dictionary = {}
var packet_queues: Dictionary = {}
var packets_enqueued: int = 0
var packets_pushed: int = 0
var packets_dropped: int = 0
var configured_stream_properties: Dictionary = {}

func _ready() -> void:
	set_process(true)

func push_source_packet(source_peer_id: int, packet: PackedByteArray) -> void:
	if packet.size() == 0:
		return

	var player := get_or_create_player(source_peer_id)
	if not player.playing:
		player.play()

	if not packet_queues.has(source_peer_id):
		packet_queues[source_peer_id] = []

	var queue: Array = packet_queues[source_peer_id]
	queue.append(packet)
	packets_enqueued += 1

	while queue.size() > max_queued_packets_per_source:
		queue.pop_front()
		packets_dropped += 1

func _process(_delta: float) -> void:
	for source_peer_id in packet_queues.keys().duplicate():
		_flush_source_queue(int(source_peer_id))

func get_or_create_player(source_peer_id: int) -> AudioStreamPlayer:
	if players.has(source_peer_id) and is_instance_valid(players[source_peer_id]):
		return players[source_peer_id]

	var player := AudioStreamPlayer.new()
	player.name = "VoiceSource_%d" % source_peer_id
	player.stream = _new_opus_stream()
	if player.stream == null:
		push_error("%s is unavailable. Voice playback cannot decode Opus packets." % OPUS_STREAM_CLASS)
	_configure_opus_stream(player.stream)
	player.bus = playback_bus
	player.autoplay = true
	player.mix_target = AudioStreamPlayer.MIX_TARGET_STEREO
	add_child(player)
	player.play()
	players[source_peer_id] = player
	return player

func _new_opus_stream() -> AudioStream:
	if not ClassDB.class_exists(OPUS_STREAM_CLASS):
		return null
	return ClassDB.instantiate(OPUS_STREAM_CLASS) as AudioStream

func _configure_opus_stream(stream: Object) -> void:
	if stream == null:
		return

	var audio_sample_rate := int(AudioServer.get_mix_rate())
	if audio_sample_rate <= 0:
		audio_sample_rate = opus_sample_rate
	var audio_frame_size := int(round(float(audio_sample_rate) * float(opus_frame_size) / float(opus_sample_rate)))

	configured_stream_properties.clear()
	_set_property_if_present(stream, "opussamplerate", opus_sample_rate)
	_set_property_if_present(stream, "opusframesize", opus_frame_size)
	_set_property_if_present(stream, "audiosamplerate", audio_sample_rate)
	_set_property_if_present(stream, "audiosamplesize", audio_frame_size)
	_set_property_if_present(stream, "audiosamplechunks", audio_sample_chunks)
	_set_property_if_present(stream, "mix_rate", audio_sample_rate)
	if stream.has_method("resetdecoder"):
		stream.call("resetdecoder")

func _set_property_if_present(target: Object, property_name: String, value) -> bool:
	for property in target.get_property_list():
		if str(property.get("name", "")) == property_name:
			target.set(property_name, value)
			configured_stream_properties[property_name] = target.get(property_name)
			return true
	return false

func _flush_source_queue(source_peer_id: int) -> void:
	if not packet_queues.has(source_peer_id):
		return
	if not players.has(source_peer_id) or not is_instance_valid(players[source_peer_id]):
		packet_queues.erase(source_peer_id)
		return

	var player: AudioStreamPlayer = players[source_peer_id]
	if not player.playing:
		player.play()

	var opus_stream := player.stream
	if not _is_opus_stream(opus_stream):
		return

	var queue: Array = packet_queues[source_peer_id]
	while queue.size() > 0 and bool(opus_stream.call("chunk_space_available")):
		var packet: PackedByteArray = queue.pop_front()
		opus_stream.call("push_opus_packet", packet, 0, 0)
		packets_pushed += 1

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
	packet_queues.erase(source_peer_id)

func clear() -> void:
	for source_peer_id in players.keys().duplicate():
		remove_source(source_peer_id)
	packet_queues.clear()

func get_debug_state() -> Dictionary:
	var queued_total := 0
	for queue in packet_queues.values():
		queued_total += (queue as Array).size()

	return {
		"playback_bus": playback_bus,
		"packets_enqueued": packets_enqueued,
		"packets_pushed": packets_pushed,
		"packets_dropped": packets_dropped,
		"queued_packets": queued_total,
		"player_count": players.size(),
		"player_ids": players.keys(),
		"audio_mix_rate": AudioServer.get_mix_rate(),
		"configured_stream_properties": configured_stream_properties.duplicate(),
		"last_playback_peak_db": _get_last_playback_peak_db(),
	}

func _get_last_playback_peak_db() -> float:
	var peak := 0.0
	for player_value in players.values():
		var player := player_value as AudioStreamPlayer
		if player == null or not is_instance_valid(player):
			continue
		var opus_stream := player.stream
		if not _is_opus_stream(opus_stream) or not opus_stream.has_method("last_chunk_max"):
			continue
		peak = max(peak, float(opus_stream.call("last_chunk_max")))
	return linear_to_db(peak) if peak > 0.0 else -80.0

func _is_opus_stream(stream: Object) -> bool:
	return stream != null and stream.is_class(OPUS_STREAM_CLASS)
