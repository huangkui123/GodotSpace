@tool
extends Node3D

const StrokeRenderer := preload(
	"res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_stroke_renderer.gd"
)
const PanelSurfaceScene := preload(
	"res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingPanelSurface.tscn"
)
const TipScene := preload(
	"res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingTip.tscn"
)
const PREVIEW_COLOR := Color(1.0, 0.03, 0.03, 1.0)

@export var show_editor_preview: bool = true

var _preview_root: Node3D


func _ready() -> void:
	if not Engine.is_editor_hint():
		set_process(false)
		return
	set_process(true)
	call_deferred("_refresh_editor_preview")


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	var should_show := show_editor_preview and DisplayServer.get_name() != "headless"
	if should_show and not is_instance_valid(_preview_root):
		_create_editor_preview()
	elif not should_show and is_instance_valid(_preview_root):
		_clear_editor_preview()


func _exit_tree() -> void:
	_clear_editor_preview()


func _refresh_editor_preview() -> void:
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	_clear_editor_preview()
	if show_editor_preview and DisplayServer.get_name() != "headless":
		_create_editor_preview()


func _create_editor_preview() -> void:
	if is_instance_valid(_preview_root):
		return
	_preview_root = Node3D.new()
	_preview_root.name = "EditorPreviewGenerated"
	add_child(_preview_root, false, Node.INTERNAL_MODE_FRONT)
	_add_real_panel_surface()
	_add_real_tip()
	_add_production_stroke_mesh()


func _add_real_panel_surface() -> void:
	var panel_surface := PanelSurfaceScene.instantiate() as Node3D
	if panel_surface == null:
		push_warning("SpatialDrawing editor preview could not instantiate the production panel.")
		return
	panel_surface.name = "ProductionPanelSurfacePreview"
	panel_surface.position = Vector3(-0.16, -0.16, 0.0)
	_preview_root.add_child(panel_surface)


func _add_real_tip() -> void:
	var tip := TipScene.instantiate() as Node3D
	if tip == null:
		push_warning("SpatialDrawing editor preview could not instantiate the production tip.")
		return
	tip.name = "ProductionTipPreview"
	tip.position = Vector3(0.18, -0.16, 0.025)
	tip.rotation_degrees = Vector3(-12.0, -28.0, 0.0)
	_preview_root.add_child(tip)
	if tip.has_method("set_tool_color"):
		tip.call("set_tool_color", PREVIEW_COLOR)


func _add_production_stroke_mesh() -> void:
	var points := PackedVector3Array([
		Vector3(-0.48, 0.22, 0.0),
		Vector3(-0.30, 0.38, 0.0),
		Vector3(-0.08, 0.19, 0.0),
		Vector3(0.12, 0.40, 0.0),
		Vector3(0.30, 0.20, 0.0),
		Vector3(0.48, 0.34, 0.0),
	])
	var stroke := MeshInstance3D.new()
	stroke.name = "ProductionStrokeMeshPreview"
	stroke.mesh = StrokeRenderer.build_tube_mesh(points, 0.012, PREVIEW_COLOR, 8)
	stroke.material_override = StrokeRenderer.make_stroke_material(PREVIEW_COLOR, false)
	stroke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_preview_root.add_child(stroke)


func _clear_editor_preview() -> void:
	if not is_instance_valid(_preview_root):
		_preview_root = null
		return
	remove_child(_preview_root)
	_preview_root.queue_free()
	_preview_root = null
