class_name LocalSpeechTranscriber
extends Node

signal transcript_ready(data: Dictionary)

const DEFAULT_MODEL_PATH := "res://addons/godot_whisper/models/ggml-base.bin"
const CAPTURE_STREAM_TO_TEXT_SCRIPT_PATH := "res://addons/godot_whisper/capture_stream_to_text.gd"

@export var enabled: bool = false
@export var model_path: String = DEFAULT_MODEL_PATH
@export var record_bus: String = "Mic"

var local_peer_id: int = 0
var display_name: String = "Local"
var _transcriber: Node

func setup(peer_id: int, p_display_name: String = "Local") -> void:
	local_peer_id = peer_id
	display_name = p_display_name
	if not enabled:
		return
	if _transcriber != null:
		return
	if not ResourceLoader.exists(model_path):
		push_warning("Whisper model not found: " + model_path)
		return

	var capture_stream_to_text_script: Script = load(CAPTURE_STREAM_TO_TEXT_SCRIPT_PATH) as Script
	if capture_stream_to_text_script == null:
		push_warning("Unable to load speech-to-text script: " + CAPTURE_STREAM_TO_TEXT_SCRIPT_PATH)
		return

	var model := ResourceLoader.load(model_path)
	if model == null:
		push_warning("Unable to load Whisper model: " + model_path)
		return

	_transcriber = capture_stream_to_text_script.new()
	_transcriber.name = "CaptureStreamToText"
	_transcriber.record_bus = record_bus
	_transcriber.language_model = model
	_transcriber.recording = true
	_transcriber.input_active = false
	add_child(_transcriber)
	_transcriber.transcribed_msg.connect(_on_transcribed_msg)

func update_local_peer(peer_id: int) -> void:
	local_peer_id = peer_id

func update_display_name(p_display_name: String) -> void:
	display_name = p_display_name

func set_input_active(active: bool) -> void:
	if _transcriber == null:
		return
	_transcriber.set_input_active(active)

func _on_transcribed_msg(is_final: bool, new_text: String) -> void:
	var clean_text := new_text.strip_edges()
	if clean_text == "":
		return
	transcript_ready.emit({
		"speaker_peer_id": local_peer_id,
		"speaker_name": display_name,
		"text": clean_text,
		"is_final": is_final,
		"timestamp_msec": Time.get_ticks_msec(),
	})
