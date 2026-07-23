extends RefCounted

const DEFAULT_HEAD_DISTANCE_M: float = 1.5
const DEFAULT_VERTICAL_OFFSET_M: float = -0.15
const DEFAULT_WINDOW_GAP_M: float = 0.12
const OVERLAP_MARGIN_M: float = 0.08
const FALLBACK_FORWARD: Vector3 = Vector3(0.0, 0.0, -1.0)


static func calculate_spawn_transform(
	window_controller: Node,
	parent_controller: Node,
	dock_manager: Node,
	viewpoint: Node3D
) -> Transform3D:
	var current_transform := _get_window_transform(window_controller)
	var window_scale := current_transform.basis.get_scale()
	var window_size := _get_window_size(window_controller)
	var parent := parent_controller
	if parent == null and dock_manager != null and dock_manager.has_method("get_last_focused_window"):
		parent = dock_manager.call("get_last_focused_window", window_controller) as Node

	var base_transform := current_transform
	var spawn_anchor := _get_spawn_anchor(parent)
	if spawn_anchor != null:
		base_transform = _transform_with_scale(spawn_anchor.global_transform, window_scale)
	elif parent != null and is_instance_valid(parent):
		var parent_transform := _get_window_transform(parent)
		var parent_size := _get_window_size(parent)
		var right := _safe_axis(parent_transform.basis.x, Vector3.RIGHT)
		var offset := (parent_size.x + window_size.x) * 0.5 + DEFAULT_WINDOW_GAP_M
		base_transform.origin = parent_transform.origin + right * offset
		base_transform.basis = _face_user_basis(
			base_transform.origin,
			_get_viewpoint_position(viewpoint, parent_transform.origin - parent_transform.basis.z),
			window_scale,
			parent_transform.basis
		)
	else:
		var head_transform := viewpoint.global_transform if viewpoint != null else Transform3D.IDENTITY
		var forward := _safe_axis(-head_transform.basis.z, FALLBACK_FORWARD)
		var up := _safe_axis(head_transform.basis.y, Vector3.UP)
		base_transform.origin = head_transform.origin \
			+ forward * DEFAULT_HEAD_DISTANCE_M \
			+ up * DEFAULT_VERTICAL_OFFSET_M
		base_transform.basis = _face_user_basis(
			base_transform.origin,
			head_transform.origin,
			window_scale,
			current_transform.basis
		)

	if not _is_finite_transform(base_transform):
		base_transform = Transform3D(
			Basis.IDENTITY.scaled(_safe_scale(window_scale)),
			Vector3(0.0, 1.35, -DEFAULT_HEAD_DISTANCE_M)
		)
	return _find_non_overlapping_transform(
		base_transform,
		window_size,
		window_controller,
		dock_manager
	)


static func _find_non_overlapping_transform(
	base_transform: Transform3D,
	window_size: Vector2,
	window_controller: Node,
	dock_manager: Node
) -> Transform3D:
	if dock_manager == null or not dock_manager.has_method("get_registered_windows"):
		return base_transform
	var right := _safe_axis(base_transform.basis.x, Vector3.RIGHT)
	var down := -_safe_axis(base_transform.basis.y, Vector3.UP)
	var horizontal_step := maxf(window_size.x + DEFAULT_WINDOW_GAP_M, 0.35)
	var vertical_step := maxf(window_size.y * 0.55, 0.25)
	var offsets: Array[Vector3] = [
		Vector3.ZERO,
		right * horizontal_step,
		-right * horizontal_step,
		down * vertical_step,
		right * horizontal_step + down * vertical_step,
		-right * horizontal_step + down * vertical_step,
		down * vertical_step * 2.0,
	]
	for offset in offsets:
		var candidate := base_transform
		candidate.origin += offset
		if not _overlaps_existing(candidate.origin, window_size, window_controller, dock_manager):
			return candidate
	return base_transform


static func _overlaps_existing(
	position: Vector3,
	window_size: Vector2,
	window_controller: Node,
	dock_manager: Node
) -> bool:
	var windows: Array = dock_manager.call("get_registered_windows")
	for other_value in windows:
		var other := other_value as Node
		if other == null or other == window_controller or not is_instance_valid(other):
			continue
		if other.has_method("is_window_open") and not bool(other.call("is_window_open")):
			continue
		var other_transform := _get_window_transform(other)
		var other_size := _get_window_size(other)
		var required_distance := maxf(
			(window_size.x + other_size.x) * 0.5 + OVERLAP_MARGIN_M,
			(window_size.y + other_size.y) * 0.5 + OVERLAP_MARGIN_M
		)
		if position.distance_to(other_transform.origin) < required_distance:
			return true
	return false


static func _get_spawn_anchor(controller: Node) -> Node3D:
	if controller != null \
			and is_instance_valid(controller) \
			and controller.has_method("get_child_spawn_anchor"):
		return controller.call("get_child_spawn_anchor") as Node3D
	return null


static func _get_window_transform(controller: Node) -> Transform3D:
	if controller != null and is_instance_valid(controller):
		if controller.has_method("get_window_global_transform"):
			return controller.call("get_window_global_transform") as Transform3D
		if controller is Node3D:
			return (controller as Node3D).global_transform
	return Transform3D.IDENTITY


static func _get_window_size(controller: Node) -> Vector2:
	if controller != null \
			and is_instance_valid(controller) \
			and controller.has_method("get_window_size_m"):
		var size_value = controller.call("get_window_size_m")
		if size_value is Vector2:
			var size := size_value as Vector2
			return Vector2(maxf(size.x, 0.05), maxf(size.y, 0.05))
	return Vector2(0.8, 0.5)


static func _get_viewpoint_position(viewpoint: Node3D, fallback: Vector3) -> Vector3:
	return viewpoint.global_position if viewpoint != null else fallback


static func _transform_with_scale(source: Transform3D, scale_value: Vector3) -> Transform3D:
	var result := source
	result.basis = source.basis.orthonormalized().scaled(_safe_scale(scale_value))
	return result


static func _face_user_basis(
	position: Vector3,
	user_position: Vector3,
	scale_value: Vector3,
	fallback_basis: Basis
) -> Basis:
	var to_user := user_position - position
	if to_user.length_squared() < 0.000001:
		return fallback_basis.orthonormalized().scaled(_safe_scale(scale_value))
	var forward := to_user.normalized()
	var right := Vector3.UP.cross(forward)
	if right.length_squared() < 0.000001:
		right = _safe_axis(fallback_basis.x, Vector3.RIGHT)
	else:
		right = right.normalized()
	var up := forward.cross(right).normalized()
	return Basis(right, up, forward).scaled(_safe_scale(scale_value))


static func _safe_axis(value: Vector3, fallback: Vector3) -> Vector3:
	if not _is_finite_vector(value) or value.length_squared() < 0.000001:
		return fallback
	return value.normalized()


static func _safe_scale(value: Vector3) -> Vector3:
	if not _is_finite_vector(value):
		return Vector3.ONE
	return Vector3(
		maxf(absf(value.x), 0.0001),
		maxf(absf(value.y), 0.0001),
		maxf(absf(value.z), 0.0001)
	)


static func _is_finite_transform(value: Transform3D) -> bool:
	return _is_finite_vector(value.origin) \
		and _is_finite_vector(value.basis.x) \
		and _is_finite_vector(value.basis.y) \
		and _is_finite_vector(value.basis.z)


static func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
