class_name VirtualAnnotationSurfaceBuilder
extends Node

signal build_started(total_surfaces: int)
signal build_progress(completed_surfaces: int, total_surfaces: int)
signal build_completed(report: Dictionary)

const ANNOTATION_SURFACE_LAYER: int = 1 << 23
const POLICY_META: StringName = &"annotation_surface_policy"
const TARGET_PATH_META: StringName = &"annotation_target_path"
const POLICY_EXCLUDE: String = "exclude"
const POLICY_BOX: String = "box"
const POLICY_CONVEX: String = "convex"
const POLICY_TRIMESH: String = "trimesh"
const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

const DEFAULT_EXCLUDED_GROUPS: Array[String] = [
	"virtual_annotation_marker",
	"virtual_annotation_surface_exclude",
	"player",
	"players",
	"pickable",
	"spatial_calibration_preview_marker",
	"remote_annotation_marker",
]

const DEFAULT_EXCLUDED_NAME_FRAGMENTS: Array[String] = [
	"canvas",
	"worktips",
	"spaceobject",
	"oldtips",
	"newtips",
	"ani_effect",
	"zhongxinjigoutips",
	"workeffect",
	"malamute",
	"player",
	"marker",
	"preview",
	"viewport",
	"functionpointer",
	"functionpickup",
]

@export var auto_build: bool = true
@export_node_path("Node3D") var shared_space_origin_path: NodePath = NodePath("../..")
@export_node_path("Node") var scan_root_path: NodePath
@export_node_path("Node") var target_root_path: NodePath
@export var include_root_paths: Array[NodePath] = []
@export var meshes_per_frame: int = 1
@export var high_poly_face_threshold: int = 30000
@export var excluded_groups: PackedStringArray = PackedStringArray(DEFAULT_EXCLUDED_GROUPS)
@export var excluded_name_fragments: PackedStringArray = PackedStringArray(DEFAULT_EXCLUDED_NAME_FRAGMENTS)

var _mesh_queue: Array[MeshInstance3D] = []
var _shape_cache: Dictionary = {}
var _convex_shape_cache: Dictionary = {}
var _proxy_entries: Array[Dictionary] = []
var _existing_body_layers: Dictionary = {}
var _existing_body_sources: Dictionary = {}
var _scan_root: Node
var _shared_origin: Node3D
var _target_root: Node
var _building: bool = false
var _ready_for_annotations: bool = false
var _total_surfaces: int = 0
var _completed_surfaces: int = 0
var _trimesh_count: int = 0
var _box_count: int = 0
var _convex_count: int = 0
var _existing_body_count: int = 0
var _excluded_count: int = 0
var _empty_mesh_count: int = 0
var _visibility_sync_seconds: float = 0.0


func _ready() -> void:
	add_to_group("virtual_annotation_surface_builder")
	set_process(false)
	if auto_build:
		call_deferred("start_build")


func _exit_tree() -> void:
	_restore_existing_body_layers()


func start_build() -> void:
	if _building or _ready_for_annotations:
		return
	_restore_existing_body_layers()
	_reset_runtime_state()
	if not _is_annotation_capable_ground():
		build_completed.emit(get_coverage_report())
		return

	_shared_origin = _resolve_shared_origin()
	_target_root = _resolve_target_root()
	_scan_root = _resolve_scan_root()
	if _shared_origin == null or _target_root == null or _scan_root == null:
		push_error("VirtualAnnotationSurfaceBuilder could not resolve its shared origin, target root, or scan root.")
		build_completed.emit(get_coverage_report())
		return

	var roots := _resolve_include_roots()
	_enable_existing_static_bodies(roots)
	_collect_meshes(roots)
	_total_surfaces = _mesh_queue.size()
	_building = true
	set_process(true)
	build_started.emit(_total_surfaces)
	if _mesh_queue.is_empty():
		_finish_build()


func rebuild() -> void:
	for entry in _proxy_entries:
		var body := entry.get("body") as StaticBody3D
		if body != null and is_instance_valid(body):
			var parent := body.get_parent()
			if parent != null:
				parent.remove_child(body)
			body.queue_free()
	_proxy_entries.clear()
	_ready_for_annotations = false
	start_build()


func is_ready_for_annotations() -> bool:
	return _ready_for_annotations


func is_building() -> bool:
	return _building


func get_annotation_surface_layer() -> int:
	return ANNOTATION_SURFACE_LAYER


func get_coverage_report() -> Dictionary:
	return {
		"ready": _ready_for_annotations,
		"building": _building,
		"total_meshes": _total_surfaces,
		"completed_meshes": _completed_surfaces,
		"trimesh_proxies": _trimesh_count,
		"convex_proxies": _convex_count,
		"box_proxies": _box_count,
		"existing_static_bodies": _existing_body_count,
		"excluded_nodes": _excluded_count,
		"empty_meshes": _empty_mesh_count,
	}


func _process(delta: float) -> void:
	if _building:
		var build_count := mini(maxi(meshes_per_frame, 1), _mesh_queue.size())
		for _index in range(build_count):
			var mesh_instance: MeshInstance3D = _mesh_queue.pop_front()
			_build_mesh_proxy(mesh_instance)
			_completed_surfaces += 1
		build_progress.emit(_completed_surfaces, _total_surfaces)
		if _mesh_queue.is_empty():
			_finish_build()

	_visibility_sync_seconds += delta
	if _visibility_sync_seconds >= 0.25:
		_visibility_sync_seconds = 0.0
		_sync_proxy_visibility()


func _collect_meshes(roots: Array[Node]) -> void:
	var seen: Dictionary = {}
	for root in roots:
		var candidates: Array[Node] = []
		if root is MeshInstance3D:
			candidates.append(root)
		candidates.append_array(root.find_children("*", "MeshInstance3D", true, false))
		for candidate in candidates:
			var mesh_instance := candidate as MeshInstance3D
			if mesh_instance == null or seen.has(mesh_instance):
				continue
			seen[mesh_instance] = true
			if _should_exclude(mesh_instance):
				_excluded_count += 1
				continue
			if mesh_instance.mesh == null:
				_empty_mesh_count += 1
				continue
			if _has_usable_existing_body(mesh_instance):
				continue
			_mesh_queue.append(mesh_instance)


func _enable_existing_static_bodies(roots: Array[Node]) -> void:
	var seen: Dictionary = {}
	for root in roots:
		var candidates: Array[Node] = []
		if root is StaticBody3D:
			candidates.append(root)
		candidates.append_array(root.find_children("*", "StaticBody3D", true, false))
		for candidate in candidates:
			var body := candidate as StaticBody3D
			if body == null or seen.has(body) or _should_exclude(body) or not _body_has_shape(body):
				continue
			seen[body] = true
			var target := _find_existing_body_target(body)
			_existing_body_layers[body] = body.collision_layer
			_existing_body_sources[body] = target
			body.collision_layer = _existing_body_collision_layer(body, target)
			body.set_meta(TARGET_PATH_META, _path_for_target(target))
			_existing_body_count += 1


func _build_mesh_proxy(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance == null or not is_instance_valid(mesh_instance) or mesh_instance.mesh == null:
		_empty_mesh_count += 1
		return
	var policy := _get_surface_policy(mesh_instance)
	if policy == POLICY_EXCLUDE:
		_excluded_count += 1
		return

	var body := StaticBody3D.new()
	body.name = "VirtualAnnotationSurface"
	body.collision_mask = 0
	body.collision_layer = ANNOTATION_SURFACE_LAYER if mesh_instance.is_visible_in_tree() else 0
	body.set_meta(TARGET_PATH_META, _path_for_target(mesh_instance))
	body.add_to_group("virtual_annotation_surface")

	var collision_shape := CollisionShape3D.new()
	var use_box := DisplayServer.get_name() == "headless" or policy == POLICY_BOX
	var use_convex := policy == POLICY_CONVEX
	if not use_box and not use_convex and policy == "":
		use_convex = _estimate_face_count(mesh_instance.mesh) > high_poly_face_threshold
	if use_box:
		var box := BoxShape3D.new()
		var bounds := mesh_instance.mesh.get_aabb()
		box.size = Vector3(
			maxf(absf(bounds.size.x), 0.002),
			maxf(absf(bounds.size.y), 0.002),
			maxf(absf(bounds.size.z), 0.002)
		)
		collision_shape.shape = box
		collision_shape.position = bounds.get_center()
		_box_count += 1
	elif use_convex:
		var convex_shape := _get_or_create_convex_shape(mesh_instance.mesh)
		if convex_shape == null:
			body.queue_free()
			_empty_mesh_count += 1
			return
		collision_shape.shape = convex_shape
		_convex_count += 1
	else:
		var shape := _get_or_create_trimesh_shape(mesh_instance.mesh)
		if shape == null:
			body.queue_free()
			_empty_mesh_count += 1
			return
		collision_shape.shape = shape
		_trimesh_count += 1

	body.add_child(collision_shape)
	mesh_instance.add_child(body)
	_proxy_entries.append({"body": body, "source": mesh_instance})


func _get_or_create_trimesh_shape(mesh: Mesh) -> ConcavePolygonShape3D:
	var cache_key := mesh.get_rid()
	if _shape_cache.has(cache_key):
		return _shape_cache[cache_key] as ConcavePolygonShape3D
	var faces := mesh.get_faces()
	if faces.size() < 3:
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	_shape_cache[cache_key] = shape
	return shape


func _get_or_create_convex_shape(mesh: Mesh) -> ConvexPolygonShape3D:
	var cache_key := mesh.get_rid()
	if _convex_shape_cache.has(cache_key):
		return _convex_shape_cache[cache_key] as ConvexPolygonShape3D
	var shape := mesh.create_convex_shape(true, true)
	if shape == null:
		return null
	_convex_shape_cache[cache_key] = shape
	return shape


func _sync_proxy_visibility() -> void:
	for entry in _proxy_entries:
		var body := entry.get("body") as StaticBody3D
		var source := entry.get("source") as MeshInstance3D
		if body == null or source == null or not is_instance_valid(body) or not is_instance_valid(source):
			continue
		body.collision_layer = ANNOTATION_SURFACE_LAYER if source.is_visible_in_tree() else 0
	for body_value in _existing_body_layers.keys():
		var body := body_value as StaticBody3D
		var source := _existing_body_sources.get(body_value) as Node3D
		if body != null and is_instance_valid(body):
			body.collision_layer = _existing_body_collision_layer(body, source)


func _finish_build() -> void:
	_building = false
	_ready_for_annotations = true
	_sync_proxy_visibility()
	build_completed.emit(get_coverage_report())


func _reset_runtime_state() -> void:
	_mesh_queue.clear()
	_shape_cache.clear()
	_convex_shape_cache.clear()
	_building = false
	_ready_for_annotations = false
	_total_surfaces = 0
	_completed_surfaces = 0
	_trimesh_count = 0
	_box_count = 0
	_convex_count = 0
	_existing_body_count = 0
	_excluded_count = 0
	_empty_mesh_count = 0


func _restore_existing_body_layers() -> void:
	for body_value in _existing_body_layers.keys():
		var body := body_value as StaticBody3D
		if body != null and is_instance_valid(body):
			body.collision_layer = int(_existing_body_layers[body_value])
	_existing_body_layers.clear()
	_existing_body_sources.clear()


func _existing_body_collision_layer(body: StaticBody3D, source: Node3D) -> int:
	var base_layer := int(_existing_body_layers.get(body, body.collision_layer))
	if source == null or source.is_visible_in_tree():
		return base_layer | ANNOTATION_SURFACE_LAYER
	return base_layer & ~ANNOTATION_SURFACE_LAYER


func _resolve_shared_origin() -> Node3D:
	if shared_space_origin_path.is_empty():
		return get_tree().current_scene as Node3D
	return get_node_or_null(shared_space_origin_path) as Node3D


func _resolve_scan_root() -> Node:
	if not scan_root_path.is_empty():
		return get_node_or_null(scan_root_path)
	return get_tree().current_scene


func _resolve_target_root() -> Node:
	if target_root_path.is_empty():
		return get_tree().current_scene
	return get_node_or_null(target_root_path)


func _resolve_include_roots() -> Array[Node]:
	var roots: Array[Node] = []
	if include_root_paths.is_empty():
		roots.append(_scan_root)
		return roots
	for path in include_root_paths:
		var root := _scan_root.get_node_or_null(path)
		if root != null:
			roots.append(root)
	return roots


func _should_exclude(node: Node) -> bool:
	var current: Node = node
	while current != null:
		var policy := str(current.get_meta(POLICY_META, "")).to_lower()
		if policy == POLICY_EXCLUDE:
			return true
		for group_name in excluded_groups:
			if current.is_in_group(group_name):
				return true
		var lower_name := current.name.to_lower()
		for fragment in excluded_name_fragments:
			if lower_name.contains(fragment.to_lower()):
				return true
		if current is RigidBody3D or current is CharacterBody3D or current is AnimatableBody3D:
			return true
		if current is XROrigin3D or current is XRController3D or current is XRCamera3D:
			return true
		var current_script := current.get_script() as Script
		if current_script != null and str(current_script.resource_path).ends_with("/player.gd"):
			return true
		if current.has_node("NetworkHead") and current.has_node("NetworkLeftHand") and current.has_node("NetworkRightHand"):
			return true
		if current == _scan_root:
			break
		current = current.get_parent()
	return false


func _get_surface_policy(node: Node) -> String:
	var current: Node = node
	while current != null:
		var policy := str(current.get_meta(POLICY_META, "")).to_lower()
		if policy in [POLICY_EXCLUDE, POLICY_BOX, POLICY_CONVEX, POLICY_TRIMESH]:
			return policy
		if current.is_in_group("virtual_annotation_surface_low_poly"):
			return POLICY_CONVEX
		if current.is_in_group("virtual_annotation_surface_box"):
			return POLICY_BOX
		if current.is_in_group("virtual_annotation_surface_precise"):
			return POLICY_TRIMESH
		if current == _scan_root:
			break
		current = current.get_parent()
	return ""


func _has_usable_existing_body(mesh_instance: MeshInstance3D) -> bool:
	var parent := mesh_instance.get_parent()
	if parent == null:
		return false
	for child in parent.get_children():
		if child is StaticBody3D and _body_has_shape(child as StaticBody3D) and not _should_exclude(child):
			return true
	return false


func _body_has_shape(body: StaticBody3D) -> bool:
	if body == null:
		return false
	for child in body.find_children("*", "CollisionShape3D", true, false):
		var collision_shape := child as CollisionShape3D
		if collision_shape != null and collision_shape.shape != null and not collision_shape.disabled:
			return true
	return false


func _find_existing_body_target(body: StaticBody3D) -> Node3D:
	var parent := body.get_parent() as Node3D
	if parent != null:
		for child in parent.get_children():
			if child is MeshInstance3D:
				return child as MeshInstance3D
	return parent


func _path_for_target(target: Node3D) -> String:
	if target == null or _target_root == null or target == _target_root:
		return ""
	if not _target_root.is_ancestor_of(target):
		return ""
	return str(_target_root.get_path_to(target))


func _estimate_face_count(mesh: Mesh) -> int:
	var count := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_INDEX:
			continue
		var indices = arrays[Mesh.ARRAY_INDEX]
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		if indices is PackedInt32Array and not (indices as PackedInt32Array).is_empty():
			count += (indices as PackedInt32Array).size() / 3
		elif vertices is PackedVector3Array:
			count += (vertices as PackedVector3Array).size() / 3
	return count


func _is_annotation_capable_ground() -> bool:
	var profile = RuntimeProfile.current()
	return profile.is_ground()
