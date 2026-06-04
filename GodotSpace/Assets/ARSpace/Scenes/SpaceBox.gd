# SpaceBox.gd
extends Node3D

const DEBUG_LOGS := false

@onready var environment_node := $SpaceBox/Environment_Life
@onready var dashiyangui := $SpaceBox/dashiyangui

@onready var worklist1 := $SpaceBox/WorkEffect/WorkList1

func _ready():
	Global.spacebox_controller = self
	worklist1.visible = false  # 默认隐藏
	if DEBUG_LOGS: print("✅ SpaceBox 控制器已注册到 Global 单例")

func set_worklist1_visible(visible: bool):
	if worklist1 and is_instance_valid(worklist1):
		worklist1.visible = visible
		if DEBUG_LOGS: print("✅ 设置 WorkList1 可见性为: ", visible)
	else:
		printerr("❌ WorkList1 无法访问")

func show_only_work_info(step_index: int):
	var work_info_root := $SpaceBox/WorkEffect/WorkList1
	for i in range(1, 21):
		var info_node := work_info_root.get_node_or_null("WorkInfo%d" % i)
		if info_node:
			info_node.visible = (i == step_index)
		else:
			printerr("❌ 未找到 WorkInfo%d 节点" % i)

func set_environment_visible(visible: bool) -> void:
	if environment_node and is_instance_valid(environment_node):
		environment_node.visible = visible
		if DEBUG_LOGS: print("✅ Environment_Life 可见性设置为: ", visible)
	else:
		printerr("❌ environment_node 无效，无法设置可见性")

func play_dashiyangui_animation():
	if dashiyangui and dashiyangui.has_method("play_from_ui"):
		dashiyangui.play_from_ui()
	else:
		printerr("❌ dashiyangui 上找不到 play_from_ui 方法")
		
# ✅ 新增：让 Global.spacebox_controller.play_step(x) 成立
func play_step(step_index: int):
	if dashiyangui and dashiyangui.has_method("play_step"):
		dashiyangui.play_step(step_index)
	else:
		printerr("❌ dashiyangui 上找不到 play_step 方法")
