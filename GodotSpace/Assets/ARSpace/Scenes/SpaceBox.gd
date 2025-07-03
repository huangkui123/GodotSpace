# SpaceBox.gd
extends Node3D

@onready var environment_node := $SpaceBox/Environment_Life
@onready var dashiyangui := $SpaceBox/dashiyangui

func _ready():
	Global.spacebox_controller = self
	print("✅ SpaceBox 控制器已注册到 Global 单例")

func set_environment_visible(visible: bool) -> void:
	if environment_node and is_instance_valid(environment_node):
		environment_node.visible = visible
		print("✅ Environment_Life 可见性设置为: ", visible)
	else:
		printerr("❌ environment_node 无效，无法设置可见性")

func play_dashiyangui_animation():
	if dashiyangui and dashiyangui.has_method("play_from_ui"):
		dashiyangui.play_from_ui()
	else:
		printerr("❌ dashiyangui 上找不到 play_from_ui 方法")
