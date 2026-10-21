extends "res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_controller.gd"

## Reuse the existing grip/ray drag without shared docking or network authority.
var calibration: Node


func _resolve_services() -> void:
	_dock_manager = null
	_state_manager = null
	_shared_origin = null
	_viewpoint = _get_viewpoint()


func _get_viewpoint() -> Node3D:
	if not is_instance_valid(calibration):
		return null
	var origin := calibration.call("_get_local_xr_origin") as XROrigin3D
	return origin.get_node_or_null("XRCamera3D") as Node3D if origin != null else null


func get_window_pixel_size() -> Vector2:
	return Vector2(1280, 900)
