# Global.gd
extends Node

var spacebox_controller = null

var main_menu_canvas: Node = null

var picture_canvas: Node = null
var picture_info_canvas: Node = null

var movie_canvas: Node = null
var movie_info_canvas: Node = null

var work_list_info_canvas: Node = null

# 窗口管理相关变量
var last_clicked_window_position: Vector3 = Vector3.ZERO
var last_clicked_window_transform: Transform3D = Transform3D.IDENTITY
var window_right_offset: float = 650.0  # 新窗口出现在右侧的偏移距离

# 记录上一个被点击的窗口位置
func set_last_clicked_window(window_node: Node3D):
	if window_node:
		last_clicked_window_position = window_node.global_position
		last_clicked_window_transform = window_node.global_transform
		print("✅ 记录上一个被点击的窗口位置: ", last_clicked_window_position)

# 获取新窗口应该出现的位置（在上一个窗口的右侧）
func get_new_window_position():
	if last_clicked_window_position != Vector3.ZERO:
		# 计算右侧位置（基于上一个窗口的朝向）
		var right_direction = last_clicked_window_transform.basis.x
		var new_position = last_clicked_window_position + right_direction * window_right_offset
		print("✅ 计算新窗口位置: ", new_position)
		return new_position
	else:
		return Vector3(0, 1.5, -2)

# 获取新窗口应该使用的朝向（与上一个窗口相同）
func get_new_window_transform():
	if last_clicked_window_transform != Transform3D.IDENTITY:
		var new_transform = last_clicked_window_transform
		# 设置新的位置
		new_transform.origin = get_new_window_position()
		return new_transform
	else:
		# 如果没有记录，返回默认朝向
		var default_transform = Transform3D.IDENTITY
		default_transform.origin = get_new_window_position()
		return default_transform
