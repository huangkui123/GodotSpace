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


static func to_row_major(t: Transform3D) -> Array:
	return [[t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x],
		[t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y],
		[t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z], [0, 0, 0, 1]]


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
	if result.get("status") not in ["candidate", "rejected"]:
		return {"error": "未知的识别结果状态。"}
	var offline: bool = result.get("mode") == "demo"
	if not offline and result.get("mode") != "live":
		return {"error": "未知的识别模式。"}
	var rows: Variant = result.get("frames")
	if not rows is Array or rows.size() != captures.size() \
			or (offline and rows.size() != 1) or (not offline and (rows.size() < 3 or rows.size() > 16)):
		return {"error": "识别帧数量不完整。"}
	if not offline and result.get("multiview", false):
		if not has_view_baseline(captures):
			return {"error": "视点移动不足 12 cm，请横向移动观察柜体；静止或原地转头不能代替多个视角。"}
		if model_kind == "cuboid":
			return _validate_multiview(result, captures, dimensions)
	var poses: Array[Transform3D] = []
	var source_indices: Array[int] = []
	var identifiers: Dictionary = {}
	var previous_time := -1
	var ambiguous := 0
	for i in range(rows.size()):
		var row: Variant = rows[i]
		if not row is Dictionary or row.get("status") not in ["candidate", "not_found", "ambiguous"]:
			return {"error": "识别帧状态无效。"}
		var identifier := str(row.get("capture_id", ""))
		if identifier.is_empty() or identifier != str(captures[i].get("capture_id", "")) or identifiers.has(identifier):
			return {"error": "识别帧重复或顺序不匹配。"}
		identifiers[identifier] = true
		if not offline:
			var captured_at := int(captures[i].get("captured_msec", -1))
			if captured_at < 0 or (previous_time >= 0 and captured_at - previous_time < 250):
				return {"error": "采集时间无效或帧间隔过短，请重新连续取景。"}
			previous_time = captured_at
		if row.status != "candidate":
			ambiguous += 1 if row.status == "ambiguous" else 0
			continue
		var rms := float(row.get("reprojection_rms_px", INF))
		var minimum_points := 6 if model_kind == "cuboid" else 10
		if not is_finite(rms) or rms < 0 or rms > 2.5 or int(row.get("inliers", 0)) < minimum_points:
			continue
		if model_kind == "cuboid":
			var support := float(row.get("edge_support", 0))
			var silhouette := float(row.get("silhouette_iou", 0))
			if not is_finite(support) or support < 0.8 or support > 1 \
					or not is_finite(silhouette) or silhouette < 0.94 or silhouette > 1:
				continue
		var decoded := from_row_major(row.get("camera_from_model"))
		if decoded.has("error"):
			return decoded
		if not captures[i].get("camera_world") is Transform3D:
			return {"error": "缺少取景相机位姿。"}
		var camera: Transform3D = captures[i].camera_world
		if not is_rigid(camera):
			return {"error": "取景相机位姿无效。"}
		poses.append(camera * OPENCV_TO_GODOT * (decoded.transform as Transform3D))
		source_indices.append(i)
	var required := 1 if offline else 3
	if poses.size() < required:
		return {"error": "已分析 %d 帧，仅 %d 帧识别有效（%d 帧有歧义），未找到可靠的多帧结果。请让完整柜体、正面和侧面清晰可见，换角度后停稳重试。" % [
			rows.size(), poses.size(), ambiguous]}
	# Every pair in a group must agree; a chain of nearby poses is not consensus.
	var neighbors: Array = []
	var candidates: Array[int] = []
	for i in range(poses.size()):
		var adjacent: Array[int] = []
		for j in range(poses.size()):
			if i != j and poses[i].origin.distance_to(poses[j].origin) <= 0.03 \
					and poses[i].basis.get_rotation_quaternion().angle_to(poses[j].basis.get_rotation_quaternion()) <= deg_to_rad(5):
				adjacent.append(j)
		neighbors.append(adjacent)
		candidates.append(i)
	var groups: Array = []
	_maximal_pose_groups(neighbors, [], candidates, [], groups)
	groups.sort_custom(func(a: Array, b: Array): return a.size() > b.size())
	var best: Array = groups[0]
	if best.size() < required or best.size() * 2 <= poses.size():
		return {"error": "已分析 %d 帧，%d 帧识别有效，但位姿不一致。请保持柜体不动，换角度后停稳重试。" % [rows.size(), poses.size()]}
	for group in groups:
		if group.size() < required:
			continue
		var overlaps := false
		for index in group:
			if best.has(index):
				overlaps = true
		if not overlaps:
			return {"error": "检测到两组持续出现的不同柜体姿态。请让画面中只保留待标定柜体后重试。"}
	var first_time := 9223372036854775807
	var last_time := 0
	var position := Vector3.ZERO
	var rotation_sum := Vector4.ZERO
	var reference := poses[best[0]].basis.get_rotation_quaternion()
	var representative: int = source_indices[best[0]]
	var lowest_rms := INF
	for index in best:
		var source_index: int = source_indices[index]
		var captured_at := int(captures[source_index].get("captured_msec", 0))
		first_time = mini(first_time, captured_at)
		last_time = maxi(last_time, captured_at)
		position += poses[index].origin
		var rotation := poses[index].basis.get_rotation_quaternion()
		var sign_value := 1.0 if reference.dot(rotation) >= 0 else -1.0
		rotation_sum += Vector4(rotation.x, rotation.y, rotation.z, rotation.w) * sign_value
		var rms := float(rows[source_index].reprojection_rms_px)
		if rms < lowest_rms:
			lowest_rms = rms
			representative = source_index
	if not offline and last_time - first_time < 1000:
		return {"error": "有效姿态持续不足 1 秒，请继续保持柜体清晰可见后重试。"}
	var fused_rotation := Quaternion(rotation_sum.x, rotation_sum.y, rotation_sum.z, rotation_sum.w).normalized()
	return {"pose": Transform3D(Basis(fused_rotation), position / best.size()), "offline": offline,
		"support_count": best.size(), "rejected_count": rows.size() - poses.size(),
		"outlier_count": poses.size() - best.size(), "representative_index": representative}


## Bron-Kerbosch with pivot, bounded to 16 frames. Avoids greedy order dependence
## and the exponential all-compatible case when finding maximal consensus groups.
static func _maximal_pose_groups(neighbors: Array, group: Array[int], remaining: Array[int],
		excluded: Array[int], groups: Array) -> void:
	if remaining.is_empty() and excluded.is_empty():
		groups.append(group)
		return
	var pivot := -1
	var most := -1
	for index in remaining + excluded:
		var count := 0
		for candidate in remaining:
			if neighbors[index].has(candidate):
				count += 1
		if count > most:
			most = count
			pivot = index
	var branches := remaining.duplicate()
	for index in branches:
		if pivot >= 0 and neighbors[pivot].has(index):
			continue
		var next_group := group.duplicate()
		next_group.append(index)
		var next_remaining: Array[int] = []
		var next_excluded: Array[int] = []
		for candidate in remaining:
			if neighbors[index].has(candidate):
				next_remaining.append(candidate)
		for candidate in excluded:
			if neighbors[index].has(candidate):
				next_excluded.append(candidate)
		_maximal_pose_groups(neighbors, next_group, next_remaining, next_excluded, groups)
		remaining.erase(index)
		excluded.append(index)


static func has_view_baseline(captures: Array[Dictionary]) -> bool:
	for a in captures:
		for b in captures:
			if a.get("camera_world") is Transform3D and b.get("camera_world") is Transform3D \
					and (a.camera_world as Transform3D).origin.distance_to((b.camera_world as Transform3D).origin) >= 0.12:
				return true
	return false


static func _validate_multiview(result: Dictionary, captures: Array[Dictionary], dimensions: Vector3) -> Dictionary:
	var fit: Dictionary = result.get("multiview_fit", {})
	if fit.get("status") != "candidate":
		var reasons := {"insufficient_baseline": "移动距离不足", "need_three_views": "有效视角不足",
			"ambiguous": "存在多个可行位置", "insufficient_edge_support": "可见边线不足或尺寸不匹配"}
		return {"error": "多个视角未能共同确定柜体：%s。请绕开遮挡，露出正面和侧面后重新扫描。" % str(reasons.get(fit.get("reason", ""), "线索不足"))}
	var decoded := from_row_major(fit.get("world_from_model"))
	if decoded.has("error"):
		return decoded
	var pose: Transform3D = decoded.transform
	if pose.basis.y.dot(Vector3.UP) < cos(deg_to_rad(4)):
		return {"error": "多视角柜体姿态与竖直方向不符。"}
	var score := float(fit.get("edge_score", 0))
	if not is_finite(score) or score < 0.65 or score > 1:
		return {"error": "多个视角中的柜体边线支持不足。"}
	var support: Variant = fit.get("support_indices")
	if not support is Array or support.size() < 3 or support.size() > captures.size():
		return {"error": "多视角有效数量不足。"}
	var seen: Dictionary = {}
	var previous_time := -1
	for i in range(captures.size()):
		var row: Variant = result.frames[i]
		var identifier := str(captures[i].get("capture_id", ""))
		var timestamp := int(captures[i].get("captured_msec", -1))
		if not row is Dictionary or identifier.is_empty() or row.get("capture_id") != identifier or seen.has(identifier) \
				or timestamp < 0 or (previous_time >= 0 and timestamp - previous_time < 250):
			return {"error": "多视角图像身份或时间不匹配。"}
		if not captures[i].get("camera_world") is Transform3D or not is_rigid(captures[i].camera_world):
			return {"error": "多视角相机位姿无效。"}
		seen[identifier] = true
		previous_time = timestamp
	var selected: Array[Dictionary] = []
	var used: Dictionary = {}
	var center := pose * (dimensions * Vector3(0.5, 0.5, -0.5))
	var rays: Array[Vector3] = []
	var first_time := 9223372036854775807
	var last_time := 0
	for index in support:
		if typeof(index) not in [TYPE_INT, TYPE_FLOAT] or float(index) != floor(float(index)) \
				or index < 0 or index >= captures.size() or used.has(int(index)):
			return {"error": "多视角支持帧索引无效。"}
		used[int(index)] = true
		var sample: Dictionary = captures[int(index)]
		for previous in selected:
			if (sample.camera_world as Transform3D).origin.distance_to((previous.camera_world as Transform3D).origin) < 0.04:
				return {"error": "有效视点重复，请从至少三个不同位置观察柜体。"}
		selected.append(sample)
		rays.append(((sample.camera_world as Transform3D).origin - center).normalized())
		first_time = mini(first_time, int(sample.captured_msec))
		last_time = maxi(last_time, int(sample.captured_msec))
	var parallax := false
	for a in rays:
		for b in rays:
			if a.dot(b) < cos(deg_to_rad(8)):
				parallax = true
	if not has_view_baseline(selected) or not parallax or last_time - first_time < 1000:
		return {"error": "有效视角的移动距离、角度或时间不足，请进一步向侧面移动。"}
	return {"pose": pose, "offline": false, "support_count": support.size(),
		"rejected_count": captures.size() - support.size(), "outlier_count": 0,
		"representative_index": int(support[0])}
