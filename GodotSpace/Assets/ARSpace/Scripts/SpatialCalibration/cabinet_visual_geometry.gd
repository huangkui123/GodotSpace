extends RefCounted

## Coordinate contract for a future validated visual pose provider.
## All transforms are rigid and in meters; never scale XROrigin to compensate
## for a miniature cabinet. Scale the cabinet content before setting its anchor.
const OPENCV_TO_GODOT := Transform3D(
	Basis(Vector3.RIGHT, Vector3.DOWN, Vector3.FORWARD), Vector3.ZERO
)


static func is_rigid(value: Transform3D) -> bool:
	if not value.is_finite():
		return false
	var basis := value.basis
	return absf(basis.determinant() - 1.0) < 0.001 \
		and absf(basis.x.length_squared() - 1.0) < 0.001 \
		and absf(basis.y.length_squared() - 1.0) < 0.001 \
		and absf(basis.z.length_squared() - 1.0) < 0.001 \
		and absf(basis.x.dot(basis.y)) < 0.001 \
		and absf(basis.x.dot(basis.z)) < 0.001 \
		and absf(basis.y.dot(basis.z)) < 0.001


static func solve_world_from_tracking(
	world_from_model: Transform3D,
	tracking_from_camera_at_capture: Transform3D,
	opencv_camera_from_model: Transform3D,
) -> Dictionary:
	for transform in [
		world_from_model, tracking_from_camera_at_capture, opencv_camera_from_model
	]:
		if not is_rigid(transform):
			return {"error": "Calibration requires rigid transforms in meters"}
	var tracking_from_model := (
		tracking_from_camera_at_capture * OPENCV_TO_GODOT * opencv_camera_from_model
	)
	return {
		"world_from_tracking": world_from_model * tracking_from_model.affine_inverse(),
	}


static func from_row_major(matrix: Variant) -> Dictionary:
	if not matrix is Array or matrix.size() != 4:
		return {"error": "Expected a 4x4 row-major matrix"}
	for row in matrix:
		if not row is Array or row.size() != 4:
			return {"error": "Expected a 4x4 row-major matrix"}
		for item in row:
			if not (item is float or item is int) or not is_finite(float(item)):
				return {"error": "Matrix contains a non-finite/non-numeric value"}
	if absf(matrix[3][0]) > 0.00001 or absf(matrix[3][1]) > 0.00001 \
			or absf(matrix[3][2]) > 0.00001 or absf(matrix[3][3] - 1.0) > 0.00001:
		return {"error": "Invalid homogeneous matrix row"}
	var value := Transform3D(
		Basis(
			Vector3(matrix[0][0], matrix[1][0], matrix[2][0]),
			Vector3(matrix[0][1], matrix[1][1], matrix[2][1]),
			Vector3(matrix[0][2], matrix[1][2], matrix[2][2]),
		),
		Vector3(matrix[0][3], matrix[1][3], matrix[2][3]),
	)
	if not is_rigid(value):
		return {"error": "Pose matrix is not rigid"}
	return {"transform": value}
