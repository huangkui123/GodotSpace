extends SceneTree

const AdapterScript = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_adapter.gd")
const PointerEvent = preload("res://addons/godot-xr-tools/events/pointer_event.gd")

class LegacyWindow:
	extends Node3D
	signal pointer_event(event)

	var scene_node: Control
	var _is_dragging: bool = false
	var allow_window_drag: bool = true
	var viewport_size := Vector2(610.0, 500.0)

	func _init() -> void:
		scene_node = Control.new()
		add_child(scene_node)


class FakeBody:
	extends Node3D

	var mapped_position := Vector2(300.0, 40.0)

	func global_to_viewport(_point: Vector3) -> Vector2:
		return mapped_position


class FakePointer:
	extends Node3D

	var target: Node3D


class FakeController:
	extends Node3D

	var tracker: StringName = &"right_hand"
	var grip_value: float = 0.0
	var grip_click: bool = false

	func get_float(_action: StringName) -> float:
		return grip_value

	func is_button_pressed(_action: StringName) -> bool:
		return grip_click


class FakeRegistry:
	extends Node

	var register_calls: int = 0
	var state: Dictionary = {}

	func get_window_state(_window_id: String) -> Dictionary:
		return state.duplicate(true)

	func register_window(descriptor: Dictionary) -> bool:
		register_calls += 1
		state = descriptor.duplicate(true)
		return true


class FakeInteractor:
	extends Node

	var active_window
	var last_begin := ""
	var last_handle := ""
	var last_commit: Variant = null

	func focus_window(window) -> bool:
		active_window = window
		window.set_focused(true)
		return true

	func begin_near_title_drag(window, _transform: Transform3D, _hand: StringName) -> bool:
		active_window = window
		last_begin = "near"
		return true

	func begin_far_ray_drag(window, _origin: Vector3, _direction: Vector3, _distance: float, _hand: StringName) -> bool:
		active_window = window
		last_begin = "far"
		return true

	func begin_resize(window, handle: String, _point: Vector3, _hand: StringName) -> bool:
		active_window = window
		last_begin = "resize"
		last_handle = handle
		return true

	func end_interaction(commit: bool) -> bool:
		last_commit = commit
		active_window = null
		return true


var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOrigin"
	shared_origin.add_to_group("shared_space_origin")
	shared_origin.position = Vector3(10.0, 0.0, 0.0)
	root.add_child(shared_origin)
	var nested_parent := Node3D.new()
	nested_parent.position = Vector3(2.0, 0.0, 0.0)
	shared_origin.add_child(nested_parent)
	var window := LegacyWindow.new()
	window.transform = Transform3D(Basis.IDENTITY.scaled(Vector3(0.01, 0.01, 0.01)), Vector3(1.0, 0.0, 0.0))
	nested_parent.add_child(window)
	var body := FakeBody.new()
	body.name = "StaticBody3D"
	window.add_child(body)
	var adapter = AdapterScript.new()
	adapter.window_id = "adapter_test"
	adapter.window_type = "test"
	adapter.default_size_m = Vector2(1.0, 1.0)
	adapter.maximized_size_m = Vector2(2.0, 1.5)
	window.add_child(adapter)
	await process_frame
	await process_frame

	var state := {
		"window_id": "adapter_test",
		"shared_transform": Transform3D(Basis.IDENTITY, Vector3(4.0, 0.5, -1.0)),
		"size_m": Vector2(2.0, 1.5),
		"mode": "maximized",
		"visible": true,
		"lease_token": "opaque",
	}
	_expect(adapter.apply_window_state(state), "Adapter must accept a valid authoritative state.")
	_expect(window.global_position.is_equal_approx(Vector3(14.0, 0.5, -1.0)), "Adapter transforms must remain relative to SharedSpaceOrigin through nested parents.")
	var scale := window.global_basis.get_scale()
	_expect(scale.is_equal_approx(Vector3(0.02, 0.015, 0.01)), "Adapter must convert physical window dimensions without compounding scale.")
	_expect(adapter.get_shared_rigid_transform().origin.is_equal_approx(Vector3(4.0, 0.5, -1.0)), "Adapter must publish an orthonormal shared-local transform.")

	state["mode"] = "closed"
	state["visible"] = false
	_expect(adapter.apply_window_state(state) and not window.visible and not window.scene_node.visible, "Closed authoritative state must hide renderer and content together.")
	state["mode"] = "normal"
	state["visible"] = true
	state["size_m"] = Vector2.ONE
	_expect(adapter.apply_window_state(state) and window.visible and window.scene_node.visible, "Reopened state must restore renderer and content without stale visibility.")
	state["shared_transform"] = Transform3D(Basis(Vector3.UP, 0.45), Vector3(4.0, 0.5, -1.0))
	state["size_m"] = Vector2(1.4, 0.7)
	_expect(adapter.apply_window_state(state), "Adapter must accept a rotated, non-uniform normal size.")
	var rotated_scale := window.global_basis.get_scale()
	_expect(rotated_scale.is_equal_approx(Vector3(0.014, 0.007, 0.01)), "Non-uniform resize must scale explicit local axes without shearing a rotated window.")
	_expect(window.global_basis.x.normalized().is_equal_approx((state["shared_transform"] as Transform3D).basis.x.normalized()), "Rotated resize must preserve the authoritative rigid orientation.")
	_expect(adapter._normal_size_m.is_equal_approx(Vector2(1.4, 0.7)), "Normal size must be retained before maximizing.")
	_expect(adapter.request_toggle_maximized(), "Offline preview mode must support maximizing without a network session.")
	_expect(adapter.get_physical_size_m().is_equal_approx(Vector2(2.0, 1.5)), "Offline maximize must use physical dimensions.")
	_expect(adapter.request_toggle_maximized(), "Offline preview mode must support restoring without a network session.")
	_expect(adapter.get_physical_size_m().is_equal_approx(Vector2(1.4, 0.7)), "Restore must return to the prior resized normal dimensions.")
	var fake_interactor := FakeInteractor.new()
	shared_origin.add_child(fake_interactor)
	adapter._interactor = fake_interactor
	var fake_controller := FakeController.new()
	shared_origin.add_child(fake_controller)
	var pointer := FakePointer.new()
	fake_controller.add_child(pointer)
	var hit_point := window.global_position
	pointer.global_position = hit_point + Vector3(0.0, 0.0, 0.2)
	body.mapped_position = Vector2(300.0, 40.0)
	window.emit_signal("pointer_event", PointerEvent.new(PointerEvent.Type.PRESSED, pointer, body, hit_point, hit_point))
	_expect(fake_interactor.last_begin == "near" and pointer.target == body, "A real title-bar pointer press within reach must start the shared near-drag path and lock its target.")
	window.emit_signal("pointer_event", PointerEvent.new(PointerEvent.Type.RELEASED, pointer, body, hit_point, hit_point))
	_expect(fake_interactor.last_commit == true and pointer.target == null, "Pointer release must commit through the shared interactor and unlock its target.")
	pointer.global_position = hit_point + Vector3(0.0, 0.0, 2.0)
	window.emit_signal("pointer_event", PointerEvent.new(PointerEvent.Type.PRESSED, pointer, body, hit_point, hit_point))
	_expect(fake_interactor.last_begin == "far", "The same title-bar event beyond near reach must start far-ray dragging.")
	window.emit_signal("pointer_event", PointerEvent.new(PointerEvent.Type.RELEASED, pointer, body, hit_point, hit_point))
	body.mapped_position = Vector2(5.0, 250.0)
	window.emit_signal("pointer_event", PointerEvent.new(PointerEvent.Type.PRESSED, pointer, body, hit_point, hit_point))
	_expect(fake_interactor.last_begin == "resize" and fake_interactor.last_handle == "Left", "Focused edge input must route to the matching one of eight resize handles.")
	window.emit_signal("pointer_event", PointerEvent.new(PointerEvent.Type.EXITED, pointer, body, hit_point, hit_point))
	_expect(fake_interactor.last_commit == false, "Pointer exit must cancel an active window manipulation.")
	fake_interactor.last_begin = ""
	fake_interactor.last_commit = null
	body.mapped_position = Vector2(300.0, 250.0)
	window.emit_signal("pointer_event", PointerEvent.new(PointerEvent.Type.ENTERED, pointer, body, hit_point, hit_point))
	fake_controller.grip_click = true
	adapter._update_grip_interaction()
	_expect(
		fake_interactor.last_begin == "far" \
			and adapter._grip_interaction_active \
			and pointer.target == body,
		"A digital Grip edge while hovering must start and lock the migrated shared-window drag."
	)
	fake_controller.grip_click = false
	adapter._update_grip_interaction()
	_expect(
		fake_interactor.last_commit == true \
			and not adapter._grip_interaction_active \
			and pointer.target == null,
		"Releasing Grip must commit and unlock the migrated shared-window drag."
	)
	window.global_position = Vector3(15.0, 0.5, -1.0)
	adapter._last_legacy_dragging = true
	state["lease_token"] = "granted_during_drag"
	adapter._on_registry_window_state_changed("adapter_test", state)
	_expect(window.global_position.is_equal_approx(Vector3(15.0, 0.5, -1.0)), "Lease grant snapshots must not snap an actively grabbed legacy window back to its start pose.")
	_expect(adapter._lease_token == "granted_during_drag", "Active drag must still consume the granted opaque lease token.")
	adapter._last_legacy_dragging = false
	var fake_registry := FakeRegistry.new()
	shared_origin.add_child(fake_registry)
	adapter._registry = fake_registry
	adapter._registered = false
	adapter._register_with_registry_for_authority(true)
	_expect(
		fake_registry.register_calls == 1 \
			and not fake_registry.get_window_state("adapter_test").is_empty(),
		"An authoritative adapter must register when the Registry has no state instead of mistaking its local descriptor for a snapshot."
	)
	adapter._register_with_registry_for_authority(true)
	_expect(
		fake_registry.register_calls == 1,
		"An already registered adapter must consume Registry state without duplicate registration."
	)
	var rejection := {"count": 0, "reason": ""}
	adapter.interaction_rejected.connect(func(_window_id: String, reason: String) -> void:
		rejection["count"] = int(rejection["count"]) + 1
		rejection["reason"] = reason
	)
	adapter._on_registry_operation_completed({
		"accepted": false,
		"window_id": "adapter_test",
		"operation": "open",
		"error": "server_registration_required",
	})
	_expect(
		int(rejection["count"]) == 1 \
			and str(rejection["reason"]) == "server_registration_required",
		"Open/maximize/visibility failures must be observable instead of being silently discarded."
	)

	shared_origin.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)


func _finish() -> void:
	if _failures.is_empty():
		print("Spatial window adapter self-test passed.")
		quit(0)
		return
	print("Spatial window adapter self-test failed with %d error(s)." % _failures.size())
	quit(1)
