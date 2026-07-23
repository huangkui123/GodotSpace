extends RefCounted

const DEFAULT_ZOOM_FACTOR := 1.6
const META_BOUND := &"panel_window_zoom_bound"
const META_MAXIMIZED := &"panel_window_zoom_maximized"
const META_ORIGINAL_SCALE := &"panel_window_zoom_original_scale"


static func bind_max_button(panel_root: Node, zoom_factor: float = DEFAULT_ZOOM_FACTOR) -> void:
	if panel_root == null:
		return

	var max_button := panel_root.find_child("MaxButton", true, false)
	if max_button == null or max_button.has_meta(META_BOUND):
		return

	if max_button is Button:
		max_button.disabled = false
		max_button.tooltip_text = "Zoom/Restore"
		max_button.pressed.connect(func(): toggle_window(panel_root, zoom_factor))
		max_button.set_meta(META_BOUND, true)


static func toggle_window(panel_root: Node, zoom_factor: float = DEFAULT_ZOOM_FACTOR) -> void:
	var spatial_controller := _get_spatial_window_controller(panel_root)
	if spatial_controller != null:
		spatial_controller.set("maximized_scale_factor", zoom_factor)
		spatial_controller.call("toggle_zoom")
		return
	var target := _get_window_target(panel_root)
	if target == null:
		return

	if bool(target.get_meta(META_MAXIMIZED, false)):
		_restore(target)
	else:
		_maximize(target, zoom_factor)


static func set_window_visible(panel_root: Node, is_visible: bool) -> void:
	var spatial_controller := _get_spatial_window_controller(panel_root)
	if spatial_controller != null:
		if is_visible:
			spatial_controller.call("open_window", null, true)
		else:
			spatial_controller.call("close_window")
		return
	var target := _get_window_target(panel_root)
	if target != null:
		target.visible = is_visible


static func _maximize(target: Node, zoom_factor: float) -> void:
	if target is Node3D:
		if not target.has_meta(META_ORIGINAL_SCALE):
			target.set_meta(META_ORIGINAL_SCALE, (target as Node3D).scale)
		(target as Node3D).scale = ((target as Node3D).get_meta(META_ORIGINAL_SCALE) as Vector3) * zoom_factor
	elif target is Control:
		if not target.has_meta(META_ORIGINAL_SCALE):
			target.set_meta(META_ORIGINAL_SCALE, (target as Control).scale)
		(target as Control).scale = ((target as Control).get_meta(META_ORIGINAL_SCALE) as Vector2) * zoom_factor
	else:
		return

	target.set_meta(META_MAXIMIZED, true)


static func _restore(target: Node) -> void:
	if not target.has_meta(META_ORIGINAL_SCALE):
		target.set_meta(META_MAXIMIZED, false)
		return

	if target is Node3D:
		(target as Node3D).scale = target.get_meta(META_ORIGINAL_SCALE) as Vector3
	elif target is Control:
		(target as Control).scale = target.get_meta(META_ORIGINAL_SCALE) as Vector2

	target.set_meta(META_MAXIMIZED, false)


static func _get_window_target(panel_root: Node) -> Node:
	var viewport := panel_root.get_viewport()
	if viewport != null:
		var viewport_parent := viewport.get_parent()
		if viewport_parent is Node3D:
			return viewport_parent

	return panel_root


static func _get_spatial_window_controller(panel_root: Node) -> Node:
	var target := _get_window_target(panel_root)
	if target == null:
		return null
	if target.has_method("toggle_zoom") and target.has_method("open_window"):
		return target
	for child in target.get_children():
		if child.has_method("toggle_zoom") and child.has_method("open_window"):
			return child
	return null
