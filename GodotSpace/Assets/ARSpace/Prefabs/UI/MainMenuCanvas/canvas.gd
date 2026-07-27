extends Control

const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

@onready var work_list_view: Control = $WorkTabView/WorkListView
@onready var llm_assistant_view: LLMAssistantUIView = $WorkTabView/LLMAssistantView
@onready var realtime_reconstruction_button: Button = \
	$WorkTabView/GridContainer/RealtimeReconstruction
var _reconstruction_session: Node
var _network_handler: Node

func _ready():
	_network_handler = get_node_or_null("/root/NetworkHandler")
	var global_node := _get_global_node()
	if global_node != null:
		global_node.set("main_menu_canvas", self)
	PanelWindowZoom.bind_max_button(self)
	work_list_view.visible = false
	llm_assistant_view.visible = false
	llm_assistant_view.set_task_catalog_provider(work_list_view)
	if _network_handler != null \
			and _network_handler.has_signal("network_ready") \
			and not _network_handler.is_connected(
				"network_ready",
				_refresh_reconstruction_entry,
			):
		_network_handler.connect("network_ready", _refresh_reconstruction_entry)
	if _network_handler != null \
			and _network_handler.has_signal("peer_role_changed") \
			and not _network_handler.is_connected(
				"peer_role_changed",
				_on_peer_role_changed,
			):
		_network_handler.connect("peer_role_changed", _on_peer_role_changed)
	call_deferred("_bind_reconstruction_session")
	_refresh_reconstruction_entry()

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

func _on_realtime_reconstruction_pressed() -> void:
	var workspace := get_tree().get_first_node_in_group(
		"reconstruction_workspace_controller"
	)
	if workspace == null or not workspace.has_method("request_enter_workspace"):
		push_warning("实时重建工作区尚未就绪")
		return
	if not bool(workspace.call("request_enter_workspace")):
		push_warning("当前端不能进入实时重建工作区")

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
		PanelWindowZoom.set_window_visible(canvas, is_visible)

func _get_global_node() -> Node:
	return get_node_or_null("/root/Global")

func _on_peer_role_changed(_peer_id: int, _assigned_role: String) -> void:
	_refresh_reconstruction_entry()


func _bind_reconstruction_session() -> void:
	_reconstruction_session = get_tree().get_first_node_in_group(
		"reconstruction_session_controller"
	)
	if _reconstruction_session == null:
		_refresh_reconstruction_entry()
		return
	if _reconstruction_session.has_signal("map_availability_changed"):
		var callback := Callable(self, "_on_reconstruction_map_availability_changed")
		if not _reconstruction_session.is_connected("map_availability_changed", callback):
			_reconstruction_session.connect("map_availability_changed", callback)
	_refresh_reconstruction_entry()


func _on_reconstruction_map_availability_changed(_is_available: bool) -> void:
	_refresh_reconstruction_entry()


func _refresh_reconstruction_entry() -> void:
	if realtime_reconstruction_button == null:
		return
	var role := ""
	if _network_handler != null \
			and _network_handler.has_method("get_local_assigned_role"):
		role = str(_network_handler.call("get_local_assigned_role"))
	if role.is_empty() or role == "unknown":
		var profile = RuntimeProfile.current()
		if profile != null and profile.has_method("is_sky") and bool(profile.call("is_sky")):
			role = "sky"
		elif profile != null and profile.has_method("uses_xr") and bool(profile.call("uses_xr")):
			role = "ground_vr"
		else:
			role = "pc_ground"
	var has_published_map := false
	if _reconstruction_session != null \
			and _reconstruction_session.has_method("has_published_map"):
		has_published_map = bool(_reconstruction_session.call("has_published_map"))
	var can_enter := role == "sky" or (role == "ground_vr" and has_published_map)
	realtime_reconstruction_button.disabled = not can_enter
	if role == "sky":
		realtime_reconstruction_button.tooltip_text = "进入实时重建控制台"
	elif role == "ground_vr" and not has_published_map:
		realtime_reconstruction_button.tooltip_text = "等待天上端确认并发布重建场景"
	else:
		realtime_reconstruction_button.tooltip_text = \
			"进入天上端共享场景" if can_enter \
			else "请使用天上或地面 VR 端进入实时重建场景"
