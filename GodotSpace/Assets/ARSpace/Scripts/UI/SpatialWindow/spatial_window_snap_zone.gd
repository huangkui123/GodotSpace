class_name SpatialWindowSnapZone
extends Node3D

@export var slot_id: String = "center_primary"
@export var target_size_m := Vector2(1.2, 0.8)
@export var preview_color := Color(0.05, 0.72, 1.0, 0.22)

var _preview: MeshInstance3D


func _ready() -> void:
	add_to_group("spatial_window_snap_zone")
	_build_preview()
	var interactor := get_node_or_null("/root/SpatialWindowInteractorService")
	if interactor != null and interactor.has_signal("snap_preview_changed"):
		interactor.connect("snap_preview_changed", _on_snap_preview_changed)


func _exit_tree() -> void:
	var interactor := get_node_or_null("/root/SpatialWindowInteractorService")
	if interactor != null and is_instance_valid(interactor) \
			and interactor.has_signal("snap_preview_changed") \
			and interactor.is_connected("snap_preview_changed", _on_snap_preview_changed):
		interactor.disconnect("snap_preview_changed", _on_snap_preview_changed)


func _build_preview() -> void:
	_preview = MeshInstance3D.new()
	_preview.name = "SnapPreview"
	var mesh := QuadMesh.new()
	mesh.size = target_size_m
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = preview_color
	material.emission_enabled = true
	material.emission = Color(preview_color.r, preview_color.g, preview_color.b)
	material.emission_energy_multiplier = 1.4
	material.no_depth_test = true
	mesh.material = material
	_preview.mesh = mesh
	_preview.visible = false
	add_child(_preview)


func _on_snap_preview_changed(_window_id: String, changed_slot_id: String, active: bool) -> void:
	_preview.visible = active and changed_slot_id == slot_id
