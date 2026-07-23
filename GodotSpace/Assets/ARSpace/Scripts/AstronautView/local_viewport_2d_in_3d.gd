extends XRToolsViewport2DIn3D

## The astronaut monitor is the one intentionally local spatial window. The
## vendored viewport script synchronizes pointer/drag state to the Server, where
## this node path does not exist, so this subclass keeps the same XR interaction
## while handling it only in the owning Ground VR process.


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	var controller = _get_controller_from_pointer(event.pointer)
	var grip_value: float = 0.0
	if controller != null:
		grip_value = controller.get_float(grip_action)
	_handle_pointer_event(multiplayer.get_unique_id(), event, grip_value)


func _sync_window_transform_to_server(_reliable: bool) -> void:
	pass
