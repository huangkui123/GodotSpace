# SpaceBox.gd
extends Node3D

const DEBUG_LOGS := false
const SKY_MR_VISIBLE_NODE_PATHS: Array[NodePath] = [
	NodePath("SpaceBox/DownPlane"),
	NodePath("SpaceBox/BackDor"),
]

@onready var environment_node := $SpaceBox/Environment_Life
@onready var dashiyangui := $SpaceBox/dashiyangui

@onready var worklist1 := $SpaceBox/WorkEffect/WorkList1

var _original_sky_surface_visibility: Dictionary = {}


func _ready():
	Global.spacebox_controller = self
	worklist1.visible = false  # 默认隐藏
	if DEBUG_LOGS: print("✅ SpaceBox 控制器已注册到 Global 单例")


func configure_for_runtime_profile(profile) -> void:
	_set_sky_mr_surfaces_visible(_should_show_sky_mr_surfaces(profile))


func _should_show_sky_mr_surfaces(profile) -> bool:
	return bool(
		profile != null
		and profile.is_valid()
		and profile.is_sky()
		and profile.uses_xr()
	)


func _set_sky_mr_surfaces_visible(enabled: bool) -> void:
	for node_path in SKY_MR_VISIBLE_NODE_PATHS:
		var surface := get_node_or_null(node_path) as Node3D
		if surface == null:
			push_warning("天上端舱体显示配置缺少节点：%s" % node_path)
			continue
		if not _original_sky_surface_visibility.has(node_path):
			_original_sky_surface_visibility[node_path] = surface.visible
		surface.visible = (
			true
			if enabled
			else bool(_original_sky_surface_visibility[node_path])
		)


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
