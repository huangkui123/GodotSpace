extends "res://addons/godot-xr-tools/objects/viewport_2d_in_3d_body.gd"

## XR Tools forwards every laser-pointer action as both touch and mouse input.
## The reconstruction panel uses the mouse stream for its single-pointer UI and
## suppresses the duplicate touch stream here. Input remains local to this
## client, so delayed EXITED events during scene teardown never access a missing
## multiplayer context.


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	if not is_inside_tree() \
			or not is_instance_valid(_viewport) \
			or not is_instance_valid(event) \
			or not is_instance_valid(event.pointer):
		return
	_handle_pointer_event(0, event)


func _report_touch_down(_index: int, _at: Vector2) -> void:
	pass


func _report_touch_up(_index: int, _at: Vector2) -> void:
	pass


func _report_touch_move(
	_index: int,
	_pressed: bool,
	_from: Vector2,
	_to: Vector2
) -> void:
	pass
