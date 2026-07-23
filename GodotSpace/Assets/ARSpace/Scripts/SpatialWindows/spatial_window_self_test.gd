extends SceneTree

const ControllerScript := preload(
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_controller.gd"
)
const DockManagerScript := preload(
	"res://Assets/ARSpace/Scripts/SpatialWindows/window_dock_manager.gd"
)
const StateManagerScript := preload(
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_state_manager.gd"
)
const SpawnPolicy := preload(
	"res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_spawn_policy.gd"
)
const SlotScene := preload(
	"res://Assets/ARSpace/Scenes/SpatialWindows/WindowDockSlot3D.tscn"
)

const STATE_HIDDEN: int = 0
const STATE_FLOATING: int = 1
const STATE_DRAGGING: int = 2
const STATE_SNAP_CANDIDATE: int = 3
const STATE_SNAPPED: int = 4
const SCOPE_LOCAL: int = 0
const SCOPE_SHARED: int = 1

var _failures: Array[String] = []
var _test_root: Node3D
var _shared_origin: Node3D
var _dock_manager: Node3D
var _state_manager: Node
var _viewpoint: Camera3D


class MockSurface extends Node:
	signal spatial_pointer_event(event, controller, grip_value)
	signal content_visibility_changed(is_visible)

	var allow_window_drag: bool = true
	var content: Node3D

	func _init() -> void:
		content = Node3D.new()
		content.name = "Content"
		add_child(content)

	func get_scene_instance() -> Node:
		return content


class MockController extends Node3D:
	var grip_value: float = 1.0
	var pulse_count: int = 0

	func get_float(_action: StringName) -> float:
		return grip_value

	func pulse(_strength: float, _duration: float) -> void:
		pulse_count += 1


class MockPointer extends Node3D:
	var target: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_world()
	await process_frame
	await process_frame
	_test_layer_and_slot_contract()
	await _test_state_machine_and_slot_lifecycle()
	await _test_ray_drag_and_grip_hysteresis()
	await _test_spawn_policy()
	await _test_authoritative_state()
	await _test_remote_preview_interpolation()
	await _cleanup()
	_finish()


func _build_world() -> void:
	_test_root = Node3D.new()
	_test_root.name = "SpatialWindowSelfTestRoot"
	root.add_child(_test_root)

	_shared_origin = Node3D.new()
	_shared_origin.name = "SharedSpaceOrigin"
	_shared_origin.add_to_group("shared_space_origin")
	_test_root.add_child(_shared_origin)

	_viewpoint = Camera3D.new()
	_viewpoint.name = "Viewpoint"
	_viewpoint.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.65, 0.0))
	_shared_origin.add_child(_viewpoint)

	_dock_manager = DockManagerScript.new()
	_dock_manager.name = "WindowDockSlots"
	_dock_manager.default_snap_distance_m = 0.5
	_shared_origin.add_child(_dock_manager)
	_add_slot(&"slot_a", Vector3(-0.6, 1.2, -1.7), PackedStringArray())
	_add_slot(&"slot_b", Vector3(0.6, 1.2, -1.7), PackedStringArray(["media"]))
	_dock_manager.call("refresh_slots")

	var spatial_windows := Node3D.new()
	spatial_windows.name = "SpatialWindows"
	_shared_origin.add_child(spatial_windows)
	_state_manager = StateManagerScript.new()
	_state_manager.name = "Manager"
	_state_manager.shared_space_origin_path = NodePath("../..")
	_state_manager.dock_manager_path = NodePath("../../WindowDockSlots")
	_state_manager.require_remote_interaction_pose = false
	_state_manager.warn_on_rejection = false
	spatial_windows.add_child(_state_manager)


func _add_slot(
	slot_id: StringName,
	position: Vector3,
	categories: PackedStringArray
) -> Node3D:
	var slot := SlotScene.instantiate() as Node3D
	slot.name = str(slot_id)
	slot.set("slot_id", slot_id)
	slot.set("accepted_categories", categories)
	slot.position = position
	_dock_manager.add_child(slot)
	return slot


func _test_layer_and_slot_contract() -> void:
	_check(
		str(ProjectSettings.get_setting("layer_names/3d_physics/layer_26", "")) == "WindowDockSlot",
		"physics layer 26 should be reserved for window dock slots"
	)
	var slot_a := _dock_manager.call("get_slot", &"slot_a") as Area3D
	_check(slot_a != null, "dock manager should register slot_a")
	if slot_a != null:
		_check(slot_a.collision_layer == (1 << 25), "dock slot should use only physics layer 26")
		_check(slot_a.collision_mask == 0, "dock slot should not query UI/player/annotation layers")
		var shape := slot_a.get_node_or_null("CollisionShape3D") as CollisionShape3D
		_check(shape != null and shape.shape is BoxShape3D, "dock slot should expose an editable detection shape")
		if shape != null and shape.shape is BoxShape3D:
			_check(
				(shape.shape as BoxShape3D).size.is_equal_approx(
					Vector3(1.119598, 1.064966, 0.148527)
				),
				"dock slot detection size should match the Unity Adsorb collider"
			)
		var fitted := _dock_manager.call(
			"get_snap_transform",
			&"slot_a",
			Vector3.ONE,
			Vector2(0.5, 0.5)
		) as Transform3D
		_check(
			fitted.basis.get_scale().is_equal_approx(Vector3.ONE * 2.129932),
			"Unity-sized slot target should deterministically scale a window to fit"
		)
	_check(
		bool(_dock_manager.call("refresh_slots")),
		"production slot IDs should be unique and non-empty"
	)


func _test_state_machine_and_slot_lifecycle() -> void:
	var window := _make_window(
		&"local_monitor",
		SCOPE_LOCAL,
		Vector3(-0.6, 1.2, -1.7),
		&"astronaut_view",
		Vector2(0.9, 0.6)
	)
	await process_frame
	await process_frame
	_check(int(window.call("get_state")) == STATE_FLOATING, "visible local window should start FLOATING")
	_check(
		not bool(window.call("_set_state", STATE_SNAPPED)),
		"FLOATING must not jump directly to SNAPPED"
	)
	_check(int(window.call("get_state")) == STATE_FLOATING, "illegal transition must preserve state")

	var xr_controller := MockController.new()
	xr_controller.name = "MockXRController"
	_shared_origin.add_child(xr_controller)
	xr_controller.global_position = Vector3.ZERO
	var base_scale := window.call("get_floating_scale") as Vector3
	window.call("toggle_zoom")
	var maximized_scale := (
		window.call("get_window_global_transform") as Transform3D
	).basis.get_scale()
	_check(
		maximized_scale.is_equal_approx(base_scale * 1.6),
		"maximize should apply the configured scale factor"
	)
	_check(
		bool(window.call("begin_drag", xr_controller, null)),
		"a maximized FLOATING window should begin dragging"
	)
	xr_controller.global_position = Vector3(10.0, 0.0, 0.0)
	window.call("update_drag_from_controller")
	_check(
		bool(window.call("finish_drag")),
		"a maximized drag away from dock slots should finish"
	)
	_check(
		(
			window.call("get_window_global_transform") as Transform3D
		).basis.get_scale().is_equal_approx(maximized_scale),
		"grip release must preserve the maximized window scale"
	)
	window.call("toggle_zoom")
	window.call("restore_window_position")
	xr_controller.global_position = Vector3.ZERO
	_check(bool(window.call("begin_drag", xr_controller, null)), "FLOATING should begin dragging")
	_check(int(window.call("get_state")) == STATE_DRAGGING, "begin drag should enter DRAGGING")
	window.call("update_drag_from_controller")
	_check(
		int(window.call("get_state")) == STATE_SNAP_CANDIDATE,
		"near an empty compatible slot, drag should enter SNAP_CANDIDATE"
	)
	xr_controller.global_position.x = 0.45
	window.call("update_drag_from_controller", 1.0)
	_check(
		int(window.call("get_state")) == STATE_SNAP_CANDIDATE,
		"snap candidate should remain active inside the release hysteresis distance"
	)
	xr_controller.global_position.x = 0.0
	window.call("update_drag_from_controller", 1.0)
	_check(xr_controller.pulse_count > 0, "candidate change should request light haptic feedback")
	_check(bool(window.call("finish_drag")), "candidate drag should finish")
	_check(int(window.call("get_state")) == STATE_SNAPPED, "candidate release should enter SNAPPED")
	_check(
		StringName(_dock_manager.call("get_slot_occupant", &"slot_a")) == &"local_monitor",
		"slot_a should be occupied by the snapped local window"
	)

	_check(bool(window.call("begin_drag", xr_controller, null)), "SNAPPED should begin dragging again")
	_check(
		StringName(_dock_manager.call("get_slot_occupant", &"slot_a")).is_empty(),
		"dragging a snapped window should immediately release its old slot"
	)
	xr_controller.grip_value = 0.0
	window.call("finish_drag")
	_check(int(window.call("get_state")) == STATE_FLOATING, "release away from a candidate should float")

	var competitor := _make_window(
		&"local_competitor",
		SCOPE_LOCAL,
		Vector3(-0.6, 1.2, -1.7),
		&"astronaut_view",
		Vector2(0.9, 0.6)
	)
	await process_frame
	await process_frame
	xr_controller.grip_value = 1.0
	window.call("begin_drag", xr_controller, null)
	window.call("update_drag_from_controller")
	window.call("finish_drag")
	_check(
		StringName(_dock_manager.call("get_slot_occupant", &"slot_a")) == &"local_monitor",
		"first window should reacquire slot_a"
	)
	var second_controller := MockController.new()
	_shared_origin.add_child(second_controller)
	competitor.call("begin_drag", second_controller, null)
	competitor.call("update_drag_from_controller")
	competitor.call("finish_drag")
	_check(
		int(competitor.call("get_state")) == STATE_FLOATING,
		"second window must remain FLOATING when the slot is occupied"
	)
	_check(
		StringName(_dock_manager.call("get_slot_occupant", &"slot_a")) == &"local_monitor",
		"slot competition must keep a single owner"
	)
	window.call("close_window")
	_check(int(window.call("get_state")) == STATE_HIDDEN, "close should enter HIDDEN")
	_check(
		StringName(_dock_manager.call("get_slot_occupant", &"slot_a")).is_empty(),
		"closing a snapped window must release occupancy"
	)
	window.call("open_window", null, false)
	_check(int(window.call("get_state")) == STATE_FLOATING, "reopen should restore FLOATING")
	xr_controller.grip_value = 1.0
	_check(bool(window.call("begin_drag", xr_controller, null)), "local drag should restart")
	var remote_drag_record := {
		"window_id": "local_monitor",
		"revision": 1,
		"visible": true,
		"state": STATE_DRAGGING,
		"transform": window.call("get_shared_transform"),
		"slot_id": "",
		"operator_peer_id": 99,
		"drag_token": 99,
	}
	window.call("apply_authoritative_record", remote_drag_record)
	_check(
		not bool(window.call("is_local_drag_active")),
		"an authoritative remote drag must cancel the losing local gesture"
	)
	window.call("_process", 0.0)
	_check(
		int(window.call("get_state")) == STATE_DRAGGING,
		"a remote DRAGGING record must not be locally auto-finished"
	)
	remote_drag_record["state"] = STATE_FLOATING
	remote_drag_record["operator_peer_id"] = 0
	remote_drag_record["drag_token"] = 0
	window.call("apply_authoritative_record", remote_drag_record)


func _test_ray_drag_and_grip_hysteresis() -> void:
	var window := _make_window(
		&"ray_drag",
		SCOPE_LOCAL,
		Vector3(0.0, 1.2, -2.5),
		&"media",
		Vector2(0.9, 0.6)
	)
	var controller := MockController.new()
	controller.name = "RayDragController"
	controller.position = Vector3(0.0, 1.2, 0.0)
	_shared_origin.add_child(controller)
	var pointer := MockPointer.new()
	pointer.name = "RayPointer"
	controller.add_child(pointer)
	await process_frame
	await process_frame
	var grab_position := Vector3(0.25, 1.2, -2.5)
	pointer.look_at(grab_position, Vector3.UP)
	_check(
		bool(window.call("begin_drag", controller, pointer, grab_position)),
		"ray hit should begin dragging from the selected surface point"
	)
	var ray_direction := -pointer.global_basis.z.normalized()
	var starting_position := (
		window.call("get_window_global_transform") as Transform3D
	).origin
	controller.global_position += ray_direction * 0.1
	window.call("update_drag_from_controller", 1.0)
	var dragged_transform := window.call("get_window_global_transform") as Transform3D
	var dragged_distance := (
		dragged_transform.origin - starting_position
	).dot(ray_direction)
	_check(
		dragged_distance > 0.2,
		"physical hand push should move ray-dragged windows forward with depth gain"
	)
	var local_grab_position := window.get("_drag_grab_local_position") as Vector3
	var world_grab_position := dragged_transform * local_grab_position
	_check(
		(world_grab_position - pointer.global_position).cross(ray_direction).length() < 0.001,
		"the original surface grab point should remain anchored to the pointer ray"
	)
	controller.grip_value = 0.6
	window.call("_process", 1.0 / 90.0)
	_check(
		bool(window.call("is_local_drag_active")),
		"grip values between press and release thresholds should keep the drag active"
	)
	controller.grip_value = 0.5
	window.call("_process", 1.0 / 90.0)
	_check(
		not bool(window.call("is_local_drag_active")),
		"grip should release only after crossing the lower release threshold"
	)


func _test_spawn_policy() -> void:
	var parent := _make_window(
		&"spawn_parent",
		SCOPE_LOCAL,
		Vector3(0.0, 1.35, -1.5),
		&"main_menu",
		Vector2(1.0, 0.65),
		true
	)
	var child := _make_window(
		&"spawn_child",
		SCOPE_LOCAL,
		Vector3(5.0, 5.0, 5.0),
		&"media",
		Vector2(0.8, 0.5)
	)
	await process_frame
	await process_frame
	_dock_manager.call("focus_window", parent)
	child.call("close_window")
	child.call("open_window", parent, true)
	var anchor := parent.call("get_child_spawn_anchor") as Node3D
	_check(anchor != null, "parent should expose ChildSpawnAnchor3D")
	if anchor != null:
		_check(
			child.call("get_window_global_transform").origin.is_equal_approx(anchor.global_position),
			"explicit parent anchor should be the first spawn choice"
		)
	var focused_parent := _make_window(
		&"focused_parent",
		SCOPE_LOCAL,
		Vector3(8.0, 1.35, -4.0),
		&"main_menu",
		Vector2(1.0, 0.65)
	)
	await process_frame
	await process_frame
	_dock_manager.call("focus_window", focused_parent)
	child.call("close_window")
	child.call("open_window", null, true)
	var focused_transform := focused_parent.call("get_window_global_transform") as Transform3D
	var focused_right := focused_transform.basis.x.normalized()
	var focused_offset := (
		child.call("get_window_global_transform") as Transform3D
	).origin - focused_transform.origin
	_check(
		focused_offset.dot(focused_right) > 0.8,
		"without an explicit parent, the last focused window should spawn the child to its right"
	)

	var fallback_current := Transform3D(
		Basis.IDENTITY.scaled(Vector3(0.75, 0.75, 0.75)),
		Vector3.ZERO
	)
	var fallback_controller := _make_window(
		&"head_fallback",
		SCOPE_LOCAL,
		Vector3.ZERO,
		&"media",
		Vector2(0.8, 0.5)
	)
	await process_frame
	fallback_controller.call("_set_window_transform", fallback_current)
	var fallback := SpawnPolicy.calculate_spawn_transform(
		fallback_controller,
		null,
		null,
		_viewpoint
	)
	var head_to_window := fallback.origin - _viewpoint.global_position
	_check(
		head_to_window.dot(-_viewpoint.global_basis.z) > 1.2,
		"head fallback should place the window in front of the user"
	)
	_check(
		fallback.origin.y < _viewpoint.global_position.y,
		"head fallback should sit slightly below eye level"
	)
	_check(
		fallback.basis.get_scale().is_equal_approx(Vector3(0.75, 0.75, 0.75)),
		"spawn policy should preserve the child window's own scale"
	)


func _test_authoritative_state() -> void:
	var shared_window := _make_window(
		&"shared_a",
		SCOPE_SHARED,
		Vector3(0.0, 1.1, -1.4),
		&"media",
		Vector2(0.9, 0.6)
	)
	var shared_competitor := _make_window(
		&"shared_b",
		SCOPE_SHARED,
		Vector3(0.1, 1.1, -1.4),
		&"media",
		Vector2(0.9, 0.6)
	)
	await process_frame
	await process_frame
	_check(
		_state_manager.call("get_window_state", &"local_monitor").is_empty(),
		"LOCAL_GROUND_VR window must never enter shared authority"
	)
	_check(
		not (_state_manager.call("get_window_state", &"shared_a") as Dictionary).is_empty(),
		"SHARED window should register an authoritative record"
	)
	var revision_before := int(_state_manager.call("get_state_revision"))
	var token := int(_state_manager.call(
		"request_begin_drag",
		&"shared_a",
		shared_window.call("get_shared_transform")
	))
	_check(token > 0, "Server-local shared drag should allocate a token")
	_check(
		int(_state_manager.call("get_state_revision")) == revision_before + 1,
		"reliable begin drag should advance the global revision once"
	)
	var drag_record := _state_manager.call("get_window_state", &"shared_a") as Dictionary
	_check(int(drag_record.get("state", -1)) == STATE_DRAGGING, "authoritative record should enter DRAGGING")
	_check(
		bool(_state_manager.call(
			"request_finish_drag",
			&"shared_a",
			token,
			1,
			shared_window.call("get_shared_transform"),
			&"slot_b"
		)),
		"authoritative finish should accept a compatible empty slot"
	)
	var snapped_record := _state_manager.call("get_window_state", &"shared_a") as Dictionary
	_check(int(snapped_record.get("state", -1)) == STATE_SNAPPED, "finish on slot_b should commit SNAPPED")
	_check(str(snapped_record.get("slot_id", "")) == "slot_b", "record should retain authoritative slot_id")
	var competition_revision := int(_state_manager.call("get_state_revision"))
	_check(
		not bool(_state_manager.call(
			"request_settled_state",
			&"shared_b",
			shared_competitor.call("get_shared_transform"),
			&"slot_b"
		)),
		"second shared window must lose an occupied-slot race"
	)
	_check(
		int(_state_manager.call("get_state_revision")) == competition_revision,
		"rejected slot competition must not advance revision"
	)
	var invalid := shared_competitor.call("get_shared_transform") as Transform3D
	invalid.origin.x = NAN
	_check(
		not bool(_state_manager.call("request_settled_state", &"shared_b", invalid, &"")),
		"non-finite shared transform must be rejected"
	)
	_check(
		int(_state_manager.call("get_state_revision")) == competition_revision,
		"invalid transform must not mutate authoritative state"
	)
	var oversized := shared_competitor.call("get_shared_transform") as Transform3D
	var oversized_scale := shared_competitor.call("get_floating_scale") as Vector3
	oversized.basis = oversized.basis.orthonormalized().scaled(
		oversized_scale * 4.0
	)
	_check(
		not bool(_state_manager.call("request_settled_state", &"shared_b", oversized, &"")),
		"oversized shared transform must be rejected"
	)


func _test_remote_preview_interpolation() -> void:
	var window := _make_window(
		&"remote_preview",
		SCOPE_LOCAL,
		Vector3(3.0, 1.2, -2.0),
		&"media",
		Vector2(0.9, 0.6)
	)
	await process_frame
	await process_frame
	var initial_transform := window.call("get_shared_transform") as Transform3D
	var remote_record := {
		"window_id": "remote_preview",
		"visible": true,
		"state": STATE_DRAGGING,
		"transform": initial_transform,
		"slot_id": "",
		"operator_peer_id": 99,
		"drag_token": 123,
	}
	window.call("apply_authoritative_record", remote_record)
	var preview_transform := initial_transform
	preview_transform.origin += Vector3(1.0, 0.0, 0.0)
	window.call("apply_authoritative_drag_preview", preview_transform, 99)
	var before_process := (
		window.call("get_window_global_transform") as Transform3D
	).origin
	_check(
		before_process.is_equal_approx(initial_transform.origin),
		"remote preview receipt should not hard-jump the window transform"
	)
	window.call("_process", 0.02)
	var interpolated_position := (
		window.call("get_window_global_transform") as Transform3D
	).origin
	_check(
		interpolated_position.x > initial_transform.origin.x \
			and interpolated_position.x < preview_transform.origin.x,
		"remote drag preview should interpolate toward the latest network target"
	)
	window.call("_process", 1.0)
	_check(
		(
			window.call("get_window_global_transform") as Transform3D
		).origin.is_equal_approx(preview_transform.origin),
		"remote interpolation should converge to the preview target"
	)
	remote_record["state"] = STATE_FLOATING
	remote_record["transform"] = preview_transform
	remote_record["operator_peer_id"] = 0
	remote_record["drag_token"] = 0
	window.call("apply_authoritative_record", remote_record)


func _make_window(
	window_id: StringName,
	scope: int,
	position: Vector3,
	category: StringName,
	size_m: Vector2,
	with_anchor: bool = false
) -> Node:
	var window_root := Node3D.new()
	window_root.name = str(window_id)
	window_root.position = position
	_shared_origin.add_child(window_root)
	var surface := MockSurface.new()
	surface.name = "Surface"
	window_root.add_child(surface)
	if with_anchor:
		var anchor := Marker3D.new()
		anchor.name = "ChildSpawnAnchor3D"
		anchor.position = Vector3(size_m.x + 0.2, 0.0, 0.0)
		window_root.add_child(anchor)
	var controller: Node = ControllerScript.new()
	controller.name = "SpatialWindowController"
	controller.window_id = window_id
	controller.scope = scope
	controller.window_category = category
	controller.window_size_m = size_m
	controller.window_root_path = NodePath("..")
	controller.event_source_path = NodePath("../Surface")
	controller.child_spawn_anchor_path = NodePath("../ChildSpawnAnchor3D") \
		if with_anchor else NodePath()
	controller.dock_manager_path = NodePath("../../WindowDockSlots")
	controller.state_manager_path = NodePath("../../SpatialWindows/Manager")
	controller.shared_space_origin_path = NodePath("../..")
	controller.viewpoint_path = NodePath("../../Viewpoint")
	controller.snap_tween_duration_sec = 0.0
	window_root.add_child(controller)
	return controller


func _cleanup() -> void:
	var old_root := _test_root
	_test_root = null
	_shared_origin = null
	_dock_manager = null
	_state_manager = null
	_viewpoint = null
	if old_root != null:
		old_root.queue_free()
	await process_frame
	await process_frame


func _finish() -> void:
	if _failures.is_empty():
		print("SPATIAL_WINDOW_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("SPATIAL_WINDOW_SELF_TEST: %s" % failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
