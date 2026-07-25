class_name SpatialStrokeRenderer
extends Node3D

const DEFAULT_RADIAL_SEGMENTS: int = 8
const MIN_SEGMENT_LENGTH_SQUARED: float = 0.00000001
const IDLE_GUIDE_COLOR := Color(1.0, 0.82, 0.04, 0.96)

@export_range(4, 12, 1) var radial_segments: int = DEFAULT_RADIAL_SEGMENTS

var _published_meshes: Dictionary = {}
var _draft_meshes: Dictionary = {}
var _idle_guide_mesh: ArrayMesh
var _idle_guide_instance: MeshInstance3D
var _idle_guide_visible: bool = true


func _ready() -> void:
	add_to_group("spatial_drawing_renderer")


func upsert_published_stroke(stroke: Dictionary) -> bool:
	var stroke_id := int(stroke.get("stroke_id", 0))
	if stroke_id <= 0:
		return false
	var mesh := build_tube_mesh(
		stroke.get("points", PackedVector3Array()) as PackedVector3Array,
		float(stroke.get("width_m", 0.0)),
		stroke.get("color", Color.WHITE) as Color,
		radial_segments
	)
	if mesh.get_surface_count() == 0:
		return false
	if DisplayServer.get_name() == "headless":
		_published_meshes[stroke_id] = mesh
		return true
	var instance := _get_or_create_mesh_instance(
		_published_meshes,
		stroke_id,
		"PublishedStroke_%d" % stroke_id
	)
	instance.mesh = mesh
	instance.material_override = make_stroke_material(
		stroke.get("color", Color.WHITE) as Color,
		false
	)
	if instance.get_parent() == null:
		add_child(instance)
	return true


func remove_published_stroke(stroke_id: int) -> void:
	_remove_mesh_instance(_published_meshes, stroke_id)


func clear_published_strokes() -> void:
	_clear_mesh_instances(_published_meshes)


func upsert_local_draft(local_id: int, draft: Dictionary) -> bool:
	if local_id <= 0:
		return false
	var color := draft.get("color", Color.WHITE) as Color
	var mesh := build_tube_mesh(
		draft.get("points", PackedVector3Array()) as PackedVector3Array,
		float(draft.get("width_m", 0.0)),
		color,
		radial_segments
	)
	if mesh.get_surface_count() == 0:
		remove_local_draft(local_id)
		return false
	if DisplayServer.get_name() == "headless":
		_draft_meshes[local_id] = mesh
		return true
	var instance := _get_or_create_mesh_instance(
		_draft_meshes,
		local_id,
		"LocalDraft_%d" % local_id
	)
	instance.mesh = mesh
	instance.material_override = make_stroke_material(color, true)
	if instance.get_parent() == null:
		add_child(instance)
	return true


func remove_local_draft(local_id: int) -> void:
	_remove_mesh_instance(_draft_meshes, local_id)


func clear_local_drafts() -> void:
	_clear_mesh_instances(_draft_meshes)


func update_idle_guide(points: PackedVector3Array, width_m: float) -> bool:
	var mesh := build_tube_mesh(
		points,
		width_m,
		IDLE_GUIDE_COLOR,
		maxi(4, radial_segments - 2)
	)
	if mesh.get_surface_count() == 0:
		clear_idle_guide()
		return false
	_idle_guide_mesh = mesh
	if DisplayServer.get_name() == "headless":
		return true
	if _idle_guide_instance == null or not is_instance_valid(_idle_guide_instance):
		_idle_guide_instance = MeshInstance3D.new()
		_idle_guide_instance.name = "IdleNozzleGuide"
		_idle_guide_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_idle_guide_instance.material_override = make_idle_guide_material()
		add_child(_idle_guide_instance)
	_idle_guide_instance.mesh = mesh
	_idle_guide_instance.visible = _idle_guide_visible
	return true


func set_idle_guide_visible(is_visible: bool) -> void:
	_idle_guide_visible = is_visible
	if _idle_guide_instance != null and is_instance_valid(_idle_guide_instance):
		_idle_guide_instance.visible = is_visible and has_idle_guide_mesh()


func clear_idle_guide() -> void:
	_idle_guide_mesh = null
	if _idle_guide_instance != null and is_instance_valid(_idle_guide_instance):
		_idle_guide_instance.mesh = null
		_idle_guide_instance.visible = false


func has_idle_guide_mesh() -> bool:
	return _idle_guide_mesh != null and _idle_guide_mesh.get_surface_count() > 0


func is_idle_guide_visible() -> bool:
	return _idle_guide_visible and has_idle_guide_mesh()


func get_idle_guide_mesh() -> ArrayMesh:
	return _idle_guide_mesh


func get_published_mesh_count() -> int:
	return _published_meshes.size()


func get_local_draft_mesh_count() -> int:
	return _draft_meshes.size()


static func build_tube_mesh(
	points: PackedVector3Array,
	width_m: float,
	color: Color,
	requested_radial_segments: int = DEFAULT_RADIAL_SEGMENTS
) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var clean_points := _remove_duplicate_points(points)
	var side_count := clampi(requested_radial_segments, 4, 12)
	if clean_points.size() < 2 or not is_finite(width_m) or width_m <= 0.0:
		return mesh

	var radius := width_m * 0.5
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	vertices.resize(clean_points.size() * side_count + 2)
	normals.resize(vertices.size())
	colors.resize(vertices.size())

	var previous_normal := Vector3.ZERO
	for point_index in range(clean_points.size()):
		var tangent := _point_tangent(clean_points, point_index)
		var normal := _transport_normal(tangent, previous_normal)
		var binormal := tangent.cross(normal).normalized()
		previous_normal = normal
		for side_index in range(side_count):
			var angle := TAU * float(side_index) / float(side_count)
			var radial := (normal * cos(angle) + binormal * sin(angle)).normalized()
			var vertex_index := point_index * side_count + side_index
			vertices[vertex_index] = clean_points[point_index] + radial * radius
			normals[vertex_index] = radial
			colors[vertex_index] = color

	for point_index in range(clean_points.size() - 1):
		var ring_start := point_index * side_count
		var next_ring_start := (point_index + 1) * side_count
		for side_index in range(side_count):
			var next_side := (side_index + 1) % side_count
			indices.append(ring_start + side_index)
			indices.append(next_ring_start + side_index)
			indices.append(next_ring_start + next_side)
			indices.append(ring_start + side_index)
			indices.append(next_ring_start + next_side)
			indices.append(ring_start + next_side)

	var start_center_index := clean_points.size() * side_count
	var end_center_index := start_center_index + 1
	var start_tangent := _point_tangent(clean_points, 0)
	var end_tangent := _point_tangent(clean_points, clean_points.size() - 1)
	vertices[start_center_index] = clean_points[0]
	normals[start_center_index] = -start_tangent
	colors[start_center_index] = color
	vertices[end_center_index] = clean_points[clean_points.size() - 1]
	normals[end_center_index] = end_tangent
	colors[end_center_index] = color
	for side_index in range(side_count):
		var next_side := (side_index + 1) % side_count
		indices.append(start_center_index)
		indices.append(next_side)
		indices.append(side_index)
		var last_ring_start := (clean_points.size() - 1) * side_count
		indices.append(end_center_index)
		indices.append(last_ring_start + side_index)
		indices.append(last_ring_start + next_side)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _remove_duplicate_points(points: PackedVector3Array) -> PackedVector3Array:
	var clean := PackedVector3Array()
	for point in points:
		if not _is_finite_vector(point):
			return PackedVector3Array()
		if clean.is_empty() or clean[clean.size() - 1].distance_squared_to(point) >= MIN_SEGMENT_LENGTH_SQUARED:
			clean.append(point)
	return clean


static func _point_tangent(points: PackedVector3Array, index: int) -> Vector3:
	var tangent := Vector3.ZERO
	var incoming := Vector3.ZERO
	var outgoing := Vector3.ZERO
	if index > 0:
		incoming = points[index] - points[index - 1]
		tangent += incoming
	if index + 1 < points.size():
		outgoing = points[index + 1] - points[index]
		tangent += outgoing
	if tangent.length_squared() < MIN_SEGMENT_LENGTH_SQUARED:
		# A 180-degree turn makes the averaged tangent cancel out. Keep a
		# deterministic adjacent direction so the ring remains finite.
		tangent = outgoing \
			if outgoing.length_squared() >= MIN_SEGMENT_LENGTH_SQUARED \
			else incoming
	return tangent.normalized()


static func _transport_normal(tangent: Vector3, previous_normal: Vector3) -> Vector3:
	if previous_normal.length_squared() >= MIN_SEGMENT_LENGTH_SQUARED:
		var transported := previous_normal - tangent * previous_normal.dot(tangent)
		if transported.length_squared() >= MIN_SEGMENT_LENGTH_SQUARED:
			return transported.normalized()
	var reference := Vector3.UP if absf(tangent.dot(Vector3.UP)) < 0.92 else Vector3.RIGHT
	return tangent.cross(reference).normalized()


static func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _get_or_create_mesh_instance(
	collection: Dictionary,
	key: int,
	node_name: String
) -> MeshInstance3D:
	if collection.has(key):
		var existing := collection[key] as MeshInstance3D
		if existing != null and is_instance_valid(existing):
			return existing
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	collection[key] = instance
	return instance


func _remove_mesh_instance(collection: Dictionary, key: int) -> void:
	if not collection.has(key):
		return
	var value = collection[key]
	collection.erase(key)
	if value is Node and is_instance_valid(value):
		(value as Node).queue_free()


func _clear_mesh_instances(collection: Dictionary) -> void:
	for key in collection.keys():
		_remove_mesh_instance(collection, int(key))
	collection.clear()


static func make_stroke_material(color: Color, is_draft: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var display_color := color
	if is_draft:
		display_color.a = minf(display_color.a, 0.58)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = display_color
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.72
	material.metallic = 0.0
	return material


static func make_idle_guide_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = IDLE_GUIDE_COLOR
	material.vertex_color_use_as_albedo = true
	material.emission_enabled = true
	material.emission = IDLE_GUIDE_COLOR
	material.emission_energy_multiplier = 1.25
	material.roughness = 0.68
	material.metallic = 0.0
	return material
