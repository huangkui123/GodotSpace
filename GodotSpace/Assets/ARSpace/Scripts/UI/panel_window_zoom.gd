extends RefCounted

const DEFAULT_ZOOM_FACTOR := 1.6
const META_BOUND := &"panel_window_zoom_bound"


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


static func toggle_window(panel_root: Node, _zoom_factor: float = DEFAULT_ZOOM_FACTOR) -> void:
	var controller := _get_window_controller(panel_root)
	if controller == null or not controller.has_method("request_toggle_maximized"):
		push_warning("Panel window is not migrated to SpatialWindow3D yet.")
		return
	controller.call("request_toggle_maximized")


static func set_window_visible(panel_root: Node, is_visible: bool) -> void:
	var controller := _get_window_controller(panel_root)
	if controller != null and controller.has_method("request_visibility"):
		controller.call("request_visibility", is_visible)
	elif panel_root != null:
		panel_root.visible = is_visible


static func _get_window_controller(panel_root: Node) -> Node:
	if panel_root == null:
		return null
	var direct_adapter := panel_root.get_node_or_null("SpatialWindowAdapter")
	if direct_adapter != null:
		return direct_adapter
	var viewport := panel_root.get_viewport()
	if viewport != null:
		var viewport_parent := viewport.get_parent()
		if viewport_parent is Node3D:
			var adapter := viewport_parent.get_node_or_null("SpatialWindowAdapter")
			if adapter != null:
				return adapter

	var current := panel_root
	while current != null:
		if current.has_method("request_toggle_maximized"):
			return current
		current = current.get_parent()
	return null
