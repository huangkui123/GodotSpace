class_name VoiceCapture
extends Node

signal opus_packet_captured(packet: PackedByteArray)
signal speaking_changed(is_speaking: bool)

@export var record_bus: String = "Mic"

var opus_effect: AudioEffectOpusChunked
var capture_effect: AudioEffectCapture
var microphone_player: AudioStreamPlayer
var ptt_active: bool = false
var packets_captured: int = 0
var chunks_dropped_while_inactive: int = 0

func _ready() -> void:
	set_process(false)

func setup() -> void:
	_ensure_record_bus()
	_ensure_microphone_player()
	_drain_opus_chunks()
	set_process(true)

func set_voice_active(active: bool) -> void:
	if ptt_active == active:
		if not active:
			_drain_opus_chunks()
		return

	ptt_active = active
	_drain_opus_chunks()
	speaking_changed.emit(ptt_active)

func set_ptt_active(active: bool) -> void:
	set_voice_active(active)

func _process(_delta: float) -> void:
	if opus_effect == null:
		return

	if not ptt_active:
		_drain_opus_chunks()
		return

	while opus_effect.chunk_available():
		var packet := opus_effect.read_opus_packet(PackedByteArray())
		opus_effect.drop_chunk()
		if packet.size() > 0:
			packets_captured += 1
			opus_packet_captured.emit(packet)

func _ensure_record_bus() -> void:
	var bus_index := AudioServer.get_bus_index(record_bus)
	if bus_index == -1:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, record_bus)

	opus_effect = _find_opus_effect(bus_index)
	if opus_effect == null:
		opus_effect = AudioEffectOpusChunked.new()
		AudioServer.add_bus_effect(bus_index, opus_effect)
		AudioServer.set_bus_effect_enabled(bus_index, AudioServer.get_bus_effect_count(bus_index) - 1, true)
	else:
		_enable_effect(bus_index, opus_effect)

	capture_effect = _find_capture_effect(bus_index)
	if capture_effect == null:
		capture_effect = AudioEffectCapture.new()
		AudioServer.add_bus_effect(bus_index, capture_effect)
		AudioServer.set_bus_effect_enabled(bus_index, AudioServer.get_bus_effect_count(bus_index) - 1, true)
	else:
		_enable_effect(bus_index, capture_effect)

	AudioServer.set_bus_mute(bus_index, false)
	AudioServer.set_bus_volume_db(bus_index, -80.0)

func _ensure_microphone_player() -> void:
	if microphone_player != null and is_instance_valid(microphone_player):
		if not microphone_player.playing:
			microphone_player.play()
		return

	microphone_player = AudioStreamPlayer.new()
	microphone_player.name = "VoiceMicrophonePlayer"
	microphone_player.stream = AudioStreamMicrophone.new()
	microphone_player.bus = record_bus
	microphone_player.autoplay = true
	microphone_player.mix_target = AudioStreamPlayer.MIX_TARGET_STEREO
	add_child(microphone_player)
	microphone_player.play()

func _find_opus_effect(bus_index: int) -> AudioEffectOpusChunked:
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		var effect := AudioServer.get_bus_effect(bus_index, i)
		if effect is AudioEffectOpusChunked:
			return effect as AudioEffectOpusChunked
	return null

func _find_capture_effect(bus_index: int) -> AudioEffectCapture:
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		var effect := AudioServer.get_bus_effect(bus_index, i)
		if effect is AudioEffectCapture:
			return effect as AudioEffectCapture
	return null

func _enable_effect(bus_index: int, target_effect: AudioEffect) -> void:
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		if AudioServer.get_bus_effect(bus_index, i) == target_effect:
			AudioServer.set_bus_effect_enabled(bus_index, i, true)
			return

func _drain_opus_chunks() -> void:
	if opus_effect == null:
		return

	while opus_effect.chunk_available():
		opus_effect.drop_chunk()
		chunks_dropped_while_inactive += 1

func get_debug_state() -> Dictionary:
	var bus_index := AudioServer.get_bus_index(record_bus)
	return {
		"voice_active": ptt_active,
		"packets_captured": packets_captured,
		"chunks_dropped_while_inactive": chunks_dropped_while_inactive,
		"record_bus": record_bus,
		"record_bus_found": bus_index != -1,
		"record_bus_muted": AudioServer.is_bus_mute(bus_index) if bus_index != -1 else false,
		"record_bus_volume_db": AudioServer.get_bus_volume_db(bus_index) if bus_index != -1 else 0.0,
		"has_opus_effect": opus_effect != null,
		"has_capture_effect": capture_effect != null,
		"microphone_playing": microphone_player != null and is_instance_valid(microphone_player) and microphone_player.playing,
	}
