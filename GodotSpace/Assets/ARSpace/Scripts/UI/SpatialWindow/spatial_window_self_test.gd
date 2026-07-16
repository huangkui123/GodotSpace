extends SceneTree

const WindowScene = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/SpatialWindow3D.tscn")
const WindowScript = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_3d.gd")
const InteractorScript = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_interactor.gd")

class MockRegistry:
	extends Node

	signal operation_completed(result: Dictionary)

	var registered_ids: Array[String] = []
	var requested_states: Array[Dictionary] = []
	var confirmed_snaps: Array[Dictionary] = []
	var focused_ids: Array[String] = []
	var closed_ids: Array[String] = []
	var operations: Array[Dictionary] = []
	var states: Dictionary = {}
	var reject_acquire: bool = false

	func register_window(descriptor: Dictionary) -> bool:
		var window_id := str(descriptor.get("window_id", ""))
		registered_ids.append(window_id)
		states[window_id] = descriptor.duplicate(true)
		return true

	func unregister_window(window_id: String) -> bool:
		registered_ids.erase(window_id)
		states.erase(window_id)
		return true

	func request_operation(window_id: String, operation: String, payload: Dictionary = {}) -> bool:
		operations.append({"window_id": window_id, "operation": operation, "payload": payload.duplicate(true)})
		if operation == "acquire_lease" and reject_acquire:
			operation_completed.emit({
				"accepted": false,
				"window_id": window_id,
				"operation": operation,
				"error": "window_lease_busy",
			})
			return false
		var state := (states.get(window_id, {}) as Dictionary).duplicate(true)
		if operation == "acquire_lease":
			state["lease_peer_id"] = 1
			state["lease_token"] = "lease_%s" % window_id
		elif operation == "release_lease":
			state["lease_peer_id"] = 0
			state["lease_token"] = ""
		elif operation == "snap":
			confirmed_snaps.append(payload.duplicate(true))
		elif operation == "close":
			closed_ids.append(window_id)
		elif operation == "focus":
			focused_ids.append(window_id)
		states[window_id] = state
		return true

	func select_window(window_id: String) -> bool:
		focused_ids.append(window_id)
		return true

	func get_window_state(window_id: String) -> Dictionary:
		return (states.get(window_id, {}) as Dictionary).duplicate(true)


var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry := MockRegistry.new()
	registry.name = "SpatialWindowTestRegistry"
	root.add_child(registry)

	var window_a = WindowScript.new()
	window_a.window_id = "window_a"
	var window_b = WindowScript.new()
	window_b.window_id = "window_b"
	var interactor = InteractorScript.new()
	interactor.registry_path = NodePath("/root/SpatialWindowTestRegistry")
	root.add_child(interactor)
	await process_frame
	registry.states["window_a"] = {"window_id": "window_a"}
	registry.states["window_b"] = {"window_id": "window_b"}

	_test_scene_contract()
	await _test_shared_space_contract()
	_test_active_interaction_snapshot_guard(window_a)
	_test_rejected_lease(window_a, interactor, registry)
	_test_size_and_maximize(window_a)
	_test_mutual_exclusion(window_a, window_b, interactor)
	_test_far_depth_and_orientation(window_a, interactor)
	_test_snap_lifecycle(window_a, interactor, registry)
	_test_haptics(window_a, interactor)

	window_a.free()
	window_b.free()
	interactor.free()
	registry.free()
	_finish()


func _test_scene_contract() -> void:
	_expect(_get_scene_node_type("ContentRoot") == "Node3D", "SpatialWindow3D must expose ContentRoot for adapter-managed content.")
	_expect(_get_scene_node_type("TitleBar") == "Area3D", "SpatialWindow3D must expose a pickable TitleBar.")
	_expect(_get_scene_node_type("TitleBar/CloseButton") == "Area3D", "The title bar must expose CloseButton.")
	_expect(_get_scene_node_type("TitleBar/MaximizeButton") == "Area3D", "The title bar must expose MaximizeButton.")
	_expect(_get_scene_node_type("SurfaceCollider/CollisionShape3D") == "CollisionShape3D", "The content surface must expose a collision shape.")
	_expect(_get_scene_node_type("SelectedOutline") == "Node3D", "A selected-window outline must be present.")
	for handle_name: String in WindowScript.HANDLE_NAMES:
		_expect(_get_scene_node_type("ResizeHandles/" + handle_name) == "Area3D", "Resize handle %s must be a pickable Area3D." % handle_name)


func _test_shared_space_contract() -> void:
	var shared_origin := Node3D.new()
	shared_origin.name = "SharedSpaceOriginTest"
	shared_origin.add_to_group("shared_space_origin")
	shared_origin.position = Vector3(5.0, 0.0, 0.0)
	root.add_child(shared_origin)
	var nested_parent := Node3D.new()
	nested_parent.position = Vector3(2.0, 0.0, 0.0)
	shared_origin.add_child(nested_parent)
	var nested_window = WindowScene.instantiate()
	nested_window.window_id = "nested_shared_window"
	nested_window.position = Vector3(1.0, 0.0, 0.0)
	nested_parent.add_child(nested_window)
	await process_frame
	_expect(nested_window.get_shared_transform().origin.is_equal_approx(Vector3(3.0, 0.0, 0.0)), "Nested windows must publish transforms relative to SharedSpaceOrigin, not their immediate parent.")
	nested_window.set_shared_transform(Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, 0.0)))
	_expect(nested_window.global_position.is_equal_approx(Vector3(9.0, 0.0, 0.0)), "Authoritative shared transforms must resolve through SharedSpaceOrigin.")
	shared_origin.free()


func _test_active_interaction_snapshot_guard(window: Node3D) -> void:
	window.transform = Transform3D(Basis.IDENTITY, Vector3(0.5, 0.0, 0.0))
	window.set_local_interaction_active(true)
	window._on_registry_window_state_changed("window_a", {
		"window_id": "window_a",
		"shared_transform": Transform3D.IDENTITY,
		"size_m": window.size_metres,
		"mode": "normal",
		"visible": true,
	})
	_expect(window.position.is_equal_approx(Vector3(0.5, 0.0, 0.0)), "Lease snapshots must not reset a locally manipulated SpatialWindow3D pose.")
	window.set_local_interaction_active(false)
	window._on_registry_window_state_changed("window_a", {
		"window_id": "window_a",
		"shared_transform": Transform3D.IDENTITY,
		"size_m": window.size_metres,
		"mode": "normal",
		"visible": true,
	})
	_expect(window.transform.is_equal_approx(Transform3D.IDENTITY), "Authoritative transforms must resume after local interaction ends.")


func _test_rejected_lease(window: Node3D, interactor: Node, registry: MockRegistry) -> void:
	registry.reject_acquire = true
	window.transform = Transform3D(Basis.IDENTITY, Vector3(0.25, 0.0, 0.0))
	_expect(not interactor.begin_near_title_drag(window, Transform3D.IDENTITY, &"left"), "A synchronously rejected manipulation lease must prevent local dragging.")
	_expect(interactor.get_mode_name() == "focused" and not window._local_interaction_active, "Rejected leases must leave no active local interaction state.")
	_expect(window.position.is_equal_approx(Vector3(0.25, 0.0, 0.0)), "Rejected leases must preserve the authoritative window pose.")
	registry.reject_acquire = false


func _test_size_and_maximize(window: Node3D) -> void:
	window.minimum_size = Vector2(0.3, 0.2)
	window.maximum_size = Vector2(1.5, 1.0)
	window.set_size_metres(Vector2(0.1, 2.0), false)
	_expect(window.size_metres.is_equal_approx(Vector2(0.3, 1.0)), "Window dimensions must clamp to the configured minimum and maximum.")
	window.set_size_metres(Vector2(0.8, 0.4), false)
	window.preserve_aspect_ratio = true
	window.resize_by(Vector2(0.2, 0.01), true, false)
	_expect(is_equal_approx(window.get_aspect_ratio(), 2.0), "Aspect-preserving resize must retain the initial ratio.")
	window.preserve_aspect_ratio = false
	var normal_size: Vector2 = window.size_metres
	window.maximized_size = Vector2(1.4, 0.8)
	window.set_maximized(true, false)
	_expect(window.state == WindowScript.STATE_MAXIMIZED and window.size_metres.is_equal_approx(Vector2(1.4, 0.8)), "Maximize must apply the bounded maximized dimensions.")
	window.set_maximized(false, false)
	_expect(window.state == WindowScript.STATE_NORMAL and window.size_metres.is_equal_approx(normal_size), "Restore must recover the pre-maximize dimensions.")


func _test_mutual_exclusion(window_a: Node3D, window_b: Node3D, interactor: Node) -> void:
	window_a.transform = Transform3D.IDENTITY
	window_b.transform = Transform3D.IDENTITY
	_expect(interactor.begin_near_title_drag(window_a, Transform3D.IDENTITY, &"left"), "Near interaction must start from the title-bar semantic API.")
	_expect(interactor.get_mode_name() == "near_title_drag", "Near title drag must enter its dedicated state.")
	_expect(not (interactor._registry as MockRegistry).focused_ids.is_empty(), "Interactor focus must dynamically call SpatialWindowRegistryService when present.")
	interactor.update_near_title_drag(Transform3D(Basis.IDENTITY, Vector3(0.2, 0.0, 0.0)), Vector3(0.0, 1.6, 2.0))
	_expect(window_a.position.distance_to(Vector3(0.2, 0.0, 0.0)) < 0.001, "Near drag must follow the grab transform.")
	_expect(interactor.begin_resize(window_b, "TopRight", window_b.position, &"right"), "Starting resize on another window must cancel the prior exclusive interaction.")
	_expect(interactor.active_window == window_b and interactor.get_mode_name() == "resize", "Only one window and one interaction mode may remain active.")
	_expect(window_a.position.distance_to(Vector3.ZERO) < 0.001, "Canceled interaction must restore its starting transform.")
	var before: Vector2 = window_b.size_metres
	interactor.update_resize(Vector3(0.15, 0.1, 0.0), 0.0, 0.0, false)
	_expect(window_b.size_metres.x > before.x and window_b.size_metres.y > before.y, "Corner resize must grow both dimensions.")
	interactor.end_interaction(false)
	_expect(window_b.size_metres.is_equal_approx(before), "Canceling resize must restore its starting dimensions.")


func _test_far_depth_and_orientation(window: Node3D, interactor: Node) -> void:
	window.transform = Transform3D.IDENTITY
	interactor.orientation_mode = InteractorScript.OrientationMode.KEEP_UPRIGHT
	_expect(interactor.begin_far_ray_drag(window, Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 1.0, &"right"), "A valid far ray must start far interaction.")
	interactor.update_far_ray_drag(Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 1.0, 0.5, Vector3(0.0, 1.6, 2.0))
	_expect(is_equal_approx(interactor.far_depth, 1.7), "Two-dimensional controller depth input must progress along the far ray.")
	var up := window.basis.y.normalized()
	_expect(up.dot(Vector3.UP) > 0.999, "KEEP_UPRIGHT orientation must prevent window roll.")
	interactor.end_interaction(false)
	window.set_size_metres(Vector2(0.8, 0.4), false)
	interactor.begin_resize(window, "TopRight", window.position, &"right")
	interactor.apply_progressive_scale(1.0, 0.5, true)
	_expect(window.size_metres.x > 0.8 and is_equal_approx(window.get_aspect_ratio(), 2.0), "Progressive scaling must grow smoothly while preserving aspect ratio.")
	interactor.end_interaction(false)


func _test_snap_lifecycle(window: Node3D, interactor: Node, registry: MockRegistry) -> void:
	window.transform = Transform3D(Basis.IDENTITY, Vector3(0.1, 0.2, 0.3))
	window.set_size_metres(Vector2(0.8, 0.4), false)
	interactor.focus_window(window)
	var before_transform: Transform3D = window.transform
	var before_size: Vector2 = window.size_metres
	var snapped_transform := Transform3D(Basis.IDENTITY, Vector3(1.0, 0.5, -0.4))
	_expect(interactor.preview_snap("slot_left", snapped_transform, Vector2(1.0, 0.6)), "A non-empty snap slot must enter preview.")
	_expect(interactor.get_mode_name() == "snap_preview" and window.transform.is_equal_approx(snapped_transform), "Snap preview must display its candidate transform without committing.")
	interactor.cancel_snap()
	_expect(window.transform.is_equal_approx(before_transform) and window.size_metres.is_equal_approx(before_size), "Canceling snap must restore transform and dimensions exactly.")
	interactor.preview_snap("slot_left", snapped_transform, Vector2(1.0, 0.6))
	interactor.confirm_snap()
	_expect(window.snap_slot == "slot_left" and registry.confirmed_snaps.size() == 1, "Confirming snap must publish one authoritative registry request.")
	_expect((registry.confirmed_snaps[0] as Dictionary).get("size_m", Vector2.ZERO) == Vector2(1.0, 0.6), "Snap confirmation must commit its authoritative dimensions with the transform.")

	window.transform = Transform3D.IDENTITY
	window.set_snap_slot("", false)
	interactor.begin_far_ray_drag(window, Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 1.0, &"right")
	interactor.preview_snap("slot_drag_away", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.5)), Vector2(0.9, 0.5))
	interactor.update_far_ray_drag(Vector3.ZERO, Vector3(0.0, 0.0, -1.0), 0.0, 0.0, Vector3(0.0, 1.6, 2.0))
	_expect(interactor.get_mode_name() == "far_ray_drag" and window.snap_slot.is_empty(), "Dragging farther than the threshold must leave snap preview and resume the original drag.")
	interactor.end_interaction(false)


func _test_haptics(window: Node3D, interactor: Node) -> void:
	var events: Array[StringName] = []
	interactor.haptic_requested.connect(func(_hand: StringName, event_name: StringName, _strength: float, _duration: float) -> void:
		events.append(event_name)
	)
	interactor.begin_near_title_drag(window, Transform3D.IDENTITY, &"left")
	interactor.end_interaction(true)
	window.set_size_metres(Vector2(0.8, 0.4), false)
	interactor.begin_resize(window, "TopRight", window.position, &"left")
	interactor.apply_progressive_scale(1.0, 0.5, true)
	interactor.end_interaction(false)
	_expect(events.has(&"select") and events.has(&"grab") and events.has(&"release") and events.has(&"scale_tick"), "Selection, drag and scale thresholds must expose configurable haptic event semantics.")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)


func _get_scene_node_type(path: String) -> String:
	var state := WindowScene.get_state()
	for index: int in range(state.get_node_count()):
		var scene_path := str(state.get_node_path(index))
		if scene_path == path or scene_path.ends_with("/" + path):
			return str(state.get_node_type(index))
	return ""


func _finish() -> void:
	if _failures.is_empty():
		print("Spatial window self-test passed.")
		quit(0)
		return
	print("Spatial window self-test failed with %d error(s)." % _failures.size())
	quit(1)
