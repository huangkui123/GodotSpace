# SpaceBox.gd
extends Node3D

const DEBUG_LOGS := false
# White translucent cabin surfaces obscure the real room in Sky MR.
# Hide their drawing locally; keep collision nodes and other roles intact.
const SKY_MR_HIDDEN_NODE_PATHS: Array[NodePath] = [
	NodePath("SpaceBox/UpPlane"),
	NodePath("SpaceBox/DownPlane"),
	NodePath("SpaceBox/BackDor"),
]

@onready var environment_node := $SpaceBox/Environment_Life
@onready var dashiyangui := $SpaceBox/dashiyangui

@onready var worklist1 := $SpaceBox/WorkEffect/WorkList1

var _original_sky_surface_visibility: Dictionary = {}
var _shared_work_step_state: Node


func _ready():
	var global_node := get_node_or_null("/root/Global")
	if global_node != null:
		global_node.set("spacebox_controller", self)
	worklist1.visible = false  # 默认隐藏
	show_only_work_info(0)
	call_deferred("_bind_shared_work_step_state")
	if DEBUG_LOGS: print("✅ SpaceBox 控制器已注册到 Global 单例")


func _exit_tree() -> void:
	if _shared_work_step_state != null and is_instance_valid(_shared_work_step_state):
		var callback := Callable(self, "_on_shared_work_step_state_changed")
		if _shared_work_step_state.has_signal("work_step_state_changed") \
				and _shared_work_step_state.is_connected(
					"work_step_state_changed",
					callback
				):
			_shared_work_step_state.disconnect(
				"work_step_state_changed",
				callback
			)
	var global_node := get_node_or_null("/root/Global")
	if global_node != null and global_node.get("spacebox_controller") == self:
		global_node.set("spacebox_controller", null)


func configure_for_runtime_profile(profile) -> void:
	_set_sky_mr_surfaces_hidden(_should_hide_sky_mr_surfaces(profile))


func _should_hide_sky_mr_surfaces(profile) -> bool:
	return bool(
		profile != null
		and profile.is_valid()
		and profile.is_sky()
		and profile.uses_xr()
	)


func _set_sky_mr_surfaces_hidden(enabled: bool) -> void:
	for node_path in SKY_MR_HIDDEN_NODE_PATHS:
		var surface := get_node_or_null(node_path) as Node3D
		if surface == null:
			push_warning("天上端舱体显示配置缺少节点：%s" % node_path)
			continue
		if not _original_sky_surface_visibility.has(node_path):
			_original_sky_surface_visibility[node_path] = surface.visible
		surface.visible = (
			false
			if enabled
			else bool(_original_sky_surface_visibility[node_path])
		)


func set_worklist1_visible(visible: bool):
	if not visible and is_instance_valid(dashiyangui) and dashiyangui.has_method("clear_step"):
		dashiyangui.call("clear_step")
	if worklist1 and is_instance_valid(worklist1):
		worklist1.visible = visible
		if DEBUG_LOGS: print("✅ 设置 WorkList1 可见性为: ", visible)
	else:
		printerr("❌ WorkList1 无法访问")


func request_worklist_visibility(is_visible: bool) -> bool:
	var shared_state := _get_shared_work_step_state()
	if shared_state != null \
			and shared_state.has_method("request_worklist_visibility"):
		return bool(shared_state.call(
			"request_worklist_visibility",
			is_visible
		))
	set_worklist1_visible(is_visible)
	return true


func show_only_work_info(step_index: int):
	# Zero means no selected step: hide every authored guidance branch.
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

func play_dashiyangui_animation() -> void:
	# Legacy main-menu entry uses the same authoritative step path as replay.
	var state := _get_shared_work_step_state()
	var step := 1
	if state != null:
		step = clampi(int(state.call("get_current_state").get("active_step", 1)), 1, 20)
	request_work_step(step)
		
# ✅ 新增：让 Global.spacebox_controller.play_step(x) 成立
func play_step(step_index: int):
	if dashiyangui and dashiyangui.has_method("play_step"):
		dashiyangui.play_step(step_index)
	else:
		printerr("❌ dashiyangui 上找不到 play_step 方法")


func request_work_step(step_index: int) -> bool:
	var shared_state := _get_shared_work_step_state()
	if shared_state != null and shared_state.has_method("request_work_step"):
		return bool(shared_state.call("request_work_step", step_index))
	if step_index < 1 or step_index > 20:
		return false
	show_only_work_info(step_index)
	set_worklist1_visible(true)
	play_step(step_index)
	return true


func _bind_shared_work_step_state() -> void:
	var shared_state := _get_shared_work_step_state()
	if shared_state == null \
			or not shared_state.has_signal("work_step_state_changed"):
		return
	_shared_work_step_state = shared_state
	var callback := Callable(self, "_on_shared_work_step_state_changed")
	if not shared_state.is_connected("work_step_state_changed", callback):
		shared_state.connect("work_step_state_changed", callback)
	if shared_state.has_method("get_current_state"):
		var state := shared_state.call("get_current_state") as Dictionary
		var is_visible := bool(state.get("is_visible", false))
		var active_step := int(state.get("active_step", 0))
		_on_shared_work_step_state_changed(
			is_visible,
			active_step,
			is_visible and active_step >= 1 and active_step <= 20
		)


func _get_shared_work_step_state() -> Node:
	if _shared_work_step_state != null \
			and is_instance_valid(_shared_work_step_state):
		return _shared_work_step_state
	if get_tree() == null:
		return null
	return get_tree().get_first_node_in_group("shared_work_step_state")


func _on_shared_work_step_state_changed(
	is_visible: bool,
	active_step: int,
	replay_animation: bool
) -> void:
	var has_step := active_step >= 1 and active_step <= 20
	show_only_work_info(active_step if has_step else 0)
	set_worklist1_visible(is_visible and has_step)
	if not is_visible or not has_step:
		return
	if replay_animation or (dashiyangui.has_method("get_active_step") and int(dashiyangui.call("get_active_step")) != active_step):
		play_step(active_step)
