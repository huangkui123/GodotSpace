extends Node3D

const PoseState = preload("res://Assets/ARSpace/Characters/Astronaut/avatar_pose_state.gd")

const MODEL_BASE_SCALE: float = 10.0
const REFERENCE_EYE_HEIGHT: float = 1.70
const MIN_HEIGHT_SCALE: float = 0.78
const MAX_HEIGHT_SCALE: float = 1.22
const TRACKING_BLEND_SECONDS: float = 0.25
const POSE_SMOOTH_SPEED: float = 14.0

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

func _ready() -> void:
	_model_root = get_node_or_null(model_root_path) as Node3D
	_bind_skeleton()
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
	_update_calibration(delta)
	_drive_skeleton()

func set_tracking_targets(head: Node3D, left_hand: Node3D, right_hand: Node3D) -> void:
	_head_target = head
	_left_hand_target = left_hand
	_right_hand_target = right_hand
	_has_smoothed_pose = false

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
	is_left: bool
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
	var pole := Vector3(side, -0.35, -0.45)
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
	var head_pose := inverse_skeleton * _smoothed_head
	head_pose.basis = head_pose.basis.orthonormalized()
	_set_global_override(&"HeadTMP", head_pose, 1.0)

	var head_forward := -_smoothed_head.basis.z
	head_forward.y = 0.0
	if head_forward.length_squared() < 0.0001:
		head_forward = Vector3.FORWARD
	head_forward = head_forward.normalized()
	var torso_world := Transform3D(Basis.looking_at(head_forward, Vector3.UP), _smoothed_head.origin + Vector3(0.0, -0.48, 0.02))
	var torso_pose := inverse_skeleton * torso_world
	var spine_rest := _bone_global_rests[int(_bone_indices[&"Spine2TMP"])] as Transform3D
	torso_pose.origin = spine_rest.origin
	_set_global_override(&"Spine2TMP", torso_pose, 0.72)

	var lateral := _smoothed_head.basis.x.normalized()
	var shoulder_center := _smoothed_head.origin + Vector3(0.0, -0.24, 0.015)
	var left_shoulder_world := shoulder_center - lateral * (_shoulder_width * 0.5)
	var right_shoulder_world := shoulder_center + lateral * (_shoulder_width * 0.5)
	_solve_arm(true, inverse_skeleton * left_shoulder_world, inverse_skeleton * _smoothed_left_hand)
	_solve_arm(false, inverse_skeleton * right_shoulder_world, inverse_skeleton * _smoothed_right_hand)
	_apply_finger_curl(true)
	_apply_finger_curl(false)

func _solve_arm(is_left: bool, shoulder_position: Vector3, wrist_pose: Transform3D) -> void:
	var upper_name: StringName = &"LeftArm" if is_left else &"RightArm"
	var lower_name: StringName = &"LeftForeArm" if is_left else &"RightForeArm"
	var hand_name: StringName = &"LeftHand" if is_left else &"RightHand"
	var upper_index := int(_bone_indices[upper_name])
	var lower_index := int(_bone_indices[lower_name])
	var hand_index := int(_bone_indices[hand_name])
	var upper_rest := _bone_global_rests[upper_index] as Transform3D
	var lower_rest := _bone_global_rests[lower_index] as Transform3D
	var hand_rest := _bone_global_rests[hand_index] as Transform3D
	var upper_length := upper_rest.origin.distance_to(lower_rest.origin)
	var lower_length := lower_rest.origin.distance_to(hand_rest.origin)
	var solution := solve_two_bone_positions(
		shoulder_position,
		wrist_pose.origin,
		upper_length,
		lower_length,
		is_left
	)
	if solution.is_empty():
		return
	var elbow_position := solution["elbow"] as Vector3
	wrist_pose.origin = solution["wrist"] as Vector3

	var upper_pose := Transform3D(
		_align_rest_basis(upper_rest.basis, lower_rest.origin - upper_rest.origin, elbow_position - shoulder_position),
		shoulder_position
	)
	var lower_pose := Transform3D(
		_align_rest_basis(lower_rest.basis, hand_rest.origin - lower_rest.origin, wrist_pose.origin - elbow_position),
		elbow_position
	)
	var hand_pose := wrist_pose
	hand_pose.basis = hand_pose.basis.orthonormalized()
	_skeleton.set_bone_global_pose_override(upper_index, upper_pose, 1.0, true)
	_skeleton.set_bone_global_pose_override(lower_index, lower_pose, 1.0, true)
	_skeleton.set_bone_global_pose_override(hand_index, hand_pose, 1.0, true)

func _align_rest_basis(rest_basis: Basis, rest_direction: Vector3, target_direction: Vector3) -> Basis:
	if rest_direction.length_squared() < 0.0001 or target_direction.length_squared() < 0.0001:
		return rest_basis
	var rotation := Quaternion(rest_direction.normalized(), target_direction.normalized())
	return (Basis(rotation) * rest_basis).orthonormalized()

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
	for mesh_name in [&"HELMET", &"HELMET_GLASS", &"Basemesh"]:
		var mesh := _model_root.find_child(mesh_name, true, false) as MeshInstance3D
		if mesh != null:
			mesh.visible = not _local_presentation
