# WorkTabView.gd
extends Control

@export var trigger_button: Button  # 在检查器中拖入按钮节点

func _ready():
	if trigger_button:
		trigger_button.pressed.connect(_on_trigger_button_pressed)

func _on_trigger_button_pressed():
	print("🟦 UI按钮被点击，准备播放3D动画")
	if Global.spacebox_controller:
		Global.spacebox_controller.play_dashiyangui_animation()
	else:
		printerr("❌ 找不到 SpaceBox 控制器")
