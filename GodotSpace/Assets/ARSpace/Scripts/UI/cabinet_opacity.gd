extends Node3D

## Local presentation only. Never hide the parent: animations, tips and ray
## targets below the cabinet must survive the zero-opacity endpoint.
const Surface := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_panel_surface.gd")
const Style := preload("res://Assets/ARSpace/Scripts/UI/sky_panel_style.gd")
const SmoothShader := preload("res://Assets/ARSpace/Shader/cabinet_smooth.gdshader")
const DepthCapture := preload("res://Assets/ARSpace/Scripts/UI/cabinet_depth_capture.gd")
# Only fixed housings. Covers, screws, sample boxes and the core are animated
# instruction objects, even though they share the imported cabinet hierarchy.
const BODY_BRANCHES := ["dashiyangui", "xiaoshiyangui/xiaoshiyangui_a"]
const GUIDANCE_BRANCHES := ["OldTips", "NewTips", "zhongxinjigouTips"]

var opacity: float = 1.0
var _materials: Array[Dictionary] = []
var _meshes: Array[Dictionary] = []
var _slider: HSlider
var _caption: Label
var _capture: Node


func _enter_tree() -> void:
	get_parent().add_to_group("independent_cabinet_visuals")


func _ready() -> void:
	for branch in BODY_BRANCHES:
		var node := get_parent().get_node_or_null(NodePath(branch))
		if node != null:
			_collect_body(node)
	_capture = DepthCapture.new()
	for entry in _meshes:
		_capture.sources.append(entry.mesh)
	for entry in _materials:
		_capture.materials.append(entry.material)
	add_child(_capture)
	_build_slider()
	set_opacity(opacity)


func _collect_body(node: Node) -> void:
	if str(node.name) in GUIDANCE_BRANCHES or node.is_in_group("cabinet_guidance"):
		return
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		_meshes.append({"mesh": instance, "shadow": instance.cast_shadow})
		if instance.material_override is BaseMaterial3D:
			instance.material_override = _copy_material(instance.material_override)
		elif instance.mesh != null:
			for index in range(instance.mesh.get_surface_count()):
				var material := instance.get_active_material(index)
				if material == null or material is BaseMaterial3D:
					instance.set_surface_override_material(index, _copy_material(material))
	for child in node.get_children():
		_collect_body(child)


func _copy_material(source: BaseMaterial3D) -> ShaderMaterial:
	if source == null:
		source = StandardMaterial3D.new()
	var copy := ShaderMaterial.new()
	var smooth := Shader.new()
	var cull := ["cull_back", "cull_front", "cull_disabled"][source.cull_mode] as String
	smooth.code = SmoothShader.code.replace("cull_back", cull)
	if not source.normal_enabled:
		smooth.code = smooth.code.replace("NORMAL_MAP = texture(normal_map, mapped_uv).rgb;", "").replace("NORMAL_MAP_DEPTH = normal_scale;", "")
	var solid := Shader.new()
	solid.code = smooth.code.replace("depth_draw_never", "depth_draw_opaque").replace("ALPHA = cabinet_opacity;", "")
	copy.shader = solid
	for pair in [["albedo_color", source.albedo_color], ["albedo_map", source.albedo_texture],
		["has_albedo_map", source.albedo_texture != null], ["vertex_albedo", source.vertex_color_use_as_albedo],
		["unshaded", source.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED],
		["uv_scale", source.uv1_scale], ["uv_offset", source.uv1_offset],
		["metallic_value", source.metallic], ["specular_value", source.metallic_specular],
		["roughness_value", source.roughness], ["metallic_map", source.metallic_texture],
		["roughness_map", source.roughness_texture], ["normal_enabled", source.normal_enabled],
		["normal_map", source.normal_texture], ["normal_scale", source.normal_scale]]:
		copy.set_shader_parameter(pair[0], pair[1])
	var channels := [Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0), Vector4(0, 0, 0, 1), Vector4(0.333333, 0.333333, 0.333333, 0)]
	copy.set_shader_parameter("metallic_channel", channels[source.metallic_texture_channel])
	copy.set_shader_parameter("roughness_channel", channels[source.roughness_texture_channel])
	_materials.append({"material": copy, "solid": solid, "smooth": smooth, "source": source})
	return copy


func set_opacity(value: float) -> void:
	if not is_finite(value):
		return
	opacity = clampf(value, 0.0, 1.0)
	for entry in _materials:
		var material := entry.material as ShaderMaterial
		material.shader = entry.solid if opacity == 1.0 else entry.smooth
		material.set_shader_parameter("cabinet_opacity", opacity)
	if _capture != null:
		_capture.opacity = opacity
	for entry in _meshes:
		(entry.mesh as MeshInstance3D).cast_shadow = entry.shadow if opacity == 1.0 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _slider != null:
		_slider.set_value_no_signal(opacity * 100.0)
		_caption.text = "柜体显示  %d%%" % roundi(opacity * 100.0)


func _build_slider() -> void:
	var anchor := get_parent().get_node_or_null("dashiyangui/MeshRenderer") as MeshInstance3D
	if anchor == null or anchor.mesh == null:
		return
	var panel := Node3D.new()
	panel.name = "CabinetOpacityPanel"
	add_child(panel)
	# This imported CAD's front is +X, with screen-right along -Z. Follow scaling
	# and alignment without depending on the user's view or screen resolution.
	var bounds := anchor.get_aabb()
	panel.transform = global_transform.affine_inverse() * anchor.global_transform
	panel.position += panel.basis * Vector3(bounds.end.x + 0.04, bounds.position.y + 0.18, bounds.position.z + 0.24)
	panel.basis *= Basis(Vector3.UP, PI * 0.5)
	var viewport := SubViewport.new()
	viewport.name = "Viewport"
	viewport.size = Vector2i(480, 120)
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	panel.add_child(viewport)
	var ui := PanelContainer.new()
	ui.size = Vector2(480, 120)
	ui.theme = Style.make_theme(24)
	ui.add_theme_stylebox_override("panel", Style.box(Style.BACKGROUND, 12))
	viewport.add_child(ui)
	var column := VBoxContainer.new()
	ui.add_child(column)
	_caption = Label.new()
	column.add_child(_caption)
	_slider = HSlider.new()
	_slider.name = "CabinetOpacitySlider"
	_slider.max_value = 100
	_slider.step = 1
	_slider.custom_minimum_size.y = 48
	_slider.tooltip_text = "仅调节本机固定柜壳；拆装部件、标注和操作指导保持显示"
	_slider.value_changed.connect(func(value: float): set_opacity(value / 100.0))
	column.add_child(_slider)
	var screen := MeshInstance3D.new()
	screen.name = "Screen"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.48, 0.12)
	screen.mesh = quad
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.disable_fog = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = viewport.get_texture()
	screen.material_override = material
	panel.add_child(screen)
	var body := StaticBody3D.new()
	body.name = "StaticBody3D"
	body.set_script(Surface)
	body.set("screen_size", quad.size)
	body.set("viewport_size", Vector2(viewport.size))
	body.collision_layer = 1 << 20
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.48, 0.12, 0.01)
	collision.shape = shape
	body.add_child(collision)
	panel.add_child(body)
