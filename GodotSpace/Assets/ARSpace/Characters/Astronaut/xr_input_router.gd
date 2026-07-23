extends Node

const PoseState = preload("res://Assets/ARSpace/Characters/Astronaut/avatar_pose_state.gd")

signal input_mode_changed(input_mode: int)
signal interaction_state_changed(state: Dictionary)

@export var camera_path: NodePath = NodePath("../XRCamera3D")
@export var left_controller_path: NodePath = NodePath("../LeftHand")
@export var right_controller_path: NodePath = NodePath("../RightHand")
@export var left_pointer_path: NodePath = NodePath("../LeftHand/FunctionPointer")
@export var right_pointer_path: NodePath = NodePath("../RightHand/FunctionPointer")
@export var left_pickup_path: NodePath = NodePath("../LeftHand/LeftHand/FunctionPickup")
@export var right_pickup_path: NodePath = NodePath("../RightHand/RightHand/FunctionPickup")
@export var gaze_pointer_path: NodePath = NodePath("../XRCamera3D/HeadGazePointer")

const POINTER_ACTION: String = "__xr_input_router_select"
const SELECT_PRESS_THRESHOLD: float = 0.65
const SELECT_RELEASE_THRESHOLD: float = 0.45

var _input_mode: int = PoseState.INPUT_MODE_RIGHT_HAND
var _requested_input_mode: int = PoseState.INPUT_MODE_RIGHT_HAND
var _state: Dictionary = PoseState.make_default()
var _previous_buttons: Dictionary = {}
var _test_override_enabled: bool = false
var _test_trigger: float = 0.0
var _test_grip: float = 0.0
var _test_trigger_click: bool = false
var _test_grip_click: bool = false
var _pointer_select_pressed: bool = false
var _pressed_pointer: Node = null

@onready var _camera: XRCamera3D = get_node_or_null(camera_path) as XRCamera3D
@onready var _left_controller: XRController3D = get_node_or_null(left_controller_path) as XRController3D
@onready var _right_controller: XRController3D = get_node_or_null(right_controller_path) as XRController3D

func _ready() -> void:
	_configure_pointer(get_node_or_null(left_pointer_path))
	_configure_pointer(get_node_or_null(right_pointer_path))
	_configure_pointer(get_node_or_null(gaze_pointer_path))
	_apply_pointer_mode()

func _process(_delta: float) -> void:
	var tracking_mask := _sample_tracking_mask()
	_handle_mode_buttons()
	var resolved_mode := resolve_mode_for_tracking(_requested_input_mode, tracking_mask)
	if resolved_mode != _input_mode:
		_release_pointer_selection()
		_input_mode = resolved_mode
		input_mode_changed.emit(_input_mode)
		_apply_pointer_mode()

	var left_trigger := _read_action_value(_left_controller, &"trigger", &"trigger_click")
	var left_grip := _read_action_value(_left_controller, &"grip", &"grip_click")
	var right_trigger := _read_action_value(_right_controller, &"trigger", &"trigger_click")
	var right_grip := _read_action_value(_right_controller, &"grip", &"grip_click")
	if _test_override_enabled:
		right_trigger = merge_axis_and_click(_test_trigger, _test_trigger_click)
		right_grip = merge_axis_and_click(_test_grip, _test_grip_click)
	_update_pointer_selection(left_trigger, right_trigger)

	var gesture_bits := 0
	if _read_button(_left_controller, &"ax_button"):
		gesture_bits |= PoseState.GESTURE_LEFT_PRIMARY
	if _read_button(_right_controller, &"ax_button"):
		gesture_bits |= PoseState.GESTURE_RIGHT_PRIMARY
	if left_trigger >= 0.65 or _read_button(_left_controller, &"trigger_click"):
		gesture_bits |= PoseState.GESTURE_LEFT_TRIGGER_CLICK
	if right_trigger >= 0.65 or _read_button(_right_controller, &"trigger_click"):
		gesture_bits |= PoseState.GESTURE_RIGHT_TRIGGER_CLICK
	if left_grip >= 0.65 or _read_button(_left_controller, &"grip_click"):
		gesture_bits |= PoseState.GESTURE_LEFT_GRIP_CLICK
	if right_grip >= 0.65 or _read_button(_right_controller, &"grip_click"):
		gesture_bits |= PoseState.GESTURE_RIGHT_GRIP_CLICK

	var next_state := PoseState.from_actions(
		tracking_mask,
		_input_mode,
		left_trigger,
		left_grip,
		right_trigger,
		right_grip,
		gesture_bits
	)
	if next_state != _state:
		_state = next_state
		interaction_state_changed.emit(_state.duplicate(true))

func set_input_mode(input_mode: int) -> void:
	var normalized := clampi(input_mode, PoseState.INPUT_MODE_HEAD_GAZE, PoseState.INPUT_MODE_RIGHT_HAND)
	_requested_input_mode = normalized
	var resolved := resolve_mode_for_tracking(_requested_input_mode, _sample_tracking_mask())
	if resolved != _input_mode:
		_release_pointer_selection()
		_input_mode = resolved
		input_mode_changed.emit(_input_mode)
		_apply_pointer_mode()

func get_input_mode() -> int:
	return _input_mode

func get_network_state() -> Dictionary:
	return _state.duplicate(true)

func set_test_input(
	trigger_value: float,
	grip_value: float,
	enabled: bool = true,
	trigger_click: bool = false,
	grip_click: bool = false
) -> void:
	_test_override_enabled = enabled
	_test_trigger = clampf(trigger_value, 0.0, 1.0)
	_test_grip = clampf(grip_value, 0.0, 1.0)
	_test_trigger_click = trigger_click
	_test_grip_click = grip_click

func get_active_ray_transform() -> Transform3D:
	match _input_mode:
		PoseState.INPUT_MODE_LEFT_HAND:
			return _left_controller.global_transform if _left_controller != null else Transform3D.IDENTITY
		PoseState.INPUT_MODE_RIGHT_HAND:
			return _right_controller.global_transform if _right_controller != null else Transform3D.IDENTITY
		_:
			return _camera.global_transform if _camera != null else Transform3D.IDENTITY

func is_select_pressed() -> bool:
	match _input_mode:
		PoseState.INPUT_MODE_LEFT_HAND:
			return PoseState.dequantize_axis(_state["left_trigger_q"]) >= 0.65
		PoseState.INPUT_MODE_RIGHT_HAND:
			return PoseState.dequantize_axis(_state["right_trigger_q"]) >= 0.65
		_:
			return PoseState.dequantize_axis(_state["right_trigger_q"]) >= 0.65 \
				or PoseState.dequantize_axis(_state["left_trigger_q"]) >= 0.65

func is_grip_pressed() -> bool:
	match _input_mode:
		PoseState.INPUT_MODE_LEFT_HAND:
			return PoseState.dequantize_axis(_state["left_grip_q"]) >= 0.65
		PoseState.INPUT_MODE_RIGHT_HAND:
			return PoseState.dequantize_axis(_state["right_grip_q"]) >= 0.65
		_:
			return false

func get_scroll_axis() -> float:
	var controller := _left_controller if _input_mode == PoseState.INPUT_MODE_LEFT_HAND else _right_controller
	if controller == null or _input_mode == PoseState.INPUT_MODE_HEAD_GAZE:
		return 0.0
	return controller.get_vector2(&"primary").y

func resolve_mode_for_tracking(requested_mode: int, tracking_mask: int) -> int:
	if requested_mode == PoseState.INPUT_MODE_LEFT_HAND \
			and (tracking_mask & PoseState.TRACKING_LEFT_HAND) != 0:
		return requested_mode
	if requested_mode == PoseState.INPUT_MODE_RIGHT_HAND \
			and (tracking_mask & PoseState.TRACKING_RIGHT_HAND) != 0:
		return requested_mode
	if requested_mode == PoseState.INPUT_MODE_HEAD_GAZE:
		return requested_mode
	if (tracking_mask & PoseState.TRACKING_RIGHT_HAND) != 0:
		return PoseState.INPUT_MODE_RIGHT_HAND
	if (tracking_mask & PoseState.TRACKING_LEFT_HAND) != 0:
		return PoseState.INPUT_MODE_LEFT_HAND
	return PoseState.INPUT_MODE_HEAD_GAZE

func _sample_tracking_mask() -> int:
	if _test_override_enabled:
		return PoseState.TRACKING_ALL
	var mask := PoseState.TRACKING_HEAD
	if _controller_has_tracking(_left_controller):
		mask |= PoseState.TRACKING_LEFT_HAND
	if _controller_has_tracking(_right_controller):
		mask |= PoseState.TRACKING_RIGHT_HAND
	return mask

func _controller_has_tracking(controller: XRController3D) -> bool:
	if controller == null or not controller.is_inside_tree():
		return false
	if controller.has_method("get_has_tracking_data"):
		return bool(controller.call("get_has_tracking_data"))
	if controller.has_method("get_is_active"):
		return bool(controller.call("get_is_active"))
	return controller.visible

func _read_axis(controller: XRController3D, action: StringName) -> float:
	if controller == null or not _controller_has_tracking(controller):
		return 0.0
	var value := controller.get_float(action)
	return clampf(value, 0.0, 1.0) if is_finite(value) else 0.0

func _read_action_value(
	controller: XRController3D,
	axis_action: StringName,
	click_action: StringName
) -> float:
	return merge_axis_and_click(
		_read_axis(controller, axis_action),
		_read_button(controller, click_action)
	)

func merge_axis_and_click(axis_value: float, click_pressed: bool) -> float:
	return 1.0 if click_pressed else clampf(axis_value, 0.0, 1.0)

func _read_button(controller: XRController3D, action: StringName) -> bool:
	return controller != null and _controller_has_tracking(controller) and controller.is_button_pressed(action)

func _handle_mode_buttons() -> void:
	var left_select := _read_button(_left_controller, &"ax_button")
	var right_select := _read_button(_right_controller, &"ax_button")
	var gaze_select := _read_button(_left_controller, &"by_button") \
		or _read_button(_right_controller, &"by_button")
	if left_select and not bool(_previous_buttons.get("left", false)):
		set_input_mode(PoseState.INPUT_MODE_LEFT_HAND)
	elif right_select and not bool(_previous_buttons.get("right", false)):
		set_input_mode(PoseState.INPUT_MODE_RIGHT_HAND)
	elif gaze_select and not bool(_previous_buttons.get("gaze", false)):
		set_input_mode(PoseState.INPUT_MODE_HEAD_GAZE)
	_previous_buttons = {"left": left_select, "right": right_select, "gaze": gaze_select}

func _apply_pointer_mode() -> void:
	_set_pointer_enabled(get_node_or_null(left_pointer_path), _input_mode == PoseState.INPUT_MODE_LEFT_HAND)
	_set_pointer_enabled(get_node_or_null(right_pointer_path), _input_mode == PoseState.INPUT_MODE_RIGHT_HAND)
	_set_pointer_enabled(get_node_or_null(gaze_pointer_path), _input_mode == PoseState.INPUT_MODE_HEAD_GAZE)
	_set_function_enabled(get_node_or_null(left_pickup_path), _input_mode == PoseState.INPUT_MODE_LEFT_HAND)
	_set_function_enabled(get_node_or_null(right_pickup_path), _input_mode == PoseState.INPUT_MODE_RIGHT_HAND)

func _configure_pointer(pointer: Node) -> void:
	if pointer != null:
		pointer.set("active_button_action", POINTER_ACTION)

func _set_pointer_enabled(pointer: Node, enabled: bool) -> void:
	if pointer == null:
		return
	pointer.set("enabled", enabled)
	pointer.set("show_laser", 1 if enabled else 0)
	if pointer is Node3D:
		(pointer as Node3D).visible = enabled

func _set_function_enabled(function_node: Node, enabled: bool) -> void:
	if function_node != null:
		function_node.set("enabled", enabled)

func _update_pointer_selection(left_trigger: float, right_trigger: float) -> void:
	var select_value := 0.0
	match _input_mode:
		PoseState.INPUT_MODE_LEFT_HAND:
			select_value = left_trigger
		PoseState.INPUT_MODE_RIGHT_HAND:
			select_value = right_trigger
		_:
			select_value = maxf(left_trigger, right_trigger)
	if not _pointer_select_pressed and select_value >= SELECT_PRESS_THRESHOLD:
		var pointer := _get_active_pointer()
		if pointer != null and bool(pointer.get("enabled")):
			_pointer_select_pressed = true
			_pressed_pointer = pointer
			pointer.call("_button_pressed")
	elif _pointer_select_pressed and select_value <= SELECT_RELEASE_THRESHOLD:
		_release_pointer_selection()

func _release_pointer_selection() -> void:
	if _pointer_select_pressed and is_instance_valid(_pressed_pointer):
		_pressed_pointer.call("_button_released")
	_pointer_select_pressed = false
	_pressed_pointer = null

func _get_active_pointer() -> Node:
	match _input_mode:
		PoseState.INPUT_MODE_LEFT_HAND:
			return get_node_or_null(left_pointer_path)
		PoseState.INPUT_MODE_RIGHT_HAND:
			return get_node_or_null(right_pointer_path)
		_:
			return get_node_or_null(gaze_pointer_path)
