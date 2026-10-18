extends RefCounted

## Cabinet origin is its front bottom-left corner; +X right, +Y up,
## +Z out of the front. Depth extends along -Z. All lengths are metres.
const CV_TO_GODOT := Basis(Vector3.RIGHT, Vector3.DOWN, Vector3.FORWARD)
const MIN_SIZE := 0.05
const MAX_SIZE := 20.0


static func valid_dimensions(value: Vector3) -> bool:
	return value.is_finite() and value.x >= MIN_SIZE and value.y >= MIN_SIZE \
		and value.z >= MIN_SIZE and value.x <= MAX_SIZE \
		and value.y <= MAX_SIZE and value.z <= MAX_SIZE


static func corners(dimensions: Vector3) -> PackedVector3Array:
	var w := dimensions.x
	var h := dimensions.y
	var d := dimensions.z
	return PackedVector3Array([
		Vector3(0, h, 0), Vector3(w, h, 0), Vector3(w, 0, 0), Vector3.ZERO,
		Vector3(0, h, -d), Vector3(w, h, -d), Vector3(w, 0, -d), Vector3(0, 0, -d),
	])


static func valid_intrinsics(k: Vector4, size: Vector2i) -> bool:
	return k.is_finite() and size.x > 0 and size.y > 0 \
		and k.x > 1.0 and k.y > 1.0 and k.z >= 0 and k.z <= size.x \
		and k.w >= 0 and k.w <= size.y


## k = (fx, fy, cx, cy). Only a single rectified camera is supported.
static func intrinsics_from_metadata(metadata: Dictionary, size: Vector2i) -> Dictionary:
	for key in ["render_mode", "camera_intrinsics_width", "camera_intrinsics_height",
			"camera_intrinsics_fx", "camera_intrinsics_fy", "camera_intrinsics_cx", "camera_intrinsics_cy"]:
		if typeof(metadata.get(key)) not in [TYPE_INT, TYPE_FLOAT] \
				or not is_finite(float(metadata[key])):
			return {"error": "相机参数缺失或格式无效；可改用头显前方放置并微调。"}
	if bool(metadata.get("output_camera_raw_data", true)):
		return {"error": "请在 Helper 中关闭原始图像，使用已校正的单眼画面。"}
	if int(metadata.get("render_mode", -1)) not in [0, 1]:
		return {"error": "四角标定只支持左眼或右眼单眼画面，不支持拼接或交错画面。"}
	if int(metadata.get("camera_intrinsics_width", 0)) != size.x \
			or int(metadata.get("camera_intrinsics_height", 0)) != size.y:
		return {"error": "相机内参分辨率与图像不一致，请检查 Helper 配置。"}
	var k := Vector4(float(metadata.get("camera_intrinsics_fx", 0.0)),
		float(metadata.get("camera_intrinsics_fy", 0.0)),
		float(metadata.get("camera_intrinsics_cx", -1.0)),
		float(metadata.get("camera_intrinsics_cy", -1.0)))
	if not valid_intrinsics(k, size):
		return {"error": "该帧没有有效相机内参；可改用头显前方放置并微调。"}
	return {"k": k}


static func project(camera_from_object: Transform3D, point: Vector3, k: Vector4) -> Vector2:
	var cv: Vector3 = CV_TO_GODOT * (camera_from_object * point)
	if cv.z <= 0.01:
		return Vector2(INF, INF)
	return Vector2(k.x * cv.x / cv.z + k.z, k.y * cv.y / cv.z + k.w)


## Ordered image points: front top-left, top-right, bottom-right, bottom-left.
## Homography initialization followed by rigid six-parameter reprojection fit.
static func solve(points: PackedVector2Array, dimensions: Vector3, k: Vector4,
		image_size: Vector2i) -> Dictionary:
	if not valid_dimensions(dimensions) or not valid_intrinsics(k, image_size):
		return {"error": "尺寸或相机参数无效。"}
	if points.size() != 4:
		return {"error": "请按左上、右上、右下、左下顺序选择柜体正面四角。"}
	var area := 0.0
	for i in range(4):
		var p := points[i]
		var q := points[(i + 1) % 4]
		var r := points[(i + 2) % 4]
		if not p.is_finite() or p.x < 0 or p.y < 0 \
				or p.x >= image_size.x or p.y >= image_size.y:
			return {"error": "角点必须位于图像内。"}
		if (q - p).cross(r - q) <= 4.0 or p.distance_to(q) < 8.0:
			return {"error": "角点顺序错误、距离太近或视角过于倾斜，请重新选择。"}
		area += p.cross(q)
	if area < 800.0:
		return {"error": "柜体在画面中太小，请靠近后重试。"}
	var object_points := corners(dimensions)
	var matrix: Array = []
	var rhs: Array = []
	for i in range(4):
		var x := object_points[i].x
		var y := object_points[i].y
		var u := (points[i].x - k.z) / k.x
		var v := (points[i].y - k.w) / k.y
		matrix.append([x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y])
		matrix.append([0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y])
		rhs.append(u)
		rhs.append(v)
	var h := linear_solve(matrix, rhs)
	if h.is_empty():
		return {"error": "四角几何退化，请换一个角度重试。"}
	var a := Vector3(h[0], h[3], h[6])
	var b := Vector3(h[1], h[4], h[7])
	var scale_factor := 2.0 / (a.length() + b.length())
	var x_axis := a.normalized()
	var y_axis := (b - x_axis * b.dot(x_axis)).normalized()
	var cv_pose := Transform3D(Basis(x_axis, y_axis, x_axis.cross(y_axis)),
		Vector3(h[2], h[5], 1.0) * scale_factor)
	var pose := Transform3D(CV_TO_GODOT * cv_pose.basis, CV_TO_GODOT * cv_pose.origin)
	pose = _refine(pose, object_points, points, k)
	var error_squared := 0.0
	for i in range(4):
		var uv := project(pose, object_points[i], k)
		if not uv.is_finite():
			return {"error": "解算结果位于相机后方，请重新选点。"}
		error_squared += uv.distance_squared_to(points[i])
	var rms := sqrt(error_squared / 4.0)
	if rms > 8.0 or pose.origin.length() > 30.0 \
			or pose.basis.z.dot(pose.origin) >= 0.0:
		return {"error": "尺寸与角点不一致或朝向异常（重投影误差 %.1f px），请检查。" % rms}
	return {"transform": pose, "rms_px": rms}


static func _refine(initial: Transform3D, object_points: PackedVector3Array,
		image_points: PackedVector2Array, k: Vector4) -> Transform3D:
	var pose := initial
	var damping := 0.001
	for _iteration in range(25):
		var residual: Array = []
		var jacobian: Array = []
		var cost := 0.0
		for i in range(4):
			var base := project(pose, object_points[i], k)
			if not base.is_finite():
				return initial
			var difference := image_points[i] - base
			cost += difference.length_squared()
			residual.append(difference.x)
			residual.append(difference.y)
			var jx: Array = []
			var jy: Array = []
			for axis in range(6):
				var step: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
				step[axis] = 0.0005
				var derivative := (project(_step_pose(pose, step), object_points[i], k) - base) / 0.0005
				jx.append(derivative.x)
				jy.append(derivative.y)
			jacobian.append(jx)
			jacobian.append(jy)
		var normal: Array = []
		var rhs: Array = []
		for a in range(6):
			var row: Array = []
			var sum := 0.0
			for r in range(8):
				sum += float(jacobian[r][a]) * float(residual[r])
			rhs.append(sum)
			for b in range(6):
				var value := 0.0
				for r in range(8):
					value += float(jacobian[r][a]) * float(jacobian[r][b])
				row.append(value + damping if a == b else value)
			normal.append(row)
		var step := linear_solve(normal, rhs)
		if step.is_empty():
			break
		var candidate := _step_pose(pose, step)
		var new_cost := 0.0
		for i in range(4):
			new_cost += project(candidate, object_points[i], k).distance_squared_to(image_points[i])
		if new_cost < cost:
			pose = candidate
			damping = maxf(0.00001, damping * 0.3)
			if cost - new_cost < 0.00001:
				break
		else:
			damping *= 10.0
	return pose


static func _step_pose(pose: Transform3D, step: Array) -> Transform3D:
	var rotation := Vector3(step[0], step[1], step[2])
	var basis := pose.basis
	if rotation.length() > 0.0000001:
		basis = Basis(rotation.normalized(), rotation.length()) * basis
	return Transform3D(basis.orthonormalized(), pose.origin + Vector3(step[3], step[4], step[5]))


static func linear_solve(matrix: Array, rhs: Array) -> Array:
	var n := rhs.size()
	var m := matrix.duplicate(true)
	var b := rhs.duplicate()
	for column in range(n):
		var pivot := column
		for row in range(column + 1, n):
			if absf(float(m[row][column])) > absf(float(m[pivot][column])):
				pivot = row
		if absf(float(m[pivot][column])) < 1e-10:
			return []
		var temp: Array = m[column]
		m[column] = m[pivot]
		m[pivot] = temp
		var temp_value: float = b[column]
		b[column] = b[pivot]
		b[pivot] = temp_value
		var divisor: float = m[column][column]
		for j in range(column, n):
			m[column][j] = float(m[column][j]) / divisor
		b[column] = float(b[column]) / divisor
		for row in range(n):
			if row == column:
				continue
			var factor: float = m[row][column]
			for j in range(column, n):
				m[row][j] = float(m[row][j]) - factor * float(m[column][j])
			b[row] = float(b[row]) - factor * float(b[column])
	return b


static func encode_transform(value: Transform3D) -> Array:
	return [value.basis.x.x, value.basis.x.y, value.basis.x.z,
		value.basis.y.x, value.basis.y.y, value.basis.y.z,
		value.basis.z.x, value.basis.z.y, value.basis.z.z,
		value.origin.x, value.origin.y, value.origin.z]


static func decode_transform(value: Variant) -> Variant:
	if not value is Array or value.size() != 12:
		return null
	for number in value:
		if typeof(number) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(number)):
			return null
	var basis := Basis(Vector3(value[0], value[1], value[2]),
		Vector3(value[3], value[4], value[5]), Vector3(value[6], value[7], value[8]))
	if absf(basis.determinant() - 1.0) > 0.01 \
			or not basis.is_equal_approx(basis.orthonormalized()):
		return null
	var origin := Vector3(value[9], value[10], value[11])
	if origin.length() > 1000:
		return null
	return Transform3D(basis, origin)
