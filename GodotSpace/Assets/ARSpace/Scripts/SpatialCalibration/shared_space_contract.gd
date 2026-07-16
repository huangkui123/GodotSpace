class_name SharedSpaceContract
extends RefCounted

## Shared-space coordinates are always local to the one SharedSpaceOrigin node.
## The origin transform maps shared-local coordinates to Godot world coordinates.
## Calibration commits replace this absolute transform; callers must never add a
## delta to the previously committed transform.

const MAX_SHARED_DISTANCE_METERS: float = 50.0
const CONTRACT_VERSION: int = 1
const COORDINATE_SPACE: String = "shared_local"
const MAX_WORLD_DISTANCE_METERS: float = 250.0
const MAX_ORIGIN_DISTANCE_METERS: float = 100.0
const UNIT_SCALE_TOLERANCE: float = 0.002
const ORTHOGONAL_TOLERANCE: float = 0.002
const MIN_NORMAL_LENGTH: float = 0.0001


static func is_finite_number(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


static func is_finite_vector2(value: Vector2) -> bool:
	return is_finite_number(value.x) and is_finite_number(value.y)


static func is_finite_vector3(value: Vector3) -> bool:
	return is_finite_number(value.x) \
		and is_finite_number(value.y) \
		and is_finite_number(value.z)


static func is_valid_shared_point(value: Vector3) -> bool:
	return is_finite_vector3(value) and value.length() <= MAX_SHARED_DISTANCE_METERS


static func is_valid_world_point(value: Vector3) -> bool:
	return is_finite_vector3(value) and value.length() <= MAX_WORLD_DISTANCE_METERS


static func is_valid_normal(value: Vector3) -> bool:
	return is_finite_vector3(value) and value.length_squared() >= MIN_NORMAL_LENGTH * MIN_NORMAL_LENGTH


static func is_valid_shared_transform(value: Transform3D) -> bool:
	return is_valid_shared_point(value.origin) and _is_finite_basis(value.basis)


static func is_valid_world_transform(value: Transform3D) -> bool:
	return is_valid_world_point(value.origin) and _is_finite_basis(value.basis)


static func is_valid_origin_transform(value: Transform3D) -> bool:
	if not is_finite_vector3(value.origin) or value.origin.length() > MAX_ORIGIN_DISTANCE_METERS:
		return false
	if not _is_finite_basis(value.basis):
		return false
	var scale := value.basis.get_scale()
	if not scale.is_equal_approx(Vector3.ONE):
		if absf(scale.x - 1.0) > UNIT_SCALE_TOLERANCE \
				or absf(scale.y - 1.0) > UNIT_SCALE_TOLERANCE \
				or absf(scale.z - 1.0) > UNIT_SCALE_TOLERANCE:
			return false
	var determinant := value.basis.determinant()
	if determinant <= 0.0 or absf(determinant - 1.0) > ORTHOGONAL_TOLERANCE:
		return false
	var normalized := value.basis.orthonormalized()
	return value.basis.x.distance_to(normalized.x) <= ORTHOGONAL_TOLERANCE \
		and value.basis.y.distance_to(normalized.y) <= ORTHOGONAL_TOLERANCE \
		and value.basis.z.distance_to(normalized.z) <= ORTHOGONAL_TOLERANCE


static func world_to_shared_transform(
	origin_global: Transform3D,
	world_transform: Transform3D
) -> Transform3D:
	return origin_global.affine_inverse() * world_transform


static func shared_to_world_transform(
	origin_global: Transform3D,
	shared_transform: Transform3D
) -> Transform3D:
	return origin_global * shared_transform


static func world_to_shared_point(origin_global: Transform3D, world_point: Vector3) -> Vector3:
	return origin_global.affine_inverse() * world_point


static func shared_to_world_point(origin_global: Transform3D, shared_point: Vector3) -> Vector3:
	return origin_global * shared_point


static func world_to_shared_normal(origin_global: Transform3D, world_normal: Vector3) -> Vector3:
	var transformed := origin_global.basis.transposed() * world_normal
	return transformed.normalized() if transformed.length_squared() >= MIN_NORMAL_LENGTH * MIN_NORMAL_LENGTH else Vector3.ZERO


static func shared_to_world_normal(origin_global: Transform3D, shared_normal: Vector3) -> Vector3:
	var transformed := origin_global.basis.inverse().transposed() * shared_normal
	return transformed.normalized() if transformed.length_squared() >= MIN_NORMAL_LENGTH * MIN_NORMAL_LENGTH else Vector3.ZERO


static func _is_finite_basis(value: Basis) -> bool:
	return is_finite_vector3(value.x) \
		and is_finite_vector3(value.y) \
		and is_finite_vector3(value.z) \
		and absf(value.determinant()) > 0.000001
