# SpaceBox.gd
extends Node3D

const DEBUG_LOGS := false
const CABIN_SHELL_MESH_PATHS: Array[NodePath] = [
	NodePath("SpaceBox/FrontDor/MeshRenderer"),
	NodePath("SpaceBox/RightPlane/MeshRenderer"),
	NodePath("SpaceBox/LeftPlane/MeshRenderer"),
	NodePath("SpaceBox/UpPlane/MeshRenderer"),
	NodePath("SpaceBox/DownPlane/MeshRenderer"),
	NodePath("SpaceBox/BackDor/MeshRenderer"),
]
const SKY_MR_HIDDEN_NODE_PATHS: Array[NodePath] = [
	NodePath("SpaceBox/DownPlane"),
	NodePath("SpaceBox/BackDor"),
]

@onready var environment_node := $SpaceBox/Environment_Life
@onready var dashiyangui := $SpaceBox/dashiyangui

@onready var worklist1 := $SpaceBox/WorkEffect/WorkList1

var _original_shell_materials: Dictionary = {}
var _original_sky_hidden_visibility: Dictionary = {}
var _sky_mr_transparency_enabled: bool = false


func _ready():
	Global.spacebox_controller = self
	worklist1.visible = false  # 默认隐藏
	if DEBUG_LOGS: print("✅ SpaceBox 控制器已注册到 Global 单例")


func configure_for_runtime_profile(
	profile,
	passthrough_enabled: bool = true
) -> void:
	var sky_mr_enabled := _should_enable_sky_mr_transparency(
		profile,
		passthrough_enabled
	)
	_set_sky_mr_transparency(sky_mr_enabled)
	_set_sky_mr_hidden_surfaces(sky_mr_enabled)


func _should_enable_sky_mr_transparency(
	profile,
	passthrough_enabled: bool
) -> bool:
	return bool(
		profile != null
		and profile.is_valid()
		and profile.is_sky()
		and profile.uses_xr()
		and profile.uses_passthrough()
		and passthrough_enabled
	)


func _set_sky_mr_transparency(enabled: bool) -> void:
	_cache_original_shell_materials()
	if _sky_mr_transparency_enabled == enabled:
		return

	for mesh_path in CABIN_SHELL_MESH_PATHS:
		var mesh_instance := get_node_or_null(mesh_path) as MeshInstance3D
		if mesh_instance == null:
			push_warning("舱体透明配置缺少网格：%s" % mesh_path)
			continue
		var original_material = _original_shell_materials.get(mesh_path)
		if not enabled:
			mesh_instance.set_surface_override_material(0, original_material)
			continue
		var source_material := original_material as BaseMaterial3D
		if source_material == null:
			source_material = mesh_instance.get_active_material(0) as BaseMaterial3D
		if source_material == null:
			push_warning("舱体透明配置缺少材质：%s" % mesh_path)
			continue
		var transparent_material := _make_sky_mr_material(source_material)
		mesh_instance.set_surface_override_material(0, transparent_material)

	_sky_mr_transparency_enabled = enabled


func _make_sky_mr_material(
	source_material: BaseMaterial3D
) -> BaseMaterial3D:
	var transparent_material := source_material.duplicate(true) as BaseMaterial3D
	transparent_material.resource_local_to_scene = true
	transparent_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return transparent_material


func _set_sky_mr_hidden_surfaces(enabled: bool) -> void:
	for node_path in SKY_MR_HIDDEN_NODE_PATHS:
		var surface := get_node_or_null(node_path) as Node3D
		if surface == null:
			push_warning("天上端舱体隐藏配置缺少节点：%s" % node_path)
			continue
		if not _original_sky_hidden_visibility.has(node_path):
			_original_sky_hidden_visibility[node_path] = surface.visible
		surface.visible = (
			false
			if enabled
			else bool(_original_sky_hidden_visibility[node_path])
		)


func _cache_original_shell_materials() -> void:
	for mesh_path in CABIN_SHELL_MESH_PATHS:
		if _original_shell_materials.has(mesh_path):
			continue
		var mesh_instance := get_node_or_null(mesh_path) as MeshInstance3D
		if mesh_instance == null:
			continue
		_original_shell_materials[mesh_path] = (
			mesh_instance.get_surface_override_material(0)
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
