# Global.gd
extends Node

var spacebox_controller = null

var main_menu_canvas: Node = null
var voice_call_window: Node = null

var picture_canvas: Node = null
var picture_info_canvas: Node = null

var movie_canvas: Node = null
var movie_info_canvas: Node = null

var work_list_info_canvas: Node = null

# 仅供尚未迁移的 XR Tools 本地放置逻辑兼容。权威窗口状态由
# SpatialWindowRegistryService 管理，这些值不得用于网络同步。
var last_clicked_window_position: Vector3 = Vector3.ZERO
var last_clicked_window_transform: Transform3D = Transform3D.IDENTITY
var window_right_offset: float = 0.7  # Godot 世界单位为米
var dragging_window: Node3D = null  # 当前正在被拖动的窗口

# 记录上一个被点击的窗口位置
func set_last_clicked_window(window_node: Node3D):
	if window_node:
		var adapter := window_node.get_node_or_null("SpatialWindowAdapter")
		if adapter != null and adapter.has_method("request_focus"):
			adapter.call("request_focus")
		last_clicked_window_position = window_node.global_position
		last_clicked_window_transform = window_node.global_transform
		# print("Recorded last clicked window position: ", last_clicked_window_position)

# 获取新窗口应该出现的位置（在上一个窗口的右侧）
func get_new_window_position():
	if last_clicked_window_position != Vector3.ZERO:
		# 获取XR相机位置
		var camera = get_tree().root.find_child("XRCamera3D", true, false)
		if camera:
			# 计算上一个窗口到相机的距离
			var distance_to_camera = last_clicked_window_position.distance_to(camera.global_transform.origin)
			
			# 计算右侧位置（基于上一个窗口的朝向）
			var right_direction = last_clicked_window_transform.basis.x
			var new_position = last_clicked_window_position + right_direction * window_right_offset
			
			# 计算从相机到新位置的方向
			var direction_from_camera = (new_position - camera.global_transform.origin).normalized()
			
			# 确保新窗口距离相机的距离与上一个窗口相同
			new_position = camera.global_transform.origin + direction_from_camera * distance_to_camera
			# print("Calculated new window position: ", new_position, " distance to camera: ", distance_to_camera)
			return new_position
		else:
			# 如果找不到相机，使用原来的逻辑
			var right_direction = last_clicked_window_transform.basis.x
			var new_position = last_clicked_window_position + right_direction * window_right_offset
			# print("Calculated new window position without camera: ", new_position)
			return new_position
	else:
		return Vector3(0, 1.5, -2)

# 获取新窗口应该使用的朝向（朝向用户）
func get_new_window_transform():
	var new_transform = Transform3D.IDENTITY
	new_transform.origin = get_new_window_position()

	# 保留原窗口的scale
	var original_scale = Vector3.ONE
	if last_clicked_window_transform != Transform3D.IDENTITY:
		original_scale = last_clicked_window_transform.basis.get_scale()

	# 获取XR相机并让窗口朝向用户
	var camera = get_tree().root.find_child("XRCamera3D", true, false)
	if camera:
		var to_camera = (camera.global_transform.origin - new_transform.origin).normalized()
		var up = Vector3.UP
		# 让Z轴朝向摄像机
		var new_basis = Basis()
		new_basis.z = to_camera
		new_basis.x = up.cross(to_camera).normalized()
		new_basis.y = to_camera.cross(new_basis.x).normalized()
		# 保留原来的缩放
		new_basis = new_basis.scaled(original_scale)
		new_transform.basis = new_basis
		# print("New window faces user, scale: ", original_scale)
	else:
		# 如果找不到相机，使用上一个窗口的朝向
		if last_clicked_window_transform != Transform3D.IDENTITY:
			new_transform.basis = last_clicked_window_transform.basis
			# print("New window uses previous window orientation")

	return new_transform
