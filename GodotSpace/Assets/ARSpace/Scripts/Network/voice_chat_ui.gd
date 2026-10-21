extends Control

const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const SERVER_PEER_ID := 1
const VOICE_LEVEL_STALE_SECONDS := 1.5
const VOICE_LEVEL_MIN_DB := -60.0
const VOICE_LEVEL_MAX_DB := 0.0
const GROUND_COLOR := "#65D8FF"
const ASTRONAUT_COLOR := "#FFD166"
const PARTIAL_CURSOR_COLOR := "#D7DEE8"
const ASSISTANT_WAKE_WORD := "助手"

@export var is_3d_panel: bool = false

@onready var voice_button: Button = _get_voice_ui_node("Header/VoiceButton") as Button
@onready var status_label: Label = _get_voice_ui_node("Header/StatusLabel") as Label
@onready var transcribe_button: Button = _get_voice_ui_node("TranscribeSection/TranscribeHeader/TranscribeButton") as Button
@onready var transcript_label: RichTextLabel = _get_voice_ui_node("TranscribeSection/TranscriptBox/TranscriptLabel") as RichTextLabel
@onready var assistant_wake_button: Button = _get_voice_ui_node("TranscribeSection/AssistantWakeButton") as Button
@onready var assistant_interaction_panel: Control = _get_voice_ui_node("TranscribeSection/AssistantInteraction") as Control
@onready var assistant_interaction_label: Label = _get_voice_ui_node("TranscribeSection/AssistantInteraction/Content/StatusLabel") as Label
@onready var assistant_command_box: Control = _get_voice_ui_node("TranscribeSection/AssistantInteraction/Content/CommandBox") as Control
@onready var assistant_command_label: Label = _get_voice_ui_node("TranscribeSection/AssistantInteraction/Content/CommandBox/CommandText") as Label
@onready var assistant_countdown_bar: ProgressBar = _get_voice_ui_node("TranscribeSection/AssistantInteraction/Content/CountdownBar") as ProgressBar
@onready var server_voice_levels: VBoxContainer = _get_voice_ui_node("ServerVoiceLevels") as VBoxContainer
@onready var rows_container: VBoxContainer = _get_voice_ui_node("ServerVoiceLevels/Rows") as VBoxContainer

var voice_chat: Node
var llm_assistant: Node
var network_handler: Node
var volume_rows: Dictionary = {}
var transcript_entries: Dictionary = {}
var transcript_sequence := 0
var assistant_pending_key := ""
var assistant_interaction_state := "idle"
var assistant_interaction_text := ""
var assistant_command_text := ""
var assistant_countdown_seconds := 0.0
var assistant_countdown_started_msec := 0


func _ready() -> void:
	voice_chat = get_node_or_null("/root/VoiceChat")
	llm_assistant = get_node_or_null("/root/LLMAssistantService")
	network_handler = get_node_or_null("/root/NetworkHandler")
	PanelWindowZoom.bind_max_button(self)
	_bind_close_button()
	_register_voice_window()

	voice_button.pressed.connect(_on_voice_button_pressed)
	transcribe_button.toggled.connect(_on_transcribe_button_toggled)
	transcribe_button.toggle_mode = true
	assistant_wake_button.pressed.connect(_on_assistant_wake_button_pressed)

	if voice_chat != null and voice_chat.has_signal("voice_enabled_changed"):
		voice_chat.connect("voice_enabled_changed", _on_voice_enabled_changed)
	if voice_chat != null and voice_chat.has_signal("voice_level_changed"):
		voice_chat.connect("voice_level_changed", _on_voice_level_changed)
	if voice_chat != null and voice_chat.has_signal("voice_transcript_received"):
		voice_chat.connect("voice_transcript_received", _on_voice_transcript_received)
	if voice_chat != null and voice_chat.has_signal("assistant_interaction_state_changed"):
		voice_chat.connect("assistant_interaction_state_changed", _on_assistant_interaction_state_changed)
	if voice_chat != null and voice_chat.has_signal("transcription_enabled_changed"):
		voice_chat.connect("transcription_enabled_changed", _on_transcription_enabled_changed)
	if llm_assistant != null and llm_assistant.has_signal("answer_started"):
		llm_assistant.connect("answer_started", _on_assistant_answer_started)
	if llm_assistant != null and llm_assistant.has_signal("answer_completed"):
		llm_assistant.connect("answer_completed", _on_assistant_answer_completed)
	if llm_assistant != null and llm_assistant.has_signal("answer_failed"):
		llm_assistant.connect("answer_failed", _on_assistant_answer_failed)
	if network_handler != null and network_handler.has_signal("network_ready"):
		network_handler.connect("network_ready", _on_network_changed)
	if network_handler != null and network_handler.has_signal("network_role_selected"):
		network_handler.connect("network_role_selected", _on_network_role_selected)

	multiplayer.peer_connected.connect(_on_peer_changed)
	multiplayer.peer_disconnected.connect(_on_peer_changed)
	_load_transcript_history()
	_update_ui()
	_update_assistant_interaction()
	if is_3d_panel:
		PanelWindowZoom.set_window_visible(self, false)


func _get_voice_ui_node(relative_path: String) -> Node:
	var paths := [
		"Canvas/PanelContainer/MarginContainer/Layout/%s" % relative_path,
		"PanelContainer/MarginContainer/Layout/%s" % relative_path,
	]
	for path in paths:
		var node := get_node_or_null(path)
		if node != null:
			return node
	push_error("VoiceChatUI missing node: %s" % relative_path)
	return null


func _bind_close_button() -> void:
	var close_button := find_child("CloseButton", true, false) as Button
	if close_button == null:
		return
	close_button.disabled = false
	var callback := Callable(self, "_on_close_button_pressed")
	if not close_button.pressed.is_connected(callback):
		close_button.pressed.connect(callback)


func _register_voice_window() -> void:
	if not is_3d_panel:
		return
	var global_node := get_node_or_null("/root/Global")
	if global_node == null:
		return
	var target := _get_window_target()
	global_node.set("voice_call_window", target if target != null else self)


func _get_window_target() -> Node:
	var viewport := get_viewport()
	if viewport != null and viewport.get_parent() is Node3D:
		return viewport.get_parent()
	return self


func _process(_delta: float) -> void:
	if not visible:
		return
	_update_status()
	_update_server_volume_panel()
	_update_transcript_text()
	_update_assistant_interaction()


func _on_voice_button_pressed() -> void:
	if _is_server_remote_monitor_panel():
		return
	if voice_chat != null and voice_chat.has_method("toggle_voice"):
		voice_chat.call("toggle_voice")


func _on_close_button_pressed() -> void:
	PanelWindowZoom.set_window_visible(self, false)


func _on_transcribe_button_toggled(enabled: bool) -> void:
	if not _can_control_transcription():
		transcribe_button.set_pressed_no_signal(_get_voice_bool("transcription_enabled"))
		return
	if voice_chat != null and voice_chat.has_method("set_transcription_enabled"):
		voice_chat.call("set_transcription_enabled", enabled)


func _on_assistant_wake_button_pressed() -> void:
	if voice_chat == null or not voice_chat.has_method("request_assistant_wake"):
		return
	var requested: bool
	if voice_chat.has_method("request_assistant_wake_when_ready"):
		requested = bool(await voice_chat.call("request_assistant_wake_when_ready"))
	else:
		requested = bool(voice_chat.call("request_assistant_wake"))
	if not requested:
		assistant_wake_button.tooltip_text = "请先连接语音服务并开启转写。"


func _on_voice_enabled_changed(_enabled: bool) -> void:
	_update_ui()


func _on_voice_level_changed(_peer_id: int, _state: Dictionary) -> void:
	if is_3d_panel:
		_update_ui()
	_update_server_volume_panel()


func _on_transcription_enabled_changed(_enabled: bool) -> void:
	_update_ui()


func _on_network_changed() -> void:
	_update_ui()


func _on_network_role_selected(_is_server: bool, _context: String = "") -> void:
	_update_ui()


func _on_peer_changed(_peer_id: int) -> void:
	_update_ui()


func _on_voice_transcript_received(data: Dictionary) -> void:
	var peer_id := int(data.get("speaker_peer_id", 0))
	var utterance_id := int(data.get("utterance_id", 0))
	var transcript_key := _transcript_entry_key(data)
	var speaker := str(data.get("speaker_name", _get_voice_panel_peer_label(peer_id)))
	var text := str(data.get("text", "")).strip_edges()
	if text.is_empty():
		return
	if _is_assistant_command_transcript(data):
		transcript_entries.erase(transcript_key)
		_update_transcript_text()
		return

	_upsert_transcript_entry(
		transcript_key,
		speaker,
		text,
		not bool(data.get("is_final", false)),
		int(data.get("timestamp_msec", Time.get_ticks_msec())),
		peer_id,
		utterance_id
	)
	_update_transcript_text()


func _transcript_entry_key(data: Dictionary) -> String:
	var source := str(data.get("source", "voice"))
	var message_id := str(data.get("message_id", "")).strip_edges()
	if not message_id.is_empty():
		return "%s:%s" % [source, message_id]
	var peer_id := int(data.get("speaker_peer_id", 0))
	var utterance_id := int(data.get("utterance_id", 0))
	if utterance_id > 0:
		return "voice:%d:%d" % [peer_id, utterance_id]
	if not bool(data.get("is_final", false)):
		return "%s:partial:%d" % [source, peer_id]
	return "%s:event:%d:%d" % [
		source,
		int(data.get("timestamp_msec", Time.get_ticks_msec())),
		transcript_sequence + 1,
	]


func _upsert_transcript_entry(
	key: String,
	speaker: String,
	text: String,
	is_partial: bool,
	timestamp_msec: int,
	peer_id: int = 0,
	utterance_id: int = 0
) -> void:
	var entry := transcript_entries.get(key, {}) as Dictionary
	if entry.is_empty():
		transcript_sequence += 1
		entry = {
			"sequence": transcript_sequence,
			"timestamp_msec": timestamp_msec,
		}
	entry["speaker"] = speaker
	entry["text"] = text
	entry["is_partial"] = is_partial
	entry["peer_id"] = peer_id
	entry["utterance_id"] = utterance_id
	transcript_entries[key] = entry


func _on_assistant_answer_started(question: String) -> void:
	if not assistant_pending_key.is_empty():
		transcript_entries.erase(assistant_pending_key)
	assistant_pending_key = "assistant_pending:%d" % (transcript_sequence + 1)
	_upsert_transcript_entry(
		assistant_pending_key,
		"智能助手",
		"正在分析问题，等待回复：%s" % question,
		true,
		Time.get_ticks_msec()
	)
	_update_transcript_text()


func _on_assistant_answer_completed(_question: String, _answer: String, _sources: Array) -> void:
	transcript_entries.erase(assistant_pending_key)
	assistant_pending_key = ""
	_update_transcript_text()


func _on_assistant_answer_failed(_question: String, _message: String) -> void:
	transcript_entries.erase(assistant_pending_key)
	assistant_pending_key = ""
	_update_transcript_text()


func _on_assistant_interaction_state_changed(data: Dictionary) -> void:
	var target_peer_id := int(data.get("target_peer_id", 0))
	if target_peer_id > 0 and target_peer_id != _get_local_peer_id():
		return
	assistant_interaction_state = str(data.get("state", "idle"))
	assistant_interaction_text = str(data.get("text", "")).strip_edges()
	assistant_command_text = str(data.get("command_text", "")).strip_edges()
	assistant_countdown_seconds = maxf(float(data.get("countdown_seconds", 0.0)), 0.0)
	assistant_countdown_started_msec = Time.get_ticks_msec()
	_update_assistant_interaction()


func _load_transcript_history() -> void:
	transcript_entries.clear()
	transcript_sequence = 0
	assistant_pending_key = ""
	assistant_interaction_state = "idle"
	assistant_interaction_text = ""
	assistant_command_text = ""
	assistant_countdown_seconds = 0.0
	assistant_countdown_started_msec = 0
	if voice_chat == null or not voice_chat.has_method("get_transcript_history"):
		return

	for item in voice_chat.call("get_transcript_history"):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var data: Dictionary = item
		var speaker := str(data.get("speaker_name", _get_voice_panel_peer_label(int(data.get("speaker_peer_id", 0)))))
		var text := str(data.get("text", "")).strip_edges()
		if text.is_empty():
			continue
		_upsert_transcript_entry(
			_transcript_entry_key(data),
			speaker,
			text,
			false,
			int(data.get("timestamp_msec", Time.get_ticks_msec())),
			int(data.get("speaker_peer_id", 0)),
			int(data.get("utterance_id", 0))
		)


func _update_transcript_text() -> void:
	var ordered_entries: Array = transcript_entries.values()
	ordered_entries.sort_custom(_sort_transcript_entries)
	var lines: Array[String] = []
	for state in ordered_entries:
		if typeof(state) != TYPE_DICTIONARY:
			continue
		var entry := state as Dictionary
		lines.append(_format_transcript_line(
			str(entry.get("speaker", "")),
			str(entry.get("text", "")),
			bool(entry.get("is_partial", false))
		))
	var body := "\n".join(lines)
	if body == "":
		body = "等待开麦语音..."
	transcript_label.text = body


func _sort_transcript_entries(left: Dictionary, right: Dictionary) -> bool:
	var left_sequence := int(left.get("sequence", 0))
	var right_sequence := int(right.get("sequence", 0))
	if left_sequence != right_sequence:
		return left_sequence < right_sequence
	return int(left.get("timestamp_msec", 0)) < int(right.get("timestamp_msec", 0))


func _update_assistant_interaction() -> void:
	_update_assistant_wake_button()
	if (
		assistant_interaction_panel == null
		or assistant_interaction_label == null
		or assistant_command_box == null
		or assistant_command_label == null
		or assistant_countdown_bar == null
	):
		return
	var visible_state := assistant_interaction_state not in ["", "idle"]
	assistant_interaction_panel.visible = visible_state
	if not visible_state:
		return
	var fallback: String = str({
		"listening": "我在，请说。",
		"processing": "正在理解你的请求…",
		"executing": "正在执行操作…",
		"speaking": "正在播报，点击按钮可停止并开始听写。",
		"timeout": "等待命令超时。",
		"failed": "请求未完成。",
	}.get(assistant_interaction_state, "助手正在处理。"))
	assistant_interaction_label.text = assistant_interaction_text if not assistant_interaction_text.is_empty() else fallback
	var is_listening := assistant_interaction_state == "listening"
	assistant_command_box.visible = is_listening
	assistant_countdown_bar.visible = is_listening
	if not is_listening:
		return
	assistant_command_label.text = assistant_command_text if not assistant_command_text.is_empty() else "等待指令…"
	var elapsed_seconds := float(Time.get_ticks_msec() - assistant_countdown_started_msec) / 1000.0
	var remaining_ratio := 0.0
	if assistant_countdown_seconds > 0.0:
		remaining_ratio = clampf(1.0 - elapsed_seconds / assistant_countdown_seconds, 0.0, 1.0)
	assistant_countdown_bar.value = remaining_ratio * assistant_countdown_bar.max_value


func _update_assistant_wake_button() -> void:
	if assistant_wake_button == null:
		return
	var has_wake_service := voice_chat != null and voice_chat.has_method("request_assistant_wake")
	var transcription_available := _get_voice_bool("transcription_enabled")
	var assistant_busy := assistant_interaction_state in ["preparing", "processing", "executing"]
	assistant_wake_button.disabled = not has_wake_service or not transcription_available or assistant_busy
	assistant_wake_button.text = "重新听写" if assistant_interaction_state == "listening" else "唤醒智能助手"
	if assistant_interaction_state == "speaking":
		assistant_wake_button.text = "停止播报并听写"
	if not transcription_available:
		assistant_wake_button.tooltip_text = "请先开启语音转写。"
	elif assistant_busy:
		assistant_wake_button.tooltip_text = "智能助手正在处理当前请求。"
	else:
		assistant_wake_button.tooltip_text = "点击后，智能助手将在 10 秒内等待你的指令。"


func _is_assistant_command_transcript(data: Dictionary) -> bool:
	if bool(data.get("history_only", false)):
		return false
	var peer_id := int(data.get("speaker_peer_id", 0))
	if peer_id <= 0:
		return false
	if (
		voice_chat != null
		and voice_chat.has_method("is_assistant_command_capture_active")
		and bool(voice_chat.call("is_assistant_command_capture_active", peer_id))
	):
		return true
	if peer_id != _get_local_peer_id():
		return false
	if assistant_interaction_state == "listening":
		return true
	return str(data.get("text", "")).find(ASSISTANT_WAKE_WORD) >= 0


func _get_local_peer_id() -> int:
	if voice_chat != null and voice_chat.has_method("_get_local_voice_peer_id"):
		return int(voice_chat.call("_get_local_voice_peer_id"))
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else SERVER_PEER_ID


func _format_transcript_line(speaker: String, message: String, is_partial: bool) -> String:
	var cursor := "[color=%s]|[/color]" % PARTIAL_CURSOR_COLOR if is_partial else ""
	return "[color=%s]%s：%s%s[/color]" % [_get_transcript_speaker_color(speaker), speaker, message, cursor]


func _get_transcript_speaker_color(speaker: String) -> String:
	if speaker == "智能助手":
		return GROUND_COLOR
	if speaker.begins_with("客户端"):
		return ASTRONAUT_COLOR
	return GROUND_COLOR


func _update_ui() -> void:
	_update_panel_visibility()
	if not visible:
		return

	if _get_displayed_voice_enabled():
		voice_button.text = "关闭语音"
		voice_button.modulate = Color(0.3, 1.0, 0.45)
	else:
		voice_button.text = "开启语音"
		voice_button.modulate = Color(1.0, 0.35, 0.35)

	_update_transcription_control()
	_update_status()
	_update_server_volume_panel()


func _update_panel_visibility() -> void:
	var profile = RuntimeProfile.current()
	visible = profile.uses_xr() if is_3d_panel else profile.uses_desktop_ui() and profile.is_server()


func _update_transcription_control() -> void:
	var enabled := _get_voice_bool("transcription_enabled")
	transcribe_button.set_pressed_no_signal(enabled)
	transcribe_button.disabled = not _can_control_transcription()
	if enabled:
		transcribe_button.text = "关闭转写" if _can_control_transcription() else "转写已开启"
		transcribe_button.modulate = Color(0.3, 1.0, 0.45)
	else:
		transcribe_button.text = "开启转写" if _can_control_transcription() else "转写已关闭"
		transcribe_button.modulate = Color(1.0, 0.35, 0.35)


func _can_control_transcription() -> bool:
	if not multiplayer.is_server():
		return false
	var profile = RuntimeProfile.current()
	return profile.uses_xr() if is_3d_panel else profile.uses_desktop_ui()


func _update_status() -> void:
	if _is_server_remote_monitor_panel():
		var client_peer_id := _get_first_client_peer_id()
		if client_peer_id > 0:
			status_label.text = "%s：%s" % [
				_get_voice_panel_peer_label(client_peer_id),
				"语音开启" if _get_displayed_voice_enabled() else "语音关闭",
			]
		else:
			status_label.text = "等待客户端"
		return

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
	var profile = RuntimeProfile.current()
	return _get_voice_bool("voice_endpoint_selected") \
			and profile.uses_desktop_ui() \
			and multiplayer.has_multiplayer_peer() \
			and multiplayer.is_server()


func _get_server_volume_peer_ids() -> Array:
	var ids: Array = [SERVER_PEER_ID]
	if multiplayer.has_multiplayer_peer():
		for peer_id in multiplayer.get_peers():
			if not ids.has(peer_id):
				ids.append(peer_id)

	for peer_id in _get_voice_level_states().keys():
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
	var state: Dictionary = _get_voice_level_states().get(peer_id, {})
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
	return "服务端" if peer_id == SERVER_PEER_ID else "客户端%d" % peer_id


func _get_displayed_voice_enabled() -> bool:
	if _is_server_remote_monitor_panel():
		var client_peer_id := _get_first_client_peer_id()
		if client_peer_id <= 0:
			return false
		var state: Dictionary = _get_voice_level_states().get(client_peer_id, {})
		return bool(state.get("mic_open", false))
	return _get_voice_bool("voice_enabled")


func _is_server_remote_monitor_panel() -> bool:
	return is_3d_panel \
		and multiplayer.is_server() \
		and RuntimeProfile.current().uses_desktop_ui()


func _get_first_client_peer_id() -> int:
	var ids: Array = []
	if multiplayer.has_multiplayer_peer():
		for peer_id in multiplayer.get_peers():
			var id := int(peer_id)
			if id != SERVER_PEER_ID:
				ids.append(id)
	for peer_id in _get_voice_level_states().keys():
		var id := int(peer_id)
		if id != SERVER_PEER_ID and not ids.has(id):
			ids.append(id)
	ids.sort()
	return int(ids[0]) if not ids.is_empty() else 0


func _voice_db_to_meter_value(peak_db: float) -> float:
	if peak_db <= VOICE_LEVEL_MIN_DB:
		return 0.0
	return clampf((peak_db - VOICE_LEVEL_MIN_DB) / (VOICE_LEVEL_MAX_DB - VOICE_LEVEL_MIN_DB), 0.0, 1.0)


func _get_voice_level_states() -> Dictionary:
	if voice_chat == null:
		return {}
	var states = voice_chat.get("voice_level_states")
	return states if typeof(states) == TYPE_DICTIONARY else {}


func _get_voice_bool(property_name: String) -> bool:
	if voice_chat == null:
		return false
	return bool(voice_chat.get(property_name))
