extends Node3D

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const SERVER_PEER_ID: int = 1
const XR_PRESS_THRESHOLD: float = 0.65
const PANEL_SURFACE_SCENE_PATH: String = \
	"res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingPanelSurface.tscn"

@export var controller_local_offset: Vector3 = Vector3(0.08, 0.12, -0.16)
@export var position_smoothing: float = 18.0
@export var initially_visible: bool = false

var _left_controller: XRController3D
var _panel_surface: Node3D
var _panel_requested_visible: bool = false
var _last_left_trigger_pressed: bool = false


func _ready() -> void:
	add_to_group("spatial_drawing_panel_3d")
	_panel_requested_visible = initially_visible
	_refresh_visibility()


func _process(delta: float) -> void:
	_resolve_left_controller()
	_poll_left_trigger()
	_refresh_visibility()
	if not visible:
		return
	if _left_controller == null or not is_instance_valid(_left_controller):
		return
	var target := _left_controller.global_transform * Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-18.0), deg_to_rad(6.0), deg_to_rad(-8.0))),
		controller_local_offset
	)
	var weight := 1.0 - exp(-maxf(position_smoothing, 0.1) * maxf(delta, 0.0))
	global_transform = global_transform.interpolate_with(target, weight)


func _refresh_visibility() -> void:
	var profile = RuntimeProfile.current()
	var can_draw: bool = profile != null \
		and profile.has_method("can_draw") \
		and bool(profile.call("can_draw"))
	visible = can_draw and _panel_requested_visible
	if can_draw:
		_ensure_panel_surface()
	elif _panel_surface != null and is_instance_valid(_panel_surface):
		_panel_surface.queue_free()
		_panel_surface = null
		_last_left_trigger_pressed = false


func is_panel_visible() -> bool:
	return visible


func set_panel_visible(is_visible: bool) -> void:
	_panel_requested_visible = is_visible
	_refresh_visibility()


func toggle_panel_visibility() -> void:
	set_panel_visible(not _panel_requested_visible)


func _poll_left_trigger() -> void:
	var profile = RuntimeProfile.current()
	var accepts_xr_shortcut: bool = profile != null \
		and profile.has_method("uses_xr") \
		and bool(profile.call("uses_xr")) \
		and profile.has_method("can_draw") \
		and bool(profile.call("can_draw"))
	if not accepts_xr_shortcut:
		_last_left_trigger_pressed = false
		return
	var left_tracker := XRServer.get_tracker(&"left_hand")
	var trigger_pressed := _tracker_input_pressed(left_tracker, &"trigger")
	if trigger_pressed and not _last_left_trigger_pressed:
		toggle_panel_visibility()
	_last_left_trigger_pressed = trigger_pressed


func _tracker_input_pressed(
	tracker: XRPositionalTracker,
	input_name: StringName
) -> bool:
	if tracker == null:
		return false
	var value = tracker.get_input(input_name)
	if value is bool:
		return value
	if value is float or value is int:
		return float(value) >= XR_PRESS_THRESHOLD
	return false


func _ensure_panel_surface() -> void:
	if _panel_surface != null and is_instance_valid(_panel_surface):
		return
	var panel_surface_scene := load(PANEL_SURFACE_SCENE_PATH) as PackedScene
	if panel_surface_scene == null:
		push_error("无法加载空间绘制功能面板。")
		return
	_panel_surface = panel_surface_scene.instantiate() as Node3D
	add_child(_panel_surface)


func _resolve_left_controller() -> void:
	if _left_controller != null and is_instance_valid(_left_controller):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var peer_id := multiplayer.get_unique_id() \
		if multiplayer.has_multiplayer_peer() \
		else SERVER_PEER_ID
	_left_controller = scene.get_node_or_null(
		NodePath("%d/XROrigin3D/LeftHand" % peer_id)
	) as XRController3D
