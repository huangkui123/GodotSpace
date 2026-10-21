extends SceneTree


class Capture extends Node:
	var setup_count := 0
	func setup() -> void:
		setup_count += 1
	func set_voice_active(_active: bool) -> void:
		pass


class Voice extends "res://Assets/ARSpace/Scripts/Network/voice_chat.gd":
	signal prepared
	var succeeds := true
	var wake_count := 0
	var states: Array[String] = []
	func _ready() -> void:
		set_process(false)
		voice_endpoint_selected = true
	func _prepare_local_asr() -> bool:
		await prepared
		return succeeds
	func request_assistant_wake() -> bool:
		wake_count += 1
		return true
	func publish_assistant_interaction_state(_peer: int, state: String, _text: String = "", _details: Dictionary = {}) -> void:
		states.append(state)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var old_mode = ProjectSettings.get_setting("arspace/local_agent/execution_mode")
	ProjectSettings.set_setting("arspace/local_agent/execution_mode", "local")
	var voice := Voice.new()
	root.add_child(voice)
	var capture := Capture.new()
	voice.add_child(capture)
	voice.capture = capture
	var results: Array[bool] = []
	var start := func() -> void:
		results.append(await voice.request_assistant_wake_when_ready())
	start.call()
	assert(voice.states.back() == "preparing")
	assert(voice.wake_count == 0 and capture.setup_count == 0)
	assert(not await voice.request_assistant_wake_when_ready())
	voice.prepared.emit()
	assert(results == [true])
	assert(voice.wake_count == 1 and capture.setup_count == 1)

	voice.succeeds = false
	start.call()
	voice.prepared.emit()
	assert(results == [true, false])
	assert(voice.states.back() == "failed" and voice.wake_count == 1)

	voice.succeeds = true
	start.call()
	voice.set_voice_enabled(false)
	voice.prepared.emit()
	assert(results == [true, false, false])
	assert(voice.states.back() == "idle")
	assert(voice.wake_count == 1 and capture.setup_count == 1)

	# A cancelled cold start must leave a later explicit click usable.
	start.call()
	voice.prepared.emit()
	assert(results == [true, false, false, true] and voice.wake_count == 2)
	start.call()
	voice.set_transcription_enabled(false)
	voice.prepared.emit()
	assert(results.back() == false and voice.wake_count == 2)
	ProjectSettings.set_setting("arspace/local_agent/execution_mode", old_mode)
	voice.queue_free()
	print("Voice ASR startup self-test passed (wait, duplicate click, failure, cancel, retry).")
	quit(0)
