# SpaceBox.gd
extends Node3D

@onready var environment_node := $SpaceBox/Environment_Life

func _ready():
	# 将自己注册到全局单例Global，方便其他场景调用
	Global.spacebox_controller = self
	print("✅ SpaceBox 控制器已注册到 Global 单例")

# 设置 Environment_Life 可见性
func set_environment_visible(visible: bool) -> void:
	if environment_node and is_instance_valid(environment_node):
		environment_node.visible = visible
		print("✅ Environment_Life 可见性设置为: ", visible)
	else:
		printerr("❌ environment_node 无效，无法设置可见性")
