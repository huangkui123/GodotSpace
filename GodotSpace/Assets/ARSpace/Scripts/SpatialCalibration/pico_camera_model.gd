extends RefCounted

const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
const CONVENTION := "pico_4_ultra_rectified_cv_to_head_openxr_v1"


## Helper applies the SDK reference-to-head transform. Only the camera-side
## OpenCV -> Godot basis change remains here; the tracked head is already OpenXR.
static func head_from_camera(metadata: Dictionary) -> Dictionary:
	if str(metadata.get("device_model", "")) != "A9410" \
			or str(metadata.get("camera_to_head_convention", "")) != CONVENTION:
		return {"error": "未收到 PICO 4 Ultra 设备外参，请更新并重启头显 Helper 后重新取景。"}
	# Godot JSON numbers are floats; Array membership is type-sensitive.
	var mode: Variant = metadata.get("render_mode")
	var selected: Variant = metadata.get("selected_camera_index")
	if metadata.get("output_camera_raw_data") != false \
			or not _is_camera_index(mode) or not _is_camera_index(selected) or mode != selected:
		return {"error": "设备外参只匹配已校正的左眼或右眼单眼画面，请检查 Helper 图像模式。"}
	if metadata.get("camera_to_head_status") != "valid" \
			or metadata.get("camera_extrinsics_status") != 1 \
			or metadata.get("camera_to_head_units") != "metres":
		return {"error": "相机外参读取失败或单位不匹配，请重新连接 Helper。"}
	var key := "camera_to_head_secondary" if int(metadata.render_mode) == 1 else "camera_to_head_primary"
	var values: Variant = metadata.get(key)
	if not values is Array or values.size() != 16:
		return {"error": "相机外参矩阵缺失。"}
	for value in values:
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
			return {"error": "相机外参包含无效数值。"}
	if absf(values[12]) + absf(values[13]) + absf(values[14]) + absf(values[15] - 1.0) > 0.00001:
		return {"error": "相机外参矩阵格式无效。"}
	var decoded: Variant = Geometry.decode_transform([values[0], values[4], values[8],
		values[1], values[5], values[9], values[2], values[6], values[10], values[3], values[7], values[11]])
	if decoded == null or (decoded as Transform3D).origin.length() > 0.3:
		return {"error": "相机外参不是有效的头部局部刚体变换。"}
	var optical: Transform3D = decoded
	return {"transform": Transform3D(optical.basis * Geometry.CV_TO_GODOT, optical.origin)}


static func _is_camera_index(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and (value == 0 or value == 1)


static func intrinsics_error(metadata: Dictionary) -> String:
	if metadata.get("camera_intrinsics_status") != 1:
		return "相机内参读取失败，请重新连接 Helper。"
	if metadata.get("camera_intrinsics_source") != "pico_4_ultra_rectified_sdk_fov":
		return "当前内参不是 PICO 去畸变画面的参数，请更新 Helper；已实测的内参可手动输入。"
	for key in ["camera_intrinsics_horizontal_fov_degrees", "camera_intrinsics_vertical_fov_degrees"]:
		var value: Variant = metadata.get(key)
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
			return "相机视场角缺失或无效。"
	if absf(float(metadata.camera_intrinsics_horizontal_fov_degrees) - 76.35) > 0.001 \
			or absf(float(metadata.camera_intrinsics_vertical_fov_degrees) - 61.05) > 0.001:
		return "相机视场角与 PICO 去畸变输出不一致，请重新配置 Helper。"
	return ""
