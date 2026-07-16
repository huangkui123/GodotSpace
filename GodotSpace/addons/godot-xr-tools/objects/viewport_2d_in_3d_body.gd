extends XRToolsInteractableBody


## Screen size
@export var screen_size = Vector2(3.0, 2.0)

## Viewport size
@export var viewport_size = Vector2(100.0, 100.0)


# Current mouse mask
var _mouse_mask := 0

# Viewport node
var _viewport : Viewport

# Dictionary of pointers to touch-index
var _touches := {}

# Dictionary of pressed pointers
var _presses := {}

# Dominant pointer (index == 0)
var _dominant : Node3D

# Mouse pointer
var _mouse : Node3D

# Last mouse position
var _mouse_last := Vector2.ZERO


func _ready():
	# Get viewport node
	_viewport = get_node("../Viewport")

	# Subscribe to pointer events
	pointer_event.connect(_on_pointer_event)


## Convert intersection point to screen coordinate
func global_to_viewport(p_at : Vector3) -> Vector2:
	var t = $CollisionShape3D.global_transform
	var at = t.affine_inverse() * p_at

	# Convert to screen space
	at.x = ((at.x / screen_size.x) + 0.5) * viewport_size.x
	at.y = (0.5 - (at.y / screen_size.y)) * viewport_size.y

	return Vector2(at.x, at.y)


# Pointer event handler
func _on_pointer_event(event: XRToolsPointerEvent):
	if _uses_application_window_registry():
		_handle_pointer_event(multiplayer.get_unique_id(), event)
		return
	if multiplayer.is_server():
		pass
	else:
		# 如果是客户端，把事件信息发给服务器
		var data = {
			"event_type": event.event_type,
			"pointer_name": event.pointer.get_path(),
			"target_name": event.target.get_path(),
			"position": event.position,
			"last_position": event.last_position
		}
		# print("客户端发送点击事件到服务器: ", data)
		rpc_id(1, "server_receive_pointer_event", data)
		_handle_pointer_event(multiplayer.get_unique_id(), event)


@rpc("any_peer")
func server_receive_pointer_event(data: Dictionary):
	if _uses_application_window_registry():
		return
	# 这里一定只会在服务器跑
	var sender_id = multiplayer.get_remote_sender_id()

	var pointer_node : Node3D = null
	if data.has("pointer_name") and data.pointer_name != NodePath(""):
		pointer_node = get_node_or_null(data.pointer_name)
	var target_node : Node3D = null
	if data.has("target_name") and data.target_name != NodePath(""):
		target_node = get_node_or_null(data.target_name)

	# 如果想在服务器端复现事件，可以构造一个假的 XRToolsPointerEvent
	var fake_event = XRToolsPointerEvent.new(
		data.get("event_type", XRToolsPointerEvent.Type.PRESSED),
		pointer_node,
		target_node,
		data.get("position", Vector3.ZERO),
		data.get("last_position", Vector3.ZERO),
	)

	# if data.get("event_type") == 2:
	# 	print("服务器收到来自 %s 的点击事件: %s" % [sender_id, data.get("event_type", "unknown")])
	# 	print("pointer_node: ", pointer_node)
	# 	print("target_node: ", target_node)

	_handle_pointer_event(sender_id, fake_event)


func _uses_application_window_registry() -> bool:
	var viewport_window := get_parent()
	return viewport_window != null and viewport_window.get_node_or_null("SpatialWindowAdapter") != null


func _handle_pointer_event(player_id: int, event: XRToolsPointerEvent):
	# Ignore if we have no viewport
	if not is_instance_valid(_viewport):
		return

	# Get the pointer and event type
	var pointer := event.pointer
	var type := event.event_type

	# Get the touch-index [0..]
	var index : int = _touches.get(pointer, -1)

	# Create a new touch-index if necessary
	if index < 0 or type == XRToolsPointerEvent.Type.ENTERED:
		# Clear any stale pointer information
		_touches.erase(pointer)
		_presses.erase(pointer)

		# Assign a new touch-index for the pointer
		index = _next_touch_index()
		_touches[pointer] = index

		# Detect dominant pointer
		if index == 0:
			_dominant = pointer

	# Get the viewport positions
	var at := global_to_viewport(event.position)
	var last := global_to_viewport(event.last_position)

	# Get/update pressed state
	var pressed : bool
	match type:
		XRToolsPointerEvent.Type.PRESSED:
			_presses[pointer] = true
			pressed = true

		XRToolsPointerEvent.Type.RELEASED:
			_presses.erase(pointer)
			pressed = false

		_:
			pressed = _presses.has(pointer)

	# Dispatch touch events
	match type:
		XRToolsPointerEvent.Type.PRESSED:
			_report_touch_down(index, at)

		XRToolsPointerEvent.Type.RELEASED:
			_report_touch_up(index, at)

		XRToolsPointerEvent.Type.MOVED:
			_report_touch_move(index, pressed, last, at)

	# If the current mouse isn't pressed then consider switching to a new one
	if not _presses.has(_mouse):
		if type == XRToolsPointerEvent.Type.PRESSED and pointer is XRToolsFunctionPointer:
			# Switch to pressed laser-pointer
			_mouse = pointer
		elif type == XRToolsPointerEvent.Type.EXITED and pointer == _mouse:
			# Current mouse leaving, switch to dominant
			_mouse = _dominant
		elif not _mouse and _dominant:
			# No mouse, pick the dominant
			_mouse = _dominant

	# Fire mouse events
	if pointer == _mouse:
		match type:
			XRToolsPointerEvent.Type.PRESSED:
				_report_mouse_down(at)

			XRToolsPointerEvent.Type.RELEASED:
				_report_mouse_up( at)

			XRToolsPointerEvent.Type.MOVED:
				_report_mouse_move(pressed, last, at)

	# Clear pointer information on exit
	if type == XRToolsPointerEvent.Type.EXITED:
		# Clear pointer information
		_touches.erase(pointer)
		_presses.erase(pointer)
		if pointer == _dominant:
			_dominant = null
		if pointer == _mouse:
			_mouse = null


# Report touch-down event
func _report_touch_down(index : int, at : Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = true
	_viewport.push_input(event)


# Report touch-up event
func _report_touch_up(index : int, at : Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = false
	_viewport.push_input(event)


# Report touch-move event
func _report_touch_move(index : int, pressed : bool, from : Vector2, to : Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = to
	event.pressure = 1.0 if pressed else 0.0
	event.relative = to - from
	_viewport.push_input(event)


# Report mouse-down event
func _report_mouse_down(at : Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = 1
	event.pressed = true
	event.position = at
	event.global_position = at
	event.button_mask = 1
	_viewport.push_input(event)


# Report mouse-up event
func _report_mouse_up(at : Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = 1
	event.pressed = false
	event.position = at
	event.global_position = at
	event.button_mask = 0
	_viewport.push_input(event)


# Report mouse-move event
func _report_mouse_move(pressed : bool, from : Vector2, to : Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - from
	event.button_mask = 1 if pressed else 0
	event.pressure = 1.0 if pressed else 0.0
	_viewport.push_input(event)


# Find the next free touch index
func _next_touch_index() -> int:
	# Get the current touches
	var current := _touches.values()
	current.sort()

	# Look for a hole
	for touch in current.size():
		if current[touch] != touch:
			return touch

	# No hole so add to end
	return current.size()
