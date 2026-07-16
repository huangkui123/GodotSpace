class_name SpatialWindowAdapter
extends Node

## Bridges the migrated XR Tools viewport renderer to the application-owned
## SpatialWindow registry. The parent stays responsible only for rendering and
## pointer mapping; IDs, authority, transforms, modes and snapshots live here.

signal window_state_applied(window_id: String, state: Dictionary)
signal interaction_rejected(window_id: String, reason: String)

const REGISTRY_PATH := NodePath("/root/SpatialWindowRegistryService")
const MODE_NORMAL := "normal"
const MODE_MAXIMIZED := "maximized"
const MODE_SNAPPED := "snapped"
const MODE_CLOSED := "closed"
const PointerEvent = preload("res://addons/godot-xr-tools/events/pointer_event.gd")
const INTERACTOR_PATH := NodePath("/root/SpatialWindowInteractorService")

@export var window_id: String = ""
@export var window_type: String = "generic"
@export var unique_per_type: bool = true
@export var default_size_m := Vector2(1.2, 0.8)
@export var maximized_size_m := Vector2(2.2, 1.5)
@export var min_size_m := Vector2(0.2, 0.2)
@export var max_size_m := Vector2(3.0, 3.0)
@export var starts_visible: bool = true
@export var follow_content_visibility: bool = true
@export var preserve_aspect_ratio: bool = true
@export_range(24.0, 120.0, 1.0) var title_bar_pixels: float = 70.0
@export_range(8.0, 48.0, 1.0) var resize_handle_pixels: float = 22.0
@export_range(0.05, 1.0, 0.01) var snap_preview_distance_m: float = 0.28

var size_metres: Vector2:
	get:
		return _last_size_m
var snap_slot: String:
	get:
		return _snap_slot

var _window: Node3D
var _shared_origin: Node3D
var _registry: Node
var _content: CanvasItem
var _base_scale := Vector3.ONE
var _last_rigid_transform := Transform3D.IDENTITY
var _last_size_m := Vector2.ZERO
var _last_content_visible: bool = true
var _last_legacy_dragging: bool = false
var _lease_token: String = ""
var _stream_sequence: int = 0
var _applying_state: bool = false
var _registered: bool = false
var _interactor: Node
var _normal_size_m := Vector2.ZERO
var _mode: String = MODE_NORMAL
var _snap_slot: String = ""
var _is_focused: bool = false
var _local_interaction_active: bool = false
var _focus_visual: Node3D
var _interaction_pointer: Node3D
var _pointer_interaction_kind: String = ""
var _last_pointer_position := Vector3.ZERO
var _mouse_depth_axis: float = 0.0
var _desktop_pointer: Node3D
var _desktop_pointer_active: bool = false


func _ready() -> void:
	add_to_group("spatial_window_adapter")
	_window = get_parent() as Node3D
	if _window == null or window_id.strip_edges().is_empty():
		push_error("SpatialWindowAdapter requires a Node3D parent and a stable window_id.")
		set_process(false)
		return
	window_id = window_id.strip_edges()
	window_type = window_type.strip_edges()
	_window.set_meta("spatial_window_id", window_id)
	_window.set_meta("spatial_window_type", window_type)
	_base_scale = _window.transform.basis.get_scale()
	if _base_scale.x <= 0.000001 or _base_scale.y <= 0.000001 or _base_scale.z <= 0.000001:
		_base_scale = Vector3.ONE
	_shared_origin = _resolve_shared_space_origin()
	if _shared_origin == null:
		push_error("SpatialWindowAdapter requires exactly one SharedSpaceOrigin.")
		set_process(false)
		return
	_last_rigid_transform = _read_rigid_transform()
	_last_size_m = default_size_m
	_normal_size_m = default_size_m
	_last_content_visible = starts_visible
	call_deferred("_finish_setup")


func _exit_tree() -> void:
	if _window != null and is_instance_valid(_window) and _window.has_signal("pointer_event"):
		var pointer_callback := Callable(self, "_on_window_pointer_event")
		if _window.is_connected("pointer_event", pointer_callback):
			_window.disconnect("pointer_event", pointer_callback)
	if _registered and _registry != null and _registry.has_method("unregister_window"):
		_registry.call("unregister_window", window_id)
	if _desktop_pointer != null and is_instance_valid(_desktop_pointer):
		_desktop_pointer.queue_free()
	_unbind_registry()


func _process(_delta: float) -> void:
	if _window == null or _applying_state:
		return
	_resolve_content()
	_sync_content_visibility()
	_capture_legacy_renderer_drag()
	_update_pointer_interaction(_delta)


func _unhandled_input(event: InputEvent) -> void:
	var mouse_button := event as InputEventMouseButton
	if mouse_button != null:
		if mouse_button.button_index == MOUSE_BUTTON_LEFT:
			if mouse_button.pressed:
				_begin_desktop_pointer_interaction(mouse_button.position)
			elif _desktop_pointer_active:
				_desktop_pointer_active = false
				_finish_pointer_interaction(true)
			return
		if mouse_button.pressed and _interactor != null and _interactor.get("active_window") == self:
			if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
				_mouse_depth_axis += 1.0
			elif mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_mouse_depth_axis -= 1.0
	var mouse_motion := event as InputEventMouseMotion
	if mouse_motion != null and _desktop_pointer_active:
		_update_desktop_pointer_ray(mouse_motion.position)


func request_toggle_maximized() -> bool:
	var current := get_state()
	var mode := str(current.get("mode", MODE_NORMAL))
	var next_mode := MODE_NORMAL if mode == MODE_MAXIMIZED else MODE_MAXIMIZED
	if mode == MODE_NORMAL:
		_normal_size_m = current.get("size_m", _last_size_m) as Vector2
	var next_size := _normal_size_m if next_mode == MODE_NORMAL else maximized_size_m
	if not _is_network_session_active():
		current["mode"] = next_mode
		current["size_m"] = _clamp_size(next_size)
		current["visible"] = true
		return apply_window_state(current)
	return request_operation("set_mode", {"mode": next_mode, "size_m": _clamp_size(next_size)})


func request_visibility(is_visible: bool) -> bool:
	if not _is_network_session_active():
		var state := get_state()
		state["mode"] = MODE_NORMAL if is_visible else MODE_CLOSED
		state["visible"] = is_visible
		return apply_window_state(state)
	if is_visible:
		return request_operation("open", _build_descriptor())
	return request_operation("close")


func request_focus() -> bool:
	if not _is_network_session_active():
		set_focused(true)
		return true
	return request_operation("focus")


func request_snap(snap_slot: String, shared_transform: Transform3D, size_m: Vector2) -> bool:
	return request_operation("snap", {
		"snap_slot": snap_slot,
		"shared_transform": shared_transform,
		"size_m": size_m,
		"lease_token": _lease_token,
	})


func request_unsnap(shared_transform: Transform3D) -> bool:
	return request_operation("transform_commit", {
		"shared_transform": shared_transform,
		"lease_token": _lease_token,
		"release_lease": true,
	})


func request_resize(size_m: Vector2, reliable: bool = true) -> bool:
	if not reliable:
		_last_size_m = _clamp_size(size_m)
		_apply_parent_transform(_last_rigid_transform, _last_size_m)
		return true
	return request_operation("resize_commit", {
		"size_m": size_m,
		"lease_token": _lease_token,
		"release_lease": true,
	})


func request_transform(shared_transform: Transform3D, reliable: bool = true) -> bool:
	_stream_sequence += 1
	return request_operation("transform_commit" if reliable else "transform_preview", {
		"shared_transform": shared_transform,
		"lease_token": _lease_token,
		"stream_sequence": _stream_sequence,
		"release_lease": reliable,
	})


func acquire_interaction_lease(timeout_msec: int = 3000) -> bool:
	return request_operation("acquire_lease", {"timeout_msec": timeout_msec})


func release_interaction_lease() -> bool:
	if _lease_token.is_empty():
		return true
	return request_operation("release_lease", {"lease_token": _lease_token})


func request_operation(operation: String, payload: Dictionary = {}) -> bool:
	if _registry == null:
		_bind_registry()
	if _registry == null or not _registry.has_method("request_operation"):
		interaction_rejected.emit(window_id, "registry_unavailable")
		return false
	var accepted := bool(_registry.call("request_operation", window_id, operation, payload))
	if not accepted:
		interaction_rejected.emit(window_id, "operation_rejected:%s" % operation)
	return accepted


func get_state() -> Dictionary:
	if _registry != null and _registry.has_method("get_window_state"):
		var value = _registry.call("get_window_state", window_id)
		if value is Dictionary and not (value as Dictionary).is_empty():
			return (value as Dictionary).duplicate(true)
	return _build_descriptor()


func apply_window_state(state: Dictionary) -> bool:
	if _window == null or str(state.get("window_id", "")) != window_id:
		return false
	var transform_value = state.get("shared_transform", null)
	var size_value = state.get("size_m", null)
	if not (transform_value is Transform3D) or not (size_value is Vector2):
		return false
	_resolve_content()
	var size_m := _clamp_size(size_value as Vector2)
	var was_visible := _window.visible
	var was_content_visible := _content.visible if _content != null else was_visible
	_applying_state = true
	_last_rigid_transform = transform_value as Transform3D
	_last_size_m = size_m
	_lease_token = str(state.get("lease_token", ""))
	_snap_slot = str(state.get("snap_slot", ""))
	_apply_parent_transform(_last_rigid_transform, size_m)
	var mode := str(state.get("mode", MODE_NORMAL))
	_mode = mode
	if mode == MODE_NORMAL:
		_normal_size_m = size_m
	var is_visible := bool(state.get("visible", mode != MODE_CLOSED)) and mode != MODE_CLOSED
	_window.visible = is_visible
	_window.set_meta("spatial_window_focus_order", int(state.get("focus_order", 0)))
	if "_last_drag_position" in _window:
		_window.set("_last_drag_position", _window.global_position)
	if _content != null:
		_content.visible = is_visible
		_last_content_visible = is_visible
	_applying_state = false
	if was_visible != is_visible or was_content_visible != is_visible:
		_notify_business_visibility(is_visible)
	window_state_applied.emit(window_id, state.duplicate(true))
	return true


func get_shared_rigid_transform() -> Transform3D:
	return _read_rigid_transform()


func get_physical_size_m() -> Vector2:
	return _last_size_m


func set_size_metres(value: Vector2, _emit_commit: bool = true) -> bool:
	var next_size := _clamp_size(value)
	if next_size.is_equal_approx(_last_size_m):
		return false
	_last_size_m = next_size
	_apply_parent_transform(_last_rigid_transform, _last_size_m)
	return true


func clamp_size(value: Vector2) -> Vector2:
	return _clamp_size(value)


func get_aspect_ratio() -> float:
	return _last_size_m.x / maxf(_last_size_m.y, 0.001)


func set_focused(value: bool, _focus_order: int = -1) -> void:
	_is_focused = value
	_window.set_meta("spatial_window_focused", value)
	if _focus_visual != null:
		_focus_visual.visible = value


func is_focused() -> bool:
	return _is_focused


func set_local_interaction_active(value: bool) -> void:
	_local_interaction_active = value


func set_snap_slot(value: String, _emit_commit: bool = true) -> void:
	_snap_slot = value.left(64)


func get_shared_transform() -> Transform3D:
	return _last_rigid_transform


func set_shared_transform(value: Transform3D) -> void:
	_last_rigid_transform = Transform3D(value.basis.orthonormalized(), value.origin)
	_apply_parent_transform(_last_rigid_transform, _last_size_m)


func shared_to_global_transform(value: Transform3D) -> Transform3D:
	return _shared_origin.global_transform * value


func global_to_shared_transform(value: Transform3D) -> Transform3D:
	return _shared_origin.global_transform.affine_inverse() * value


func get_interaction_global_transform() -> Transform3D:
	return shared_to_global_transform(_last_rigid_transform)


func set_interaction_global_transform(value: Transform3D) -> void:
	set_shared_transform(global_to_shared_transform(value))


func get_window_state() -> Dictionary:
	return {
		"window_id": window_id,
		"shared_transform": _last_rigid_transform,
		"size_m": _last_size_m,
		"mode": str(get_state().get("mode", MODE_NORMAL)),
		"visible": _window.visible,
		"snap_slot": _snap_slot,
	}


func apply_authoritative_state(value: Dictionary) -> bool:
	return apply_window_state(value)


func _finish_setup() -> void:
	_resolve_content()
	if _content != null:
		_last_content_visible = _content.visible
	_bind_registry()
	_interactor = get_node_or_null(INTERACTOR_PATH)
	if "allow_window_drag" in _window:
		_window.set("allow_window_drag", false)
	if _window.has_signal("pointer_event"):
		var pointer_callback := Callable(self, "_on_window_pointer_event")
		if not _window.is_connected("pointer_event", pointer_callback):
			_window.connect("pointer_event", pointer_callback)
	_ensure_focus_visual()
	_register_with_registry()


func _bind_registry() -> void:
	_unbind_registry()
	_registry = get_node_or_null(REGISTRY_PATH)
	if _registry == null:
		return
	if _registry.has_signal("window_state_changed"):
		var callback := Callable(self, "_on_registry_window_state_changed")
		if not _registry.is_connected("window_state_changed", callback):
			_registry.connect("window_state_changed", callback)
	if _registry.has_signal("window_preview_changed"):
		var preview_callback := Callable(self, "_on_registry_window_preview_changed")
		if not _registry.is_connected("window_preview_changed", preview_callback):
			_registry.connect("window_preview_changed", preview_callback)
	if _registry.has_signal("operation_completed"):
		var operation_callback := Callable(self, "_on_registry_operation_completed")
		if not _registry.is_connected("operation_completed", operation_callback):
			_registry.connect("operation_completed", operation_callback)


func _unbind_registry() -> void:
	if _registry == null or not is_instance_valid(_registry):
		_registry = null
		return
	if _registry.has_signal("window_state_changed"):
		var callback := Callable(self, "_on_registry_window_state_changed")
		if _registry.is_connected("window_state_changed", callback):
			_registry.disconnect("window_state_changed", callback)
	if _registry.has_signal("window_preview_changed"):
		var preview_callback := Callable(self, "_on_registry_window_preview_changed")
		if _registry.is_connected("window_preview_changed", preview_callback):
			_registry.disconnect("window_preview_changed", preview_callback)
	if _registry.has_signal("operation_completed"):
		var operation_callback := Callable(self, "_on_registry_operation_completed")
		if _registry.is_connected("operation_completed", operation_callback):
			_registry.disconnect("operation_completed", operation_callback)


func _register_with_registry() -> void:
	if _registry == null or not _registry.has_method("register_window"):
		return
	# A late-joining Client may receive the absolute snapshot before ARSpace and
	# its adapters enter the tree. Consume that replica immediately and never
	# attempt client-side registration.
	var state := get_state()
	if not state.is_empty():
		apply_window_state(state)
		return
	if not _is_local_server_authority():
		return
	_registered = bool(_registry.call("register_window", _build_descriptor()))
	if not _registered:
		return
	state = get_state()
	if not state.is_empty():
		apply_window_state(state)
	if not starts_visible:
		request_visibility(false)


func _build_descriptor() -> Dictionary:
	return {
		"window_id": window_id,
		"window_type": window_type,
		"instance_policy": "unique" if unique_per_type else "multiple",
		"content_key": window_id,
		"shared_transform": _last_rigid_transform,
		"size_m": _last_size_m,
		"default_size_m": default_size_m,
		"maximized_size_m": maximized_size_m,
		"min_size_m": min_size_m,
		"max_size_m": max_size_m,
		"mode": _mode,
		"visible": _window.visible if _window != null else starts_visible,
	}


func _on_registry_window_state_changed(changed_window_id: String, state: Dictionary) -> void:
	if changed_window_id != window_id:
		_refresh_authoritative_focus()
		return
	if state.is_empty():
		_window.visible = false
		_refresh_authoritative_focus()
		return
	# Lease grants are reliable state changes. Applying their still-authoritative
	# transform during a local XR Tools drag would snap the grabbed panel back
	# to its start pose before the first preview. Preserve the live pose while
	# still accepting the opaque token; CLOSED always wins immediately.
	if _last_legacy_dragging and str(state.get("mode", MODE_NORMAL)) != MODE_CLOSED:
		_lease_token = str(state.get("lease_token", ""))
		_refresh_authoritative_focus()
		return
	apply_window_state(state)
	_refresh_authoritative_focus()


func _on_registry_window_preview_changed(
	changed_window_id: String,
	shared_transform: Transform3D,
	_stream_sequence_value: int
) -> void:
	if changed_window_id == window_id and not _last_legacy_dragging:
		_last_rigid_transform = shared_transform
		_apply_parent_transform(shared_transform, _last_size_m)


func _on_registry_operation_completed(result: Dictionary) -> void:
	if bool(result.get("accepted", false)) or str(result.get("window_id", "")) != window_id:
		return
	var operation := str(result.get("operation", ""))
	if operation not in ["acquire_lease", "transform_commit", "resize_commit", "snap"]:
		return
	if _window != null and _window.has_method("_stop_dragging"):
		_window.call("_stop_dragging")
	_last_legacy_dragging = false
	_lease_token = ""
	var authoritative := get_state()
	if not authoritative.is_empty():
		apply_window_state(authoritative)
	interaction_rejected.emit(window_id, str(result.get("error", "operation_rejected")))


func _on_window_pointer_event(event) -> void:
	if _interactor == null or event == null or not is_instance_valid(event.pointer):
		return
	var event_type := int(event.event_type)
	_last_pointer_position = event.position
	if event_type == PointerEvent.Type.PRESSED:
		_interactor.call("focus_window", self)
		var viewport_position: Vector2 = _get_viewport_position(event.position)
		var viewport_size: Vector2 = _get_viewport_size()
		var handle: String = _get_resize_handle(viewport_position, viewport_size) if _is_focused else ""
		var hand: StringName = _get_pointer_hand(event.pointer)
		var started: bool = false
		if not handle.is_empty():
			started = bool(_interactor.call("begin_resize", self, handle, event.position, hand))
			_pointer_interaction_kind = "resize"
		elif viewport_position.y <= title_bar_pixels \
				and viewport_position.x < viewport_size.x - 140.0:
			var distance: float = event.pointer.global_position.distance_to(event.position)
			if distance <= 0.3:
				started = bool(_interactor.call("begin_near_title_drag", self, event.pointer.global_transform, hand))
				_pointer_interaction_kind = "near"
			else:
				var ray_direction: Vector3 = (event.position - event.pointer.global_position).normalized()
				started = bool(_interactor.call("begin_far_ray_drag", self, event.pointer.global_position, ray_direction, distance, hand))
				_pointer_interaction_kind = "far"
		if started:
			_interaction_pointer = event.pointer
			_lock_pointer_target(_interaction_pointer, true)
	elif event_type == PointerEvent.Type.RELEASED:
		_finish_pointer_interaction(true)
	elif event_type == PointerEvent.Type.EXITED and _interaction_pointer == event.pointer:
		_finish_pointer_interaction(false)


func _update_pointer_interaction(delta: float) -> void:
	if _interactor == null or _interactor.get("active_window") != self:
		return
	if _interaction_pointer == null or not is_instance_valid(_interaction_pointer):
		_finish_pointer_interaction(false)
		return
	var mode_name := str(_interactor.call("get_mode_name"))
	var user_position: Vector3 = _get_user_position()
	if mode_name == "near_title_drag" or (mode_name == "snap_preview" and _pointer_interaction_kind == "near"):
		_interactor.call("update_near_title_drag", _interaction_pointer.global_transform, user_position)
	elif mode_name == "far_ray_drag" or (mode_name == "snap_preview" and _pointer_interaction_kind == "far"):
		var direction: Vector3 = -_interaction_pointer.global_basis.z.normalized()
		if direction.length_squared() <= 0.000001:
			direction = (_last_pointer_position - _interaction_pointer.global_position).normalized()
		var depth_axis: float = _get_pointer_depth_axis(_interaction_pointer) + _mouse_depth_axis
		_interactor.call("update_far_ray_drag", _interaction_pointer.global_position, direction, depth_axis, delta, user_position)
		_mouse_depth_axis = 0.0
	elif mode_name == "resize":
		_interactor.call("update_resize", _last_pointer_position, 0.0, delta, Input.is_key_pressed(KEY_SHIFT))
	if mode_name in ["near_title_drag", "far_ray_drag", "snap_preview"]:
		_preview_nearest_snap_zone()


func _finish_pointer_interaction(commit: bool) -> void:
	if _interactor != null and _interactor.get("active_window") == self:
		_interactor.call("end_interaction", commit)
	_lock_pointer_target(_interaction_pointer, false)
	_interaction_pointer = null
	_pointer_interaction_kind = ""
	_mouse_depth_axis = 0.0


func _begin_desktop_pointer_interaction(screen_position: Vector2) -> bool:
	if _interactor == null or _window == null or not _window.visible:
		return false
	var camera := get_viewport().get_camera_3d()
	var body := _window.get_node_or_null("StaticBody3D") as CollisionObject3D
	if camera == null or body == null or camera.get_world_3d() == null:
		return false
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_direction := camera.project_ray_normal(screen_position).normalized()
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_direction * 100.0)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.get("collider") != body:
		return false
	_ensure_desktop_pointer()
	_update_desktop_pointer_transform(ray_origin, ray_direction)
	_desktop_pointer_active = true
	var hit_position := hit.get("position", ray_origin) as Vector3
	_last_pointer_position = hit_position
	_on_window_pointer_event(PointerEvent.new(
		PointerEvent.Type.PRESSED,
		_desktop_pointer,
		body,
		hit_position,
		hit_position
	))
	if _interaction_pointer == null:
		_desktop_pointer_active = false
		return false
	return true


func _update_desktop_pointer_ray(screen_position: Vector2) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null or _desktop_pointer == null:
		return
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_direction := camera.project_ray_normal(screen_position).normalized()
	_update_desktop_pointer_transform(ray_origin, ray_direction)
	var normal := _window.global_basis.z.normalized()
	var denominator := normal.dot(ray_direction)
	if absf(denominator) <= 0.000001:
		return
	var distance := normal.dot(_window.global_position - ray_origin) / denominator
	if distance > 0.0:
		_last_pointer_position = ray_origin + ray_direction * distance


func _ensure_desktop_pointer() -> void:
	if _desktop_pointer != null and is_instance_valid(_desktop_pointer):
		return
	_desktop_pointer = Node3D.new()
	_desktop_pointer.name = "%sDesktopPointer" % window_id.to_pascal_case()
	_shared_origin.add_child(_desktop_pointer)


func _update_desktop_pointer_transform(ray_origin: Vector3, ray_direction: Vector3) -> void:
	var up := Vector3.UP
	if absf(ray_direction.dot(up)) > 0.99:
		up = Vector3.FORWARD
	_desktop_pointer.global_transform = Transform3D(Basis.looking_at(ray_direction, up), ray_origin)


func _preview_nearest_snap_zone() -> void:
	var nearest: Node3D
	var nearest_distance: float = snap_preview_distance_m
	for candidate in get_tree().get_nodes_in_group("spatial_window_snap_zone"):
		var zone := candidate as Node3D
		if zone == null:
			continue
		var zone_shared_transform := _shared_origin.global_transform.affine_inverse() * zone.global_transform
		var distance: float = _last_rigid_transform.origin.distance_to(zone_shared_transform.origin)
		if distance <= nearest_distance:
			nearest = zone
			nearest_distance = distance
	if nearest == null:
		return
	var slot_id: String = str(nearest.get("slot_id")) if "slot_id" in nearest else nearest.name
	var target_size: Variant = nearest.get("target_size_m") if "target_size_m" in nearest else _last_size_m
	if target_size is Vector2:
		var target_transform := _shared_origin.global_transform.affine_inverse() * nearest.global_transform
		_interactor.call("preview_snap", slot_id, target_transform, target_size)


func _refresh_authoritative_focus() -> void:
	if _registry == null or not _registry.has_method("get_active_windows"):
		return
	var active_value = _registry.call("get_active_windows")
	if not (active_value is Array):
		return
	var focused_window_id := ""
	var highest_order := -1
	for value in active_value as Array:
		if not (value is Dictionary):
			continue
		var record := value as Dictionary
		var order := int(record.get("focus_order", 0))
		if order >= highest_order:
			highest_order = order
			focused_window_id = str(record.get("window_id", ""))
	set_focused(not focused_window_id.is_empty() and focused_window_id == window_id, highest_order)


func _get_viewport_position(global_point: Vector3) -> Vector2:
	var body := _window.get_node_or_null("StaticBody3D")
	if body != null and body.has_method("global_to_viewport"):
		return body.call("global_to_viewport", global_point) as Vector2
	return _get_viewport_size() * 0.5


func _get_viewport_size() -> Vector2:
	var value = _window.get("viewport_size") if "viewport_size" in _window else Vector2(610.0, 500.0)
	return value as Vector2 if value is Vector2 else Vector2(610.0, 500.0)


func _get_resize_handle(point: Vector2, viewport_size: Vector2) -> String:
	var left := point.x <= resize_handle_pixels
	var right := point.x >= viewport_size.x - resize_handle_pixels
	var top := point.y <= resize_handle_pixels
	var bottom := point.y >= viewport_size.y - resize_handle_pixels
	if top and left:
		return "TopLeft"
	if top and right:
		return "TopRight"
	if bottom and left:
		return "BottomLeft"
	if bottom and right:
		return "BottomRight"
	if top:
		return "Top"
	if bottom:
		return "Bottom"
	if left:
		return "Left"
	if right:
		return "Right"
	return ""


func _get_pointer_hand(pointer: Node3D) -> StringName:
	var current: Node = pointer
	while current != null:
		if "tracker" in current:
			var tracker_name := str(current.get("tracker"))
			if "left" in tracker_name.to_lower():
				return &"left_hand"
			if "right" in tracker_name.to_lower():
				return &"right_hand"
		current = current.get_parent()
	return &"none"


func _get_pointer_depth_axis(pointer: Node3D) -> float:
	var current: Node = pointer
	while current != null:
		if current.has_method("get_vector2"):
			var axis = current.call("get_vector2", &"primary")
			if axis is Vector2:
				return (axis as Vector2).y
		current = current.get_parent()
	return 0.0


func _get_user_position() -> Vector3:
	var camera := get_tree().root.find_child("XRCamera3D", true, false) as Node3D
	if camera != null:
		return camera.global_position
	var viewport_camera := get_viewport().get_camera_3d()
	return viewport_camera.global_position if viewport_camera != null else Vector3.ZERO


func _lock_pointer_target(pointer: Node3D, locked: bool) -> void:
	if pointer == null or not is_instance_valid(pointer) or not "target" in pointer:
		return
	pointer.set("target", _window.get_node_or_null("StaticBody3D") if locked else null)


func _capture_legacy_renderer_drag() -> void:
	var dragging := bool(_window.get("_is_dragging")) if "_is_dragging" in _window else false
	if dragging and not _last_legacy_dragging:
		acquire_interaction_lease()
	var current := _read_rigid_transform()
	if dragging and not current.is_equal_approx(_last_rigid_transform):
		_last_rigid_transform = current
		request_transform(current, false)
	elif _last_legacy_dragging and not dragging:
		_last_rigid_transform = current
		request_transform(current, true)
	_last_legacy_dragging = dragging


func _sync_content_visibility() -> void:
	if not follow_content_visibility or _content == null:
		return
	if _content.visible == _last_content_visible:
		return
	_last_content_visible = _content.visible
	request_visibility(_last_content_visible)


func _resolve_content() -> void:
	if _content != null and is_instance_valid(_content):
		return
	var scene_node = _window.get("scene_node") if "scene_node" in _window else null
	if scene_node is CanvasItem:
		_content = scene_node as CanvasItem


func _read_rigid_transform() -> Transform3D:
	var shared := _shared_origin.global_transform.affine_inverse() * _window.global_transform
	return Transform3D(shared.basis.orthonormalized(), shared.origin)


func _apply_parent_transform(shared_transform: Transform3D, size_m: Vector2) -> void:
	var ratio := Vector2(
		size_m.x / maxf(default_size_m.x, 0.001),
		size_m.y / maxf(default_size_m.y, 0.001)
	)
	var scaled_basis := shared_transform.basis
	scaled_basis.x *= _base_scale.x * ratio.x
	scaled_basis.y *= _base_scale.y * ratio.y
	scaled_basis.z *= _base_scale.z
	var scaled_shared := Transform3D(scaled_basis, shared_transform.origin)
	_window.global_transform = _shared_origin.global_transform * scaled_shared


func _ensure_focus_visual() -> void:
	if _focus_visual != null or _window == null:
		return
	_focus_visual = Node3D.new()
	_focus_visual.name = "SpatialWindowFocusVisual"
	_focus_visual.visible = false
	_window.add_child(_focus_visual)
	var viewport_size := _get_viewport_size()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.08, 0.82, 1.0, 0.92)
	material.emission_enabled = true
	material.emission = Color(0.02, 0.55, 1.0)
	material.emission_energy_multiplier = 1.8
	material.no_depth_test = true
	material.render_priority = 20
	var thickness := 8.0
	_add_focus_bar("Top", Vector2(viewport_size.x + thickness, thickness), Vector3(0.0, viewport_size.y * 0.5, 2.0), material)
	_add_focus_bar("Bottom", Vector2(viewport_size.x + thickness, thickness), Vector3(0.0, -viewport_size.y * 0.5, 2.0), material)
	_add_focus_bar("Left", Vector2(thickness, viewport_size.y), Vector3(-viewport_size.x * 0.5, 0.0, 2.0), material)
	_add_focus_bar("Right", Vector2(thickness, viewport_size.y), Vector3(viewport_size.x * 0.5, 0.0, 2.0), material)
	var corner_size := Vector2(22.0, 22.0)
	_add_focus_bar("TopLeft", corner_size, Vector3(-viewport_size.x * 0.5, viewport_size.y * 0.5, 3.0), material)
	_add_focus_bar("TopRight", corner_size, Vector3(viewport_size.x * 0.5, viewport_size.y * 0.5, 3.0), material)
	_add_focus_bar("BottomLeft", corner_size, Vector3(-viewport_size.x * 0.5, -viewport_size.y * 0.5, 3.0), material)
	_add_focus_bar("BottomRight", corner_size, Vector3(viewport_size.x * 0.5, -viewport_size.y * 0.5, 3.0), material)


func _add_focus_bar(bar_name: String, dimensions: Vector2, at: Vector3, material: Material) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = bar_name
	var mesh := QuadMesh.new()
	mesh.size = dimensions
	mesh.material = material
	mesh_instance.mesh = mesh
	mesh_instance.position = at
	_focus_visual.add_child(mesh_instance)


func _notify_business_visibility(is_visible: bool) -> void:
	if _content == null:
		return
	var pending: Array[Node] = [_content]
	while not pending.is_empty():
		var current: Node = pending.pop_back()
		if current.has_method("on_spatial_window_visibility_changed"):
			current.call("on_spatial_window_visibility_changed", is_visible)
			return
		for child in current.get_children():
			pending.append(child)


func _clamp_size(value: Vector2) -> Vector2:
	return Vector2(
		clampf(value.x, min_size_m.x, max_size_m.x),
		clampf(value.y, min_size_m.y, max_size_m.y)
	)


func _resolve_shared_space_origin() -> Node3D:
	var candidates := get_tree().get_nodes_in_group("shared_space_origin")
	if candidates.size() != 1:
		return null
	return candidates[0] as Node3D


func _is_local_server_authority() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and multiplayer.is_server() \
		and multiplayer.get_unique_id() == 1


func _is_network_session_active() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
