extends RefCounted

## Coordinate contract for the experimental visual pose provider.
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


## Compare poses in the SAME world frame, not camera coordinates. Camera motion
## between captures must not look like object motion, nor hide inconsistent poses.
static func validate_batch(result: Dictionary, captures: Array[Dictionary], physical_scale: float,
		model_kind: String = "cad", dimensions: Vector3 = Vector3.ZERO) -> Dictionary:
	var model_coordinates := "godot_frame_mesh_local_right_handed_y_up" if model_kind == "cad" \
		else "cabinet_front_bottom_left_x_right_y_up_depth_negative_z"
	if model_kind not in ["cad", "cuboid"] or result.get("model_kind", "cad") != model_kind:
		return {"error": "识别结果与当前柜体类型不匹配。"}
	if model_kind == "cuboid":
		var actual: Variant = result.get("dimensions_m")
		if not actual is Array or actual.size() != 3:
			return {"error": "识别结果缺少柜体尺寸。"}
		for i in range(3):
			if typeof(actual[i]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(actual[i])) \
					or not is_equal_approx(float(actual[i]), dimensions[i]):
				return {"error": "识别结果与当前柜体尺寸不匹配，请重新识别。"}
	if result.get("schema_version") != 1 or result.get("units") != "meters" \
			or result.get("coordinate_system") != "opencv_camera_x_right_y_down_z_forward" \
			or result.get("model_coordinates") != model_coordinates \
			or not is_equal_approx(float(result.get("physical_scale", 0)), physical_scale):
		return {"error": "识别结果的坐标、单位或模型比例不匹配。"}
	if result.get("status") != "candidate":
		return {"error": "未找到可靠的柜体，或存在多个可能姿态。请让整个柜体及正面、侧面棱边清晰可见后重试。"}
	var offline: bool = result.get("mode") == "demo"
	if not offline and result.get("mode") != "live":
		return {"error": "未知的识别模式。"}
	var rows: Variant = result.get("frames")
	var count := 1 if offline else 3
	if not rows is Array or rows.size() != count or captures.size() != count:
		return {"error": "识别帧数量不完整。"}
	var poses: Array[Transform3D] = []
	var identifiers: Dictionary = {}
	for i in range(count):
		var row: Variant = rows[i]
		if not row is Dictionary or row.get("status") != "candidate":
			return {"error": "未找到可靠的柜体，或存在多个可能姿态。请换一个能看清柜体结构的视角重试。"}
		var identifier := str(row.get("capture_id", ""))
		if identifier != str(captures[i].get("capture_id", "")) or identifiers.has(identifier):
			return {"error": "识别帧重复或顺序不匹配。"}
		identifiers[identifier] = true
		var rms := float(row.get("reprojection_rms_px", INF))
		var minimum_points := 6 if model_kind == "cuboid" else 10
		if not is_finite(rms) or rms < 0 or rms > 2.5 or int(row.get("inliers", 0)) < minimum_points:
			return {"error": "CAD 特征匹配质量不足。"}
		if model_kind == "cuboid":
			var support := float(row.get("edge_support", 0))
			var silhouette := float(row.get("silhouette_iou", 0))
			if not is_finite(support) or support < 0.8 or support > 1 \
					or not is_finite(silhouette) or silhouette < 0.94 or silhouette > 1:
				return {"error": "柜体轮廓或棱边不完整，请换到能看清多个面的角度。"}
		var decoded := from_row_major(row.get("camera_from_model"))
		if decoded.has("error"):
			return decoded
		var camera: Transform3D = captures[i].camera_world
		if not is_rigid(camera):
			return {"error": "取景相机位姿无效。"}
		var pose: Transform3D = camera * OPENCV_TO_GODOT * (decoded.transform as Transform3D)
		for previous in poses:
			if previous.origin.distance_to(pose.origin) > 0.03 \
					or previous.basis.get_rotation_quaternion().angle_to(pose.basis.get_rotation_quaternion()) > deg_to_rad(5):
				return {"error": "多帧识别位姿不一致，请停稳头部、保持柜体不动后重试。"}
		poses.append(pose)
	return {"pose": poses.back(), "offline": offline}
