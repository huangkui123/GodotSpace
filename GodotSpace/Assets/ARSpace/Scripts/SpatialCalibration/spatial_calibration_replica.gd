class_name SpatialCalibrationReplica
extends Node

const PREVIEW_COLOR := Color(0.2, 1.0, 0.25, 0.85)
const CONFIRMED_COLOR := Color(1.0, 0.62, 0.12, 1.0)
const PREVIEW_RADIUS: float = 0.025
const CONFIRMED_RADIUS: float = 0.035

@export_node_path("Node") var state_service_path := NodePath("/root/SpatialCalibrationState")
@export_node_path("Node3D") var shared_space_origin_path: NodePath

var _state_service: Node
var _shared_origin: Node3D
var _marker_root: Node3D
var _preview_marker: MeshInstance3D


func _ready() -> void:
	add_to_group("spatial_calibration_replica")
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)
	_bind_state_service()
	call_deferred("_rebuild_from_service")


func _exit_tree() -> void:
	_unbind_state_service()
	if get_tree() != null and get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.disconnect(_on_tree_node_added)


func rebuild(state: Dictionary) -> bool:
	if not _ensure_marker_root():
		return false
	_clear_marker_children()
	var points_value = state.get("confirmed_points", [])
	if points_value is Array:
		for point_value in points_value as Array:
			if point_value is Dictionary:
				_add_confirmed_marker(point_value as Dictionary)
	_apply_preview(state.get("preview", {}) as Dictionary)
	return true


func get_marker_root() -> Node3D:
	return _marker_root


func _bind_state_service() -> void:
	_unbind_state_service()
	_state_service = get_node_or_null(state_service_path)
	if _state_service == null:
		return
	if _state_service.has_signal("calibration_changed") \
			and not _state_service.is_connected("calibration_changed", _on_calibration_changed):
		_state_service.connect("calibration_changed", _on_calibration_changed)
	if _state_service.has_signal("preview_changed") \
			and not _state_service.is_connected("preview_changed", _on_preview_changed):
		_state_service.connect("preview_changed", _on_preview_changed)


func _unbind_state_service() -> void:
	if _state_service == null or not is_instance_valid(_state_service):
		_state_service = null
		return
	if _state_service.has_signal("calibration_changed") \
			and _state_service.is_connected("calibration_changed", _on_calibration_changed):
		_state_service.disconnect("calibration_changed", _on_calibration_changed)
	if _state_service.has_signal("preview_changed") \
			and _state_service.is_connected("preview_changed", _on_preview_changed):
		_state_service.disconnect("preview_changed", _on_preview_changed)
	_state_service = null


func _rebuild_from_service() -> void:
	if _state_service == null or not is_instance_valid(_state_service):
		_bind_state_service()
	if _state_service != null and _state_service.has_method("get_state"):
		rebuild(_state_service.call("get_state") as Dictionary)


func _on_calibration_changed(state: Dictionary) -> void:
	rebuild(state)


func _on_preview_changed(preview: Dictionary) -> void:
	if not _ensure_marker_root():
		return
	_apply_preview(preview)


func _ensure_marker_root() -> bool:
	var resolved_origin := _resolve_shared_origin()
	if resolved_origin == null:
		return false
	if _shared_origin != resolved_origin or _marker_root == null or not is_instance_valid(_marker_root):
		_shared_origin = resolved_origin
		_marker_root = _shared_origin.get_node_or_null("SpatialCalibrationStateReplica") as Node3D
		if _marker_root == null:
			_marker_root = Node3D.new()
			_marker_root.name = "SpatialCalibrationStateReplica"
			_marker_root.add_to_group("spatial_calibration_marker_root")
			_shared_origin.add_child(_marker_root)
		_marker_root.transform = Transform3D.IDENTITY
		_preview_marker = _marker_root.get_node_or_null("Preview") as MeshInstance3D
	return true


func _resolve_shared_origin() -> Node3D:
	if not shared_space_origin_path.is_empty():
		return get_node_or_null(shared_space_origin_path) as Node3D
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return null
	var grouped: Array[Node] = []
	for candidate in current_scene.find_children("*", "Node3D", true, false):
		if candidate.is_in_group("shared_space_origin"):
			grouped.append(candidate)
	if grouped.size() == 1:
		return grouped[0] as Node3D
	if grouped.size() > 1:
		push_warning("SpatialCalibrationReplica found multiple shared-space origins.")
		return null
	return current_scene.find_child("SharedSpaceOrigin", true, false) as Node3D


func _clear_marker_children() -> void:
	_preview_marker = null
	for child in _marker_root.get_children():
		_marker_root.remove_child(child)
		child.queue_free()


func _add_confirmed_marker(point: Dictionary) -> void:
	var position_value = point.get("shared_position", null)
	if not (position_value is Vector3):
		return
	var marker := _make_marker(CONFIRMED_COLOR, CONFIRMED_RADIUS)
	marker.name = _safe_node_name(str(point.get("id", "ConfirmedPoint")))
	marker.position = position_value as Vector3
	marker.add_to_group("spatial_calibration_confirmed_marker")
	marker.set_meta("calibration_data", (point.get("data", {}) as Dictionary).duplicate(true))
	_marker_root.add_child(marker)


func _apply_preview(preview: Dictionary) -> void:
	if preview.is_empty() or preview.get("visible", false) != true \
			or not (preview.get("shared_position", null) is Vector3):
		if _preview_marker != null and is_instance_valid(_preview_marker):
			_preview_marker.visible = false
		return
	if _preview_marker == null or not is_instance_valid(_preview_marker):
		_preview_marker = _make_marker(PREVIEW_COLOR, PREVIEW_RADIUS)
		_preview_marker.name = "Preview"
		_preview_marker.add_to_group("spatial_calibration_preview_marker")
		_marker_root.add_child(_preview_marker)
	_preview_marker.position = preview.get("shared_position") as Vector3
	_preview_marker.visible = true
	_preview_marker.set_meta("calibration_data", (preview.get("data", {}) as Dictionary).duplicate(true))


func _make_marker(color: Color, radius: float) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if DisplayServer.get_name() == "headless":
		return marker
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	marker.mesh = sphere
	marker.material_override = material
	return marker


func _safe_node_name(value: String) -> String:
	var safe := value.validate_node_name()
	return safe if not safe.is_empty() else "ConfirmedPoint"


func _on_tree_node_added(node: Node) -> void:
	if node.name == &"SharedSpaceOrigin" or node.is_in_group("shared_space_origin"):
		call_deferred("_rebuild_from_service")
