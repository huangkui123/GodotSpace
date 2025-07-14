# 示例：在2D场景脚本中控制3D碰撞
# 这个脚本展示了几种控制viewport_2d_in_3d碰撞的方法

extends Control

# 获取父级的viewport_2d_in_3d节点
var viewport_3d : XRToolsViewport2DIn3D

func _ready():
	# 方法1：通过节点路径获取viewport_2d_in_3d节点
	viewport_3d = get_node("../../") as XRToolsViewport2DIn3D
	
	# 方法2：通过查找父级节点获取
	# var current = self
	# while current and not current is XRToolsViewport2DIn3D:
	#     current = current.get_parent()
	# viewport_3d = current as XRToolsViewport2DIn3D

# 示例：隐藏UI时自动禁用碰撞
func hide_ui():
	visible = false
	# 自动功能会检测到可见性变化并禁用碰撞
	print("UI hidden, collision should be disabled automatically")

# 示例：显示UI时自动启用碰撞
func show_ui():
	visible = true
	# 自动功能会检测到可见性变化并启用碰撞
	print("UI shown, collision should be enabled automatically")

# 示例：手动控制碰撞状态
func set_collision_manually(enabled: bool):
	if viewport_3d:
		viewport_3d.set_collision_enabled(enabled)
		print("Collision manually set to: ", enabled)

# 示例：检查当前碰撞状态
func check_collision_state():
	if viewport_3d:
		var is_enabled = viewport_3d.is_collision_enabled()
		print("Current collision state: ", is_enabled)

# 示例：切换碰撞状态
func toggle_collision():
	if viewport_3d:
		var current_state = viewport_3d.is_collision_enabled()
		viewport_3d.set_collision_enabled(not current_state)
		print("Collision toggled to: ", not current_state)

# 示例：临时禁用自动检测，手动控制
func disable_auto_detection():
	if viewport_3d:
		viewport_3d.auto_disable_collision_on_invisible = false
		print("Auto collision detection disabled")

# 示例：重新启用自动检测
func enable_auto_detection():
	if viewport_3d:
		viewport_3d.auto_disable_collision_on_invisible = true
		print("Auto collision detection enabled")

# 示例按钮信号连接
func _on_hide_button_pressed():
	hide_ui()

func _on_show_button_pressed():
	show_ui()

func _on_toggle_collision_button_pressed():
	toggle_collision()
