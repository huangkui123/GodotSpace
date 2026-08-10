@tool
extends Area3D

const WINDOW_DOCK_SLOT_LAYER: int = 1 << 25

signal preview_changed(slot_id: StringName, visible: bool, candidate_window_id: StringName)
signal occupancy_changed(slot_id: StringName, occupied_window_id: StringName)

@export var slot_id: StringName = &""
@export var enabled: bool = true:
	set(value):
		enabled = value
		_refresh_visuals()
@export var accepted_categories: PackedStringArray = PackedStringArray()
@export var min_window_size_m: Vector2 = Vector2(0.25, 0.18)
@export var max_window_size_m: Vector2 = Vector2(2.5, 1.8)
@export var target_size_m: Vector2 = Vector2(1.119598, 1.064966)
@export_range(0.02, 1.0, 0.001) var detection_depth_m: float = 0.148527
@export_range(0.1, 3.0, 0.05) var target_scale_multiplier: float = 1.0
@export var preview_path: NodePath = NodePath("Preview")
@export var direction_marker_path: NodePath = NodePath("FacingMarker")
@export var collision_shape_path: NodePath = NodePath("CollisionShape3D")

var _occupied_window_id: StringName = &""
var _candidate_window_id: StringName = &""
var _preview: GeometryInstance3D
var _direction_marker: Node3D


func _ready() -> void:
	collision_layer = WINDOW_DOCK_SLOT_LAYER
	collision_mask = 0
	monitoring = false
	monitorable = true
	_ensure_visuals()
	_preview = get_node_or_null(preview_path) as GeometryInstance3D
	_direction_marker = get_node_or_null(direction_marker_path) as Node3D
	_refresh_visuals()


func can_accept(
	window_id: StringName,
	window_category: StringName,
	window_size_m: Vector2
) -> bool:
	if not enabled or slot_id.is_empty() or window_id.is_empty():
		return false
	if not _occupied_window_id.is_empty() and _occupied_window_id != window_id:
		return false
	if not accepted_categories.is_empty() \
			and str(window_category) not in accepted_categories:
		return false
	if not _is_finite_size(window_size_m):
		return false
	return window_size_m.x >= min_window_size_m.x \
		and window_size_m.y >= min_window_size_m.y \
		and window_size_m.x <= max_window_size_m.x \
		and window_size_m.y <= max_window_size_m.y


func set_candidate(window_id: StringName, active: bool) -> void:
	var next_candidate := window_id if active and can_accept(window_id, &"", target_size_m) else &""
	if active and not accepted_categories.is_empty():
		next_candidate = window_id if _occupied_window_id.is_empty() or _occupied_window_id == window_id else &""
	if next_candidate == _candidate_window_id:
		return
	_candidate_window_id = next_candidate
	_refresh_visuals()
	preview_changed.emit(slot_id, not _candidate_window_id.is_empty(), _candidate_window_id)


func clear_candidate(window_id: StringName = &"") -> void:
	if not window_id.is_empty() and _candidate_window_id != window_id:
		return
	if _candidate_window_id.is_empty():
		return
	_candidate_window_id = &""
	_refresh_visuals()
	preview_changed.emit(slot_id, false, &"")


func try_occupy(window_id: StringName) -> bool:
	if window_id.is_empty() or not enabled:
		return false
	if not _occupied_window_id.is_empty() and _occupied_window_id != window_id:
		return false
	if _occupied_window_id == window_id:
		clear_candidate(window_id)
		return true
	_occupied_window_id = window_id
	clear_candidate(window_id)
	_refresh_visuals()
	occupancy_changed.emit(slot_id, _occupied_window_id)
	return true


func release(window_id: StringName) -> bool:
	if window_id.is_empty() or _occupied_window_id != window_id:
		return false
	_occupied_window_id = &""
	_refresh_visuals()
	occupancy_changed.emit(slot_id, &"")
	return true


func force_release() -> StringName:
	var previous := _occupied_window_id
	if previous.is_empty():
		return previous
	_occupied_window_id = &""
	_refresh_visuals()
	occupancy_changed.emit(slot_id, &"")
	return previous


func get_occupied_window_id() -> StringName:
	return _occupied_window_id


func get_candidate_window_id() -> StringName:
	return _candidate_window_id


func get_snap_transform(
	floating_scale: Vector3,
	window_size_m: Vector2 = Vector2.ZERO
) -> Transform3D:
	var fit_multiplier := 1.0
	if _is_finite_size(window_size_m):
		fit_multiplier = minf(
			target_size_m.x / window_size_m.x,
			target_size_m.y / window_size_m.y
		)
	var scale_value := floating_scale * fit_multiplier * target_scale_multiplier
	return Transform3D(
		global_transform.basis.orthonormalized().scaled(scale_value),
		global_position
	)


func get_target_size_m() -> Vector2:
	return target_size_m


func _refresh_visuals() -> void:
	if not is_inside_tree():
		return
	if _preview == null:
		_preview = get_node_or_null(preview_path) as GeometryInstance3D
	if _direction_marker == null:
		_direction_marker = get_node_or_null(direction_marker_path) as Node3D
	var runtime_preview := enabled \
		and not _candidate_window_id.is_empty() \
		and _occupied_window_id.is_empty()
	if _preview != null:
		_preview.visible = Engine.is_editor_hint() or runtime_preview
		_preview.scale = Vector3(maxf(target_size_m.x, 0.05), maxf(target_size_m.y, 0.05), 1.0)
	if _direction_marker != null:
		_direction_marker.visible = Engine.is_editor_hint()
	var collision_shape := get_node_or_null(collision_shape_path) as CollisionShape3D
	if collision_shape != null and collision_shape.shape is BoxShape3D:
		(collision_shape.shape as BoxShape3D).size = Vector3(
			maxf(target_size_m.x, 0.05),
			maxf(target_size_m.y, 0.05),
			detection_depth_m
		)


func _ensure_visuals() -> void:
	# Dummy/headless rendering reports noisy mesh errors for editor-only preview
	# nodes. Normal desktop/XR runtimes and the editor create the same visuals
	# dynamically, while headless self-tests still exercise collision/state.
	if DisplayServer.get_name() == "headless":
		return
	if get_node_or_null(preview_path) == null:
		var preview := MeshInstance3D.new()
		preview.name = "Preview"
		var preview_mesh := QuadMesh.new()
		preview_mesh.size = Vector2.ONE
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.12, 0.78, 1.0, 0.24)
		preview_mesh.material = material
		preview.mesh = preview_mesh
		add_child(preview, false, Node.INTERNAL_MODE_BACK)
	if get_node_or_null(direction_marker_path) == null:
		var marker := MeshInstance3D.new()
		marker.name = "FacingMarker"
		var marker_mesh := BoxMesh.new()
		marker_mesh.size = Vector3(0.08, 0.04, 0.24)
		marker.mesh = marker_mesh
		marker.position = Vector3(0.0, -0.38, 0.14)
		add_child(marker, false, Node.INTERNAL_MODE_BACK)


func _is_finite_size(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y) and value.x > 0.0 and value.y > 0.0
