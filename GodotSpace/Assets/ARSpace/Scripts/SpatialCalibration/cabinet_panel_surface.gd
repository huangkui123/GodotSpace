extends XRToolsInteractableBody

## Private XR surface: all pointer events remain local to this SubViewport.
## Explicit local coordinates avoid desktop screen transforms in stereo VR.
@export var screen_size := Vector2(1.28, 0.9)
@export var viewport_size := Vector2(1280, 900)

var _pressed_pointer: Node3D
@onready var _viewport: SubViewport = get_node("../Viewport")


func _ready() -> void:
	pointer_event.connect(_on_pointer_event)
	get_parent().visibility_changed.connect(_cancel_press_if_hidden)


func global_to_viewport(at: Vector3) -> Vector2:
	var local := global_transform.affine_inverse() * at
	return Vector2((local.x / screen_size.x + 0.5) * viewport_size.x,
		(0.5 - local.y / screen_size.y) * viewport_size.y)


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	if not is_instance_valid(event.pointer) or not get_parent().is_visible_in_tree():
		return
	if is_instance_valid(_pressed_pointer) and _pressed_pointer != event.pointer:
		return
	var window := get_node_or_null("../SpatialWindowController")
	var controller: Node = event.pointer
	while controller != null and not controller is XRController3D:
		controller = controller.get_parent()
	var gripping := controller != null and float(controller.call("get_float", "grip")) >= 0.7
	if gripping or (window != null and bool(window.call("is_local_drag_active"))):
		_cancel_press()
		return
	var position := global_to_viewport(event.position)
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED, XRToolsPointerEvent.Type.MOVED:
			var motion := InputEventMouseMotion.new()
			motion.position = position
			motion.global_position = position
			motion.relative = position - global_to_viewport(event.last_position)
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT if is_instance_valid(_pressed_pointer) else 0
			_viewport.push_input(motion, true)
		XRToolsPointerEvent.Type.PRESSED:
			_pressed_pointer = event.pointer
			_push_button(position, true)
		XRToolsPointerEvent.Type.RELEASED:
			_push_button(position, false)
			_pressed_pointer = null
		XRToolsPointerEvent.Type.EXITED:
			if _pressed_pointer == event.pointer:
				_push_button(position, false)
				_pressed_pointer = null
			var motion := InputEventMouseMotion.new()
			motion.position = Vector2(-1, -1)
			motion.global_position = motion.position
			_viewport.push_input(motion, true)


func _push_button(position: Vector2, pressed: bool) -> void:
	var button := InputEventMouseButton.new()
	button.position = position
	button.global_position = position
	button.button_index = MOUSE_BUTTON_LEFT
	button.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	button.pressed = pressed
	_viewport.push_input(button, true)


func _cancel_press() -> void:
	if is_instance_valid(_pressed_pointer):
		var motion := InputEventMouseMotion.new()
		motion.position = Vector2(-1, -1)
		motion.global_position = motion.position
		_viewport.push_input(motion, true)
		_push_button(motion.position, false)
		_pressed_pointer = null


func _cancel_press_if_hidden() -> void:
	if not get_parent().is_visible_in_tree():
		_cancel_press()
