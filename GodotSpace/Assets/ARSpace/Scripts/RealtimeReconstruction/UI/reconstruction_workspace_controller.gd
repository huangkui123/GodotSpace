class_name RealtimeReconstructionWorkspaceController
extends Node3D

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const PanelUI := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/UI/reconstruction_panel_ui.gd"
)
const SERVER_PEER_ID: int = 1
const ROLE_PC_GROUND: String = "pc_ground"
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"
const PANEL_DISTANCE_METERS: float = 1.3
const PANEL_VERTICAL_OFFSET_METERS: float = -0.15

signal workspace_entered(role: String)
signal workspace_exited(role: String)
signal manual_adjustment_requested(kind: StringName, amount: float)

@export var suppressed_scene_paths: Array[NodePath] = [
	NodePath("SpaceBox"),
	NodePath("MainMenuCanvas"),
	NodePath("GroupUI"),
	NodePath("SharedSpaceOrigin/AstronautViewAnchor"),
	NodePath("SharedSpaceOrigin/SpatialWindows"),
	NodePath("SharedSpaceOrigin/WindowDockSlots"),
	NodePath("SharedSpaceOrigin/VirtualAnnotations"),
	NodePath("SharedSpaceOrigin/SpatialDrawingSystem"),
]

@onready var reconstruction_root: Node3D = $ReconstructionRoot
@onready var point_cloud_chunks: Node3D = $ReconstructionRoot/PointCloudChunks
@onready var ground_spawn_anchor: Marker3D = $GroundSpawnAnchor
@onready var panel_host: Node3D = $LocalPanelHost
@onready var panel_surface: Node = $LocalPanelHost/PanelSurface

var _workspace_active: bool = false
var _local_role: String = ROLE_SKY
var _suppressed_visibility: Dictionary = {}
var _panel_ui: Node
var _session_controller: Node
var _selected_import_map_id: String = ""
var _start_prerequisites_ready: bool = false
var _start_disabled_reason: String = "等待 PICO Helper、Lab 和点云通道"
var _shared_space_alignment: Node
var _previous_ground_anchor_path: NodePath
var _last_applied_state_name: String = ""


func _ready() -> void:
	add_to_group("reconstruction_workspace_controller")
	panel_host.visible = false
	reconstruction_root.visible = false
	call_deferred("_bind_panel")
	call_deferred("_bind_session_controller")


func _unhandled_input(event: InputEvent) -> void:
	if not _workspace_active:
		return
	if event.is_action_pressed("menu_button"):
		recenter_panel()
		get_viewport().set_input_as_handled()


func request_enter_workspace() -> bool:
	if _workspace_active:
		recenter_panel()
		return true
	_local_role = _resolve_local_role()
	if _local_role == ROLE_PC_GROUND:
		return false
	if _local_role not in [ROLE_SKY, ROLE_GROUND_VR]:
		push_warning("实时重建工作区拒绝未知角色: %s" % _local_role)
		return false
	if _local_role == ROLE_GROUND_VR and not _has_confirmed_shared_map():
		push_warning("实时重建场景尚未由天上端确认发布")
		return false
	_suppress_standard_arspace()
	_workspace_active = true
	if _local_role == ROLE_GROUND_VR:
		_enter_ground_spawn_anchor()
	panel_host.visible = true
	reconstruction_root.visible = _local_role == ROLE_GROUND_VR
	_last_applied_state_name = ""
	if _panel_ui != null:
		_panel_ui.configure_role(_local_role)
		_panel_ui.set_point_cloud_visible(reconstruction_root.visible)
		_refresh_panel_from_session()
	recenter_panel()
	workspace_entered.emit(_local_role)
	return true


func return_to_arspace() -> void:
	if not _workspace_active:
		return
	panel_host.visible = false
	reconstruction_root.visible = false
	if _local_role == ROLE_GROUND_VR:
		_restore_ground_spawn_anchor()
	_restore_standard_arspace()
	_workspace_active = false
	workspace_exited.emit(_local_role)


func is_workspace_active() -> bool:
	return _workspace_active


func set_point_cloud_visible(is_visible: bool) -> void:
	if not _workspace_active:
		return
	reconstruction_root.visible = is_visible
	if _panel_ui != null:
		_panel_ui.set_point_cloud_visible(is_visible)


func recenter_panel() -> void:
	if not _workspace_active:
		return
	var camera := _get_local_camera()
	if camera == null:
		return
	var camera_transform := camera.global_transform
	var forward := -camera_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var panel_position := camera_transform.origin \
		+ forward * PANEL_DISTANCE_METERS \
		+ Vector3.UP * PANEL_VERTICAL_OFFSET_METERS
	var to_camera := camera_transform.origin - panel_position
	to_camera.y = 0.0
	if to_camera.length_squared() < 0.0001:
		to_camera = Vector3.BACK
	panel_host.global_transform = Transform3D(
		Basis.looking_at(to_camera.normalized(), Vector3.UP),
		panel_position
	)


func get_ground_spawn_anchor() -> Marker3D:
	return ground_spawn_anchor


func get_reconstruction_root() -> Node3D:
	return reconstruction_root


func set_selected_import_map_id(map_id: String) -> void:
	_selected_import_map_id = map_id.strip_edges()


func set_map_library(entries: Array[Dictionary]) -> void:
	if _panel_ui != null and _panel_ui.has_method("set_map_library"):
		_panel_ui.call("set_map_library", entries)


func set_stop_draining(is_draining: bool) -> void:
	if _panel_ui != null and _panel_ui.has_method("set_stop_draining"):
		_panel_ui.call("set_stop_draining", is_draining)


func set_start_prerequisites_ready(is_ready: bool, reason: String = "") -> void:
	_start_prerequisites_ready = is_ready
	_start_disabled_reason = reason
	if _start_disabled_reason.is_empty() and not is_ready:
		_start_disabled_reason = "重建服务尚未全部就绪"
	_refresh_panel_from_session()


func set_service_status(service_name: StringName, is_ready: bool, detail: String = "") -> void:
	if _panel_ui != null and _panel_ui.has_method("set_service_status"):
		_panel_ui.call("set_service_status", service_name, is_ready, detail)


func set_collecting_progress(progress: float, instruction: String = "") -> void:
	if _panel_ui != null and _panel_ui.has_method("set_collecting_progress"):
		_panel_ui.call("set_collecting_progress", progress, instruction)


func set_preview_metrics(
	position_error_cm: float,
	rotation_error_deg: float,
	scale: float
) -> void:
	if _panel_ui != null and _panel_ui.has_method("set_preview_metrics"):
		_panel_ui.call(
			"set_preview_metrics",
			position_error_cm,
			rotation_error_deg,
			scale,
		)


func set_live_stats(
	input_fps: float,
	update_hz: float,
	latency_ms: float,
	point_count: int,
	elapsed_seconds: float
) -> void:
	if _panel_ui != null and _panel_ui.has_method("set_live_stats"):
		_panel_ui.call(
			"set_live_stats",
			input_fps,
			update_hz,
			latency_ms,
			point_count,
			elapsed_seconds,
		)


func _bind_panel() -> void:
	_panel_ui = _find_panel_ui(panel_surface)
	if _panel_ui == null:
		push_warning("实时重建面板尚未实例化")
		return
	_panel_ui.exit_requested.connect(_on_exit_requested)
	_panel_ui.recenter_requested.connect(recenter_panel)
	_panel_ui.start_requested.connect(_on_start_requested)
	_panel_ui.import_requested.connect(_on_import_requested)
	_panel_ui.cancel_requested.connect(_on_cancel_requested)
	_panel_ui.confirm_requested.connect(_on_confirm_requested)
	_panel_ui.retry_requested.connect(_on_retry_requested)
	_panel_ui.stop_requested.connect(_on_stop_requested)
	_panel_ui.reregister_requested.connect(_on_reregister_requested)
	_panel_ui.export_requested.connect(_on_export_requested)
	_panel_ui.new_session_requested.connect(_on_new_session_requested)
	_panel_ui.clear_requested.connect(_on_clear_requested)
	_panel_ui.point_cloud_visibility_requested.connect(set_point_cloud_visible)
	_panel_ui.manual_adjustment_requested.connect(_on_manual_adjustment_requested)
	_panel_ui.map_selected.connect(set_selected_import_map_id)
	_panel_ui.configure_role(_resolve_local_role())
	_panel_ui.set_service_status(&"helper", false, "等待视频流")
	_panel_ui.set_service_status(&"lab", false, "等待模型")
	_panel_ui.set_service_status(&"point_channel", false, "未连接")
	_panel_ui.set_service_status(&"storage", true, "服务器可写")
	_panel_ui.set_start_enabled(false, "等待 PICO Helper、Lab 和点云通道")


func _bind_session_controller() -> void:
	_session_controller = get_tree().get_first_node_in_group(
		"reconstruction_session_controller"
	)
	if _session_controller == null:
		return
	if _session_controller.has_signal("snapshot_changed"):
		var snapshot_callback := Callable(self, "_on_session_snapshot_changed")
		if not _session_controller.snapshot_changed.is_connected(snapshot_callback):
			_session_controller.snapshot_changed.connect(snapshot_callback)
	if _session_controller.has_signal("operation_rejected"):
		var rejection_callback := Callable(self, "_on_session_operation_rejected")
		if not _session_controller.operation_rejected.is_connected(rejection_callback):
			_session_controller.operation_rejected.connect(rejection_callback)
	_refresh_panel_from_session()


func _refresh_panel_from_session() -> void:
	if _panel_ui == null:
		return
	if _session_controller == null:
		_panel_ui.set_view_state(PanelUI.ViewState.PREPARE)
		return
	if _session_controller.has_method("get_snapshot"):
		_apply_ui_snapshot(_session_controller.call("get_snapshot") as Dictionary)


func _on_session_snapshot_changed(snapshot: Dictionary) -> void:
	_apply_ui_snapshot(snapshot)


func _on_session_operation_rejected(_action: StringName, message: String) -> void:
	if _panel_ui != null:
		_panel_ui.show_error(message)


func _apply_ui_snapshot(snapshot: Dictionary) -> void:
	if _panel_ui == null or snapshot.is_empty():
		return
	var state_name := str(snapshot.get("state_name", snapshot.get("state", "idle"))).to_lower()
	var did_state_change := state_name != _last_applied_state_name
	_last_applied_state_name = state_name
	var view_state: int = PanelUI.ViewState.PREPARE
	var message := ""
	match state_name:
		"preflight":
			view_state = PanelUI.ViewState.PREFLIGHT
			message = "正在检查 PICO Helper、Lab、点云通道和地图存储。"
		"collecting":
			view_state = PanelUI.ViewState.COLLECTING
		"solving":
			view_state = PanelUI.ViewState.SOLVING
		"preview":
			view_state = PanelUI.ViewState.PREVIEW
		"live":
			view_state = PanelUI.ViewState.LIVE
		"stopped":
			view_state = PanelUI.ViewState.STOPPED
		"importing":
			view_state = PanelUI.ViewState.IMPORTING
		"error":
			view_state = PanelUI.ViewState.ERROR
			message = str(snapshot.get("error_message", "重建会话发生错误。"))
	_panel_ui.set_view_state(view_state, message)
	_panel_ui.set_imported_session(
		bool(snapshot.get("session_is_imported", false))
	)
	if _workspace_active and did_state_change:
		if _local_role == ROLE_SKY and state_name == "preview":
			set_point_cloud_visible(true)
		elif _local_role == ROLE_SKY and state_name == "live":
			set_point_cloud_visible(false)
		elif _local_role == ROLE_GROUND_VR:
			set_point_cloud_visible(bool(snapshot.get("has_published_map", false)))
	var can_start := _local_role == ROLE_SKY \
		and state_name == "idle" \
		and _start_prerequisites_ready
	_panel_ui.set_start_enabled(
		can_start,
		"" if can_start else _start_disabled_reason
	)
	if _local_role == ROLE_GROUND_VR:
		var map_version := int(snapshot.get("map_version", 0))
		if bool(snapshot.get("has_published_map", state_name in ["live", "stopped"])):
			_panel_ui.set_ground_status("共享场景已就绪 · 地图版本 %d" % map_version)
		else:
			_panel_ui.set_ground_status("等待天上端确认并发布场景")


func _call_session(method_name: StringName, args: Array = []) -> bool:
	if _session_controller == null:
		_bind_session_controller()
	if _session_controller == null or not _session_controller.has_method(method_name):
		if _panel_ui != null:
			_panel_ui.show_error("重建会话控制器尚未就绪")
		return false
	var result: Variant = _session_controller.callv(method_name, args)
	return bool(result) if typeof(result) == TYPE_BOOL else true


func _on_exit_requested() -> void:
	return_to_arspace()


func _on_start_requested() -> void:
	_request_start_if_ready()


func _on_import_requested() -> void:
	if _selected_import_map_id.is_empty():
		if _panel_ui != null:
			_panel_ui.set_view_state(
				PanelUI.ViewState.PREPARE,
				"请先从 PC Server 重建地图库选择一张地图。"
			)
		return
	_call_session(&"request_import", [_selected_import_map_id])


func _on_cancel_requested() -> void:
	_call_session(&"request_reset")


func _on_confirm_requested() -> void:
	_call_session(&"request_confirm")


func _on_retry_requested() -> void:
	_call_session(&"request_retry")


func _on_stop_requested() -> void:
	_call_session(&"request_stop")


func _on_reregister_requested() -> void:
	_call_session(&"request_retry")


func _on_export_requested() -> void:
	_call_session(&"request_export", [_default_export_name()])


func _on_new_session_requested() -> void:
	_request_start_if_ready()


func _on_clear_requested() -> void:
	_call_session(&"request_reset")


func _on_manual_adjustment_requested(kind: StringName, amount: float) -> void:
	manual_adjustment_requested.emit(kind, amount)


func _request_start_if_ready() -> void:
	if not _start_prerequisites_ready:
		if _panel_ui != null:
			_panel_ui.set_view_state(
				PanelUI.ViewState.PREPARE,
				_start_disabled_reason
			)
		return
	_call_session(&"request_start", [{}])


func _has_confirmed_shared_map() -> bool:
	if _session_controller == null:
		_bind_session_controller()
	if _session_controller == null or not _session_controller.has_method("get_snapshot"):
		return false
	var snapshot := _session_controller.call("get_snapshot") as Dictionary
	return bool(snapshot.get(
		"has_published_map",
		str(snapshot.get("state_name", "")).to_lower() in ["live", "stopped"]
	))


func _default_export_name() -> String:
	var timestamp := Time.get_datetime_dict_from_system()
	return "实时重建_%04d-%02d-%02d_%02d-%02d-%02d" % [
		int(timestamp.get("year", 0)),
		int(timestamp.get("month", 0)),
		int(timestamp.get("day", 0)),
		int(timestamp.get("hour", 0)),
		int(timestamp.get("minute", 0)),
		int(timestamp.get("second", 0)),
	]


func _suppress_standard_arspace() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	_suppressed_visibility.clear()
	for path in suppressed_scene_paths:
		var node := scene.get_node_or_null(path)
		if node == null or not _has_visible_property(node):
			continue
		_suppressed_visibility[node] = bool(node.get("visible"))
		node.set("visible", false)


func _restore_standard_arspace() -> void:
	for value in _suppressed_visibility.keys():
		var node := value as Node
		if node != null and is_instance_valid(node) and _has_visible_property(node):
			node.set("visible", bool(_suppressed_visibility[value]))
	_suppressed_visibility.clear()


func _enter_ground_spawn_anchor() -> void:
	_shared_space_alignment = get_tree().get_first_node_in_group(
		"shared_space_alignment"
	)
	if _shared_space_alignment == null:
		return
	_previous_ground_anchor_path = _shared_space_alignment.get(
		"ground_anchor_path"
	) as NodePath
	_shared_space_alignment.set(
		"ground_anchor_path",
		NodePath("../SharedSpaceOrigin/ReconstructionWorkspace/GroundSpawnAnchor"),
	)
	if _shared_space_alignment.has_method("request_recenter"):
		# Entering Ground is the one controlled origin move allowed while the
		# workspace lock is active.
		_shared_space_alignment.call_deferred("request_recenter", true)


func _restore_ground_spawn_anchor() -> void:
	if _shared_space_alignment == null or not is_instance_valid(_shared_space_alignment):
		return
	if not _previous_ground_anchor_path.is_empty():
		_shared_space_alignment.set("ground_anchor_path", _previous_ground_anchor_path)
	if _shared_space_alignment.has_method("request_recenter"):
		_shared_space_alignment.call_deferred("request_recenter")
	_shared_space_alignment = null
	_previous_ground_anchor_path = NodePath()


func _has_visible_property(node: Node) -> bool:
	return node is Node3D or node is CanvasItem


func _resolve_local_role() -> String:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler != null and network_handler.has_method("get_local_assigned_role"):
		var assigned_role := str(network_handler.call("get_local_assigned_role"))
		if assigned_role in [ROLE_PC_GROUND, ROLE_GROUND_VR, ROLE_SKY]:
			return assigned_role
	var profile = RuntimeProfile.current()
	if profile != null and profile.has_method("is_sky") and bool(profile.call("is_sky")):
		return ROLE_SKY
	if profile != null and profile.has_method("uses_xr") and bool(profile.call("uses_xr")):
		return ROLE_GROUND_VR
	return ROLE_PC_GROUND


func _get_local_camera() -> Camera3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var peer_id := multiplayer.get_unique_id() \
		if multiplayer.has_multiplayer_peer() \
		else SERVER_PEER_ID
	var player_camera := scene.get_node_or_null(
		NodePath("%d/XROrigin3D/XRCamera3D" % peer_id)
	) as Camera3D
	if player_camera != null:
		return player_camera
	return get_viewport().get_camera_3d()


func _find_panel_ui(root: Node) -> Node:
	if root != null and root.get_script() == PanelUI:
		return root
	for child in root.get_children():
		var match_node: Node = _find_panel_ui(child)
		if match_node != null:
			return match_node
	return null
