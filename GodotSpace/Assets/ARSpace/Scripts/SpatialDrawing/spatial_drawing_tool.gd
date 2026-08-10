@tool
class_name SpatialDrawingTool
extends Node3D

@export var tool_color: Color = Color(1.0, 0.03, 0.03, 1.0):
	set(value):
		if tool_color.is_equal_approx(value):
			return
		tool_color = value
		_apply_tool_color()

var _tip_indicator: MeshInstance3D
var _body_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	_cache_visuals()
	_apply_tool_color()


func set_tool_color(color: Color) -> void:
	tool_color = color


func get_tip_indicator() -> MeshInstance3D:
	_cache_visuals()
	return _tip_indicator


func get_body_meshes() -> Array[MeshInstance3D]:
	_cache_visuals()
	return _body_meshes.duplicate()


func _cache_visuals() -> void:
	if _tip_indicator == null or not is_instance_valid(_tip_indicator):
		_tip_indicator = get_node_or_null("TipIndicator") as MeshInstance3D
	if not _body_meshes.is_empty():
		return
	var model_root := get_node_or_null("ToolModel")
	if model_root == null:
		return
	for child in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance != null:
			_body_meshes.append(mesh_instance)


func _apply_tool_color() -> void:
	if not is_inside_tree():
		return
	_cache_visuals()
	if _tip_indicator != null:
		var tip_material := _tip_indicator.material_override as StandardMaterial3D
		if tip_material == null:
			tip_material = StandardMaterial3D.new()
			tip_material.resource_local_to_scene = true
			tip_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			tip_material.emission_enabled = true
			_tip_indicator.material_override = tip_material
		tip_material.albedo_color = tool_color
		tip_material.emission = tool_color
	for body_mesh in _body_meshes:
		var body_material := body_mesh.material_override as StandardMaterial3D
		if body_material == null:
			body_material = StandardMaterial3D.new()
			body_material.resource_local_to_scene = true
			body_material.metallic = 0.12
			body_material.roughness = 0.38
			body_mesh.material_override = body_material
		body_material.albedo_color = tool_color
