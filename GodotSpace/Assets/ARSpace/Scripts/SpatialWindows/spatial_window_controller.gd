extends Node

const SpawnPolicy = preload(
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_spawn_policy.gd"
)
const NETWORK_PREVIEW_INTERVAL_MSEC: int = 40

enum WindowState {
	HIDDEN,
	FLOATING,
	DRAGGING,
	SNAP_CANDIDATE,
	SNAPPED,
}

enum WindowScope {
	LOCAL_GROUND_VR,
	SHARED,
}

signal window_opened(window_id: StringName)
signal drag_started(window_id: StringName)
signal drag_updated(window_id: StringName, window_transform: Transform3D)
signal snap_candidate_changed(window_id: StringName, slot_id: StringName)
signal drag_finished(window_id: StringName, final_state: int)
signal snapped(window_id: StringName, slot_id: StringName)
signal undocked(window_id: StringName, slot_id: StringName)
signal window_closed(window_id: StringName)
signal haptic_requested(window_id: StringName, strength: float, duration: float)

@export var window_id: StringName = &""
@export var scope: WindowScope = WindowScope.SHARED
@export var window_category: StringName = &"panel"
@export var window_size_m: Vector2 = Vector2(0.9, 0.6)
@export var window_root_path: NodePath = NodePath("..")
@export var event_source_path: NodePath
@export var visibility_target_path: NodePath
@export var child_spawn_anchor_path: NodePath
@export var dock_manager_path: NodePath
@export var state_manager_path: NodePath
@export var shared_space_origin_path: NodePath
@export var viewpoint_path: NodePath
@export var grip_action: StringName = &"grip"
@export_range(0.1, 1.0, 0.05) var grip_threshold: float = 0.7
@export_range(0.0, 0.95, 0.05) var grip_release_threshold: float = 0.55
@export_range(0.05, 2.0, 0.01) var snap_distance_m: float = 0.38
@export_range(0.05, 2.0, 0.01) var snap_release_distance_m: float = 0.52
@export_range(0.0, 1.0, 0.01) var snap_tween_duration_sec: float = 0.18
@export_range(1.0, 3.0, 0.1) var maximized_scale_factor: float = 1.6
@export_group("Ray Drag")
@export_range(0.2, 2.0, 0.05) var drag_min_distance_m: float = 0.5
@export_range(1.0, 12.0, 0.25) var drag_max_distance_m: float = 6.0
@export_range(1.0, 5.0, 0.05) var drag_depth_gain: float = 2.25
@export_range(0.0, 0.25, 0.005) var drag_position_smooth_time_sec: float = 0.055
@export_range(0.0, 0.25, 0.005) var drag_depth_smooth_time_sec: float = 0.08
@export_range(0.0, 0.25, 0.005) var drag_rotation_smooth_time_sec: float = 0.075
@export_range(0.0, 10.0, 0.25) var drag_facing_deadzone_deg: float = 2.0
@export_range(0.0, 0.25, 0.005) var remote_preview_smooth_time_sec: float = 0.06
@export_group("")

var _state: WindowState = WindowState.HIDDEN
var _window_root: Node3D
var _event_source: Node
var _visibility_target: Node
var _dock_manager: Node
var _state_manager: Node
var _shared_origin: Node3D
var _viewpoint: Node3D
var _child_spawn_anchor: Node3D
var _drag_controller: Node3D
var _drag_pointer: Node3D
var _drag_offset: Transform3D = Transform3D.IDENTITY
var _drag_uses_ray: bool = false
var _drag_grab_local_position: Vector3 = Vector3.ZERO
var _drag_distance_m: float = 1.0
var _drag_target_distance_m: float = 1.0
var _drag_last_controller_position: Vector3 = Vector3.ZERO
var _drag_release_scale: Vector3 = Vector3.ONE
var _floating_scale: Vector3 = Vector3.ONE
var _floating_transform: Transform3D = Transform3D.IDENTITY
var _default_floating_transform: Transform3D = Transform3D.IDENTITY
var _candidate_slot_id: StringName = &""
var _current_slot_id: StringName = &""
var _drag_token: int = 0
var _drag_sequence: int = 0
var _local_drag_active: bool = false
var _next_network_preview_msec: int = 0
var _applying_authority: bool = false
var _changing_visibility: bool = false
var _is_maximized: bool = false
var _setup_complete: bool = false
var _active_tween: Tween
var _remote_preview_active: bool = false
var _remote_preview_target: Transform3D = Transform3D.IDENTITY


func _ready() -> void:
	add_to_group("spatial_window_controller")
	if window_id.is_empty():
		window_id = StringName(str(get_parent().name))
	_window_root = get_node_or_null(window_root_path) as Node3D
	if _window_root == null:
		push_error("Spatial window %s has no valid window_root_path." % window_id)
		set_process(false)
		return
	_event_source = get_node_or_null(event_source_path) if not event_source_path.is_empty() else get_parent()
	_floating_scale = _window_root.global_transform.basis.get_scale()
	_floating_transform = _window_root.global_transform
	_default_floating_transform = _floating_transform
	_child_spawn_anchor = get_node_or_null(child_spawn_anchor_path) as Node3D \
		if not child_spawn_anchor_path.is_empty() else null
	_resolve_services()
	_bind_event_source()
	call_deferred("_finish_setup")


func _exit_tree() -> void:
	_cancel_tween()
	_clear_candidate()
	if _dock_manager != null and is_instance_valid(_dock_manager):
		_dock_manager.call("release_window", window_id)
		_dock_manager.call("unregister_window", self)
	if _state_manager != null \
			and is_instance_valid(_state_manager) \
			and _state_manager.has_method("unregister_window"):
		_state_manager.call("unregister_window", self)
	_clear_local_drag_context()


func _process(delta: float) -> void:
	if not _local_drag_active:
		_update_remote_preview(delta)
		return
	if _state not in [WindowState.DRAGGING, WindowState.SNAP_CANDIDATE]:
		_clear_local_drag_context()
		return
	if _drag_controller == null or not is_instance_valid(_drag_controller):
		finish_drag()
		return
	var grip_value := 0.0
	if _drag_controller.has_method("get_float"):
		grip_value = float(_drag_controller.call("get_float", grip_action))
	if grip_value <= _get_grip_release_threshold():
		finish_drag()
		return
	update_drag_from_controller(delta)


func _finish_setup() -> void:
	if _window_root == null or not is_instance_valid(_window_root):
		return
	_bind_visibility_target()
	_state = WindowState.FLOATING if _is_visibility_target_visible() else WindowState.HIDDEN
	_setup_complete = true
	if _dock_manager != null:
		_dock_manager.call("register_window", self)
	if scope == WindowScope.SHARED and _state_manager != null:
		_state_manager.call("register_window", self)


func get_window_id() -> StringName:
	return window_id


func get_scope() -> int:
	return scope


func get_state() -> int:
	return _state


func get_window_size_m() -> Vector2:
	return window_size_m


func get_window_global_transform() -> Transform3D:
	return _window_root.global_transform if _window_root != null else Transform3D.IDENTITY


func get_shared_transform() -> Transform3D:
	if _window_root == null:
		return Transform3D.IDENTITY
	if _shared_origin == null:
		_resolve_services()
	return _shared_origin.global_transform.affine_inverse() * _window_root.global_transform \
		if _shared_origin != null else _window_root.global_transform


func get_floating_scale() -> Vector3:
	return _floating_scale


func get_child_spawn_anchor() -> Node3D:
	return _child_spawn_anchor


func get_current_slot_id() -> StringName:
	return _current_slot_id


func is_window_open() -> bool:
	return _state != WindowState.HIDDEN and _is_visibility_target_visible()


func is_dragging() -> bool:
	return _state in [WindowState.DRAGGING, WindowState.SNAP_CANDIDATE]


func is_local_drag_active() -> bool:
	return _local_drag_active


func get_window_config() -> Dictionary:
	return {
		"window_id": str(window_id),
		"scope": scope,
		"category": str(window_category),
		"size_m": window_size_m,
		"base_scale": _floating_scale,
	}


func open_window(parent_controller: Node = null, reposition: bool = true) -> bool:
	if _window_root == null:
		return false
	if _state == WindowState.HIDDEN and reposition:
		var spawn_transform := SpawnPolicy.calculate_spawn_transform(
			self,
			parent_controller,
			_dock_manager,
			_get_viewpoint()
		)
		_set_window_transform(spawn_transform)
		_floating_transform = spawn_transform
	_set_visibility_target(true)
	if _state == WindowState.HIDDEN:
		_set_state(WindowState.FLOATING)
	if _dock_manager != null:
		_dock_manager.call("focus_window", self)
	if scope == WindowScope.SHARED and _state_manager != null and not _applying_authority:
		_state_manager.call("request_open_window", window_id, get_shared_transform())
	window_opened.emit(window_id)
	return true


func close_window() -> bool:
	if _state == WindowState.HIDDEN and not _is_visibility_target_visible():
		return true
	if _local_drag_active:
		_finish_drag_internal(false)
	_clear_candidate()
	_release_current_slot()
	_set_visibility_target(false)
	_set_state(WindowState.HIDDEN, true)
	if scope == WindowScope.SHARED and _state_manager != null and not _applying_authority:
		_state_manager.call("request_close_window", window_id)
	window_closed.emit(window_id)
	return true


func restore_window_position() -> void:
	_clear_candidate()
	_release_current_slot()
	_is_maximized = false
	_floating_scale = _default_floating_transform.basis.get_scale()
	_floating_transform = _default_floating_transform
	_set_window_transform(_default_floating_transform)
	if _state != WindowState.HIDDEN:
		_set_state(WindowState.FLOATING, true)
		_submit_settled_state()


func toggle_zoom() -> void:
	if _window_root == null or _state == WindowState.HIDDEN:
		return
	_is_maximized = not _is_maximized
	var target_scale := _get_active_floating_scale()
	var transform_value := _window_root.global_transform
	transform_value.basis = transform_value.basis.orthonormalized().scaled(target_scale)
	_set_window_transform(transform_value)
	_floating_transform = transform_value
	_submit_settled_state()


func begin_drag(
	controller: Node3D,
	pointer: Node3D = null,
	grab_position: Vector3 = Vector3.INF
) -> bool:
	if _state not in [WindowState.FLOATING, WindowState.SNAPPED]:
		return false
	if controller == null or not is_instance_valid(controller) or _window_root == null:
		return false
	var next_drag_token := Time.get_ticks_usec()
	if scope == WindowScope.SHARED and _state_manager != null:
		next_drag_token = int(_state_manager.call(
			"request_begin_drag",
			window_id,
			get_shared_transform()
		))
		if next_drag_token <= 0:
			return false
	var released_slot := _current_slot_id
	if not released_slot.is_empty():
		_release_current_slot()
		undocked.emit(window_id, released_slot)
	# A floating window may have been enlarged locally or by an authoritative
	# shared-state update. Preserve the scale that was visible when grip began,
	# instead of rebuilding it from the initial scene scale on release.
	_drag_release_scale = _window_root.global_transform.basis.get_scale() \
		if _state == WindowState.FLOATING else _get_active_floating_scale()
	_drag_controller = controller
	_drag_pointer = pointer
	_drag_offset = controller.global_transform.affine_inverse() * _window_root.global_transform
	_drag_uses_ray = pointer != null and is_instance_valid(pointer)
	if _drag_uses_ray:
		var ray_origin := pointer.global_position
		var ray_direction := -pointer.global_basis.z
		if ray_direction.length_squared() < 0.000001:
			_drag_uses_ray = false
		else:
			ray_direction = ray_direction.normalized()
			var projected_distance := (
				(grab_position - ray_origin).dot(ray_direction)
				if _is_finite_vector(grab_position)
				else (_window_root.global_position - ray_origin).dot(ray_direction)
			)
			var min_distance := minf(drag_min_distance_m, drag_max_distance_m)
			var max_distance := maxf(drag_min_distance_m, drag_max_distance_m)
			_drag_distance_m = clampf(projected_distance, min_distance, max_distance)
			_drag_target_distance_m = _drag_distance_m
			var projected_grab_position := ray_origin + ray_direction * _drag_distance_m
			_drag_grab_local_position = (
				_window_root.global_transform.affine_inverse() * projected_grab_position
			)
			_drag_last_controller_position = controller.global_position
	_drag_token = next_drag_token
	_drag_sequence = 0
	_next_network_preview_msec = 0
	_remote_preview_active = false
	_local_drag_active = true
	_set_state(WindowState.DRAGGING)
	_lock_pointer()
	_pulse(0.25, 0.06)
	drag_started.emit(window_id)
	return true


func update_drag_from_controller(delta: float = 1.0 / 90.0) -> bool:
	if not is_dragging() or _drag_controller == null or _window_root == null:
		return false
	var current := _window_root.global_transform
	var target := current
	if _drag_uses_ray and _drag_pointer != null and is_instance_valid(_drag_pointer):
		var ray_direction := -_drag_pointer.global_basis.z
		if ray_direction.length_squared() < 0.000001:
			return false
		ray_direction = ray_direction.normalized()
		var controller_position := _drag_controller.global_position
		var controller_delta := controller_position - _drag_last_controller_position
		_drag_last_controller_position = controller_position
		_drag_target_distance_m += (
			controller_delta.dot(ray_direction) * maxf(drag_depth_gain - 1.0, 0.0)
		)
		var min_distance := minf(drag_min_distance_m, drag_max_distance_m)
		var max_distance := maxf(drag_min_distance_m, drag_max_distance_m)
		_drag_target_distance_m = clampf(
			_drag_target_distance_m,
			min_distance,
			max_distance
		)
		_drag_distance_m = lerpf(
			_drag_distance_m,
			_drag_target_distance_m,
			_smoothing_alpha(delta, drag_depth_smooth_time_sec)
		)
		var grab_anchor := _drag_pointer.global_position + ray_direction * _drag_distance_m
		target.basis = _get_smoothed_drag_basis(
			grab_anchor,
			current.basis,
			_drag_release_scale,
			delta
		)
		var target_origin := grab_anchor - target.basis * _drag_grab_local_position
		target.origin = current.origin.lerp(
			target_origin,
			_smoothing_alpha(delta, drag_position_smooth_time_sec)
		)
	else:
		var controller_target := _drag_controller.global_transform * _drag_offset
		target.basis = _get_smoothed_drag_basis(
			controller_target.origin,
			current.basis,
			controller_target.basis.get_scale(),
			delta
		)
		target.origin = current.origin.lerp(
			controller_target.origin,
			_smoothing_alpha(delta, drag_position_smooth_time_sec)
		)
	_set_window_transform(target)
	_floating_transform = target
	_update_snap_candidate()
	_drag_sequence += 1
	if scope == WindowScope.SHARED and _state_manager != null:
		var now_msec := Time.get_ticks_msec()
		if now_msec >= _next_network_preview_msec:
			_next_network_preview_msec = now_msec + NETWORK_PREVIEW_INTERVAL_MSEC
			_state_manager.call(
				"request_drag_preview",
				window_id,
				_drag_token,
				_drag_sequence,
				get_shared_transform()
			)
	drag_updated.emit(window_id, target)
	return true


func finish_drag() -> bool:
	return _finish_drag_internal(true)


func _finish_drag_internal(allow_snap: bool) -> bool:
	if not _local_drag_active \
			or _state not in [WindowState.DRAGGING, WindowState.SNAP_CANDIDATE]:
		return false
	var selected_slot := _candidate_slot_id if allow_snap else &""
	_clear_candidate()
	if not selected_slot.is_empty() \
			and _dock_manager != null \
			and bool(_dock_manager.call("try_occupy", selected_slot, window_id)):
		_current_slot_id = selected_slot
		var snap_transform: Transform3D = _dock_manager.call(
			"get_snap_transform",
			selected_slot,
			_floating_scale,
			window_size_m
		)
		_move_to_transform(snap_transform)
		_set_state(WindowState.SNAPPED, true)
		snapped.emit(window_id, selected_slot)
	else:
		_set_state(WindowState.FLOATING, true)
		var floating := _window_root.global_transform
		floating.basis = _face_user_basis(floating.origin, _drag_release_scale)
		_set_window_transform(floating)
		_floating_transform = floating
		selected_slot = &""
	if scope == WindowScope.SHARED and _state_manager != null:
		_drag_sequence += 1
		_state_manager.call(
			"request_finish_drag",
			window_id,
			_drag_token,
			_drag_sequence,
			get_shared_transform(),
			selected_slot
		)
	_pulse(0.18, 0.04)
	_clear_local_drag_context()
	drag_finished.emit(window_id, _state)
	return true


func apply_authoritative_record(record: Dictionary) -> void:
	if str(record.get("window_id", "")) != str(window_id):
		return
	var visible_value := bool(record.get("visible", false))
	var state_value := int(record.get("state", WindowState.HIDDEN))
	var shared_transform_value = record.get("transform", Transform3D.IDENTITY)
	var slot_id := StringName(str(record.get("slot_id", "")))
	if not (shared_transform_value is Transform3D):
		return
	var shared_transform: Transform3D = shared_transform_value
	var local_is_operator := state_value == WindowState.DRAGGING \
		and int(record.get("operator_peer_id", 0)) == _get_local_peer_id() \
		and int(record.get("drag_token", 0)) == _drag_token \
		and _local_drag_active
	if not local_is_operator:
		_remote_preview_active = false
	if _local_drag_active and not local_is_operator:
		_clear_candidate()
		_clear_local_drag_context()
	_applying_authority = true
	if not visible_value:
		_clear_candidate()
		_release_current_slot()
		_set_visibility_target(false)
		_set_state(WindowState.HIDDEN, true)
	else:
		_set_visibility_target(true)
		if not local_is_operator:
			var global_value: Transform3D = (_shared_origin.global_transform * shared_transform) \
				if _shared_origin != null else shared_transform
			_set_window_transform(global_value)
		if slot_id.is_empty():
			_release_current_slot()
		else:
			if _dock_manager != null:
				_dock_manager.call("apply_authoritative_occupancy", slot_id, window_id)
			_current_slot_id = slot_id
		_set_state(clampi(state_value, WindowState.FLOATING, WindowState.SNAPPED), true)
	_applying_authority = false


func apply_authoritative_drag_preview(
	shared_transform: Transform3D,
	operator_peer_id: int
) -> void:
	if operator_peer_id == _get_local_peer_id() and is_dragging():
		return
	var global_value: Transform3D = (_shared_origin.global_transform * shared_transform) \
		if _shared_origin != null else shared_transform
	_remote_preview_target = global_value
	_remote_preview_active = true


func handle_slot_preempted(slot_id: StringName) -> void:
	if _current_slot_id != slot_id:
		return
	_current_slot_id = &""
	if _state == WindowState.SNAPPED:
		_set_state(WindowState.FLOATING, true)
	undocked.emit(window_id, slot_id)


func _update_snap_candidate() -> void:
	if _dock_manager == null or _window_root == null:
		return
	var next_slot: StringName = &""
	if not _candidate_slot_id.is_empty():
		var current_slot := _dock_manager.call("get_slot", _candidate_slot_id) as Node3D
		var release_distance := maxf(snap_release_distance_m, snap_distance_m)
		if current_slot != null \
				and bool(current_slot.call(
					"can_accept",
					window_id,
					window_category,
					window_size_m
				)) \
				and _window_root.global_position.distance_to(
					current_slot.global_position
				) <= release_distance:
			next_slot = _candidate_slot_id
	if next_slot.is_empty():
		next_slot = _dock_manager.call(
			"find_candidate",
			window_id,
			window_category,
			window_size_m,
			_window_root.global_position,
			snap_distance_m
		)
	if next_slot == _candidate_slot_id:
		return
	_candidate_slot_id = next_slot
	_dock_manager.call("show_candidate", window_id, next_slot)
	if next_slot.is_empty():
		_set_state(WindowState.DRAGGING)
	else:
		_set_state(WindowState.SNAP_CANDIDATE)
		_pulse(0.12, 0.035)
	snap_candidate_changed.emit(window_id, next_slot)


func _clear_candidate() -> void:
	if _dock_manager != null and not _candidate_slot_id.is_empty():
		_dock_manager.call("clear_candidate", window_id)
	_candidate_slot_id = &""


func _release_current_slot() -> void:
	if _current_slot_id.is_empty():
		return
	if _dock_manager != null:
		_dock_manager.call("release_slot", _current_slot_id, window_id)
	_current_slot_id = &""


func _submit_settled_state() -> void:
	if scope == WindowScope.SHARED and _state_manager != null and not _applying_authority:
		_state_manager.call(
			"request_settled_state",
			window_id,
			get_shared_transform(),
			_current_slot_id
		)


func _set_state(next_state: int, authoritative: bool = false) -> bool:
	if next_state == _state:
		return true
	if not authoritative and not _is_legal_transition(_state, next_state):
		return false
	_state = next_state as WindowState
	return true


func _is_legal_transition(from_state: int, to_state: int) -> bool:
	match from_state:
		WindowState.HIDDEN:
			return to_state == WindowState.FLOATING
		WindowState.FLOATING:
			return to_state in [WindowState.HIDDEN, WindowState.DRAGGING]
		WindowState.DRAGGING:
			return to_state in [
				WindowState.HIDDEN,
				WindowState.FLOATING,
				WindowState.SNAP_CANDIDATE,
			]
		WindowState.SNAP_CANDIDATE:
			return to_state in [
				WindowState.HIDDEN,
				WindowState.FLOATING,
				WindowState.DRAGGING,
				WindowState.SNAPPED,
			]
		WindowState.SNAPPED:
			return to_state in [
				WindowState.HIDDEN,
				WindowState.FLOATING,
				WindowState.DRAGGING,
			]
	return false


func _bind_event_source() -> void:
	if _event_source == null:
		return
	if _has_property(_event_source, "allow_window_drag"):
		_event_source.set("allow_window_drag", false)
	if _event_source.has_signal("spatial_pointer_event"):
		var callback := Callable(self, "_on_spatial_pointer_event")
		if not _event_source.is_connected("spatial_pointer_event", callback):
			_event_source.connect("spatial_pointer_event", callback)
	elif _event_source.has_signal("pointer_event"):
		var callback := Callable(self, "_on_legacy_pointer_event")
		if not _event_source.is_connected("pointer_event", callback):
			_event_source.connect("pointer_event", callback)


func _bind_visibility_target() -> void:
	if not visibility_target_path.is_empty():
		_visibility_target = get_node_or_null(visibility_target_path)
	elif _event_source != null and _event_source.has_method("get_content_visibility_node"):
		_visibility_target = _event_source.call("get_content_visibility_node") as Node
	elif _event_source != null and _event_source.has_method("get_scene_instance"):
		_visibility_target = _event_source.call("get_scene_instance") as Node
	if _visibility_target == null:
		_visibility_target = _window_root
	if _visibility_target != null and _visibility_target.has_signal("visibility_changed"):
		var callback := Callable(self, "_on_visibility_target_changed")
		if not _visibility_target.is_connected("visibility_changed", callback):
			_visibility_target.connect("visibility_changed", callback)


func _on_spatial_pointer_event(
	event: XRToolsPointerEvent,
	controller: Node3D,
	grip_value: float
) -> void:
	if event.event_type == XRToolsPointerEvent.Type.PRESSED and _dock_manager != null:
		_dock_manager.call("focus_window", self)
	if controller == null:
		return
	if grip_value >= grip_threshold \
			and not _local_drag_active \
			and event.event_type in [
				XRToolsPointerEvent.Type.ENTERED,
				XRToolsPointerEvent.Type.MOVED,
			]:
		begin_drag(controller, event.pointer, event.position)
	elif grip_value <= _get_grip_release_threshold() \
			and _local_drag_active \
			and controller == _drag_controller:
		finish_drag()


func _on_legacy_pointer_event(event: XRToolsPointerEvent) -> void:
	var controller := _find_controller(event.pointer)
	var grip_value := float(controller.call("get_float", grip_action)) \
		if controller != null and controller.has_method("get_float") else 0.0
	_on_spatial_pointer_event(event, controller, grip_value)


func _on_visibility_target_changed() -> void:
	if not _setup_complete or _changing_visibility or _applying_authority:
		return
	if _is_visibility_target_visible():
		if _state == WindowState.HIDDEN:
			open_window(null, true)
	else:
		close_window()


func _set_visibility_target(value: bool) -> void:
	if _visibility_target == null or not _has_property(_visibility_target, "visible"):
		return
	if bool(_visibility_target.get("visible")) == value:
		return
	_changing_visibility = true
	_visibility_target.set("visible", value)
	_changing_visibility = false


func _is_visibility_target_visible() -> bool:
	return _visibility_target != null \
		and _has_property(_visibility_target, "visible") \
		and bool(_visibility_target.get("visible"))


func _resolve_services() -> void:
	_dock_manager = get_node_or_null(dock_manager_path) if not dock_manager_path.is_empty() else null
	if _dock_manager == null and is_inside_tree():
		_dock_manager = get_tree().get_first_node_in_group("window_dock_manager")
	_state_manager = get_node_or_null(state_manager_path) if not state_manager_path.is_empty() else null
	if _state_manager == null and is_inside_tree():
		_state_manager = get_tree().get_first_node_in_group("spatial_window_state_manager")
	_shared_origin = get_node_or_null(shared_space_origin_path) as Node3D \
		if not shared_space_origin_path.is_empty() else null
	if _shared_origin == null and is_inside_tree():
		_shared_origin = get_tree().get_first_node_in_group("shared_space_origin") as Node3D
	_viewpoint = get_node_or_null(viewpoint_path) as Node3D \
		if not viewpoint_path.is_empty() else null


func _get_viewpoint() -> Node3D:
	if _viewpoint != null and is_instance_valid(_viewpoint):
		return _viewpoint
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		_viewpoint = camera
		return camera
	var found := get_tree().root.find_child("XRCamera3D", true, false)
	return found as Node3D


func _face_user_basis(position: Vector3, scale_value: Vector3) -> Basis:
	var viewpoint := _get_viewpoint()
	if viewpoint == null:
		return _window_root.global_transform.basis.orthonormalized().scaled(scale_value)
	var to_user := viewpoint.global_position - position
	to_user.y = 0.0
	if to_user.length_squared() < 0.000001:
		return _window_root.global_transform.basis.orthonormalized().scaled(scale_value)
	var forward := to_user.normalized()
	var right := Vector3.UP.cross(forward)
	if right.length_squared() < 0.000001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := forward.cross(right).normalized()
	return Basis(right, up, forward).scaled(scale_value)


func _get_smoothed_drag_basis(
	position: Vector3,
	current_basis: Basis,
	scale_value: Vector3,
	delta: float
) -> Basis:
	var desired_basis := _face_user_basis(position, Vector3.ONE).orthonormalized()
	var current_rotation := current_basis.orthonormalized()
	var current_forward := current_rotation.z
	var desired_forward := desired_basis.z
	current_forward.y = 0.0
	desired_forward.y = 0.0
	if current_forward.length_squared() >= 0.000001 \
			and desired_forward.length_squared() >= 0.000001:
		current_forward = current_forward.normalized()
		desired_forward = desired_forward.normalized()
		var facing_delta := absf(current_forward.signed_angle_to(
			desired_forward,
			Vector3.UP
		))
		if facing_delta <= deg_to_rad(drag_facing_deadzone_deg):
			var right := Vector3.UP.cross(current_forward).normalized()
			desired_basis = Basis(
				right,
				current_forward.cross(right).normalized(),
				current_forward
			)
	var current_quaternion := current_rotation.get_rotation_quaternion()
	var desired_quaternion := desired_basis.get_rotation_quaternion()
	var rotation_alpha := _smoothing_alpha(delta, drag_rotation_smooth_time_sec)
	return Basis(
		current_quaternion.slerp(desired_quaternion, rotation_alpha)
	).orthonormalized().scaled(scale_value)


func _update_remote_preview(delta: float) -> void:
	if not _remote_preview_active \
			or _window_root == null \
			or _local_drag_active \
			or _state not in [WindowState.DRAGGING, WindowState.SNAP_CANDIDATE]:
		return
	var alpha := _smoothing_alpha(delta, remote_preview_smooth_time_sec)
	var current := _window_root.global_transform
	var next_transform := current.interpolate_with(_remote_preview_target, alpha)
	if alpha >= 0.999:
		next_transform = _remote_preview_target
	_applying_authority = true
	_set_window_transform(next_transform)
	_applying_authority = false


func _smoothing_alpha(delta: float, smooth_time_sec: float) -> float:
	if smooth_time_sec <= 0.0:
		return 1.0
	if delta <= 0.0:
		return 0.0
	return clampf(1.0 - exp(-3.0 * delta / smooth_time_sec), 0.0, 1.0)


func _get_grip_release_threshold() -> float:
	return clampf(minf(grip_release_threshold, grip_threshold - 0.05), 0.0, 1.0)


func _get_active_floating_scale() -> Vector3:
	return _floating_scale * (maximized_scale_factor if _is_maximized else 1.0)


func _move_to_transform(target: Transform3D) -> void:
	_cancel_tween()
	if snap_tween_duration_sec <= 0.0 or not is_inside_tree():
		_set_window_transform(target)
		return
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_active_tween.tween_method(
		func(value: Transform3D) -> void:
			_set_window_transform(value),
		_window_root.global_transform,
		target,
		snap_tween_duration_sec
	)


func _cancel_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null


func _set_window_transform(value: Transform3D) -> void:
	if _window_root == null:
		return
	_window_root.global_transform = value


func _lock_pointer() -> void:
	if _drag_pointer == null or not _has_property(_drag_pointer, "target"):
		return
	var target: Node = null
	if _event_source != null:
		target = _event_source.get_node_or_null("StaticBody3D")
	_drag_pointer.set("target", target)


func _unlock_pointer() -> void:
	if _drag_pointer != null \
			and is_instance_valid(_drag_pointer) \
			and _has_property(_drag_pointer, "target"):
		_drag_pointer.set("target", null)


func _clear_local_drag_context() -> void:
	_unlock_pointer()
	_drag_controller = null
	_drag_pointer = null
	_drag_uses_ray = false
	_drag_grab_local_position = Vector3.ZERO
	_drag_distance_m = 1.0
	_drag_target_distance_m = 1.0
	_drag_last_controller_position = Vector3.ZERO
	_drag_release_scale = Vector3.ONE
	_drag_token = 0
	_drag_sequence = 0
	_local_drag_active = false


func _pulse(strength: float, duration: float) -> void:
	if _drag_controller != null and _drag_controller.has_method("pulse"):
		_drag_controller.call("pulse", strength, duration)
	haptic_requested.emit(window_id, strength, duration)


func _find_controller(pointer: Node3D) -> Node3D:
	var current: Node = pointer
	while current != null:
		if current is XRController3D:
			return current as Node3D
		current = current.get_parent()
	return null


func _get_local_peer_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1


func _has_property(object: Object, property_name: String) -> bool:
	if object == null:
		return false
	for property_info in object.get_property_list():
		if str(property_info.get("name", "")) == property_name:
			return true
	return false


func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
