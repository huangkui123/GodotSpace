class_name SharedSpaceAlignment
extends Node

const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const HEAD_TRACKER_PATH := &"head"
const DEFAULT_POSE_NAME := "default"
const RECENTER_CONTROLLER_BUTTON := &"menu_button"

signal alignment_succeeded(role: String, anchor: Node3D)
signal alignment_failed(reason: String)

@export var ground_anchor_path: NodePath = NodePath("../SharedSpaceOrigin/GroundVRAnchor")
@export var sky_anchor_path: NodePath = NodePath("../SharedSpaceOrigin/SkyXRAnchor")
@export var local_xr_origin_path: NodePath
@export var auto_recenter: bool = true
@export var show_recenter_controls: bool = true
@export_range(1.0, 60.0, 0.5) var tracking_timeout_seconds: float = 15.0
@export_range(0.02, 1.0, 0.01) var retry_interval_seconds: float = 0.1

var _runtime_profile
var _retry_seconds: float = 0.0
var _waiting_seconds: float = 0.0
var _timeout_reported: bool = false
var _is_aligned: bool = false
var _recenter_canvas: CanvasLayer
var _recenter_button: Button
var _status_label: Label
var _force_recenter_pending: bool = false


func _ready() -> void:
	add_to_group("shared_space_alignment")
	_runtime_profile = RuntimeProfile.current()
	if not _runtime_profile.is_valid() or not _runtime_profile.uses_xr():
		set_process(false)
		return
	var xr := XRServer.find_interface("OpenXR")
	if xr != null and not xr.is_connected("pose_recentered", _on_runtime_recentered):
		xr.connect("pose_recentered", _on_runtime_recentered)
	if show_recenter_controls and DisplayServer.get_name() != "headless":
		_build_recenter_controls()
	set_process(auto_recenter)


func _unhandled_input(event: InputEvent) -> void:
	if _runtime_profile == null or not _runtime_profile.uses_xr():
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.pressed and not key_event.echo and key_event.physical_keycode == KEY_R:
		request_recenter()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _is_reconstruction_workspace_active() and not _force_recenter_pending:
		return
	_waiting_seconds += delta
	_retry_seconds += delta
	if _retry_seconds < retry_interval_seconds:
		return
	_retry_seconds = 0.0

	if recenter(_force_recenter_pending):
		set_process(false)
		return

	if _waiting_seconds >= tracking_timeout_seconds and not _timeout_reported:
		_timeout_reported = true
		alignment_failed.emit("Timed out waiting for the local XR player and head tracking")
		push_warning("Shared-space alignment timed out. Use recenter() after tracking becomes available.")
		_set_status("共享空间：等待跟踪，按 R 或按钮重试")
		set_process(false)


## Aligns the current HMD's horizontal position and yaw with the role anchor.
## Head height and pitch/roll remain controlled by the XR tracking runtime.
func recenter(force: bool = false) -> bool:
	if _is_reconstruction_workspace_active() and not force:
		return false
	if _runtime_profile == null:
		_runtime_profile = RuntimeProfile.current()
	if not _runtime_profile.is_valid() or not _runtime_profile.uses_xr():
		return false

	var anchor := _get_role_anchor()
	var xr_origin := _get_local_xr_origin()
	if anchor == null or xr_origin == null:
		return false
	_bind_recenter_controllers(xr_origin)
	var xr_camera := xr_origin.get_node_or_null("XRCamera3D") as XRCamera3D
	if xr_camera == null or not _has_head_tracking():
		return false

	xr_origin.global_transform = compute_origin_transform(xr_camera.transform, anchor.global_transform)
	# Anchors are floor positions. The Stage pose already contains physical eye
	# height; adding a player height or a saved Y offset would count it twice.
	print("[SharedSpaceAlignment] role=%s reference_space=%d world_scale=%.3f floor_y=%.3f tracked_head_y=%.3f origin_y=%.3f world_head_y=%.3f" % [
		"ground" if _runtime_profile.is_ground() else "sky",
		int(ProjectSettings.get_setting("xr/openxr/reference_space", 1)),
		XRServer.world_scale, anchor.global_position.y, xr_camera.position.y,
		xr_origin.global_position.y, xr_camera.global_position.y,
	])
	_is_aligned = true
	_force_recenter_pending = false
	_timeout_reported = false
	_set_status("共享空间：已对齐")
	alignment_succeeded.emit("ground" if _runtime_profile.is_ground() else "sky", anchor)
	return true


func request_recenter(force: bool = false) -> void:
	if _is_reconstruction_workspace_active() and not force:
		_set_status("共享空间：实时重建期间已锁定全局对齐")
		return
	_force_recenter_pending = force
	_waiting_seconds = 0.0
	_retry_seconds = retry_interval_seconds
	_timeout_reported = false
	_is_aligned = false
	_set_status("共享空间：正在重新对齐…")
	set_process(true)


func _on_runtime_recentered() -> void:
	# Stage-space resets change the tracking frame. Invalidating cabinet data
	# alone leaves the previous origin transform applied to the new frame.
	# Use the same floor-preserving alignment as explicit application recenter.
	print("[SharedSpaceAlignment] OpenXR reference-space reset received; waiting for updated tracking")
	request_recenter()
	# Do not read the camera synchronously in the runtime's reset callback.
	_retry_seconds = 0.0


func is_aligned() -> bool:
	return _is_aligned


func get_role_anchor() -> Node3D:
	return _get_role_anchor()


static func compute_origin_transform(tracked_head_local: Transform3D, anchor_global: Transform3D) -> Transform3D:
	var tracked_head_yaw := _yaw_basis(tracked_head_local.basis)
	var anchor_yaw := _yaw_basis(anchor_global.basis)
	var origin_basis := anchor_yaw * tracked_head_yaw.inverse()
	var horizontal_head_offset := Vector3(
		tracked_head_local.origin.x,
		0.0,
		tracked_head_local.origin.z
	)
	var rotated_head_offset := origin_basis * horizontal_head_offset
	var origin_position := anchor_global.origin - rotated_head_offset
	origin_position.y = anchor_global.origin.y
	return Transform3D(origin_basis, origin_position)


static func _yaw_basis(source: Basis) -> Basis:
	var forward := -source.z
	forward.y = 0.0
	if forward.length_squared() < 0.000001:
		return Basis.IDENTITY
	forward = forward.normalized()
	var yaw := atan2(-forward.x, -forward.z)
	return Basis(Vector3.UP, yaw)


func _get_role_anchor() -> Node3D:
	var anchor_path := ground_anchor_path if _runtime_profile.is_ground() else sky_anchor_path
	return get_node_or_null(anchor_path) as Node3D


func _get_local_xr_origin() -> XROrigin3D:
	if not local_xr_origin_path.is_empty():
		var configured_origin := get_node_or_null(local_xr_origin_path) as XROrigin3D
		if configured_origin != null:
			return configured_origin

	var current_scene := get_tree().current_scene
	if current_scene == null:
		return null

	var peer_id := 1
	if multiplayer.has_multiplayer_peer():
		peer_id = multiplayer.get_unique_id()
	var local_player := current_scene.get_node_or_null(str(peer_id))
	if local_player == null:
		return null
	return local_player.get_node_or_null("XROrigin3D") as XROrigin3D


func _has_head_tracking() -> bool:
	var tracker := XRServer.get_tracker(HEAD_TRACKER_PATH)
	if tracker == null:
		return false
	var pose = tracker.get_pose(DEFAULT_POSE_NAME)
	# A retained or inferred pose is not enough to establish the initial frame.
	return pose != null and pose.has_tracking_data \
		and pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_HIGH


func _bind_recenter_controllers(xr_origin: XROrigin3D) -> void:
	for controller_path in [NodePath("LeftHand"), NodePath("RightHand")]:
		var controller := xr_origin.get_node_or_null(controller_path) as XRController3D
		if controller != null and not controller.button_pressed.is_connected(_on_controller_button_pressed):
			controller.button_pressed.connect(_on_controller_button_pressed)


func _on_controller_button_pressed(button_name: String) -> void:
	if StringName(button_name) == RECENTER_CONTROLLER_BUTTON:
		request_recenter()


func _is_reconstruction_workspace_active() -> bool:
	var workspace := get_tree().get_first_node_in_group(
		"reconstruction_workspace_controller"
	)
	return workspace != null \
		and workspace.has_method("is_workspace_active") \
		and bool(workspace.call("is_workspace_active"))


func _build_recenter_controls() -> void:
	_recenter_canvas = CanvasLayer.new()
	_recenter_canvas.name = "SharedSpaceRecenterCanvas"
	_recenter_canvas.layer = 40
	add_child(_recenter_canvas)

	var panel := PanelContainer.new()
	panel.name = "SharedSpaceRecenterPanel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -248.0
	panel.offset_top = 18.0
	panel.offset_right = -18.0
	panel.offset_bottom = 98.0
	_recenter_canvas.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	margin.add_child(column)
	_status_label = Label.new()
	_status_label.text = "共享空间：等待头显跟踪"
	column.add_child(_status_label)
	_recenter_button = Button.new()
	_recenter_button.text = "重新对齐（R / 控制器菜单键）"
	_recenter_button.pressed.connect(request_recenter)
	column.add_child(_recenter_button)


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
