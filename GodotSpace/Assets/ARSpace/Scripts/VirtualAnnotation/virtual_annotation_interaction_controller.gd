class_name VirtualAnnotationInteractionController
extends Node

signal annotation_mode_changed(enabled: bool)
signal draft_changed(draft: Dictionary)
signal status_changed(message: String)

const MARKER_SCENE := preload("res://Assets/ARSpace/Scenes/VirtualAnnotationMarker.tscn")
const ANNOTATION_SURFACE_LAYER: int = 1 << 23
const MARKER_COLLISION_LAYER: int = 1 << 24
const PC_TOGGLE_KEY: Key = KEY_P
const RAY_LENGTH: float = 100.0
const XR_PRESS_THRESHOLD: float = 0.65
const SERVER_PEER_ID: int = 1
const MAX_ANNOTATIONS: int = 128
const MAX_TEXT_LENGTH: int = 80
const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

@export_node_path("Node3D") var manager_path: NodePath = NodePath("../Manager")
@export_node_path("Node") var surface_builder_path: NodePath = NodePath("../SurfaceBuilder")
@export_node_path("XRController3D") var right_controller_path: NodePath
@export var show_pc_panel: bool = true

var _manager: Variant
var _surface_builder: Variant
var _voice_chat: Node
var _annotation_mode: bool = false
var _draft: Dictionary = {}
var _selected_annotation_id: int = -1
var _last_annotation_id: int = -1
var _draft_preview: Node3D
var _hover_preview: MeshInstance3D
var _vr_ray: MeshInstance3D
var _right_controller: XRController3D
var _wrist_label: Label3D
var _pickup_node: Node
var _function_pointer: Node
var _pickup_previous_enabled: bool = true
var _last_trigger_pressed: bool = false
var _last_grip_pressed: bool = false
var _last_secondary_pressed: bool = false
var _last_primary_pressed: bool = false
var _last_left_primary_pressed: bool = false
var _last_left_secondary_pressed: bool = false
var _current_vr_hit: Dictionary = {}
var _local_text_buffer: String = ""
var _dictation_session_id: String = ""
var _dictation_active: bool = false
var _clear_confirmation_deadline_ms: int = 0
var _status_message: String = ""
var _pending_create_drafts: Dictionary = {}

var _control_panel: Node
var _panel: Control
var _mode_button: Button
var _status_label: Label
var _count_label: Label
var _note_edit: LineEdit
var _record_button: Button
var _confirm_button: Button
var _delete_button: Button
var _clear_button: Button


func _ready() -> void:
	add_to_group("virtual_annotation_interaction")
	_manager = get_node_or_null(manager_path)
	_surface_builder = get_node_or_null(surface_builder_path)
	_voice_chat = get_node_or_null("/root/VoiceChat")
	if _manager == null:
		push_error("VirtualAnnotationInteractionController requires a VirtualAnnotationManager.")
		set_process(false)
		return
	_connect_manager_signals()
	_connect_builder_signals()
	_connect_dictation_signals()
	var profile = RuntimeProfile.current()
	if show_pc_panel and profile.uses_desktop_ui():
		_bind_control_panel_section()
	_refresh_authority_visibility()
	_update_panel()


func _exit_tree() -> void:
	_cancel_dictation()
	if _annotation_mode:
		_set_pickup_suppressed(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _can_local_annotate():
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.physical_keycode == PC_TOGGLE_KEY:
			toggle_annotation_mode()
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_refresh_authority_visibility()
	_update_clear_confirmation()
	_update_xr_controller()
	_poll_xr_input()


func is_annotation_mode_enabled() -> bool:
	return _annotation_mode


func toggle_annotation_mode() -> bool:
	return set_annotation_mode(not _annotation_mode)


func set_annotation_mode(enabled: bool) -> bool:
	if enabled and not _can_local_annotate():
		_set_status("当前端未获得地面标注权限。")
		return false
	if enabled and not _surfaces_ready():
		_set_status("正在准备可标注表面，请稍候。")
		return false
	if _annotation_mode == enabled:
		return true

	_annotation_mode = enabled
	if enabled:
		_open_control_panel_section()
	_set_pickup_suppressed(enabled)
	_set_vr_visuals_visible(enabled)
	if not enabled:
		_cancel_dictation()
		_clear_draft()
		_current_vr_hit.clear()
		_set_status("标注模式已关闭。")
	else:
		_set_status("标注模式已开启。点击虚拟模型表面放置标注。")
	annotation_mode_changed.emit(enabled)
	_update_panel()
	return true


func handle_pc_pointer(camera: Camera3D, screen_position: Vector2) -> bool:
	if not _annotation_mode or camera == null or not camera.is_current():
		return false
	if not _surfaces_ready():
		_set_status("正在准备可标注表面，请稍候。")
		return true
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_end := ray_origin + camera.project_ray_normal(screen_position) * RAY_LENGTH
	var hit := _raycast(camera.get_world_3d(), ray_origin, ray_end)
	_handle_pointing_hit(hit)
	return true


func set_draft_text(text: String) -> void:
	var clean := text.strip_edges().left(MAX_TEXT_LENGTH)
	_local_text_buffer = clean
	if not _draft.is_empty():
		_draft["text"] = clean
	if _note_edit != null and _note_edit.text != clean:
		_note_edit.text = clean
	draft_changed.emit(_draft.duplicate(true))
	_update_wrist_label()


func confirm_draft_or_update() -> bool:
	if not _can_local_annotate():
		return false
	if not _draft.is_empty():
		if not _pending_create_drafts.is_empty():
			_set_status("上一个标注正在等待 PC 地面 Server 处理。")
			return false
		var text := _note_edit.text.strip_edges() if _note_edit != null else _local_text_buffer.strip_edges()
		if text == "":
			text = str(_draft.get("text", "")).strip_edges()
		if text == "":
			text = _manager.get_next_default_text()
		_draft["text"] = text
		var annotation_id: int = int(_manager.create_annotation(_draft))
		if annotation_id < 0:
			return false
		if annotation_id == 0:
			_clear_draft()
			_set_status("已提交给 PC 地面 Server，正在等待发布。")
			return true
		_last_annotation_id = annotation_id
		_selected_annotation_id = annotation_id
		_clear_draft()
		_set_status("已发布虚拟标注 %d。" % annotation_id)
		return true

	if _selected_annotation_id > 0:
		var selected: Dictionary = _manager.get_annotation(_selected_annotation_id)
		if selected.is_empty():
			_selected_annotation_id = -1
			_update_panel()
			return false
		var text := _note_edit.text.strip_edges() if _note_edit != null else _local_text_buffer.strip_edges()
		if text == "":
			text = str(selected.get("text", ""))
		if text == "":
			text = "标注 %d" % _selected_annotation_id
		if _manager.update_annotation_text(_selected_annotation_id, text):
			_set_status(
				"已更新虚拟标注 %d。" % _selected_annotation_id
				if multiplayer.is_server()
				else "已提交标注更新请求。"
			)
			return true
	return false


func cancel_draft() -> void:
	_cancel_dictation()
	_clear_draft()
	_set_status("已取消本地草稿。")


func delete_selected_annotation() -> bool:
	if _selected_annotation_id <= 0:
		_set_status("请先选中一个虚拟标注。")
		return false
	var annotation_id := _selected_annotation_id
	if not _manager.delete_annotation(annotation_id):
		return false
	# A Ground VR Client keeps the selection until the Server confirms the
	# deletion and the authoritative remove event arrives. This also preserves
	# the selection when a request is rejected.
	if multiplayer.is_server():
		_selected_annotation_id = -1
	_set_status(
		"已删除虚拟标注 %d。" % annotation_id
		if multiplayer.is_server()
		else "已提交标注删除请求。"
	)
	return true


func delete_last_annotation() -> bool:
	if _last_annotation_id <= 0 or _manager.get_annotation(_last_annotation_id).is_empty():
		_recalculate_last_annotation_id()
	if _last_annotation_id <= 0:
		_set_status("当前没有可删除的虚拟标注。")
		return false
	_selected_annotation_id = _last_annotation_id
	return delete_selected_annotation()


func request_clear_all() -> bool:
	var now := Time.get_ticks_msec()
	if now > _clear_confirmation_deadline_ms:
		_clear_confirmation_deadline_ms = now + 3000
		_set_status("3 秒内再次清除可删除全部虚拟标注。")
		_update_panel()
		return false
	_clear_confirmation_deadline_ms = 0
	if not _manager.clear_annotations():
		return false
	# Clients wait for the reliable authoritative clear event. Optimistically
	# clearing these ids would hide useful state if the Server rejects a request.
	if multiplayer.is_server():
		_selected_annotation_id = -1
		_last_annotation_id = -1
	_set_status(
		"已清除全部虚拟标注。"
		if multiplayer.is_server()
		else "已提交全部清除请求。"
	)
	return true


func begin_dictation() -> bool:
	if _dictation_active:
		return true
	if _draft.is_empty() and _selected_annotation_id <= 0:
		_set_status("请先放置草稿点或选中现有标注。")
		return false
	if _voice_chat == null or not _voice_chat.has_method("get_dictation_readiness"):
		_set_status("语音听写不可用，可保留编号说明后确认。")
		return false
	var readiness = _voice_chat.call("get_dictation_readiness")
	if readiness is Dictionary and not bool((readiness as Dictionary).get("available", (readiness as Dictionary).get("ready", false))):
		var reason := str((readiness as Dictionary).get("message", (readiness as Dictionary).get("reason", "语音听写未就绪")))
		_set_status("%s，可保留编号说明后确认。" % reason)
		return false

	_dictation_session_id = "virtual-annotation-%d" % Time.get_ticks_msec()
	var started := bool(_voice_chat.call("begin_local_dictation", _dictation_session_id, "annotation"))
	if not started:
		_dictation_session_id = ""
		_set_status("语音听写启动失败，可保留编号说明后确认。")
		return false
	_dictation_active = true
	_set_status("正在听写，松开录音键后生成说明。")
	_update_panel()
	return true


func finish_dictation() -> bool:
	if not _dictation_active or _voice_chat == null:
		return false
	var accepted := bool(_voice_chat.call("finish_local_dictation", _dictation_session_id))
	if accepted:
		_set_status("正在等待最终转写结果…")
	else:
		_dictation_active = false
		_set_status("听写结束失败，已保留当前说明。")
	_update_panel()
	return accepted


func _handle_pointing_hit(hit: Dictionary) -> void:
	if hit.is_empty():
		_set_status("射线未命中可标注的虚拟模型。")
		return
	var annotation_id: int = int(_manager.find_annotation_id_from_collider(hit.get("collider")))
	if annotation_id > 0:
		_select_annotation(annotation_id)
		return
	var draft: Dictionary = _manager.make_draft_from_hit(
		hit.get("position", Vector3.ZERO),
		hit.get("normal", Vector3.UP),
		hit.get("collider")
	)
	if draft.is_empty():
		_set_status("命中点数据无效。")
		return
	_set_draft(draft)


func _set_draft(draft: Dictionary) -> void:
	_cancel_dictation()
	_draft = draft.duplicate(true)
	_selected_annotation_id = -1
	if str(_draft.get("text", "")).strip_edges() == "":
		_draft["text"] = _manager.get_next_default_text()
	_local_text_buffer = str(_draft.get("text", ""))
	if DisplayServer.get_name() != "headless" \
			and (_draft_preview == null or not is_instance_valid(_draft_preview)):
		_draft_preview = MARKER_SCENE.instantiate() as Node3D
		_draft_preview.name = "LocalVirtualAnnotationDraft"
		add_child(_draft_preview)
	if _draft_preview != null:
		_draft_preview.call("configure", _draft, _manager.get_shared_space_origin(), true, _manager.get_target_root())
	if _note_edit != null:
		_note_edit.text = str(_draft.get("text", ""))
	draft_changed.emit(_draft.duplicate(true))
	_set_status("草稿点已锁定。按住录音键添加说明，确认后同步。")
	_update_panel()


func _clear_draft() -> void:
	_draft.clear()
	if _draft_preview != null and is_instance_valid(_draft_preview):
		_draft_preview.queue_free()
	_draft_preview = null
	if _note_edit != null and _selected_annotation_id <= 0:
		_note_edit.text = ""
	if _selected_annotation_id <= 0:
		_local_text_buffer = ""
	draft_changed.emit({})
	_update_panel()


func _select_annotation(annotation_id: int) -> void:
	if not _manager.select_annotation(annotation_id):
		return
	_clear_draft()
	_selected_annotation_id = annotation_id
	var annotation: Dictionary = _manager.get_annotation(annotation_id)
	_local_text_buffer = str(annotation.get("text", ""))
	if _note_edit != null:
		_note_edit.text = str(annotation.get("text", ""))
	_set_status("已选中虚拟标注 %d。" % annotation_id)
	_update_panel()


func _raycast(world: World3D, ray_origin: Vector3, ray_end: Vector3) -> Dictionary:
	if world == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collision_mask = ANNOTATION_SURFACE_LAYER | MARKER_COLLISION_LAYER
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return world.direct_space_state.intersect_ray(query)


func _update_xr_controller() -> void:
	if _right_controller != null and is_instance_valid(_right_controller):
		_find_function_pointer()
		return
	if not right_controller_path.is_empty():
		_right_controller = get_node_or_null(right_controller_path) as XRController3D
	if _right_controller == null:
		var scene := get_tree().current_scene
		if scene != null:
			var peer_id := multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else SERVER_PEER_ID
			_right_controller = scene.get_node_or_null(
				NodePath("%d/XROrigin3D/RightHand" % peer_id)
			) as XRController3D
	if _right_controller != null:
		_create_xr_visuals()
		_find_pickup_node()
		_find_function_pointer()
		_set_pickup_suppressed(_annotation_mode)


func _poll_xr_input() -> void:
	if _right_controller == null or not is_instance_valid(_right_controller) or not _right_controller.get_is_active():
		return
	var right_tracker := XRServer.get_tracker(&"right_hand")
	var left_tracker := XRServer.get_tracker(&"left_hand")
	var trigger_pressed := _tracker_input_pressed(right_tracker, &"trigger")
	var grip_pressed := _tracker_input_pressed(right_tracker, &"grip")
	var secondary_pressed := _tracker_input_pressed(right_tracker, &"by_button")
	var primary_pressed := _tracker_input_pressed(right_tracker, &"ax_button")
	var left_primary_pressed := _tracker_input_pressed(left_tracker, &"ax_button")
	var left_secondary_pressed := _tracker_input_pressed(left_tracker, &"by_button")

	if secondary_pressed and not _last_secondary_pressed:
		toggle_annotation_mode()
	if _annotation_mode:
		_update_vr_ray()
		if trigger_pressed and not _last_trigger_pressed:
			if not _is_pointer_interaction_active(_current_vr_hit):
				_handle_pointing_hit(_current_vr_hit)
		if grip_pressed and not _last_grip_pressed:
			begin_dictation()
		elif not grip_pressed and _last_grip_pressed:
			finish_dictation()
		if primary_pressed and not _last_primary_pressed:
			confirm_draft_or_update()
		if left_primary_pressed and not _last_left_primary_pressed:
			delete_selected_annotation()
		if left_secondary_pressed and not _last_left_secondary_pressed:
			request_clear_all()

	_last_trigger_pressed = trigger_pressed
	_last_grip_pressed = grip_pressed
	_last_secondary_pressed = secondary_pressed
	_last_primary_pressed = primary_pressed
	_last_left_primary_pressed = left_primary_pressed
	_last_left_secondary_pressed = left_secondary_pressed


func _tracker_input_pressed(tracker: XRPositionalTracker, input_name: StringName) -> bool:
	if tracker == null:
		return false
	var value = tracker.get_input(input_name)
	if value is bool:
		return value
	if value is float or value is int:
		return float(value) >= XR_PRESS_THRESHOLD
	return false


func _update_vr_ray() -> void:
	if _right_controller == null:
		return
	var ray_origin := _right_controller.global_position
	var ray_end := ray_origin - _right_controller.global_transform.basis.z * RAY_LENGTH
	_current_vr_hit = _raycast(_right_controller.get_world_3d(), ray_origin, ray_end)
	var visible_end := _current_vr_hit.get("position", ray_end) as Vector3
	_update_ray_mesh(ray_origin, visible_end)
	if _hover_preview != null:
		_hover_preview.visible = not _current_vr_hit.is_empty()
		if _hover_preview.visible:
			_hover_preview.global_position = visible_end


func _create_xr_visuals() -> void:
	if _right_controller == null:
		return
	if _wrist_label == null:
		_wrist_label = Label3D.new()
		_wrist_label.name = "VirtualAnnotationWristStatus"
		_wrist_label.position = Vector3(0.08, 0.06, 0.02)
		_wrist_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_wrist_label.no_depth_test = true
		_wrist_label.font_size = 24
		_wrist_label.outline_size = 6
		_wrist_label.visible = false
		_right_controller.add_child(_wrist_label)
	if _vr_ray == null:
		_vr_ray = MeshInstance3D.new()
		_vr_ray.name = "VirtualAnnotationRay"
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.002
		cylinder.bottom_radius = 0.002
		cylinder.height = 1.0
		_vr_ray.mesh = cylinder
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(1.0, 0.35, 0.06, 0.85)
		material.emission_enabled = true
		material.emission = material.albedo_color
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_vr_ray.material_override = material
		_vr_ray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_vr_ray.visible = false
		add_child(_vr_ray)
	if _hover_preview == null:
		_hover_preview = MeshInstance3D.new()
		_hover_preview.name = "VirtualAnnotationHitPreview"
		var sphere := SphereMesh.new()
		sphere.radius = 0.012
		sphere.height = 0.024
		_hover_preview.mesh = sphere
		_hover_preview.material_override = _vr_ray.material_override
		_hover_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_hover_preview.visible = false
		add_child(_hover_preview)
	_set_vr_visuals_visible(_annotation_mode)


func _update_ray_mesh(ray_origin: Vector3, ray_end: Vector3) -> void:
	if _vr_ray == null:
		return
	var direction := ray_end - ray_origin
	var length := direction.length()
	if length < 0.001:
		_vr_ray.visible = false
		return
	var cylinder := _vr_ray.mesh as CylinderMesh
	cylinder.height = length
	_vr_ray.global_transform = Transform3D(
		_basis_from_up(direction.normalized()),
		ray_origin + direction * 0.5
	)
	_vr_ray.visible = _annotation_mode


func _basis_from_up(up: Vector3) -> Basis:
	var tangent := Vector3.FORWARD.cross(up)
	if tangent.length_squared() < 0.000001:
		tangent = Vector3.RIGHT.cross(up)
	tangent = tangent.normalized()
	var forward := tangent.cross(up).normalized()
	return Basis(tangent, up, forward).orthonormalized()


func _set_vr_visuals_visible(visible: bool) -> void:
	if _vr_ray != null:
		_vr_ray.visible = visible
	if _hover_preview != null:
		_hover_preview.visible = visible and not _current_vr_hit.is_empty()
	_refresh_wrist_visibility()
	_update_wrist_label()


func _refresh_wrist_visibility() -> void:
	if _wrist_label != null:
		_wrist_label.visible = _annotation_mode \
			or (_can_local_annotate() and not _surfaces_ready())


func _find_pickup_node() -> void:
	if _right_controller == null or _pickup_node != null:
		return
	for candidate in _right_controller.find_children("*", "Node", true, false):
		if candidate.has_method("is_xr_class") and bool(candidate.call("is_xr_class", "XRToolsFunctionPickup")):
			_pickup_node = candidate
			_pickup_previous_enabled = bool(candidate.get("enabled"))
			return


func _find_function_pointer() -> void:
	if _right_controller == null or (_function_pointer != null and is_instance_valid(_function_pointer)):
		return
	_function_pointer = _right_controller.get_node_or_null("FunctionPointer")


func _is_pointer_interaction_active(annotation_hit: Dictionary = {}) -> bool:
	if _function_pointer == null or not is_instance_valid(_function_pointer):
		return false
	var pointer_ray := _function_pointer.get_node_or_null("RayCast") as RayCast3D
	var locked_target = _function_pointer.get("target")
	var hover_target = _function_pointer.get("last_target")
	var has_pointer_target := (locked_target is Node and is_instance_valid(locked_target)) \
		or (hover_target is Node and is_instance_valid(hover_target))
	var has_pointer_collision := pointer_ray != null and pointer_ray.is_colliding()
	if not has_pointer_target and not has_pointer_collision:
		return false
	if annotation_hit.is_empty() or not has_pointer_collision:
		return true

	var annotation_position = annotation_hit.get("position")
	if not (annotation_position is Vector3):
		return true
	var ray_origin := _right_controller.global_position \
		if _right_controller != null and is_instance_valid(_right_controller) \
		else pointer_ray.global_position
	var pointer_distance := ray_origin.distance_to(pointer_ray.get_collision_point())
	var annotation_distance := ray_origin.distance_to(annotation_position as Vector3)
	return should_pointer_take_priority(pointer_distance, annotation_distance)


static func should_pointer_take_priority(pointer_distance: float, annotation_distance: float) -> bool:
	return pointer_distance <= annotation_distance + 0.005


func _set_pickup_suppressed(suppressed: bool) -> void:
	if _pickup_node == null or not is_instance_valid(_pickup_node):
		return
	if suppressed:
		_pickup_previous_enabled = bool(_pickup_node.get("enabled"))
		_pickup_node.set("enabled", false)
	else:
		_pickup_node.set("enabled", _pickup_previous_enabled)


func _bind_control_panel_section() -> void:
	_panel = get_tree().get_first_node_in_group("virtual_annotation_panel") as Control
	_control_panel = get_tree().get_first_node_in_group("unified_control_panel")
	if _panel == null:
		push_warning("ControlPanelUI does not provide a virtual annotation section.")
		return

	_mode_button = _panel.get_node_or_null("Layout/ModeButton") as Button
	_status_label = _panel.get_node_or_null("Layout/StatusLabel") as Label
	_count_label = _panel.get_node_or_null("Layout/CountLabel") as Label
	_note_edit = _panel.get_node_or_null("Layout/NoteEdit") as LineEdit
	_record_button = _panel.get_node_or_null("Layout/PrimaryRow/RecordButton") as Button
	_confirm_button = _panel.get_node_or_null("Layout/PrimaryRow/ConfirmButton") as Button
	var cancel_button := _panel.get_node_or_null("Layout/PrimaryRow/CancelButton") as Button
	_delete_button = _panel.get_node_or_null("Layout/ManageRow/DeleteButton") as Button
	var delete_last_button := _panel.get_node_or_null("Layout/ManageRow/DeleteLastButton") as Button
	_clear_button = _panel.get_node_or_null("Layout/ManageRow/ClearButton") as Button

	if _mode_button == null \
			or _status_label == null \
			or _count_label == null \
			or _note_edit == null \
			or _record_button == null \
			or _confirm_button == null \
			or cancel_button == null \
			or _delete_button == null \
			or delete_last_button == null \
			or _clear_button == null:
		push_error("ControlPanelUI virtual annotation section is incomplete.")
		_mode_button = null
		return

	_note_edit.max_length = MAX_TEXT_LENGTH
	_mode_button.pressed.connect(toggle_annotation_mode)
	_note_edit.text_changed.connect(_on_note_text_changed)
	_record_button.button_down.connect(begin_dictation)
	_record_button.button_up.connect(finish_dictation)
	_confirm_button.pressed.connect(confirm_draft_or_update)
	cancel_button.pressed.connect(cancel_draft)
	_delete_button.pressed.connect(delete_selected_annotation)
	delete_last_button.pressed.connect(delete_last_annotation)
	_clear_button.pressed.connect(request_clear_all)


func _open_control_panel_section() -> void:
	if _control_panel != null and _control_panel.has_method("open_annotation_panel"):
		_control_panel.call("open_annotation_panel")


func _connect_manager_signals() -> void:
	_manager.annotation_added.connect(_on_annotation_added)
	_manager.annotation_updated.connect(_on_annotation_updated)
	_manager.annotation_removed.connect(_on_annotation_removed)
	_manager.annotations_cleared.connect(_on_annotations_cleared)
	_manager.snapshot_applied.connect(_on_snapshot_applied)
	_manager.operation_rejected.connect(_set_status)
	if _manager.has_signal("operation_completed"):
		_manager.operation_completed.connect(_on_operation_completed)
	if _manager.has_signal("operation_submitted"):
		_manager.operation_submitted.connect(_on_operation_submitted)
	if _manager.has_signal("operation_failed"):
		_manager.operation_failed.connect(_on_operation_failed)


func _connect_builder_signals() -> void:
	if _surface_builder == null:
		return
	_surface_builder.build_started.connect(func(total: int) -> void:
		_set_status("正在准备 %d 个可标注表面…" % total)
		_update_panel()
	)
	_surface_builder.build_progress.connect(func(completed: int, total: int) -> void:
		if completed == total or completed % 10 == 0:
			_set_status("正在准备可标注表面：%d/%d" % [completed, total])
	)
	_surface_builder.build_completed.connect(func(report: Dictionary) -> void:
		_set_status("可标注表面已就绪，共 %d 个碰撞代理。" % (
			int(report.get("trimesh_proxies", 0)) \
			+ int(report.get("convex_proxies", 0)) \
			+ int(report.get("box_proxies", 0)) \
			+ int(report.get("existing_static_bodies", 0))
		))
		_update_panel()
	)


func _connect_dictation_signals() -> void:
	if _voice_chat == null:
		return
	if _voice_chat.has_signal("dictation_state_changed"):
		_voice_chat.connect("dictation_state_changed", _on_dictation_state_changed)
	if _voice_chat.has_signal("dictation_partial_received"):
		_voice_chat.connect("dictation_partial_received", _on_dictation_partial_received)
	if _voice_chat.has_signal("dictation_final_received"):
		_voice_chat.connect("dictation_final_received", _on_dictation_final_received)
	if _voice_chat.has_signal("dictation_failed"):
		_voice_chat.connect("dictation_failed", _on_dictation_failed)


func _on_dictation_state_changed(session_id: String, state: String, detail: String) -> void:
	if session_id != _dictation_session_id:
		return
	_set_status(detail if detail != "" else "听写状态：%s" % state)
	if state in ["completed", "failed", "cancelled", "idle"]:
		_dictation_active = false
		_dictation_session_id = ""
	_update_panel()


func _on_dictation_partial_received(session_id: String, text: String) -> void:
	if session_id != _dictation_session_id or text.strip_edges() == "":
		return
	set_draft_text(text)
	_set_status("听写中：%s" % text.left(40))


func _on_dictation_final_received(session_id: String, text: String) -> void:
	if session_id != _dictation_session_id:
		return
	if text.strip_edges() != "":
		set_draft_text(text)
	_dictation_active = false
	_dictation_session_id = ""
	_set_status("转写完成，请确认后发布。")
	_update_panel()


func _on_dictation_failed(session_id: String, _code: int, message: String) -> void:
	if session_id != _dictation_session_id:
		return
	_dictation_active = false
	_dictation_session_id = ""
	_set_status("%s，已保留当前编号或说明。" % message)
	_update_panel()


func _cancel_dictation() -> void:
	if not _dictation_active:
		return
	if _voice_chat != null and _voice_chat.has_method("cancel_local_dictation"):
		_voice_chat.call("cancel_local_dictation", _dictation_session_id)
	_dictation_active = false
	_dictation_session_id = ""


func _on_note_text_changed(text: String) -> void:
	_local_text_buffer = text
	if not _draft.is_empty():
		_draft["text"] = text
		draft_changed.emit(_draft.duplicate(true))
	_update_wrist_label()


func _on_annotation_added(annotation: Dictionary) -> void:
	_last_annotation_id = maxi(_last_annotation_id, int(annotation.get("id", -1)))
	if int(annotation.get("creator_peer_id", -1)) == _get_local_peer_id():
		_selected_annotation_id = int(annotation.get("id", -1))
		_local_text_buffer = str(annotation.get("text", ""))
	_update_panel()


func _on_operation_submitted(operation: String, request_sequence: int) -> void:
	if operation == "create" and not _draft.is_empty():
		_pending_create_drafts[request_sequence] = _draft.duplicate(true)


func _on_operation_completed(operation: String, request_sequence: int, annotation_id: int) -> void:
	if operation == "create":
		_pending_create_drafts.erase(request_sequence)
	match operation:
		"create":
			_last_annotation_id = maxi(_last_annotation_id, annotation_id)
			_selected_annotation_id = annotation_id
			_set_status("已发布虚拟标注 %d。" % annotation_id)
		"update":
			_set_status("已更新虚拟标注 %d。" % annotation_id)
		"delete":
			_set_status("已删除虚拟标注 %d。" % annotation_id)
		"clear":
			_set_status("已清除全部虚拟标注。")
	_update_panel()


func _on_operation_failed(operation: String, request_sequence: int, message: String) -> void:
	if operation != "create" or not _pending_create_drafts.has(request_sequence):
		return
	var retained_draft: Dictionary = (_pending_create_drafts[request_sequence] as Dictionary).duplicate(true)
	_pending_create_drafts.erase(request_sequence)
	if _draft.is_empty():
		_set_draft(retained_draft)
	_set_status("%s 本地草稿已保留，可修改后重试。" % message)


func _on_annotation_updated(annotation: Dictionary) -> void:
	if int(annotation.get("id", -1)) == _selected_annotation_id and _note_edit != null and _draft.is_empty():
		_note_edit.text = str(annotation.get("text", ""))
	if int(annotation.get("id", -1)) == _selected_annotation_id and _draft.is_empty():
		_local_text_buffer = str(annotation.get("text", ""))
	_update_panel()


func _on_annotation_removed(annotation_id: int) -> void:
	if annotation_id == _selected_annotation_id:
		_selected_annotation_id = -1
		_local_text_buffer = ""
	if annotation_id == _last_annotation_id:
		_recalculate_last_annotation_id()
	_update_panel()


func _on_annotations_cleared() -> void:
	_selected_annotation_id = -1
	_last_annotation_id = -1
	_local_text_buffer = ""
	_update_panel()


func _on_snapshot_applied(_revision: int, _count: int) -> void:
	_recalculate_last_annotation_id()
	_update_panel()


func _recalculate_last_annotation_id() -> void:
	_last_annotation_id = -1
	for annotation in _manager.get_annotations():
		_last_annotation_id = maxi(_last_annotation_id, int((annotation as Dictionary).get("id", -1)))


func _refresh_authority_visibility() -> void:
	if not _can_local_annotate() and _annotation_mode:
		set_annotation_mode(false)


func _surfaces_ready() -> bool:
	return _surface_builder == null or _surface_builder.is_ready_for_annotations()


func _can_local_annotate() -> bool:
	return _manager != null \
		and _manager.has_method("can_local_annotate") \
		and bool(_manager.call("can_local_annotate"))


func _get_local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return SERVER_PEER_ID
	return multiplayer.get_unique_id()


func _set_status(message: String) -> void:
	_status_message = message
	if _status_label != null:
		_status_label.text = message
	status_changed.emit(message)
	_refresh_wrist_visibility()
	_update_wrist_label()


func _update_panel() -> void:
	if _mode_button == null:
		return
	_mode_button.text = "关闭标注模式 (P)" if _annotation_mode else "开启标注模式 (P)"
	_mode_button.disabled = not _can_local_annotate() or (not _surfaces_ready() and not _annotation_mode)
	_count_label.text = "会话标注：%d/%d　选中：%s" % [
		_manager.get_annotation_count(),
		MAX_ANNOTATIONS,
		str(_selected_annotation_id) if _selected_annotation_id > 0 else "无",
	]
	_record_button.text = "录音中…" if _dictation_active else "按住录音"
	_record_button.disabled = _draft.is_empty() and _selected_annotation_id <= 0
	_confirm_button.disabled = _draft.is_empty() and _selected_annotation_id <= 0
	_delete_button.disabled = _selected_annotation_id <= 0
	_clear_button.text = "再次点击确认清除" if Time.get_ticks_msec() <= _clear_confirmation_deadline_ms else "清除全部"
	_update_wrist_label()


func _update_wrist_label() -> void:
	if _wrist_label == null:
		return
	var state := "射线取点"
	if not _surfaces_ready():
		state = _status_message if not _status_message.is_empty() else "正在准备可标注表面"
	elif _dictation_active:
		state = "正在听写"
	elif not _draft.is_empty():
		state = "草稿：%s" % str(_draft.get("text", "")).left(24)
	elif _selected_annotation_id > 0:
		state = "选中标注 %d：%s" % [_selected_annotation_id, _local_text_buffer.left(18)]
	_wrist_label.text = "%s\n扳机取点  握把听写  A确认\nX删除  Y清除  B退出" % state


func _update_clear_confirmation() -> void:
	if _clear_confirmation_deadline_ms > 0 and Time.get_ticks_msec() > _clear_confirmation_deadline_ms:
		_clear_confirmation_deadline_ms = 0
		_update_panel()
