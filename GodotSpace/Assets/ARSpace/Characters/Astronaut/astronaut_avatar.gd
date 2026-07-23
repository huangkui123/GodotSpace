extends Node3D

const PoseState = preload("res://Assets/ARSpace/Characters/Astronaut/avatar_pose_state.gd")

const MODEL_BASE_SCALE: float = 10.0
const REFERENCE_EYE_HEIGHT: float = 1.70
const MIN_HEIGHT_SCALE: float = 0.78
const MAX_HEIGHT_SCALE: float = 1.22
const TRACKING_BLEND_SECONDS: float = 0.25
const POSE_SMOOTH_SPEED: float = 14.0
const BODY_ANCHOR_SMOOTH_SPEED: float = 10.0
const BODY_ANCHOR_SNAP_DISTANCE_M: float = 0.5
const FULL_BODY_MESHES: Array[StringName] = [
	&"Basemesh", &"TORSO", &"HELMET_GLASS", &"HELMET",
	&"GLOVES", &"PANT", &"DETAIL", &"STRIP",
]
const LOCAL_HIDDEN_MESHES: Array[StringName] = [&"HELMET", &"HELMET_GLASS", &"Basemesh"]
const UNITY_MATERIAL_OVERRIDES: Dictionary = {
	&"Basemesh": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/basemesh.tres"),
	&"TORSO": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/torso.tres"),
	&"HELMET_GLASS": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/helmet_glass.tres"),
	&"HELMET": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/helmet.tres"),
	&"GLOVES": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/gloves.tres"),
	&"PANT": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/pant.tres"),
	&"DETAIL": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/detail.tres"),
	&"STRIP": preload("res://Assets/ARSpace/Characters/Astronaut/Materials/strip.tres"),
}

const REQUIRED_BONES: Array[StringName] = [
	&"Hips", &"Spine", &"Spine1TMP", &"Spine2TMP", &"NeckTMP", &"HeadTMP",
	&"LeftShoulder", &"LeftArm", &"LeftForeArm", &"LeftHand",
	&"RightShoulder", &"RightArm", &"RightForeArm", &"RightHand",
]

@export var model_root_path: NodePath = NodePath("ImportedModel")
@export var label_path: NodePath = NodePath("RoleLabel")
@export var head_local_offset: Vector3 = Vector3(0.0, -0.08, 0.02)
@export var left_hand_local_offset: Vector3 = Vector3(0.0, 0.0, 0.04)
@export var right_hand_local_offset: Vector3 = Vector3(0.0, 0.0, 0.04)

var _head_target: Node3D
var _left_hand_target: Node3D
var _right_hand_target: Node3D
var _model_root: Node3D
var _skeleton: Skeleton3D
var _bone_indices: Dictionary = {}
var _bone_global_rests: Dictionary = {}
var _pose_state: Dictionary = PoseState.make_default()
var _smoothed_head: Transform3D = Transform3D.IDENTITY
var _smoothed_left_hand: Transform3D = Transform3D.IDENTITY
var _smoothed_right_hand: Transform3D = Transform3D.IDENTITY
var _has_smoothed_pose: bool = false
var _left_tracking_weight: float = 1.0
var _right_tracking_weight: float = 1.0
var _height_scale: float = 1.0
var _shoulder_width: float = 0.42
var _local_presentation: bool = false
var _body_floor_local_y: float = 0.0
var _has_body_anchor: bool = false

func _ready() -> void:
	_body_floor_local_y = position.y
	_model_root = get_node_or_null(model_root_path) as Node3D
	_bind_skeleton()
	_apply_full_body_visibility()
	_apply_source_materials()
	_apply_local_visibility()

func _exit_tree() -> void:
	if is_instance_valid(_skeleton) and _skeleton.has_method("clear_bones_global_pose_override"):
		_skeleton.call("clear_bones_global_pose_override")

func _process(delta: float) -> void:
	if _skeleton == null:
		_bind_skeleton()
	if _skeleton == null or _head_target == null:
		return
	_update_smoothed_targets(delta)
	_update_body_anchor(delta)
	_update_calibration(delta)
	_drive_skeleton()

func set_tracking_targets(head: Node3D, left_hand: Node3D, right_hand: Node3D) -> void:
	_head_target = head
	_left_hand_target = left_hand
	_right_hand_target = right_hand
	_has_smoothed_pose = false
	_has_body_anchor = false

func set_pose_state(state: Dictionary) -> bool:
	var normalized := PoseState.normalize(state)
	if normalized.is_empty():
		return false
	_pose_state = normalized
	return true

func set_local_presentation(enabled: bool) -> void:
	_local_presentation = enabled
	_apply_local_visibility()

func set_role_label(text: String, color: Color) -> void:
	var label := get_node_or_null(label_path) as Label3D
	if label != null:
		label.text = text
		label.modulate = color

func is_model_ready() -> bool:
	return _skeleton != null and _bone_indices.size() == REQUIRED_BONES.size()

func get_debug_state() -> Dictionary:
	return {
		"model_ready": is_model_ready(),
		"bone_count": _skeleton.get_bone_count() if _skeleton != null else 0,
		"height_scale": _height_scale,
		"shoulder_width": _shoulder_width,
		"left_tracking_weight": _left_tracking_weight,
		"right_tracking_weight": _right_tracking_weight,
		"left_hand_position": _smoothed_left_hand.origin,
		"right_hand_position": _smoothed_right_hand.origin,
	}

func solve_two_bone_positions(
	shoulder_position: Vector3,
	wrist_position: Vector3,
	upper_length: float,
	lower_length: float,
	is_left: bool,
	pole_hint: Vector3 = Vector3.ZERO
) -> Dictionary:
	if upper_length <= 0.0001 or lower_length <= 0.0001:
		return {}
	var to_wrist := wrist_position - shoulder_position
	var raw_distance := to_wrist.length()
	var direction := to_wrist / raw_distance if raw_distance > 0.0001 else Vector3.FORWARD
	var minimum_distance := absf(upper_length - lower_length) + 0.001
	var maximum_distance := (upper_length + lower_length) * 0.985
	var distance := clampf(raw_distance, minimum_distance, maximum_distance)
	var solved_wrist := shoulder_position + direction * distance
	var cos_angle := clampf(
		(upper_length * upper_length + distance * distance - lower_length * lower_length) \
			/ (2.0 * upper_length * distance),
		-1.0,
		1.0
	)
	var along := upper_length * cos_angle
	var outward := sqrt(maxf(upper_length * upper_length - along * along, 0.0))
	var side := -1.0 if is_left else 1.0
	var pole := pole_hint if pole_hint.length_squared() >= 0.0001 else Vector3(side, -0.35, -0.45)
	pole -= direction * pole.dot(direction)
	if pole.length_squared() < 0.0001:
		pole = Vector3.UP.cross(direction)
	if pole.length_squared() < 0.0001:
		pole = Vector3.RIGHT
	pole = pole.normalized()
	return {
		"elbow": shoulder_position + direction * along + pole * outward,
		"wrist": solved_wrist,
		"reach_ratio": distance / maxf(upper_length + lower_length, 0.0001),
	}

func _bind_skeleton() -> void:
	if _model_root == null:
		_model_root = get_node_or_null(model_root_path) as Node3D
	if _model_root == null:
		return
	_skeleton = _find_skeleton(_model_root)
	if _skeleton == null:
		return
	_bone_indices.clear()
	_bone_global_rests.clear()
	for bone_name in REQUIRED_BONES:
		var bone_index := _skeleton.find_bone(bone_name)
		if bone_index < 0:
			push_error("Astronaut skeleton is missing bone: %s" % bone_name)
			_skeleton = null
			return
		_bone_indices[bone_name] = bone_index
	for bone_index in _skeleton.get_bone_count():
		_bone_global_rests[bone_index] = _calculate_global_rest(bone_index)

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null

func _calculate_global_rest(bone_index: int) -> Transform3D:
	var chain: Array[int] = []
	var current := bone_index
	while current >= 0:
		chain.push_front(current)
		current = _skeleton.get_bone_parent(current)
	var result := Transform3D.IDENTITY
	for index in chain:
		result *= _skeleton.get_bone_rest(index)
	return result

func _update_smoothed_targets(delta: float) -> void:
	var head_transform := _target_transform_with_offset(_head_target, head_local_offset)
	if not _has_smoothed_pose:
		_smoothed_head = head_transform
		_smoothed_left_hand = _fallback_hand_transform(head_transform, true)
		_smoothed_right_hand = _fallback_hand_transform(head_transform, false)
		if _left_hand_target != null:
			_smoothed_left_hand = _target_transform_with_offset(_left_hand_target, left_hand_local_offset)
		if _right_hand_target != null:
			_smoothed_right_hand = _target_transform_with_offset(_right_hand_target, right_hand_local_offset)
		_has_smoothed_pose = true

	var left_tracked := PoseState.has_tracking(_pose_state, PoseState.TRACKING_LEFT_HAND) \
		and _left_hand_target != null
	var right_tracked := PoseState.has_tracking(_pose_state, PoseState.TRACKING_RIGHT_HAND) \
		and _right_hand_target != null
	_left_tracking_weight = move_toward(
		_left_tracking_weight,
		1.0 if left_tracked else 0.0,
		delta / TRACKING_BLEND_SECONDS
	)
	_right_tracking_weight = move_toward(
		_right_tracking_weight,
		1.0 if right_tracked else 0.0,
		delta / TRACKING_BLEND_SECONDS
	)

	var left_target := _target_transform_with_offset(_left_hand_target, left_hand_local_offset) \
		if left_tracked else _fallback_hand_transform(head_transform, true)
	var right_target := _target_transform_with_offset(_right_hand_target, right_hand_local_offset) \
		if right_tracked else _fallback_hand_transform(head_transform, false)
	var blend := 1.0 - exp(-POSE_SMOOTH_SPEED * maxf(delta, 0.0))
	_smoothed_head = _smoothed_head.interpolate_with(head_transform, blend)
	_smoothed_left_hand = _smoothed_left_hand.interpolate_with(left_target, blend)
	_smoothed_right_hand = _smoothed_right_hand.interpolate_with(right_target, blend)

func _target_transform_with_offset(target: Node3D, offset: Vector3) -> Transform3D:
	if target == null:
		return Transform3D.IDENTITY
	var result := target.global_transform
	result.origin += result.basis * offset
	result.basis = result.basis.orthonormalized()
	return result

func _fallback_hand_transform(head: Transform3D, is_left: bool) -> Transform3D:
	var side := -1.0 if is_left else 1.0
	var result := head
	result.origin += head.basis * Vector3(0.28 * side, -0.38, -0.08)
	return result

func _update_body_anchor(delta: float) -> void:
	var parent_3d := get_parent_node_3d()
	var floor_origin := Vector3(0.0, _body_floor_local_y, 0.0)
	var floor_up := Vector3.UP
	if parent_3d != null:
		floor_origin = parent_3d.global_transform * floor_origin
		floor_up = parent_3d.global_transform.basis.y.normalized()
	var head_forward := -_smoothed_head.basis.z
	head_forward -= floor_up * head_forward.dot(floor_up)
	if head_forward.length_squared() < 0.0001:
		head_forward = -global_transform.basis.z
		head_forward -= floor_up * head_forward.dot(floor_up)
	if head_forward.length_squared() < 0.0001:
		head_forward = Vector3.FORWARD
	head_forward = head_forward.normalized()
	var target_origin := _smoothed_head.origin
	target_origin -= floor_up * (target_origin - floor_origin).dot(floor_up)
	var target_transform := Transform3D(
		Basis.looking_at(head_forward, floor_up).orthonormalized(),
		target_origin
	)
	if not _has_body_anchor:
		global_transform = target_transform
		_has_body_anchor = true
		return
	if global_position.distance_to(target_origin) >= BODY_ANCHOR_SNAP_DISTANCE_M:
		global_transform = target_transform
		return
	var blend := 1.0 - exp(-BODY_ANCHOR_SMOOTH_SPEED * maxf(delta, 0.0))
	global_transform = global_transform.interpolate_with(target_transform, blend)
	global_transform.basis = global_transform.basis.orthonormalized()

func _update_calibration(delta: float) -> void:
	var head_local := global_transform.affine_inverse() * _smoothed_head.origin
	var target_height_scale := clampf(head_local.y / REFERENCE_EYE_HEIGHT, MIN_HEIGHT_SCALE, MAX_HEIGHT_SCALE)
	var calibration_blend := 1.0 - exp(-3.0 * maxf(delta, 0.0))
	_height_scale = lerpf(_height_scale, target_height_scale, calibration_blend)
	var hand_span := _smoothed_left_hand.origin.distance_to(_smoothed_right_hand.origin)
	var target_shoulder_width := clampf(hand_span * 0.34, 0.34, 0.50)
	_shoulder_width = lerpf(_shoulder_width, target_shoulder_width, calibration_blend)
	if _model_root != null:
		_model_root.scale = Vector3.ONE * MODEL_BASE_SCALE * _height_scale

func _drive_skeleton() -> void:
	var inverse_skeleton := _skeleton.global_transform.affine_inverse()
	var head_rest := _bone_global_rests[int(_bone_indices[&"HeadTMP"])] as Transform3D
	var head_pose := inverse_skeleton * _smoothed_head
	head_pose.basis = _retarget_tracker_basis(head_rest.basis, _smoothed_head.basis)
	_set_global_override(&"HeadTMP", head_pose, 1.0)

	var head_forward := -_smoothed_head.basis.z
	head_forward.y = 0.0
	if head_forward.length_squared() < 0.0001:
		head_forward = Vector3.FORWARD
	head_forward = head_forward.normalized()
	var spine_rest := _bone_global_rests[int(_bone_indices[&"Spine2TMP"])] as Transform3D
	var neutral_forward := -global_transform.basis.orthonormalized().z
	neutral_forward.y = 0.0
	if neutral_forward.length_squared() < 0.0001:
		neutral_forward = Vector3.FORWARD
	neutral_forward = neutral_forward.normalized()
	var torso_world_delta := _rotation_between(neutral_forward, head_forward)
	var torso_pose := spine_rest
	torso_pose.basis = _retarget_rest_basis(spine_rest.basis, torso_world_delta)
	_set_global_override(&"Spine2TMP", torso_pose, 0.72)

	var lateral := _smoothed_head.basis.x.normalized()
	var shoulder_center := _smoothed_head.origin + Vector3(0.0, -0.24, 0.015)
	var left_shoulder_world := shoulder_center - lateral * (_shoulder_width * 0.5)
	var right_shoulder_world := shoulder_center + lateral * (_shoulder_width * 0.5)
	var left_pole_world := -lateral + Vector3.DOWN * 0.35 + head_forward * 0.45
	var right_pole_world := lateral + Vector3.DOWN * 0.35 + head_forward * 0.45
	_solve_arm(true, left_shoulder_world, _smoothed_left_hand, left_pole_world)
	_solve_arm(false, right_shoulder_world, _smoothed_right_hand, right_pole_world)
	_apply_finger_curl(true)
	_apply_finger_curl(false)

func _solve_arm(
	is_left: bool,
	shoulder_world: Vector3,
	wrist_world: Transform3D,
	pole_world: Vector3
) -> void:
	var upper_name: StringName = &"LeftArm" if is_left else &"RightArm"
	var lower_name: StringName = &"LeftForeArm" if is_left else &"RightForeArm"
	var hand_name: StringName = &"LeftHand" if is_left else &"RightHand"
	var upper_index := int(_bone_indices[upper_name])
	var lower_index := int(_bone_indices[lower_name])
	var hand_index := int(_bone_indices[hand_name])
	var upper_rest := _bone_global_rests[upper_index] as Transform3D
	var lower_rest := _bone_global_rests[lower_index] as Transform3D
	var hand_rest := _bone_global_rests[hand_index] as Transform3D
	var skeleton_basis := _skeleton.global_transform.basis
	var upper_length := (skeleton_basis * (lower_rest.origin - upper_rest.origin)).length()
	var lower_length := (skeleton_basis * (hand_rest.origin - lower_rest.origin)).length()
	var solution := solve_two_bone_positions(
		shoulder_world,
		wrist_world.origin,
		upper_length,
		lower_length,
		is_left,
		pole_world
	)
	if solution.is_empty():
		return
	var inverse_skeleton := _skeleton.global_transform.affine_inverse()
	var shoulder_position := inverse_skeleton * shoulder_world
	var elbow_position := inverse_skeleton * (solution["elbow"] as Vector3)
	var wrist_pose := inverse_skeleton * wrist_world
	wrist_pose.origin = inverse_skeleton * (solution["wrist"] as Vector3)

	var upper_pose := Transform3D(
		_align_rest_basis(upper_rest.basis, lower_rest.origin - upper_rest.origin, elbow_position - shoulder_position),
		shoulder_position
	)
	var lower_pose := Transform3D(
		_align_rest_basis(lower_rest.basis, hand_rest.origin - lower_rest.origin, wrist_pose.origin - elbow_position),
		elbow_position
	)
	var hand_pose := wrist_pose
	hand_pose.basis = _retarget_tracker_basis(hand_rest.basis, wrist_world.basis)
	_skeleton.set_bone_global_pose_override(upper_index, upper_pose, 1.0, true)
	_skeleton.set_bone_global_pose_override(lower_index, lower_pose, 1.0, true)
	_skeleton.set_bone_global_pose_override(hand_index, hand_pose, 1.0, true)

func _align_rest_basis(rest_basis: Basis, rest_direction: Vector3, target_direction: Vector3) -> Basis:
	if rest_direction.length_squared() < 0.0001 or target_direction.length_squared() < 0.0001:
		return rest_basis
	return (_rotation_between(rest_direction, target_direction) * rest_basis).orthonormalized()

func _rotation_between(from_direction: Vector3, to_direction: Vector3) -> Basis:
	if from_direction.length_squared() < 0.0001 or to_direction.length_squared() < 0.0001:
		return Basis.IDENTITY
	var from_normalized := from_direction.normalized()
	var to_normalized := to_direction.normalized()
	var cosine := clampf(from_normalized.dot(to_normalized), -1.0, 1.0)
	if cosine >= 0.999999:
		return Basis.IDENTITY
	if cosine <= -0.999999:
		var axis := from_normalized.cross(Vector3.UP)
		if axis.length_squared() < 0.0001:
			axis = from_normalized.cross(Vector3.RIGHT)
		return Basis(Quaternion(axis.normalized(), PI))
	var axis := from_normalized.cross(to_normalized).normalized()
	return Basis(Quaternion(axis, acos(cosine)))

func _retarget_tracker_basis(rest_basis: Basis, tracker_world_basis: Basis) -> Basis:
	var avatar_world_basis := global_transform.basis.orthonormalized()
	var tracker_delta_world := tracker_world_basis.orthonormalized() * avatar_world_basis.inverse()
	return _retarget_rest_basis(rest_basis, tracker_delta_world)

func _retarget_rest_basis(rest_basis: Basis, world_delta: Basis) -> Basis:
	var skeleton_world_basis := _skeleton.global_transform.basis.orthonormalized()
	return (
		skeleton_world_basis.inverse()
		* world_delta.orthonormalized()
		* skeleton_world_basis
		* rest_basis
	).orthonormalized()

func _apply_finger_curl(is_left: bool) -> void:
	var grip_key := "left_grip_q" if is_left else "right_grip_q"
	var trigger_key := "left_trigger_q" if is_left else "right_trigger_q"
	var curl := maxf(PoseState.dequantize_axis(_pose_state[grip_key]), PoseState.dequantize_axis(_pose_state[trigger_key]))
	var prefix := "Left" if is_left else "Right"
	var direction := -1.0 if is_left else 1.0
	for segment in range(1, 4):
		var bone_index := _skeleton.find_bone(StringName("%sHandIndex%d" % [prefix, segment]))
		if bone_index >= 0:
			_skeleton.set_bone_pose_rotation(bone_index, Quaternion(Vector3.FORWARD, direction * curl * 0.55))

func _set_global_override(bone_name: StringName, pose: Transform3D, weight: float) -> void:
	var bone_index := int(_bone_indices[bone_name])
	_skeleton.set_bone_global_pose_override(bone_index, pose, clampf(weight, 0.0, 1.0), true)

func _apply_local_visibility() -> void:
	if _model_root == null:
		return
	for mesh_name in LOCAL_HIDDEN_MESHES:
		var mesh := _model_root.find_child(mesh_name, true, false) as MeshInstance3D
		if mesh != null:
			mesh.visible = not _local_presentation

func _apply_full_body_visibility() -> void:
	if _model_root == null:
		return
	for mesh_name in FULL_BODY_MESHES:
		var mesh := _model_root.find_child(mesh_name, true, false) as MeshInstance3D
		if mesh != null:
			mesh.visible = true

func _apply_source_materials() -> void:
	if _model_root == null:
		return
	for mesh_name: StringName in UNITY_MATERIAL_OVERRIDES:
		var mesh := _model_root.find_child(mesh_name, true, false) as MeshInstance3D
		if mesh != null:
			mesh.set_surface_override_material(0, UNITY_MATERIAL_OVERRIDES[mesh_name] as Material)
