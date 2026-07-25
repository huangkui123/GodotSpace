class_name SpatialDrawingInteraction
extends Node

signal drawing_mode_changed(enabled: bool)
signal drafts_changed(draft_count: int)
signal exit_confirmation_requested(draft_count: int)
signal status_changed(message: String)

const Simplifier := preload("res://Assets/ARSpace/Scripts/SpatialDrawing/spatial_stroke_simplifier.gd")
const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const TipScene := preload("res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingTip.tscn")
const SERVER_PEER_ID: int = 1
const TOGGLE_KEY: Key = KEY_L
const TEST_TRIGGER_KEY: Key = KEY_J
const XR_PRESS_THRESHOLD: float = 0.65
const MIN_SAMPLE_DISTANCE_M: float = 0.005
const MAX_SAMPLE_INTERVAL_MSEC: int = 90
const SIMPLIFY_TOLERANCE_M: float = 0.0025
const MAX_POINTS_PER_STROKE: int = 2048
const MIN_WIDTH_M: float = 0.002
const MAX_WIDTH_M: float = 0.05
const MIN_TIP_DISTANCE_M: float = 0.03
const MAX_TIP_DISTANCE_M: float = 0.35
const AXIS_ADJUST_INTERVAL_MSEC: int = 160
const STATIC_NOZZLE_REFERENCE_BONE: StringName = &"Index_Tip_R"
const IDLE_GUIDE_DURATION_MSEC: int = 500
const IDLE_GUIDE_SAMPLE_INTERVAL_MSEC: int = 45
const IDLE_GUIDE_MIN_SAMPLE_DISTANCE_M: float = 0.002
const IDLE_GUIDE_MIN_WIDTH_M: float = 0.001
const IDLE_GUIDE_MAX_POINTS: int = 160
const IDLE_GUIDE_WIDTH_SCALE: float = 0.4
const PALETTE: Array[Color] = [
	Color(1.0, 0.03, 0.03, 1.0),
	Color(0.02, 1.0, 0.08, 1.0),
	Color(0.04, 0.08, 1.0, 1.0),
	Color(1.0, 0.02, 0.92, 1.0),
	Color(1.0, 0.36, 0.03, 1.0),
]

@export_node_path("Node") var manager_path: NodePath = NodePath("../SpatialDrawingManager")
@export_node_path("Node") var renderer_path: NodePath = NodePath("../SpatialDrawingRenderer")
@export_node_path("XRController3D") var right_controller_path: NodePath
@export_range(MIN_WIDTH_M, MAX_WIDTH_M, 0.001) var initial_width_m: float = 0.01
@export_range(MIN_TIP_DISTANCE_M, MAX_TIP_DISTANCE_M, 0.01) var initial_tip_distance_m: float = 0.12

var _manager: Node
var _renderer: Node
var _shared_space_origin: Node3D
var _right_controller: XRController3D
var _has_static_nozzle_alignment: bool = false
var _static_nozzle_controller_offset := Vector3.ZERO
var _function_pointer: Node
var _pickup_node: Node
var _movement_direct: Node
var _movement_direct_previous_enabled: bool = true
var _drawing_mode: bool = false
var _awaiting_exit_confirmation: bool = false
var _drafts: Array[Dictionary] = []
var _active_points := PackedVector3Array()
var _active_local_id: int = 0
var _next_local_id: int = 1
var _last_sample_msec: int = 0
var _selected_color_index: int = 0
var _width_m: float = initial_width_m
var _tip_distance_m: float = initial_tip_distance_m
var _last_axis_adjust_msec: int = 0
var _last_trigger_pressed: bool = false
var _last_toggle_pressed: bool = false
var _last_right_primary_pressed: bool = false
var _last_left_primary_pressed: bool = false
var _last_left_secondary_pressed: bool = false
var _status_message: String = ""
var _tip_visual: Node3D
var _idle_guide_points := PackedVector3Array()
var _idle_guide_sample_times: Array[int] = []

var _panel: Control
var _mode_button: Button
var _mode_label: Label
var _toggle_knob: Control
var _color_buttons: Array[Button] = []
var _clear_local_button: Button
var _sync_button: Button
var _confirm_overlay: Control
var _confirm_sync_button: Button
var _confirm_discard_button: Button


func _ready() -> void:
	add_to_group("spatial_drawing_interaction")
	_manager = get_node_or_null(manager_path)
	_renderer = get_node_or_null(renderer_path)
	if _manager == null or _renderer == null:
		push_error("SpatialDrawingInteraction requires manager and renderer siblings.")
		set_process(false)
		return
	if _manager.has_method("get_shared_space_origin"):
		_shared_space_origin = _manager.call("get_shared_space_origin") as Node3D
	_connect_manager_signals()
	_connect_annotation_interactions()
	_bind_panel()
	_width_m = clampf(initial_width_m, MIN_WIDTH_M, MAX_WIDTH_M)
	_tip_distance_m = clampf(initial_tip_distance_m, MIN_TIP_DISTANCE_M, MAX_TIP_DISTANCE_M)
	_update_panel()


func _exit_tree() -> void:
	_finish_active_stroke()
	clear_idle_guide()
	_clear_all_local_drafts()
	_clear_pointer_target_filter()
	_restore_movement_direct()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if key_event.pressed \
			and not key_event.echo \
			and key_event.physical_keycode == TOGGLE_KEY \
			and _can_local_draw():
		if _drawing_mode:
			request_exit()
		else:
			set_drawing_mode(true)
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_refresh_permission()
	if _panel == null or not is_instance_valid(_panel):
		_reset_panel_references()
		_bind_panel()
	_update_controller()
	_poll_input()
	_update_tip_visual()
	_update_idle_guide()


func is_drawing_mode_enabled() -> bool:
	return _drawing_mode


func has_unsynced_drafts() -> bool:
	return not _drafts.is_empty() or not _active_points.is_empty()


func get_drafts() -> Array:
	var result: Array = []
	for draft in _drafts:
		result.append(draft.duplicate(true))
	return result


func get_draft_count() -> int:
	return _drafts.size()


func get_current_color() -> Color:
	return PALETTE[_selected_color_index]


func get_width_m() -> float:
	return _width_m


func get_tip_distance_m() -> float:
	return _tip_distance_m


func set_drawing_mode(enabled: bool) -> bool:
	if enabled and not _can_local_draw():
		_set_status("当前端没有空间绘制权限。")
		return false
	if _drawing_mode == enabled:
		return true
	if enabled:
		_disable_conflicting_annotation_mode()
		_set_movement_direct_suppressed(true)
	_drawing_mode = enabled
	_awaiting_exit_confirmation = false
	clear_idle_guide()
	_configure_pointer_target_filter()
	if not enabled:
		_finish_active_stroke()
		_set_movement_direct_suppressed(false)
		_set_status("空间绘制模式已关闭。")
	else:
		_set_status("空间绘制已开启。按住右扳机在自由空间绘制。")
	drawing_mode_changed.emit(enabled)
	_update_visual_visibility()
	_update_panel()
	return true


func request_exit() -> bool:
	_finish_active_stroke()
	if _drafts.is_empty():
		return set_drawing_mode(false)
	_awaiting_exit_confirmation = true
	_set_status("有 %d 条未同步笔画：确认同步，或取消并丢弃。" % _drafts.size())
	exit_confirmation_requested.emit(_drafts.size())
	_update_panel()
	return false


func resolve_exit(sync_drafts: bool) -> bool:
	if not _awaiting_exit_confirmation:
		return false
	_awaiting_exit_confirmation = false
	if sync_drafts:
		sync_pending_drafts()
	else:
		clear_local_drafts()
	set_drawing_mode(false)
	return true


func begin_stroke_at_shared_position(shared_position: Vector3) -> bool:
	if not _drawing_mode or not _can_local_draw() or _input_is_blocked():
		return false
	if not Simplifier.is_finite_vector(shared_position):
		return false
	clear_idle_guide()
	_set_idle_guide_visible(false)
	_active_points = PackedVector3Array([shared_position])
	_active_local_id = _next_local_id
	_next_local_id += 1
	_last_sample_msec = Time.get_ticks_msec()
	_render_active_stroke()
	return true


func append_stroke_point(shared_position: Vector3, now_msec: int = -1) -> bool:
	if _active_points.is_empty() or _active_points.size() >= MAX_POINTS_PER_STROKE:
		return false
	var sample_msec := Time.get_ticks_msec() if now_msec < 0 else now_msec
	if not Simplifier.should_sample(
		_active_points,
		shared_position,
		sample_msec,
		_last_sample_msec,
		MIN_SAMPLE_DISTANCE_M,
		MAX_SAMPLE_INTERVAL_MSEC
	):
		return false
	_active_points.append(shared_position)
	_last_sample_msec = sample_msec
	_render_active_stroke()
	return true


func finish_stroke() -> bool:
	return _finish_active_stroke()


func undo_last_local_draft() -> bool:
	for index in range(_drafts.size() - 1, -1, -1):
		var draft := _drafts[index] as Dictionary
		if bool(draft.get("pending", false)):
			continue
		var local_id := int(draft.get("local_id", 0))
		_drafts.remove_at(index)
		_renderer.call("remove_local_draft", local_id)
		_set_status("已撤销本地笔画。")
		_emit_drafts_changed()
		return true
	_set_status("没有可撤销的本地笔画。")
	return false


func clear_local_drafts() -> int:
	_finish_active_stroke()
	var removed := 0
	for index in range(_drafts.size() - 1, -1, -1):
		var draft := _drafts[index] as Dictionary
		if bool(draft.get("pending", false)):
			continue
		_renderer.call("remove_local_draft", int(draft.get("local_id", 0)))
		_drafts.remove_at(index)
		removed += 1
	_set_status("已清除 %d 条未同步本地笔画。" % removed)
	_emit_drafts_changed()
	return removed


func clear_all_drawing() -> bool:
	var removed_local := clear_local_drafts()
	var published_count := 0
	if _manager != null and _manager.has_method("get_stroke_count"):
		published_count = int(_manager.call("get_stroke_count"))
	if published_count <= 0:
		return removed_local > 0
	return request_clear_published()


func sync_pending_drafts() -> int:
	_finish_active_stroke()
	var publishable: Array = []
	for draft in _drafts:
		if not bool(draft.get("pending", false)):
			publishable.append(draft.duplicate(true))
	if publishable.is_empty():
		_set_status("没有等待同步的空间笔画。")
		return 0
	_manager.call("submit_drafts", publishable)
	_set_status("正在同步 %d 条空间笔画…" % publishable.size())
	return publishable.size()


func request_clear_published() -> bool:
	if not _can_local_draw():
		return false
	var accepted := bool(_manager.call("request_clear_published"))
	if accepted:
		_set_status("已提交三端空间笔画清空请求。")
	return accepted


func set_color_index(index: int) -> void:
	_selected_color_index = posmod(index, PALETTE.size())
	_update_panel()


func set_width_m(value: float) -> void:
	_width_m = clampf(value, MIN_WIDTH_M, MAX_WIDTH_M)
	_render_idle_guide()
	_update_panel()


func set_tip_distance_m(value: float) -> void:
	_tip_distance_m = clampf(value, MIN_TIP_DISTANCE_M, MAX_TIP_DISTANCE_M)
	_update_panel()


func is_input_blocked() -> bool:
	return _input_is_blocked()


func get_nozzle_global_transform() -> Transform3D:
	return _get_nozzle_global_transform()


func has_static_nozzle_alignment() -> bool:
	_capture_static_nozzle_alignment()
	return _has_static_nozzle_alignment


func get_idle_guide_points() -> PackedVector3Array:
	return _idle_guide_points.duplicate()


func sample_idle_guide_at_shared_position(
	shared_position: Vector3,
	now_msec: int = -1
) -> bool:
	if not Simplifier.is_finite_vector(shared_position):
		return false
	var sample_msec := Time.get_ticks_msec() if now_msec < 0 else now_msec
	if not _idle_guide_sample_times.is_empty() \
			and sample_msec < _idle_guide_sample_times[-1]:
		clear_idle_guide()
	var changed := _prune_idle_guide(sample_msec)
	var should_append := _idle_guide_points.is_empty()
	if not should_append:
		should_append = (
			_idle_guide_points[-1].distance_squared_to(shared_position)
				>= IDLE_GUIDE_MIN_SAMPLE_DISTANCE_M * IDLE_GUIDE_MIN_SAMPLE_DISTANCE_M
			or sample_msec - _idle_guide_sample_times[-1]
				>= IDLE_GUIDE_SAMPLE_INTERVAL_MSEC
		)
	if should_append:
		_idle_guide_points.append(shared_position)
		_idle_guide_sample_times.append(sample_msec)
		changed = true
	while _idle_guide_points.size() > IDLE_GUIDE_MAX_POINTS:
		_idle_guide_points.remove_at(0)
		_idle_guide_sample_times.remove_at(0)
		changed = true
	if changed:
		_render_idle_guide()
	return should_append


func clear_idle_guide() -> void:
	var had_points := not _idle_guide_points.is_empty()
	_idle_guide_points = PackedVector3Array()
	_idle_guide_sample_times.clear()
	if had_points and _renderer != null and _renderer.has_method("clear_idle_guide"):
		_renderer.call("clear_idle_guide")


func _finish_active_stroke() -> bool:
	if _active_points.is_empty():
		return false
	_set_idle_guide_visible(true)
	var local_id := _active_local_id
	var simplified: PackedVector3Array = Simplifier.simplify(
		_active_points,
		SIMPLIFY_TOLERANCE_M,
		MAX_POINTS_PER_STROKE
	)
	_active_points = PackedVector3Array()
	_active_local_id = 0
	if simplified.size() < 2:
		_renderer.call("remove_local_draft", local_id)
		_set_status("笔画点数不足，已丢弃。")
		return false
	var draft := {
		"local_id": local_id,
		"points": simplified,
		"color": get_current_color(),
		"width_m": _width_m,
		"completed": true,
		"pending": false,
	}
	_drafts.append(draft)
	_renderer.call("upsert_local_draft", local_id, draft)
	_set_status("笔画已保存到本地，点击“同步”后发布。")
	_emit_drafts_changed()
	return true


func _render_active_stroke() -> void:
	if _active_local_id <= 0:
		return
	_renderer.call("upsert_local_draft", _active_local_id, {
		"points": _active_points,
		"color": get_current_color(),
		"width_m": _width_m,
	})


func _poll_input() -> void:
	if _right_controller == null or not is_instance_valid(_right_controller):
		return
	var profile = RuntimeProfile.current()
	var test_mode: bool = profile != null and profile.is_test_mode()
	if not test_mode and not _right_controller.get_is_active():
		return
	var right_tracker := XRServer.get_tracker(&"right_hand")
	var left_tracker := XRServer.get_tracker(&"left_hand")
	var toggle_pressed := _tracker_input_pressed(right_tracker, &"primary_click")
	var trigger_pressed := Input.is_key_pressed(TEST_TRIGGER_KEY) \
		if test_mode \
		else _tracker_input_pressed(right_tracker, &"trigger")
	var right_primary_pressed := _tracker_input_pressed(right_tracker, &"ax_button")
	var left_primary_pressed := _tracker_input_pressed(left_tracker, &"ax_button")
	var left_secondary_pressed := _tracker_input_pressed(left_tracker, &"by_button")

	if toggle_pressed and not _last_toggle_pressed:
		if _drawing_mode:
			request_exit()
		else:
			set_drawing_mode(true)

	if _awaiting_exit_confirmation:
		if right_primary_pressed and not _last_right_primary_pressed:
			resolve_exit(true)
		elif left_secondary_pressed and not _last_left_secondary_pressed:
			resolve_exit(false)
	elif _drawing_mode:
		if trigger_pressed and not _last_trigger_pressed:
			if not _input_is_blocked():
				begin_stroke_at_shared_position(_get_tip_shared_position())
		elif trigger_pressed and not _active_points.is_empty():
			if _input_is_blocked():
				_finish_active_stroke()
			else:
				append_stroke_point(_get_tip_shared_position())
		elif not trigger_pressed and _last_trigger_pressed:
			_finish_active_stroke()

		var right_grip := _tracker_input_pressed(right_tracker, &"grip")
		if right_primary_pressed and not _last_right_primary_pressed:
			if right_grip:
				request_clear_published()
			else:
				sync_pending_drafts()
		if left_primary_pressed and not _last_left_primary_pressed:
			undo_last_local_draft()
		if left_secondary_pressed and not _last_left_secondary_pressed:
			clear_local_drafts()
		_adjust_from_axes(right_tracker, left_tracker)

	_last_trigger_pressed = trigger_pressed
	_last_toggle_pressed = toggle_pressed
	_last_right_primary_pressed = right_primary_pressed
	_last_left_primary_pressed = left_primary_pressed
	_last_left_secondary_pressed = left_secondary_pressed


func _adjust_from_axes(
	right_tracker: XRPositionalTracker,
	left_tracker: XRPositionalTracker
) -> void:
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_axis_adjust_msec < AXIS_ADJUST_INTERVAL_MSEC:
		return
	var right_axis := _tracker_axis(right_tracker, &"primary")
	var left_axis := _tracker_axis(left_tracker, &"primary")
	var adjusted := false
	if absf(right_axis.y) > 0.65:
		set_tip_distance_m(_tip_distance_m + signf(right_axis.y) * 0.01)
		adjusted = true
	elif absf(left_axis.x) > 0.65:
		set_color_index(_selected_color_index + int(signf(left_axis.x)))
		adjusted = true
	elif absf(left_axis.y) > 0.65:
		set_width_m(_width_m + signf(left_axis.y) * 0.002)
		adjusted = true
	if adjusted:
		_last_axis_adjust_msec = now_msec


func _update_controller() -> void:
	if _right_controller != null and is_instance_valid(_right_controller):
		_find_controller_helpers()
		return
	_right_controller = null
	_has_static_nozzle_alignment = false
	_static_nozzle_controller_offset = Vector3.ZERO
	if not right_controller_path.is_empty():
		_right_controller = get_node_or_null(right_controller_path) as XRController3D
	if _right_controller == null:
		var scene := get_tree().current_scene
		if scene != null:
			var peer_id := multiplayer.get_unique_id() \
				if multiplayer.has_multiplayer_peer() \
				else SERVER_PEER_ID
			_right_controller = scene.get_node_or_null(
				NodePath("%d/XROrigin3D/RightHand" % peer_id)
			) as XRController3D
	if _right_controller != null:
		_create_controller_visuals()
		_find_controller_helpers()


func _find_controller_helpers() -> void:
	if _right_controller == null:
		return
	_capture_static_nozzle_alignment()
	if _function_pointer == null or not is_instance_valid(_function_pointer):
		_function_pointer = _right_controller.get_node_or_null("FunctionPointer")
	_configure_pointer_target_filter()
	if _movement_direct == null or not is_instance_valid(_movement_direct):
		_movement_direct = _right_controller.get_node_or_null("MovementDirect")
	if _pickup_node == null or not is_instance_valid(_pickup_node):
		for candidate in _right_controller.find_children("*", "Node", true, false):
			if candidate.has_method("is_xr_class") \
					and bool(candidate.call("is_xr_class", "XRToolsFunctionPickup")):
				_pickup_node = candidate
				break


func _capture_static_nozzle_alignment() -> void:
	if _has_static_nozzle_alignment \
			or _right_controller == null \
			or not is_instance_valid(_right_controller):
		return
	for candidate in _right_controller.find_children("*", "Skeleton3D", true, false):
		var skeleton := candidate as Skeleton3D
		if skeleton == null:
			continue
		var tip_bone := skeleton.find_bone(STATIC_NOZZLE_REFERENCE_BONE)
		if tip_bone < 0:
			continue
		var reference_pose := skeleton.global_transform \
			* skeleton.get_bone_global_pose(tip_bone)
		_static_nozzle_controller_offset = _right_controller.to_local(
			reference_pose.origin
		)
		_has_static_nozzle_alignment = true
		return


func _input_is_blocked() -> bool:
	if _window_drag_is_active():
		return true
	if _pickup_node != null and is_instance_valid(_pickup_node):
		var picked = _pickup_node.get("picked_up_object")
		if picked is Node and is_instance_valid(picked):
			return true
	if _function_pointer != null and is_instance_valid(_function_pointer):
		var target = _function_pointer.get("target")
		var last_target = _function_pointer.get("last_target")
		if _is_spatial_drawing_panel_target(target) \
				or _is_spatial_drawing_panel_target(last_target):
			return true
	return false


func _configure_pointer_target_filter() -> void:
	if _function_pointer == null or not is_instance_valid(_function_pointer):
		return
	if _drawing_mode and _function_pointer.has_method("set_target_filter"):
		_function_pointer.call(
			"set_target_filter",
			Callable(self, "_is_spatial_drawing_panel_target")
		)
	elif not _drawing_mode and _function_pointer.has_method("clear_target_filter"):
		_function_pointer.call("clear_target_filter")


func _clear_pointer_target_filter() -> void:
	if _function_pointer != null \
			and is_instance_valid(_function_pointer) \
			and _function_pointer.has_method("clear_target_filter"):
		_function_pointer.call("clear_target_filter")


func _is_spatial_drawing_panel_target(candidate) -> bool:
	if not (candidate is Node) or not is_instance_valid(candidate):
		return false
	var current := candidate as Node
	while current != null:
		if current.is_in_group("spatial_drawing_panel_3d"):
			return true
		current = current.get_parent()
	return false


func _window_drag_is_active() -> bool:
	for controller in get_tree().get_nodes_in_group("spatial_window_controller"):
		if controller.has_method("is_local_drag_active") \
				and bool(controller.call("is_local_drag_active")):
			return true
	return false


func _get_tip_shared_position() -> Vector3:
	if _right_controller == null or _shared_space_origin == null:
		return Vector3.INF
	return _shared_space_origin.to_local(_get_nozzle_global_transform().origin)


func _get_nozzle_global_transform() -> Transform3D:
	if _right_controller == null or not is_instance_valid(_right_controller):
		return Transform3D()
	var nozzle_transform := _right_controller.global_transform
	nozzle_transform.basis = nozzle_transform.basis.orthonormalized()
	_capture_static_nozzle_alignment()
	if _has_static_nozzle_alignment:
		nozzle_transform.origin = _right_controller.to_global(
			_static_nozzle_controller_offset
		)
	else:
		nozzle_transform.origin = _right_controller.global_position \
			- nozzle_transform.basis.z * _tip_distance_m
	return nozzle_transform


func _tracker_input_pressed(tracker: XRPositionalTracker, input_name: StringName) -> bool:
	if tracker == null:
		return false
	var value = tracker.get_input(input_name)
	if value is bool:
		return value
	if value is float or value is int:
		return float(value) >= XR_PRESS_THRESHOLD
	return false


func _tracker_axis(tracker: XRPositionalTracker, input_name: StringName) -> Vector2:
	if tracker == null:
		return Vector2.ZERO
	var value = tracker.get_input(input_name)
	return value as Vector2 if value is Vector2 else Vector2.ZERO


func _create_controller_visuals() -> void:
	if _right_controller == null:
		return
	if _tip_visual == null:
		_tip_visual = TipScene.instantiate() as Node3D
		if _tip_visual == null:
			push_error("SpatialDrawingTip scene root must be a Node3D.")
			return
		add_child(_tip_visual)
	_update_visual_visibility()


func _update_tip_visual() -> void:
	if _tip_visual == null:
		return
	_tip_visual.visible = _drawing_mode and _right_controller != null
	if not _tip_visual.visible:
		return
	_tip_visual.global_transform = _get_nozzle_global_transform()
	if _tip_visual.has_method("set_tool_color"):
		_tip_visual.call("set_tool_color", get_current_color())


func _update_idle_guide() -> void:
	if not _drawing_mode \
			or _awaiting_exit_confirmation \
			or not _controller_pose_is_available() \
			or _shared_space_origin == null \
			or _input_is_blocked():
		clear_idle_guide()
		return
	if _last_trigger_pressed:
		clear_idle_guide()
		_set_idle_guide_visible(false)
		return
	var shared_position := _get_tip_shared_position()
	if not Simplifier.is_finite_vector(shared_position):
		clear_idle_guide()
		return
	sample_idle_guide_at_shared_position(shared_position)
	_set_idle_guide_visible(not _last_trigger_pressed)


func _controller_pose_is_available() -> bool:
	if _right_controller == null or not is_instance_valid(_right_controller):
		return false
	var profile = RuntimeProfile.current()
	return (profile != null and profile.is_test_mode()) \
		or _right_controller.get_is_active()


func _prune_idle_guide(now_msec: int) -> bool:
	var changed := false
	var cutoff_msec := now_msec - IDLE_GUIDE_DURATION_MSEC
	while not _idle_guide_sample_times.is_empty() \
			and _idle_guide_sample_times[0] < cutoff_msec:
		_idle_guide_sample_times.remove_at(0)
		_idle_guide_points.remove_at(0)
		changed = true
	return changed


func _render_idle_guide() -> void:
	if _renderer == null or not _renderer.has_method("update_idle_guide"):
		return
	_renderer.call(
		"update_idle_guide",
		_idle_guide_points,
		maxf(IDLE_GUIDE_MIN_WIDTH_M, _width_m * IDLE_GUIDE_WIDTH_SCALE)
	)


func _set_idle_guide_visible(is_visible: bool) -> void:
	if _renderer != null and _renderer.has_method("set_idle_guide_visible"):
		_renderer.call("set_idle_guide_visible", is_visible)


func _update_visual_visibility() -> void:
	if _tip_visual != null:
		_tip_visual.visible = _drawing_mode
	_update_panel()


func _disable_conflicting_annotation_mode() -> void:
	for interaction in get_tree().get_nodes_in_group("virtual_annotation_interaction"):
		if interaction.has_method("set_annotation_mode"):
			interaction.call("set_annotation_mode", false)


func _connect_annotation_interactions() -> void:
	for interaction in get_tree().get_nodes_in_group("virtual_annotation_interaction"):
		if not interaction.has_signal("annotation_mode_changed"):
			continue
		var callback := _on_annotation_mode_changed
		if not interaction.is_connected("annotation_mode_changed", callback):
			interaction.connect("annotation_mode_changed", callback)


func _on_annotation_mode_changed(enabled: bool) -> void:
	if enabled and _drawing_mode:
		request_exit()


func _set_movement_direct_suppressed(suppressed: bool) -> void:
	if _movement_direct == null or not is_instance_valid(_movement_direct):
		return
	if suppressed:
		_movement_direct_previous_enabled = bool(_movement_direct.get("enabled"))
		_movement_direct.set("enabled", false)
	else:
		_restore_movement_direct()


func _restore_movement_direct() -> void:
	if _movement_direct != null and is_instance_valid(_movement_direct):
		_movement_direct.set("enabled", _movement_direct_previous_enabled)


func _refresh_permission() -> void:
	if _drawing_mode and not _can_local_draw():
		_finish_active_stroke()
		clear_local_drafts()
		set_drawing_mode(false)


func _can_local_draw() -> bool:
	return _manager != null \
		and _manager.has_method("can_local_draw") \
		and bool(_manager.call("can_local_draw"))


func _connect_manager_signals() -> void:
	_manager.connect("operation_submitted", _on_operation_submitted)
	_manager.connect("operation_completed", _on_operation_completed)
	_manager.connect("operation_failed", _on_operation_failed)
	_manager.connect("stroke_added", func(_stroke: Dictionary) -> void: _update_panel())
	_manager.connect("stroke_removed", func(_stroke_id: int) -> void: _update_panel())
	_manager.connect("strokes_cleared", func() -> void: _update_panel())
	_manager.connect("snapshot_applied", func(_revision: int, _count: int) -> void: _update_panel())


func _on_operation_submitted(operation: String, _request_sequence: int, local_id: int) -> void:
	if operation != "submit":
		return
	_set_draft_pending(local_id, true)


func _on_operation_completed(
	operation: String,
	_request_sequence: int,
	local_id: int,
	_stroke_id: int
) -> void:
	if operation == "submit":
		_remove_draft_by_local_id(local_id)
		_set_status("空间笔画已由 Server 确认并同步到三端。")
	elif operation == "clear":
		_set_status("三端已同步清空空间笔画。")
	elif operation == "delete":
		_set_status("空间笔画已删除。")
	_update_panel()


func _on_operation_failed(
	operation: String,
	_request_sequence: int,
	local_id: int,
	message: String
) -> void:
	if operation == "submit":
		_set_draft_pending(local_id, false)
	_set_status("%s 本地草稿已保留。" % message)


func _set_draft_pending(local_id: int, pending: bool) -> void:
	for index in range(_drafts.size()):
		if int(_drafts[index].get("local_id", 0)) != local_id:
			continue
		var draft := _drafts[index] as Dictionary
		draft["pending"] = pending
		_drafts[index] = draft
		break
	_emit_drafts_changed()


func _remove_draft_by_local_id(local_id: int) -> void:
	for index in range(_drafts.size() - 1, -1, -1):
		if int(_drafts[index].get("local_id", 0)) != local_id:
			continue
		_drafts.remove_at(index)
		_renderer.call("remove_local_draft", local_id)
		break
	_emit_drafts_changed()


func _clear_all_local_drafts() -> void:
	_drafts.clear()
	_active_points = PackedVector3Array()
	_active_local_id = 0
	if _renderer != null and _renderer.has_method("clear_local_drafts"):
		_renderer.call("clear_local_drafts")


func _emit_drafts_changed() -> void:
	drafts_changed.emit(_drafts.size())
	_update_panel()


func _bind_panel() -> void:
	_panel = get_tree().get_first_node_in_group("spatial_drawing_panel") as Control
	if _panel == null:
		return
	_mode_button = _panel.get_node_or_null(
		"Margin/Layout/Header/ModeRow/ModeButton"
	) as Button
	_mode_label = _panel.get_node_or_null(
		"Margin/Layout/Header/ModeRow/ModeLabel"
	) as Label
	_toggle_knob = _panel.get_node_or_null(
		"Margin/Layout/Header/ModeRow/ModeButton/Track/Knob"
	) as Control
	if _mode_button != null:
		_mode_button.toggled.connect(_on_mode_button_toggled)
	var color_names: Array[String] = ["Red", "Green", "Blue", "Magenta", "Orange"]
	for index in range(color_names.size()):
		var color_button := _panel.get_node_or_null(
			"Margin/Layout/ToolRow/%s/ColorButton" % color_names[index]
		) as Button
		if color_button == null:
			continue
		var color_index := index
		color_button.pressed.connect(
			func() -> void: set_color_index(color_index)
		)
		_color_buttons.append(color_button)
	_clear_local_button = _panel.get_node_or_null(
		"Margin/Layout/ToolRow/Clear/ClearButton"
	) as Button
	_sync_button = _panel.get_node_or_null(
		"Margin/Layout/ToolRow/Sync/SyncButton"
	) as Button
	_confirm_overlay = _panel.get_node_or_null("ConfirmOverlay") as Control
	_confirm_sync_button = _panel.get_node_or_null(
		"ConfirmOverlay/Center/Content/Actions/SyncExitButton"
	) as Button
	_confirm_discard_button = _panel.get_node_or_null(
		"ConfirmOverlay/Center/Content/Actions/DiscardExitButton"
	) as Button
	if _clear_local_button != null:
		_clear_local_button.pressed.connect(clear_all_drawing)
	if _sync_button != null:
		_sync_button.pressed.connect(sync_pending_drafts)
	if _confirm_sync_button != null:
		_confirm_sync_button.pressed.connect(
			func() -> void: resolve_exit(true)
		)
	if _confirm_discard_button != null:
		_confirm_discard_button.pressed.connect(
			func() -> void: resolve_exit(false)
		)
	_update_panel()


func _reset_panel_references() -> void:
	_panel = null
	_mode_button = null
	_mode_label = null
	_toggle_knob = null
	_color_buttons.clear()
	_clear_local_button = null
	_sync_button = null
	_confirm_overlay = null
	_confirm_sync_button = null
	_confirm_discard_button = null


func _on_mode_button_toggled(pressed: bool) -> void:
	if pressed:
		set_drawing_mode(true)
	else:
		request_exit()
	_update_panel()


func _update_panel() -> void:
	if _panel == null or not is_instance_valid(_panel):
		return
	if _mode_button != null:
		_mode_button.set_pressed_no_signal(_drawing_mode)
		_mode_button.disabled = not _can_local_draw()
	if _mode_label != null:
		_mode_label.modulate = (
			Color(0.82, 0.86, 1.0, 1.0)
			if _drawing_mode
			else Color(0.68, 0.74, 1.0, 1.0)
		)
	if _toggle_knob != null:
		_toggle_knob.position.x = 61.0 if _drawing_mode else 9.0
	for index in range(_color_buttons.size()):
		_color_buttons[index].set_pressed_no_signal(index == _selected_color_index)
	var has_editable_drafts := _has_editable_local_drafts()
	var has_published_strokes := _manager != null \
		and _manager.has_method("get_stroke_count") \
		and int(_manager.call("get_stroke_count")) > 0
	if _clear_local_button != null:
		_clear_local_button.disabled = not has_editable_drafts and not has_published_strokes
	if _sync_button != null:
		_sync_button.disabled = not has_editable_drafts
	if _confirm_overlay != null:
		_confirm_overlay.visible = _awaiting_exit_confirmation
	_panel.tooltip_text = _status_message


func _has_editable_local_drafts() -> bool:
	if not _active_points.is_empty():
		return true
	for draft in _drafts:
		if not bool(draft.get("pending", false)):
			return true
	return false


func _set_status(message: String) -> void:
	_status_message = message
	status_changed.emit(message)
	_update_panel()
