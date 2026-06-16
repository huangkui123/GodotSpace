extends Control

const SERVER_PEER_ID := 1
const VOICE_LEVEL_STALE_SECONDS := 1.5
const VOICE_LEVEL_MIN_DB := -60.0
const VOICE_LEVEL_MAX_DB := 0.0
const GROUND_COLOR := "#65D8FF"
const ASTRONAUT_COLOR := "#FFD166"
const PARTIAL_CURSOR_COLOR := "#D7DEE8"
const DEMO_TRANSCRIPT_LINES := [
	{
		"speaker": "server",
		"final": "神舟飞船，这里是北京航天飞行控制中心，听到请回答",
		"partials": [
			"神舟飞船，这里是北京航天飞控中心",
			"神舟飞船，这里是北京航天飞行控制中心，听到请回",
			"神舟飞船，这里是北京航天飞行控制中心，听到请回答",
		],
	},
	{
		"speaker": "client",
		"final": "北京，神舟飞船收到，声音清晰，状态良好",
		"partials": [
			"北京，神舟飞船收到",
			"北京，神舟飞船收到，声音清西，状态良",
			"北京，神舟飞船收到，声音清晰，状态良好",
		],
	},
	{
		"speaker": "server",
		"final": "收到，当前飞船各系统工作正常，轨道参数符合预期",
		"partials": [
			"收到，当前飞船各系统工作正常",
			"收到，当前飞船各系统工作正常，轨道参数复合预期",
			"收到，当前飞船各系统工作正常，轨道参数符合预期",
		],
	},
	{
		"speaker": "client",
		"final": "明白，我们正在按计划进行在轨检查，舱内环境舒适",
		"partials": [
			"明白，我们正在按计划进行在轨检",
			"明白，我们正在按计划进行在轨检查，舱内环境舒",
			"明白，我们正在按计划进行在轨检查，舱内环境舒适",
		],
	},
]

@export var demo_transcript_enabled := true
@export var demo_transcript_start_delay := 4.0

@onready var voice_button: Button = $PanelContainer/MarginContainer/Layout/Header/VoiceButton
@onready var status_label: Label = $PanelContainer/MarginContainer/Layout/Header/StatusLabel
@onready var transcribe_button: Button = $PanelContainer/MarginContainer/Layout/TranscribeSection/TranscribeHeader/TranscribeButton
@onready var transcript_label: RichTextLabel = $PanelContainer/MarginContainer/Layout/TranscribeSection/TranscriptBox/TranscriptLabel
@onready var server_voice_levels: VBoxContainer = $PanelContainer/MarginContainer/Layout/ServerVoiceLevels
@onready var rows_container: VBoxContainer = $PanelContainer/MarginContainer/Layout/ServerVoiceLevels/Rows
@onready var mic_player: AudioStreamPlayer = $Runtime/MicPlayer
@onready var speech_to_text: Node = $Runtime/CaptureStreamToText

var volume_rows: Dictionary = {}
var completed_transcript := ""
var partial_transcript := ""
var partial_speaker := ""
var _demo_run_id := 0
var _demo_transcript_active := false


func _ready() -> void:
	voice_button.pressed.connect(_on_voice_button_pressed)
	transcribe_button.toggled.connect(_on_transcribe_toggled)
	mic_player.bus = "Mic"
	_set_transcription_enabled(false)
	_configure_transcription_audio_source()

	if speech_to_text.has_signal("transcribed_msg"):
		speech_to_text.transcribed_msg.connect(_on_transcribed_msg)

	if VoiceChat.has_signal("voice_enabled_changed"):
		VoiceChat.voice_enabled_changed.connect(_on_voice_enabled_changed)
	if VoiceChat.has_signal("voice_level_changed"):
		VoiceChat.voice_level_changed.connect(_on_voice_level_changed)
	if NetworkHandler.has_signal("network_ready"):
		NetworkHandler.network_ready.connect(_on_network_changed)
	if NetworkHandler.has_signal("network_role_selected"):
		NetworkHandler.network_role_selected.connect(_on_network_role_selected)

	multiplayer.peer_connected.connect(_on_peer_changed)
	multiplayer.peer_disconnected.connect(_on_peer_changed)
	_update_ui()


func _process(_delta: float) -> void:
	_update_status()
	_update_server_volume_panel()
	_update_transcript_text()


func _on_voice_button_pressed() -> void:
	VoiceChat.toggle_voice()


func _on_voice_enabled_changed(_enabled: bool) -> void:
	_update_ui()


func _on_voice_level_changed(_peer_id: int, _state: Dictionary) -> void:
	_update_server_volume_panel()


func _on_network_changed() -> void:
	_update_ui()


func _on_network_role_selected(_is_server: bool, _context: String = "") -> void:
	_configure_transcription_audio_source()
	_update_ui()


func _on_peer_changed(_peer_id: int) -> void:
	_update_ui()


func _on_transcribe_toggled(enabled: bool) -> void:
	_set_transcription_enabled(enabled)


func _on_transcribed_msg(is_partial: Variant, new_text: Variant) -> void:
	if demo_transcript_enabled:
		return

	var text := str(new_text).strip_edges()
	if text == "":
		return

	if bool(is_partial):
		completed_transcript += text
		partial_transcript = ""
	else:
		partial_transcript = text
	_update_transcript_text()


func _set_transcription_enabled(enabled: bool) -> void:
	_configure_transcription_audio_source()
	transcribe_button.button_pressed = enabled
	transcribe_button.text = "转写开启" if enabled else "转写关闭"
	transcribe_button.modulate = Color(0.3, 1.0, 0.45) if enabled else Color(1.0, 0.35, 0.35)
	var real_transcription_enabled := enabled and not demo_transcript_enabled
	speech_to_text.set("use_external_audio_frames", true)
	speech_to_text.set("input_active", real_transcription_enabled)
	speech_to_text.set("recording", real_transcription_enabled)
	if speech_to_text.has_method("set_input_active"):
		speech_to_text.set_input_active(real_transcription_enabled)
	if mic_player.playing:
		mic_player.stop()
	if demo_transcript_enabled:
		if enabled:
			_start_demo_transcript()
		else:
			_stop_demo_transcript()
	if not enabled:
		partial_transcript = ""
		partial_speaker = ""
	_update_transcript_text()


func _configure_transcription_audio_source() -> void:
	if speech_to_text != null:
		speech_to_text.set("use_external_audio_frames", true)

	if VoiceChat.capture == null:
		return
	if not VoiceChat.capture.has_signal("pcm_frames_captured"):
		return

	var callback := Callable(self, "_on_voice_pcm_frames_captured")
	if VoiceChat.capture.pcm_frames_captured.is_connected(callback):
		return

	VoiceChat.capture.pcm_frames_captured.connect(callback)


func _on_voice_pcm_frames_captured(frames: PackedVector2Array) -> void:
	if not transcribe_button.button_pressed:
		return
	if demo_transcript_enabled:
		return
	if speech_to_text == null or not speech_to_text.has_method("push_audio_frames"):
		return
	speech_to_text.push_audio_frames(frames)


func _update_transcript_text() -> void:
	var body := completed_transcript
	if partial_transcript != "":
		if body != "":
			body += "\n"
		body += _format_transcript_line(partial_speaker, partial_transcript, true)
	if body == "":
		body = "等待语音输入..."
	transcript_label.text = body


func _start_demo_transcript() -> void:
	_demo_run_id += 1
	_demo_transcript_active = true
	completed_transcript = ""
	partial_transcript = ""
	partial_speaker = ""
	_update_transcript_text()
	_run_demo_transcript(_demo_run_id)


func _stop_demo_transcript() -> void:
	_demo_run_id += 1
	_demo_transcript_active = false
	partial_transcript = ""
	partial_speaker = ""


func _run_demo_transcript(run_id: int) -> void:
	await get_tree().create_timer(demo_transcript_start_delay).timeout
	if not _is_demo_run_current(run_id):
		return

	for line in DEMO_TRANSCRIPT_LINES:
		var speaker := _get_demo_speaker_label(str(line.get("speaker", "server")))
		var final_text := str(line.get("final", ""))
		var partials: Array = line.get("partials", [])
		for partial in partials:
			if not _is_demo_run_current(run_id):
				return
			partial_speaker = speaker
			partial_transcript = str(partial)
			_update_transcript_text()
			await get_tree().create_timer(_get_demo_partial_delay(str(partial))).timeout

		if not _is_demo_run_current(run_id):
			return
		partial_transcript = ""
		partial_speaker = ""
		if completed_transcript != "":
			completed_transcript += "\n"
		completed_transcript += _format_transcript_line(speaker, final_text, false)
		_update_transcript_text()
		await get_tree().create_timer(1.7).timeout

	_demo_transcript_active = false


func _is_demo_run_current(run_id: int) -> bool:
	return _demo_transcript_active and run_id == _demo_run_id and transcribe_button.button_pressed


func _get_demo_partial_delay(text: String) -> float:
	return clampf(1.2 + float(text.length()) * 0.045, 1.7, 3.2)


func _format_transcript_line(speaker: String, message: String, is_partial: bool) -> String:
	var cursor := "[color=%s]|[/color]" % PARTIAL_CURSOR_COLOR if is_partial else ""
	return "[color=%s]%s：%s%s[/color]" % [_get_transcript_speaker_color(speaker), speaker, message, cursor]


func _get_transcript_speaker_color(speaker: String) -> String:
	if speaker.begins_with("客户端"):
		return ASTRONAUT_COLOR
	return GROUND_COLOR


func _get_demo_speaker_label(speaker_key: String) -> String:
	if speaker_key == "client":
		return _get_voice_panel_peer_label(_get_demo_client_peer_id())
	return _get_voice_panel_peer_label(SERVER_PEER_ID)


func _get_demo_client_peer_id() -> int:
	var ids := []
	if multiplayer.has_multiplayer_peer():
		for peer_id in multiplayer.get_peers():
			var id := int(peer_id)
			if id != SERVER_PEER_ID:
				ids.append(id)
		if not multiplayer.is_server():
			var local_id := multiplayer.get_unique_id()
			if local_id != SERVER_PEER_ID and not ids.has(local_id):
				ids.append(local_id)

	for peer_id in VoiceChat.voice_level_states.keys():
		var id := int(peer_id)
		if id != SERVER_PEER_ID and not ids.has(id):
			ids.append(id)

	ids.sort()
	return int(ids[0]) if not ids.is_empty() else 2


func _update_ui() -> void:
	if VoiceChat.voice_enabled:
		voice_button.text = "语音开启"
		voice_button.modulate = Color(0.3, 1.0, 0.45)
	else:
		voice_button.text = "语音关闭"
		voice_button.modulate = Color(1.0, 0.35, 0.35)

	_update_status()
	_update_server_volume_panel()


func _update_status() -> void:
	var peer_count := multiplayer.get_peers().size() if multiplayer.has_multiplayer_peer() else 0
	var role := "服务端" if multiplayer.is_server() else "客户端"
	if peer_count > 0:
		status_label.text = "%s已连接：%d" % [role, peer_count]
	elif multiplayer.has_multiplayer_peer():
		status_label.text = "%s等待连接" % role
	else:
		status_label.text = "网络离线"


func _update_server_volume_panel() -> void:
	if not _should_show_server_volume_panel():
		server_voice_levels.visible = false
		_clear_volume_rows()
		return

	server_voice_levels.visible = true
	var peer_ids := _get_server_volume_peer_ids()
	_sync_volume_rows(peer_ids)
	var now := Time.get_ticks_msec()
	for peer_id in peer_ids:
		_update_volume_row(int(peer_id), now)


func _should_show_server_volume_panel() -> bool:
	return VoiceChat.voice_endpoint_selected \
		and not VoiceChat.is_vr_mode \
		and multiplayer.has_multiplayer_peer() \
		and multiplayer.is_server()


func _get_server_volume_peer_ids() -> Array:
	var ids: Array = [SERVER_PEER_ID]
	if multiplayer.has_multiplayer_peer():
		for peer_id in multiplayer.get_peers():
			if not ids.has(peer_id):
				ids.append(peer_id)

	for peer_id in VoiceChat.voice_level_states.keys():
		var id := int(peer_id)
		if id == SERVER_PEER_ID or (multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(id)):
			if not ids.has(id):
				ids.append(id)

	ids.sort()
	return ids


func _sync_volume_rows(peer_ids: Array) -> void:
	for peer_id in volume_rows.keys().duplicate():
		if not peer_ids.has(int(peer_id)):
			_remove_volume_row(int(peer_id))

	for peer_id in peer_ids:
		var id := int(peer_id)
		if not volume_rows.has(id):
			_create_volume_row(id)


func _create_volume_row(peer_id: int) -> void:
	var row := HBoxContainer.new()
	row.name = "Peer_%d" % peer_id
	row.custom_minimum_size = Vector2(390.0, 28.0)
	row.add_theme_constant_override("separation", 8)
	rows_container.add_child(row)

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

	volume_rows[peer_id] = {
		"root": row,
		"name": name_label,
		"mic": mic_label,
		"meter": meter,
		"db": db_label,
	}


func _remove_volume_row(peer_id: int) -> void:
	if not volume_rows.has(peer_id):
		return

	var row_state: Dictionary = volume_rows[peer_id]
	var row := row_state.get("root") as Node
	if row != null and is_instance_valid(row):
		row.queue_free()
	volume_rows.erase(peer_id)


func _clear_volume_rows() -> void:
	for peer_id in volume_rows.keys().duplicate():
		_remove_volume_row(int(peer_id))


func _update_volume_row(peer_id: int, now_msec: int) -> void:
	if not volume_rows.has(peer_id):
		return

	var row_state: Dictionary = volume_rows[peer_id]
	var name_label := row_state.get("name") as Label
	var mic_label := row_state.get("mic") as Label
	var meter := row_state.get("meter") as ProgressBar
	var db_label := row_state.get("db") as Label
	var state: Dictionary = VoiceChat.voice_level_states.get(peer_id, {})
	var has_state := not state.is_empty()
	var has_level := bool(state.get("has_level", false))
	var level_updated_msec := int(state.get("level_updated_msec", 0))
	var level_is_fresh := has_level and level_updated_msec > 0 and float(now_msec - level_updated_msec) / 1000.0 <= VOICE_LEVEL_STALE_SECONDS
	var mic_open := bool(state.get("mic_open", false))

	if name_label != null:
		name_label.text = _get_voice_panel_peer_label(peer_id)

	if mic_label != null:
		if has_state:
			mic_label.text = "开" if mic_open else "关"
			mic_label.modulate = Color(0.3, 1.0, 0.45) if mic_open else Color(0.9, 0.9, 0.9)
		else:
			mic_label.text = "无数据"
			mic_label.modulate = Color(1.0, 0.85, 0.35)

	if meter != null:
		meter.value = _voice_db_to_meter_value(float(state.get("peak_db", -80.0))) if level_is_fresh else 0.0

	if db_label != null:
		db_label.text = "%.1f dB" % float(state.get("peak_db", -80.0)) if level_is_fresh else "-- dB"


func _get_voice_panel_peer_label(peer_id: int) -> String:
	return "服务端" if peer_id == SERVER_PEER_ID else "客户端 %d" % peer_id


func _voice_db_to_meter_value(peak_db: float) -> float:
	if peak_db <= VOICE_LEVEL_MIN_DB:
		return 0.0
	return clampf((peak_db - VOICE_LEVEL_MIN_DB) / (VOICE_LEVEL_MAX_DB - VOICE_LEVEL_MIN_DB), 0.0, 1.0)
