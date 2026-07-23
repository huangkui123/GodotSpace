extends XRToolsViewport2DIn3D

## Adapter for business-owned spatial windows. The surface still maps XR ray
## input into its SubViewport, while drag and network authority live in the
## sibling SpatialWindowController rather than the vendored XR Tools script.

signal spatial_pointer_event(event: XRToolsPointerEvent, controller: Node3D, grip_value: float)
signal content_visibility_changed(is_visible: bool)


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	var controller := _get_controller_from_pointer(event.pointer) as Node3D
	var grip_value: float = 0.0
	if controller != null and controller.has_method("get_float"):
		grip_value = float(controller.call("get_float", grip_action))
	_handle_pointer_event(multiplayer.get_unique_id(), event, grip_value)
	spatial_pointer_event.emit(event, controller, grip_value)


@rpc("any_peer", "call_remote", "reliable", 0)
func server_receive_pointer_event(_data: Dictionary) -> void:
	# Raw node paths and input events are never accepted from a remote peer.
	pass


@rpc("any_peer", "call_remote", "unreliable", 0)
func server_receive_window_transform(_window_transform: Transform3D) -> void:
	# SpatialWindowStateManager owns the validated transform protocol.
	pass


@rpc("any_peer", "call_remote", "reliable", 0)
func server_receive_window_transform_reliable(_window_transform: Transform3D) -> void:
	# SpatialWindowStateManager owns the validated transform protocol.
	pass


func _sync_window_transform_to_server(_reliable: bool) -> void:
	pass


func _position_window_relative_to_last_clicked() -> void:
	# Opening is owned by SpatialWindowSpawnPolicy in meter-based world space.
	pass


func _get_target_child_node() -> Node:
	if not is_instance_valid(scene_node):
		return null
	if scene_node is CanvasLayer:
		for child in scene_node.get_children():
			if child is CanvasItem:
				return child
	return scene_node


func _on_child_visibility_changed() -> void:
	super._on_child_visibility_changed()
	var content := _get_target_child_node()
	content_visibility_changed.emit(content == null or bool(content.get("visible")))


func is_content_visible() -> bool:
	var content := _get_target_child_node()
	return content == null or bool(content.get("visible"))


func get_content_visibility_node() -> Node:
	return _get_target_child_node()
