extends Control

const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")

@onready var work_list_view: Control = $WorkTabView/WorkListView
@onready var llm_assistant_view: LLMAssistantUIView = $WorkTabView/LLMAssistantView

func _ready():
	var global_node := _get_global_node()
	if global_node != null:
		global_node.set("main_menu_canvas", self)
	PanelWindowZoom.bind_max_button(self)
	work_list_view.visible = false
	llm_assistant_view.visible = false
	llm_assistant_view.set_task_catalog_provider(work_list_view)

func _on_photo_pressed():
	_set_global_canvas_visible("picture_canvas", true)

func _on_movie_pressed():
	_set_global_canvas_visible("movie_canvas", true)

func _on_voice_call_pressed():
	_set_global_canvas_visible("voice_call_window", true)

func _on_work_list_pressed():
	_hide_llm_assistant_view()
	work_list_view.visible = true
	# Global.work_list_view.refresh_work_list()
	_set_spacebox_worklist_visible(true)

func _on_back_button_pressed():
	work_list_view.visible = false
	_set_spacebox_worklist_visible(false)

func _on_close_button_pressed():
	_hide_llm_assistant_view()
	self.visible = false

func _on_llm_assistant_pressed() -> void:
	work_list_view.visible = false
	_set_spacebox_worklist_visible(false)

	llm_assistant_view.set_task_catalog_provider(work_list_view)
	llm_assistant_view.visible = true
	llm_assistant_view.start_assistant()

func _on_llm_back_button_pressed() -> void:
	_hide_llm_assistant_view()

func _hide_llm_assistant_view() -> void:
	if llm_assistant_view:
		llm_assistant_view.stop_assistant()
		llm_assistant_view.visible = false

func _set_spacebox_worklist_visible(is_visible: bool) -> void:
	var global_node := _get_global_node()
	var spacebox_controller = global_node.get("spacebox_controller") if global_node != null else null
	if spacebox_controller != null and spacebox_controller.has_method("set_worklist1_visible"):
		spacebox_controller.call("set_worklist1_visible", is_visible)

func _set_global_canvas_visible(property_name: StringName, is_visible: bool) -> void:
	var global_node := _get_global_node()
	var canvas = global_node.get(property_name) if global_node != null else null
	if canvas != null:
		canvas.visible = is_visible

func _get_global_node() -> Node:
	return get_node_or_null("/root/Global")
