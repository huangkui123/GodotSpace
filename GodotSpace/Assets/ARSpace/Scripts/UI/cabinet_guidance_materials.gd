extends Node3D

const SymbolShader := preload("res://Assets/ARSpace/Shader/guidance_symbol.gdshader")
const StepGuidance := preload("res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_guidance.gd")
const SYMBOL_MATERIALS := ["M_Arrow.material", "M_Arrow_Big.material", "M_Arrow_L.material", "M_Circle.material"]


func _ready() -> void:
	StepGuidance.install(get_parent())
	_prepare(get_parent())


func _prepare(node: Node) -> void:
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		if instance.mesh != null:
			for surface in instance.mesh.get_surface_count():
				var source := instance.get_active_material(surface) as BaseMaterial3D
				if source == null:
					continue
				if source.resource_path.get_file() in SYMBOL_MATERIALS:
					var symbol := ShaderMaterial.new()
					symbol.shader = SymbolShader
					symbol.set_shader_parameter("symbol_texture", source.albedo_texture)
					symbol.set_shader_parameter("symbol_color", source.emission if source.emission_enabled else source.albedo_color)
					symbol.set_shader_parameter("uv_scale", source.uv1_scale)
					symbol.set_shader_parameter("uv_offset", source.uv1_offset)
					instance.set_surface_override_material(surface, symbol)
					instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				elif source.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					# Other animated effects keep their authored appearance, but
					# transparent texels must not write invisible occluding planes.
					var copy := source.duplicate(false) as BaseMaterial3D
					copy.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
					instance.set_surface_override_material(surface, copy)
	for child in node.get_children():
		_prepare(child)
