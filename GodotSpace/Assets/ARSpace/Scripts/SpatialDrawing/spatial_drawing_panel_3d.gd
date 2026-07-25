extends Node3D

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const SERVER_PEER_ID: int = 1
const PanelSurfaceScene := preload(
	"res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingPanelSurface.tscn"
)

@export var controller_local_offset: Vector3 = Vector3(0.08, 0.12, -0.16)
@export var position_smoothing: float = 18.0

var _left_controller: XRController3D
var _panel_surface: Node3D


func _ready() -> void:
	add_to_group("spatial_drawing_panel_3d")
	_refresh_visibility()


func _process(delta: float) -> void:
	_refresh_visibility()
	if not visible:
		return
	_resolve_left_controller()
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
	visible = can_draw
	if can_draw:
		_ensure_panel_surface()
	elif _panel_surface != null and is_instance_valid(_panel_surface):
		_panel_surface.queue_free()
		_panel_surface = null


func _ensure_panel_surface() -> void:
	if _panel_surface != null and is_instance_valid(_panel_surface):
		return
	_panel_surface = PanelSurfaceScene.instantiate() as Node3D
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
