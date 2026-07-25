class_name VirtualAnnotationMarker
extends Node3D

const MARKER_COLLISION_LAYER: int = 1 << 24
const SURFACE_OFFSET: float = 0.01

@export var marker_radius: float = 0.025
@export var normal_length: float = 0.08
@export var marker_color: Color = Color(1.0, 0.19, 0.05, 1.0)
@export var draft_color: Color = Color(1.0, 0.8, 0.08, 0.85)

var _annotation: Dictionary = {}
var _shared_origin: Node3D
var _target_root: Node
var _target: Node3D
var _is_draft: bool = false
var _visual_root: Node3D
var _label: Label3D
var _collision_body: StaticBody3D
var _material: StandardMaterial3D


func _ready() -> void:
	add_to_group("virtual_annotation_marker")
	_build_visuals()
	_apply_annotation()


func configure(annotation: Dictionary, shared_origin: Node3D, is_draft: bool = false, target_root: Node = null) -> void:
	_annotation = annotation.duplicate(true)
	_shared_origin = shared_origin
	_target_root = target_root if target_root != null else shared_origin
	_is_draft = is_draft
	_target = null
	_resolve_target()
	if is_inside_tree():
		_apply_annotation()


func get_annotation_id() -> int:
	return int(_annotation.get("id", -1))


func get_annotation_data() -> Dictionary:
	return _annotation.duplicate(true)


func _process(_delta: float) -> void:
	_apply_anchor_transform()


func _build_visuals() -> void:
	if _visual_root != null:
		return

	_visual_root = Node3D.new()
	_visual_root.name = "Visuals"
	add_child(_visual_root)

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.emission_enabled = true
	_material.emission_energy_multiplier = 2.5
	_material.no_depth_test = false

	var point_mesh := MeshInstance3D.new()
	point_mesh.name = "Point"
	var sphere := SphereMesh.new()
	sphere.radius = marker_radius
	sphere.height = marker_radius * 2.0
	point_mesh.mesh = sphere
	point_mesh.material_override = _material
	point_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual_root.add_child(point_mesh)

	var ring_mesh := MeshInstance3D.new()
	ring_mesh.name = "Ring"
	var ring := TorusMesh.new()
	ring.inner_radius = marker_radius * 1.45
	ring.outer_radius = marker_radius * 1.75
	ring_mesh.mesh = ring
	ring_mesh.material_override = _material
	ring_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual_root.add_child(ring_mesh)

	var normal_mesh := MeshInstance3D.new()
	normal_mesh.name = "Normal"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = marker_radius * 0.12
	cylinder.bottom_radius = marker_radius * 0.12
	cylinder.height = normal_length
	normal_mesh.mesh = cylinder
	normal_mesh.position.y = normal_length * 0.5
	normal_mesh.material_override = _material
	normal_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual_root.add_child(normal_mesh)

	_label = Label3D.new()
	_label.name = "Description"
	_label.position = Vector3(0.0, normal_length + 0.055, 0.0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 32
	_label.outline_size = 8
	_label.modulate = Color.WHITE
	_label.outline_modulate = Color(0.04, 0.04, 0.04, 0.95)
	_label.render_priority = 10
	_visual_root.add_child(_label)

	_collision_body = StaticBody3D.new()
	_collision_body.name = "SelectionBody"
	_collision_body.collision_mask = 0
	_collision_body.input_ray_pickable = true
	var collision_shape := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = marker_radius * 2.2
	collision_shape.shape = shape
	_collision_body.add_child(collision_shape)
	add_child(_collision_body)


func _apply_annotation() -> void:
	if _visual_root == null:
		return
	var color := draft_color if _is_draft else marker_color
	_material.albedo_color = color
	_material.emission = Color(color.r, color.g, color.b, 1.0)
	_label.text = str(_annotation.get("text", ""))
	_label.modulate = Color(1.0, 0.96, 0.86, color.a)
	var annotation_id := get_annotation_id()
	set_meta("virtual_annotation_id", annotation_id)
	_collision_body.set_meta("virtual_annotation_id", annotation_id)
	_collision_body.collision_layer = 0 if _is_draft or annotation_id <= 0 else MARKER_COLLISION_LAYER
	_apply_anchor_transform()


func _resolve_target() -> void:
	if _target_root == null or not is_instance_valid(_target_root):
		return
	var target_path := str(_annotation.get("target_path", ""))
	if target_path == "":
		return
	_target = _target_root.get_node_or_null(NodePath(target_path)) as Node3D


func _apply_anchor_transform() -> void:
	if _shared_origin == null or not is_instance_valid(_shared_origin):
		return
	if _target != null and not is_instance_valid(_target):
		_target = null
	if _target == null:
		_resolve_target()

	var world_position: Vector3
	var world_normal: Vector3
	if _target != null:
		world_position = _target.to_global(_annotation.get("target_local_position", Vector3.ZERO))
		world_normal = _local_normal_to_world(
			_target,
			_annotation.get("target_local_normal", Vector3.UP)
		)
	else:
		world_position = _shared_origin.to_global(_annotation.get("shared_position", Vector3.ZERO))
		world_normal = _local_normal_to_world(
			_shared_origin,
			_annotation.get("shared_normal", Vector3.UP)
		)

	global_transform = Transform3D(_basis_from_up(world_normal), world_position + world_normal * SURFACE_OFFSET)


func _local_normal_to_world(target: Node3D, local_normal: Vector3) -> Vector3:
	var normal := target.global_transform.basis.inverse().transposed() * local_normal
	if not normal.is_finite() or normal.length_squared() < 0.000001:
		return Vector3.UP
	return normal.normalized()


func _basis_from_up(up: Vector3) -> Basis:
	var normalized_up := up.normalized()
	var tangent := Vector3.FORWARD.cross(normalized_up)
	if tangent.length_squared() < 0.000001:
		tangent = Vector3.RIGHT.cross(normalized_up)
	tangent = tangent.normalized()
	var forward := tangent.cross(normalized_up).normalized()
	return Basis(tangent, normalized_up, forward).orthonormalized()
