extends Control

class_name WorkListInfoUIView

const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
const DEBUG_LOGS := false

@export var to_sound: Button
@export var to_video: Button
@export var to_animation: Button

@onready var title_label: Label = $TopMenuBox/Title
@onready var llm_assistant_view: LLMAssistantUIView = $LLMAssistantView
@onready var animation_toggle_button: Button = $WorkListInfo/ListContent/WorkListInfoItem/AnimationToggle
@onready var audio_toggle_button: Button = $WorkListInfo/ListContent/WorkListInfoItem/AudioToggle

var _info_save_list: Array[WorkListInfoData] = []
@export var info_: Array[WorkListInfoItem] = []

var page_index: int = 1
var page_count: int = 0
var item_count: int = 0
var page_item_count: int = 1

func _ready():
	var global_node := _get_global_node()
	if global_node != null:
		global_node.set("work_list_info_canvas", self)
	PanelWindowZoom.bind_max_button(self)
	self.visible = false
	if llm_assistant_view:
		llm_assistant_view.visible = false
	if animation_toggle_button != null and not animation_toggle_button.pressed.is_connected(_on_animation_toggle_pressed):
		animation_toggle_button.pressed.connect(_on_animation_toggle_pressed)
	if audio_toggle_button != null and not audio_toggle_button.pressed.is_connected(_on_audio_toggle_pressed):
		audio_toggle_button.pressed.connect(_on_audio_toggle_pressed)

	if DEBUG_LOGS: print(self.name, ": _ready")
	init_view()

func _enter_tree():
	if DEBUG_LOGS: print(self.name, ": _enter_tree")

func init_view():
	if DEBUG_LOGS: print(self.name, ": init_view")

func on_refresh_data_change_view(result: WorkListInfoDataResult):
	if DEBUG_LOGS: print(self.name, ": on_refresh_data_change_view -> WorkListInfoDataResult")
	if title_label:
		title_label.text = result.title
	refresh_list(result)

func refresh_list(refresh_list_data: WorkListInfoDataResult):
	if DEBUG_LOGS: print("refresh_list refresh_list_data.list.size() = ", refresh_list_data.list.size())
	
	_info_save_list.clear()
	for i in range(refresh_list_data.list.size()):
		if DEBUG_LOGS: print(refresh_list_data.list[i].step, refresh_list_data.list[i].title)
		_info_save_list.append(refresh_list_data.list[i])
	
	page_index = 1
	page_count = 0
	item_count = 0
	refresh_info()
	_sync_assistant_context()

func refresh_info():
	item_count = _info_save_list.size()
	page_count = int(ceil(float(_info_save_list.size()) / page_item_count))
	bind_page(page_index)

func bind_page(index: int):
	if _info_save_list.size() <= 0:
		if DEBUG_LOGS: print("_info_save_list.size() = ", _info_save_list.size())
		return
	
	for item in info_:
		item.visible = false

	if page_count == 1:
		for i in range(item_count):
			if i < info_.size():
				bind_item(info_[i], _info_save_list[i])
				info_[i].visible = true
	elif page_count > 1:
		if index == page_count:
			var start_index = (index - 1) * page_item_count
			var current_page_items = item_count - start_index
			for i in range(current_page_items):
				if i < info_.size():
					bind_item(info_[i], _info_save_list[start_index + i])
					info_[i].visible = true
		else:
			var start_index = (index - 1) * page_item_count
			for i in range(page_item_count):
				if i < info_.size():
					bind_item(info_[i], _info_save_list[start_index + i])
					info_[i].visible = true

func bind_item(item: WorkListInfoItem, infos: WorkListInfoData):
	if DEBUG_LOGS: print(self.name, ": WorkListInfoStep = ", infos.step)
	if DEBUG_LOGS: print("🟦 [DEBUG] 尝试播放动画 Step", infos.step)

	var global_node := _get_global_node()
	var spacebox_controller = global_node.get("spacebox_controller") if global_node != null else null
	if spacebox_controller:
		spacebox_controller.play_step(infos.step)
		spacebox_controller.show_only_work_info(infos.step)
	else:
		if DEBUG_LOGS: print("❌ [DEBUG] Global.spacebox_controller 为空")

	item.refresh_info(infos)


func replay_current_step_animation() -> void:
	var current_step := _get_current_step_data()
	if current_step == null:
		return

	var global_node := _get_global_node()
	var spacebox_controller = global_node.get("spacebox_controller") if global_node != null else null
	if spacebox_controller == null:
		if DEBUG_LOGS: print("spacebox_controller is null, unable to replay step animation.")
		return

	if spacebox_controller.has_method("set_worklist1_visible"):
		spacebox_controller.call("set_worklist1_visible", true)
	if spacebox_controller.has_method("show_only_work_info"):
		spacebox_controller.call("show_only_work_info", current_step.step)
	if spacebox_controller.has_method("play_step"):
		spacebox_controller.call("play_step", current_step.step)


func play_current_step_voice() -> void:
	var current_step := _get_current_step_data()
	if current_step == null:
		return

	var voice_text := _build_step_voice_text(current_step)
	if voice_text.strip_edges().is_empty():
		return

	if not ClassDB.class_has_method("DisplayServer", "tts_speak"):
		push_warning("DisplayServer TTS is not available on this platform.")
		return

	var voice_id := _get_preferred_tts_voice_id()
	_stop_current_step_voice()
	DisplayServer.tts_speak(voice_text, voice_id, 80, 1.0, 1.0, current_step.step, true)


func _build_step_voice_text(step_data: WorkListInfoData) -> String:
	var lines: Array[String] = []
	var title_text := step_data.title.strip_edges()
	var info_text := step_data.info.strip_edges()
	if not title_text.is_empty():
		lines.append(title_text)
	if not info_text.is_empty():
		lines.append(info_text)
	return "\n".join(lines)


func _get_preferred_tts_voice_id() -> String:
	if ClassDB.class_has_method("DisplayServer", "tts_get_voices_for_language"):
		var language_codes: Array[String] = ["zh_CN", "zh-CN", "zh", "zh_TW", "zh-TW", "zh_HK", "zh-HK"]
		for language_code in language_codes:
			var voice_ids: PackedStringArray = DisplayServer.tts_get_voices_for_language(language_code)
			if voice_ids.size() > 0:
				return voice_ids[0]

	if ClassDB.class_has_method("DisplayServer", "tts_get_voices"):
		var voices: Array = DisplayServer.tts_get_voices()
		for voice in voices:
			if typeof(voice) != TYPE_DICTIONARY:
				continue
			var language := str(voice.get("language", "")).to_lower()
			if language.begins_with("zh"):
				return str(voice.get("id", voice.get("name", "")))
		for voice in voices:
			if typeof(voice) == TYPE_DICTIONARY:
				return str(voice.get("id", voice.get("name", "")))

	return ""


func _stop_current_step_voice() -> void:
	if ClassDB.class_has_method("DisplayServer", "tts_stop"):
		DisplayServer.tts_stop()


func get_current_task_context_entries() -> Array[Dictionary]:
	if _info_save_list.is_empty():
		return []

	var task_title := title_label.text if title_label != null else "当前任务"
	var entries: Array[Dictionary] = []
	var current_step := _get_current_step_data()
	if current_step != null:
		entries.append({
			"id": "current-task-step-%d" % current_step.step,
			"title": "%s / 当前步骤 %d" % [task_title, current_step.step],
			"source": "当前专家任务步骤",
			"tags": ["当前任务", "当前步骤", "专家指导", current_step.title, task_title],
			"content": "当前任务：%s\n当前页：%d / %d\n当前步骤：%d. %s\n步骤要求：%s" % [
				task_title,
				page_index,
				max(page_count, 1),
				current_step.step,
				current_step.title,
				current_step.info,
			],
		})

	var lines: Array[String] = ["当前任务：%s" % task_title, "当前任务步骤："]
	for step_data in _info_save_list:
		if step_data == null:
			continue
		lines.append("%d. %s：%s" % [step_data.step, step_data.title, step_data.info])

	entries.append({
		"id": "current-task-guidance",
		"title": task_title,
		"source": "当前专家任务指导",
		"tags": ["当前任务", "专家指导", "步骤", task_title],
		"content": "\n".join(lines),
	})
	return entries


func _get_current_step_data() -> WorkListInfoData:
	if _info_save_list.is_empty():
		return null
	var current_index: int = max(0, min(_info_save_list.size() - 1, (page_index - 1) * page_item_count))
	return _info_save_list[current_index]


func pre_click():
	if page_count <= 0:
		return
	if page_index <= 1:
		return
	_stop_current_step_voice()
	page_index -= 1
	if page_index < 1:
		page_index = 1
	bind_page(page_index)
	_sync_assistant_context()

func first_page():
	_stop_current_step_voice()
	page_index = 1
	bind_page(page_index)
	_sync_assistant_context()

func last_page():
	_stop_current_step_voice()
	page_index = page_count
	bind_page(page_index)
	_sync_assistant_context()

func next_click():
	if page_count <= 0:
		return
	if page_index >= page_count:
		return
	_stop_current_step_voice()
	page_index += 1
	if page_index > page_count:
		page_index = page_count
	bind_page(page_index)
	_sync_assistant_context()

func to_animation_on_value_changed(arg0: bool):
	if arg0:
		replay_current_step_animation()

func _on_animation_toggle_pressed() -> void:
	replay_current_step_animation()

func _on_audio_toggle_pressed() -> void:
	play_current_step_voice()

func _on_back_pressed():
	pre_click()

func _on_next_pressed():
	next_click()


func _on_close_button_pressed():
	_stop_current_step_voice()
	_hide_llm_assistant_view()
	PanelWindowZoom.set_window_visible(self, false)


func on_spatial_window_visibility_changed(is_visible: bool) -> void:
	if is_visible:
		return
	_stop_current_step_voice()
	_hide_llm_assistant_view()


func _on_llm_assistant_pressed() -> void:
	if llm_assistant_view == null:
		return
	llm_assistant_view.visible = true
	llm_assistant_view.refresh_task_context()
	llm_assistant_view.start_assistant()


func _on_llm_assistant_back_pressed() -> void:
	_hide_llm_assistant_view()


func _hide_llm_assistant_view() -> void:
	if llm_assistant_view == null:
		return
	llm_assistant_view.stop_assistant()
	llm_assistant_view.visible = false


func _get_global_node() -> Node:
	return get_node_or_null("/root/Global")


func _sync_assistant_context() -> void:
	if llm_assistant_view != null and llm_assistant_view.has_method("refresh_task_context"):
		llm_assistant_view.call("refresh_task_context")
