extends Node3D

const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")

const DEFAULT_DIMENSIONS := Vector3(0.45, 1.21, 0.80)
var dimensions := DEFAULT_DIMENSIONS


## Uses the solver's front-bottom-left origin. The box center is an offset,
## not the calibrated origin; no eye-height or half-height correction belongs here.
func set_dimensions(value: Vector3) -> void:
	if not Geometry.valid_dimensions(value):
		return
	dimensions = value
	var body := $Body as MeshInstance3D
	(body.mesh as BoxMesh).size = value
	body.position = Vector3(value.x * 0.5, value.y * 0.5, -value.z * 0.5)
	$Status.position = Vector3(value.x * 0.5, value.y + 0.1, 0)


func show_uncalibrated_label(show_label: bool) -> void:
	$Status.visible = show_label
