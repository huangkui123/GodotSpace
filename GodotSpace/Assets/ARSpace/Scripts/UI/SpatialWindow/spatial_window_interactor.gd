class_name SpatialWindowInteractor
extends Node

## Input-device-neutral spatial-window interaction state machine.
## PC mouse and XR controllers feed the same imperative methods below.

signal interaction_started(window_id: String, mode: String)
signal interaction_finished(window_id: String, mode: String, committed: bool)
signal focus_requested(window_id: String)
signal state_commit_requested(window_id: String, state: Dictionary)
signal snap_preview_changed(window_id: String, slot_id: String, active: bool)
signal haptic_requested(hand: StringName, event_name: StringName, strength: float, duration_seconds: float)

const RumbleEvent = preload("res://addons/godot-xr-tools/rumble/rumble_event.gd")

enum InteractionMode {
	IDLE,
	FOCUSED,
	NEAR_TITLE_DRAG,
	FAR_RAY_DRAG,
	RESIZE,
	SNAP_PREVIEW,
}

enum OrientationMode {
	FREE,
	FACE_USER,
	KEEP_UPRIGHT,
	LIMITED_ROTATION,
}

const MODE_NAMES: Dictionary = {
	InteractionMode.IDLE: "idle",
	InteractionMode.FOCUSED: "focused",
	InteractionMode.NEAR_TITLE_DRAG: "near_title_drag",
	InteractionMode.FAR_RAY_DRAG: "far_ray_drag",
	InteractionMode.RESIZE: "resize",
	InteractionMode.SNAP_PREVIEW: "snap_preview",
}

@export var registry_path: NodePath = NodePath("/root/SpatialWindowRegistryService")
@export var orientation_mode: OrientationMode = OrientationMode.KEEP_UPRIGHT
@export_range(0.05, 8.0, 0.05) var far_depth_speed: float = 1.4
@export_range(0.05, 4.0, 0.05) var progressive_scale_speed: float = 1.2
@export_range(1.0, 89.0, 1.0) var maximum_pitch_degrees: float = 35.0
@export_range(0.0, 45.0, 1.0) var maximum_roll_degrees: float = 10.0
@export_range(0.01, 0.5, 0.01) var snap_drag_away_distance: float = 0.12
@export_range(0.0, 1.0, 0.05) var default_haptic_strength: float = 0.35
@export_range(0.0, 0.2, 0.005) var default_haptic_duration: float = 0.035
@export_range(0.0, 1.0, 0.05) var selection_haptic_strength: float = 0.15
@export_range(0.0, 1.0, 0.05) var scale_tick_haptic_strength: float = 0.22
@export_range(0.0, 1.0, 0.05) var snap_haptic_strength: float = 0.45
@export_range(0.02, 0.5, 0.01) var scale_tick_metres: float = 0.1

var mode: InteractionMode = InteractionMode.IDLE
var active_window
var active_hand: StringName = &"none"
var active_resize_handle: String = ""
var far_depth: float = 0.0
var lease_token: String = ""
var lease_request_pending: bool = false

var _grab_to_window: Transform3D = Transform3D.IDENTITY
var _resize_start_point: Vector3
var _resize_start_size: Vector2
var _resize_start_aspect: float = 1.0
var _interaction_start_transform: Transform3D
var _interaction_start_size: Vector2
var _pre_snap_transform: Transform3D
var _pre_snap_size: Vector2
var _pre_snap_slot: String = ""
var _snap_preview_transform: Transform3D
var _snap_preview_size: Vector2
var _snap_slot_id: String = ""
var _mode_before_snap: InteractionMode = InteractionMode.FOCUSED
var _preview_sequence: int = 0
var _last_scale_tick: int = 0
var _registry: Node


func _ready() -> void:
	_registry = get_node_or_null(registry_path)
	if _registry == null:
		var candidates := get_tree().get_nodes_in_group("spatial_window_registry")
		if not candidates.is_empty():
			_registry = candidates[0]
	if _registry != null and _registry.has_signal("operation_completed"):
		var callback := Callable(self, "_on_registry_operation_completed")
		if not _registry.is_connected("operation_completed", callback):
			_registry.connect("operation_completed", callback)


func _exit_tree() -> void:
	if _registry != null and is_instance_valid(_registry) and _registry.has_signal("operation_completed"):
		var callback := Callable(self, "_on_registry_operation_completed")
		if _registry.is_connected("operation_completed", callback):
			_registry.disconnect("operation_completed", callback)


func focus_window(window) -> bool:
	if window == null or not is_instance_valid(window):
		return false
	if active_window != null and is_instance_valid(active_window) and active_window != window:
		active_window.set_focused(false)
	active_window = window
	mode = InteractionMode.FOCUSED
	active_window.set_focused(true)
	focus_requested.emit(window.window_id)
	if _registry != null and is_instance_valid(_registry):
		if _registry.has_method("select_window"):
			_registry.call("select_window", window.window_id)
		_request_registry_operation("focus")
	_emit_haptic(&"select", selection_haptic_strength)
	return true


func clear_focus() -> void:
	if _has_active_window() and mode not in [InteractionMode.IDLE, InteractionMode.FOCUSED]:
		end_interaction(false)
	if active_window != null and is_instance_valid(active_window):
		active_window.set_local_interaction_active(false)
		active_window.set_focused(false)
	active_window = null
	active_hand = &"none"
	active_resize_handle = ""
	lease_token = ""
	mode = InteractionMode.IDLE


func begin_near_title_drag(window, grab_global_transform: Transform3D, hand: StringName = &"none") -> bool:
	if not _begin_exclusive(window, InteractionMode.NEAR_TITLE_DRAG, hand):
		return false
	_grab_to_window = grab_global_transform.affine_inverse() * _get_window_global_transform(window)
	_emit_haptic(&"grab")
	return true


func update_near_title_drag(grab_global_transform: Transform3D, user_global_position: Vector3) -> bool:
	if not _is_drag_mode(InteractionMode.NEAR_TITLE_DRAG) or not _has_active_window():
		return false
	if not _lease_ready():
		return false
	var target := grab_global_transform * _grab_to_window
	target = constrain_orientation(target, user_global_position, orientation_mode, maximum_pitch_degrees, maximum_roll_degrees)
	_apply_drag_candidate(target)
	_send_transform_preview()
	return true


func begin_far_ray_drag(window, ray_origin: Vector3, ray_direction: Vector3, hit_distance: float, hand: StringName = &"none") -> bool:
	if ray_direction.length_squared() <= 0.000001:
		return false
	if not _begin_exclusive(window, InteractionMode.FAR_RAY_DRAG, hand):
		return false
	far_depth = maxf(hit_distance, 0.05)
	var hit_point := ray_origin + ray_direction.normalized() * far_depth
	_grab_to_window = Transform3D(Basis.IDENTITY, hit_point).affine_inverse() * _get_window_global_transform(window)
	_emit_haptic(&"grab")
	return true


func update_far_ray_drag(ray_origin: Vector3, ray_direction: Vector3, depth_axis: float, delta: float, user_global_position: Vector3) -> bool:
	if not _is_drag_mode(InteractionMode.FAR_RAY_DRAG) or not _has_active_window() or ray_direction.length_squared() <= 0.000001:
		return false
	if not _lease_ready():
		return false
	far_depth = maxf(0.05, far_depth + depth_axis * far_depth_speed * maxf(delta, 0.0))
	var hit_point := ray_origin + ray_direction.normalized() * far_depth
	var target := Transform3D(Basis.IDENTITY, hit_point) * _grab_to_window
	target = constrain_orientation(target, user_global_position, orientation_mode, maximum_pitch_degrees, maximum_roll_degrees)
	_apply_drag_candidate(target)
	_send_transform_preview()
	return true


func begin_resize(window, handle_name: String, grab_global_point: Vector3, hand: StringName = &"none") -> bool:
	if not SpatialWindow3D.HANDLE_NAMES.has(handle_name):
		return false
	if not _begin_exclusive(window, InteractionMode.RESIZE, hand):
		return false
	active_resize_handle = handle_name
	_resize_start_point = _window_to_local(window, grab_global_point)
	_resize_start_size = window.size_metres
	_resize_start_aspect = window.get_aspect_ratio()
	_last_scale_tick = _get_scale_tick(window.size_metres)
	_emit_haptic(&"resize_begin")
	return true


func update_resize(grab_global_point: Vector3, progressive_axis: float = 0.0, delta: float = 0.0, keep_aspect: bool = false) -> bool:
	if mode != InteractionMode.RESIZE or not _has_active_window():
		return false
	if not _lease_ready():
		return false
	var local_point := _window_to_local(active_window, grab_global_point)
	var local_delta := local_point - _resize_start_point
	var signs := get_resize_handle_signs(active_resize_handle)
	var next_size := _resize_start_size + Vector2(local_delta.x * signs.x, local_delta.y * signs.y)
	if not is_zero_approx(progressive_axis):
		var factor := exp(progressive_axis * progressive_scale_speed * maxf(delta, 0.0))
		next_size *= factor
	if keep_aspect or active_window.preserve_aspect_ratio:
		next_size = SpatialWindow3D.fit_aspect(next_size, _resize_start_aspect)
	var changed: bool = bool(active_window.set_size_metres(next_size, false))
	if changed:
		_emit_scale_tick_if_needed()
		_send_transform_preview()
	return changed


func apply_progressive_scale(axis: float, delta: float, keep_aspect: bool = true) -> bool:
	if mode != InteractionMode.RESIZE or not _has_active_window() or is_zero_approx(axis):
		return false
	if not _lease_ready():
		return false
	_last_scale_tick = _get_scale_tick(active_window.size_metres)
	var factor := exp(axis * progressive_scale_speed * maxf(delta, 0.0))
	var next_size: Vector2 = active_window.size_metres * factor
	if keep_aspect:
		next_size = SpatialWindow3D.fit_aspect(next_size, active_window.get_aspect_ratio())
	var changed: bool = bool(active_window.set_size_metres(next_size, false))
	if changed:
		_emit_scale_tick_if_needed()
	return changed


func preview_snap(slot_id: String, target_shared_transform: Transform3D, target_size: Vector2) -> bool:
	if not _has_active_window() or slot_id.is_empty():
		return false
	if lease_token.is_empty():
		if not _acquire_lease() or not _lease_ready():
			return false
	if mode != InteractionMode.SNAP_PREVIEW:
		_pre_snap_transform = active_window.get_shared_transform()
		_pre_snap_size = active_window.size_metres
		_pre_snap_slot = active_window.snap_slot
		_mode_before_snap = mode
	_snap_slot_id = slot_id.left(64)
	_snap_preview_transform = target_shared_transform
	_snap_preview_size = active_window.clamp_size(target_size)
	active_window.set_shared_transform(_snap_preview_transform)
	active_window.set_size_metres(_snap_preview_size, false)
	mode = InteractionMode.SNAP_PREVIEW
	snap_preview_changed.emit(active_window.window_id, _snap_slot_id, true)
	_emit_haptic(&"snap_preview")
	return true


func confirm_snap() -> bool:
	if mode != InteractionMode.SNAP_PREVIEW or not _has_active_window():
		return false
	active_window.set_snap_slot(_snap_slot_id, false)
	var window_id: String = str(active_window.window_id)
	var snapshot: Dictionary = active_window.get_window_state()
	state_commit_requested.emit(window_id, snapshot)
	_request_registry_operation("snap", {
		"snap_slot": _snap_slot_id,
		"shared_transform": active_window.get_shared_transform(),
		"size_m": active_window.size_metres,
		"lease_token": lease_token,
	})
	active_window.set_local_interaction_active(false)
	snap_preview_changed.emit(window_id, _snap_slot_id, false)
	_emit_haptic(&"snap_confirm", snap_haptic_strength)
	mode = InteractionMode.FOCUSED
	_snap_slot_id = ""
	lease_token = ""
	return true


func cancel_snap() -> bool:
	if mode != InteractionMode.SNAP_PREVIEW or not _has_active_window():
		return false
	var window_id: String = str(active_window.window_id)
	var old_slot := _snap_slot_id
	active_window.set_shared_transform(_pre_snap_transform)
	active_window.set_size_metres(_pre_snap_size, false)
	active_window.set_snap_slot(_pre_snap_slot, false)
	_release_lease()
	active_window.set_local_interaction_active(false)
	mode = InteractionMode.FOCUSED
	_snap_slot_id = ""
	snap_preview_changed.emit(window_id, old_slot, false)
	_emit_haptic(&"snap_cancel")
	return true


func end_interaction(commit: bool = true) -> bool:
	if not _has_active_window() or mode in [InteractionMode.IDLE, InteractionMode.FOCUSED]:
		return false
	if mode == InteractionMode.SNAP_PREVIEW:
		return confirm_snap() if commit else cancel_snap()
	var finished_mode := get_mode_name()
	var window_id: String = str(active_window.window_id)
	if commit:
		var snapshot: Dictionary = active_window.get_window_state()
		state_commit_requested.emit(window_id, snapshot)
		_commit_interaction_state()
	else:
		active_window.set_shared_transform(_interaction_start_transform)
		active_window.set_size_metres(_interaction_start_size, false)
		_release_lease()
	active_window.set_local_interaction_active(false)
	mode = InteractionMode.FOCUSED
	active_resize_handle = ""
	interaction_finished.emit(window_id, finished_mode, commit)
	_emit_haptic(&"release" if commit else &"cancel")
	lease_token = ""
	return true


func get_mode_name() -> String:
	return str(MODE_NAMES.get(mode, "unknown"))


func _begin_exclusive(window, next_mode: InteractionMode, hand: StringName) -> bool:
	if window == null or not is_instance_valid(window):
		return false
	if mode == InteractionMode.SNAP_PREVIEW:
		cancel_snap()
	elif mode not in [InteractionMode.IDLE, InteractionMode.FOCUSED]:
		end_interaction(false)
	focus_window(window)
	mode = next_mode
	active_hand = hand
	window.set_local_interaction_active(true)
	_interaction_start_transform = window.get_shared_transform()
	_interaction_start_size = window.size_metres
	if not _acquire_lease():
		window.set_local_interaction_active(false)
		mode = InteractionMode.FOCUSED
		return false
	interaction_started.emit(window.window_id, get_mode_name())
	return true


func _is_drag_mode(expected: InteractionMode) -> bool:
	return mode == expected or (mode == InteractionMode.SNAP_PREVIEW and _mode_before_snap == expected)


func _apply_drag_candidate(target_global: Transform3D) -> void:
	if mode != InteractionMode.SNAP_PREVIEW:
		_set_window_global_transform(active_window, target_global)
		return
	var snap_global: Transform3D = active_window.shared_to_global_transform(_snap_preview_transform)
	if target_global.origin.distance_to(snap_global.origin) <= snap_drag_away_distance:
		return
	var old_slot := _snap_slot_id
	active_window.set_shared_transform(_pre_snap_transform)
	active_window.set_size_metres(_pre_snap_size, false)
	active_window.set_snap_slot("", false)
	_snap_slot_id = ""
	mode = _mode_before_snap
	snap_preview_changed.emit(active_window.window_id, old_slot, false)
	_emit_haptic(&"snap_leave")
	_set_window_global_transform(active_window, target_global)


func _has_active_window() -> bool:
	return active_window != null and is_instance_valid(active_window)


func set_lease_token(value: String) -> void:
	lease_token = value.left(64)


func _acquire_lease() -> bool:
	if lease_request_pending:
		_refresh_lease_token()
		if not lease_token.is_empty():
			lease_request_pending = false
		return true
	lease_token = ""
	lease_request_pending = true
	if not _request_registry_operation("acquire_lease", {"timeout_msec": 5000}):
		lease_request_pending = false
		return false
	_refresh_lease_token()
	if not lease_token.is_empty():
		lease_request_pending = false
	return true


func _release_lease() -> void:
	_refresh_lease_token()
	if not lease_token.is_empty():
		_request_registry_operation("release_lease", {"lease_token": lease_token})
	lease_token = ""
	lease_request_pending = false


func _lease_ready() -> bool:
	_refresh_lease_token()
	if lease_token.is_empty():
		return false
	lease_request_pending = false
	return true


func _refresh_lease_token() -> void:
	if not _has_active_window() or _registry == null or not is_instance_valid(_registry) or not _registry.has_method("get_window_state"):
		return
	var current = _registry.call("get_window_state", active_window.window_id)
	if current is Dictionary:
		var state := current as Dictionary
		if int(state.get("lease_peer_id", 0)) == multiplayer.get_unique_id():
			lease_token = str(state.get("lease_token", "")).left(64)


func _send_transform_preview() -> void:
	if not _has_active_window():
		return
	_refresh_lease_token()
	if lease_token.is_empty():
		return
	_preview_sequence += 1
	_request_registry_operation("transform_preview", {
		"shared_transform": active_window.get_shared_transform(),
		"stream_sequence": _preview_sequence,
		"lease_token": lease_token,
	})


func _commit_interaction_state() -> void:
	if not _has_active_window():
		return
	_refresh_lease_token()
	if lease_token.is_empty():
		return
	var transform_changed: bool = not active_window.get_shared_transform().is_equal_approx(_interaction_start_transform)
	var size_changed: bool = not active_window.size_metres.is_equal_approx(_interaction_start_size)
	if transform_changed or size_changed:
		_request_registry_operation("transform_commit", {
			"shared_transform": active_window.get_shared_transform(),
			"size_m": active_window.size_metres,
			"lease_token": lease_token,
			"release_lease": true,
		})
	if not transform_changed and not size_changed:
		_release_lease()


func _request_registry_operation(operation: String, payload: Dictionary = {}) -> bool:
	if not _has_active_window() or _registry == null or not is_instance_valid(_registry) or not _registry.has_method("request_operation"):
		return false
	return bool(_registry.call("request_operation", active_window.window_id, operation, payload))


func _on_registry_operation_completed(result: Dictionary) -> void:
	if not _has_active_window():
		return
	if str(result.get("window_id", "")) != active_window.window_id:
		return
	var operation := str(result.get("operation", ""))
	if operation == "acquire_lease" and bool(result.get("accepted", false)):
		lease_request_pending = false
		_refresh_lease_token()
		if mode in [InteractionMode.IDLE, InteractionMode.FOCUSED] and not lease_token.is_empty():
			_release_lease()
		return
	if bool(result.get("accepted", false)):
		return
	if operation not in ["acquire_lease", "transform_commit", "resize_commit", "snap"]:
		return
	var failed_mode := get_mode_name()
	active_window.set_local_interaction_active(false)
	if _registry != null and _registry.has_method("get_window_state"):
		var authoritative = _registry.call("get_window_state", active_window.window_id)
		if authoritative is Dictionary and not (authoritative as Dictionary).is_empty():
			active_window.apply_authoritative_state(authoritative)
		else:
			active_window.set_shared_transform(_interaction_start_transform)
			active_window.set_size_metres(_interaction_start_size, false)
	lease_token = ""
	lease_request_pending = false
	active_resize_handle = ""
	mode = InteractionMode.FOCUSED
	interaction_finished.emit(active_window.window_id, failed_mode, false)
	_emit_haptic(&"cancel")


func _get_window_global_transform(window) -> Transform3D:
	if window.has_method("get_interaction_global_transform"):
		return window.call("get_interaction_global_transform") as Transform3D
	return window.global_transform if window.is_inside_tree() else window.transform


func _set_window_global_transform(window, value: Transform3D) -> void:
	if window.has_method("set_interaction_global_transform"):
		window.call("set_interaction_global_transform", value)
		return
	if window.is_inside_tree():
		window.global_transform = value
	else:
		window.transform = value


func _window_to_local(window, global_point: Vector3) -> Vector3:
	return _get_window_global_transform(window).affine_inverse() * global_point


func _emit_scale_tick_if_needed() -> void:
	if not _has_active_window():
		return
	var next_tick := _get_scale_tick(active_window.size_metres)
	if next_tick == _last_scale_tick:
		return
	_last_scale_tick = next_tick
	_emit_haptic(&"scale_tick", scale_tick_haptic_strength)


func _get_scale_tick(size: Vector2) -> int:
	return roundi(maxf(size.x, size.y) / maxf(scale_tick_metres, 0.001))


func _emit_haptic(event_name: StringName, strength: float = -1.0) -> void:
	var magnitude := default_haptic_strength if strength < 0.0 else clampf(strength, 0.0, 1.0)
	haptic_requested.emit(active_hand, event_name, magnitude, default_haptic_duration)
	var tracker := _tracker_for_hand(active_hand)
	if tracker.is_empty() or magnitude <= 0.0 or XRServer.primary_interface == null:
		return
	var rumble_manager := get_node_or_null(NodePath("/root/XRToolsRumbleManager"))
	if rumble_manager == null or not rumble_manager.has_method("add"):
		return
	var event := RumbleEvent.new()
	event.magnitude = magnitude
	event.duration_ms = maxi(roundi(default_haptic_duration * 1000.0), 10)
	var event_key := "%s:%s" % [get_instance_id(), event_name]
	rumble_manager.call("add", event_key, event, [tracker])


func _tracker_for_hand(hand: StringName) -> StringName:
	if hand in [&"left", &"left_hand"]:
		return &"left_hand"
	if hand in [&"right", &"right_hand"]:
		return &"right_hand"
	return &""


static func get_resize_handle_signs(handle_name: String) -> Vector2:
	var x_sign := 0.0
	var y_sign := 0.0
	if "Left" in handle_name:
		x_sign = -1.0
	elif "Right" in handle_name:
		x_sign = 1.0
	if "Top" in handle_name:
		y_sign = 1.0
	elif "Bottom" in handle_name:
		y_sign = -1.0
	return Vector2(x_sign, y_sign)


static func constrain_orientation(source: Transform3D, user_global_position: Vector3, orientation: OrientationMode, maximum_pitch: float, maximum_roll: float) -> Transform3D:
	if orientation == OrientationMode.FREE:
		return source
	var to_user := user_global_position - source.origin
	if to_user.length_squared() <= 0.000001:
		return source
	if orientation == OrientationMode.KEEP_UPRIGHT:
		to_user.y = 0.0
		if to_user.length_squared() <= 0.000001:
			return source
		return source.looking_at(source.origin + to_user.normalized(), Vector3.UP)
	if orientation == OrientationMode.FACE_USER:
		return source.looking_at(user_global_position, Vector3.UP)
	var euler := source.basis.get_euler()
	euler.x = clampf(euler.x, deg_to_rad(-maximum_pitch), deg_to_rad(maximum_pitch))
	euler.z = clampf(euler.z, deg_to_rad(-maximum_roll), deg_to_rad(maximum_roll))
	return Transform3D(Basis.from_euler(euler), source.origin)
