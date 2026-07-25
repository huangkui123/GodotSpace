@tool
extends Node3D

signal configuration_error(message: String)
signal slot_candidate_changed(window_id: StringName, slot_id: StringName)
signal slot_occupancy_changed(slot_id: StringName, window_id: StringName)
signal window_focused(window_id: StringName)

@export_range(0.05, 2.0, 0.01) var default_snap_distance_m: float = 0.45

var _slots: Dictionary = {}
var _windows: Dictionary = {}
var _candidate_by_window: Dictionary = {}
var _last_focused_window_id: StringName = &""


func _ready() -> void:
	add_to_group("window_dock_manager")
	call_deferred("refresh_slots")


func refresh_slots() -> bool:
	_slots.clear()
	var valid := true
	for child in get_children():
		if not child.has_method("get_occupied_window_id"):
			continue
		var id := StringName(str(child.get("slot_id")).strip_edges())
		if id.is_empty():
			valid = false
			_report_configuration_error("Window dock slot has an empty slot_id: %s" % child.get_path())
			continue
		if _slots.has(id):
			valid = false
			_report_configuration_error("Duplicate window dock slot_id: %s" % id)
			continue
		_slots[id] = child
		if child.has_signal("occupancy_changed"):
			var callback := Callable(self, "_on_slot_occupancy_changed")
			if not child.is_connected("occupancy_changed", callback):
				child.connect("occupancy_changed", callback)
	return valid


func register_window(controller: Node) -> bool:
	if controller == null or not is_instance_valid(controller) \
			or not controller.has_method("get_window_id"):
		return false
	var window_id := StringName(str(controller.call("get_window_id")))
	if window_id.is_empty():
		_report_configuration_error("Spatial window controller has an empty window_id.")
		return false
	var existing: Node = _windows.get(window_id)
	if existing != null and is_instance_valid(existing) and existing != controller:
		_report_configuration_error("Duplicate spatial window_id: %s" % window_id)
		return false
	_windows[window_id] = controller
	return true


func unregister_window(controller: Node) -> void:
	if controller == null or not controller.has_method("get_window_id"):
		return
	var window_id := StringName(str(controller.call("get_window_id")))
	clear_candidate(window_id)
	release_window(window_id)
	if _windows.get(window_id) == controller:
		_windows.erase(window_id)
	if _last_focused_window_id == window_id:
		_last_focused_window_id = &""


func get_registered_windows() -> Array:
	var result: Array = []
	for window_id in _windows.keys():
		var controller: Node = _windows.get(window_id)
		if controller != null and is_instance_valid(controller):
			result.append(controller)
	return result


func get_slot(slot_id: StringName) -> Node3D:
	var slot: Node = _slots.get(slot_id)
	return slot as Node3D if slot != null and is_instance_valid(slot) else null


func get_slot_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for slot_id in _slots.keys():
		ids.append(str(slot_id))
	ids.sort()
	return ids


func find_candidate(
	window_id: StringName,
	window_category: StringName,
	window_size_m: Vector2,
	window_position: Vector3,
	max_distance_m: float = -1.0
) -> StringName:
	if window_id.is_empty() or not _is_finite_vector(window_position):
		return &""
	var distance_limit := default_snap_distance_m if max_distance_m <= 0.0 else max_distance_m
	var best_id: StringName = &""
	var best_distance := INF
	for slot_id_value in _slots.keys():
		var slot_id := StringName(slot_id_value)
		var slot: Node3D = get_slot(slot_id)
		if slot == null \
			or not slot.call("can_accept", window_id, window_category, window_size_m):
			continue
		var distance := window_position.distance_to(slot.global_position)
		if distance > distance_limit:
			continue
		if distance < best_distance - 0.0001 \
			or (is_equal_approx(distance, best_distance) and str(slot_id) < str(best_id)):
			best_distance = distance
			best_id = slot_id
	return best_id


func show_candidate(window_id: StringName, slot_id: StringName) -> bool:
	var previous := StringName(_candidate_by_window.get(window_id, &""))
	if previous == slot_id:
		return not slot_id.is_empty()
	if not previous.is_empty():
		var previous_slot := get_slot(previous)
		if previous_slot != null:
			previous_slot.call("clear_candidate", window_id)
	_candidate_by_window.erase(window_id)
	if slot_id.is_empty():
		slot_candidate_changed.emit(window_id, &"")
		return false
	var slot := get_slot(slot_id)
	if slot == null:
		slot_candidate_changed.emit(window_id, &"")
		return false
	slot.call("set_candidate", window_id, true)
	if StringName(slot.call("get_candidate_window_id")) != window_id:
		slot_candidate_changed.emit(window_id, &"")
		return false
	_candidate_by_window[window_id] = slot_id
	slot_candidate_changed.emit(window_id, slot_id)
	return true


func clear_candidate(window_id: StringName) -> void:
	show_candidate(window_id, &"")


func try_occupy(slot_id: StringName, window_id: StringName) -> bool:
	var slot := get_slot(slot_id)
	if slot == null or not bool(slot.call("try_occupy", window_id)):
		return false
	clear_candidate(window_id)
	return true


func apply_authoritative_occupancy(slot_id: StringName, window_id: StringName) -> bool:
	var slot := get_slot(slot_id)
	if slot == null or window_id.is_empty():
		return false
	var previous := StringName(slot.call("get_occupied_window_id"))
	if previous == window_id:
		return true
	if not previous.is_empty():
		var previous_controller: Node = _windows.get(previous)
		if previous_controller != null \
			and is_instance_valid(previous_controller) \
			and previous_controller.has_method("handle_slot_preempted"):
			previous_controller.call("handle_slot_preempted", slot_id)
		slot.call("force_release")
	return bool(slot.call("try_occupy", window_id))


func release_slot(slot_id: StringName, window_id: StringName) -> bool:
	var slot := get_slot(slot_id)
	return slot != null and bool(slot.call("release", window_id))


func release_window(window_id: StringName) -> bool:
	var released := false
	for slot_value in _slots.values():
		var slot := slot_value as Node
		if slot != null and StringName(slot.call("get_occupied_window_id")) == window_id:
			released = bool(slot.call("release", window_id)) or released
	return released


func get_occupied_slot(window_id: StringName) -> StringName:
	for slot_id_value in _slots.keys():
		var slot_id := StringName(slot_id_value)
		var slot := get_slot(slot_id)
		if slot != null and StringName(slot.call("get_occupied_window_id")) == window_id:
			return slot_id
	return &""


func get_slot_occupant(slot_id: StringName) -> StringName:
	var slot := get_slot(slot_id)
	return StringName(slot.call("get_occupied_window_id")) if slot != null else &""


func get_snap_transform(
	slot_id: StringName,
	floating_scale: Vector3,
	window_size_m: Vector2 = Vector2.ZERO
) -> Transform3D:
	var slot := get_slot(slot_id)
	if slot == null:
		return Transform3D.IDENTITY
	return slot.call("get_snap_transform", floating_scale, window_size_m) as Transform3D


func focus_window(controller: Node) -> void:
	if not register_window(controller):
		return
	var window_id := StringName(str(controller.call("get_window_id")))
	if _last_focused_window_id == window_id:
		return
	_last_focused_window_id = window_id
	window_focused.emit(window_id)


func get_last_focused_window(excluded_controller: Node = null) -> Node:
	var controller: Node = _windows.get(_last_focused_window_id)
	if controller == null or not is_instance_valid(controller) or controller == excluded_controller:
		return null
	return controller


func _on_slot_occupancy_changed(slot_id: StringName, window_id: StringName) -> void:
	slot_occupancy_changed.emit(slot_id, window_id)


func _report_configuration_error(message: String) -> void:
	push_error(message)
	configuration_error.emit(message)


func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
