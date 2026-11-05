extends Node3D

## Sky-owned calibration. Camera frames, head pose, solve and origin changes
## stay in this process; no calibration RPC, replicated pose or server ACK.
const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
const CabinetUI := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_calibration_window.gd")
const VisualUI := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_panel.gd")
const VisualGeometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_geometry.gd")
const CabinetScene := preload("res://Assets/ARSpace/Prefabs/CalibrationCabinet.tscn")
const FrameReceiver := preload("res://Assets/ARSpace/Scripts/RealtimeReconstruction/Capture/pico_frame_receiver.gd")
const VIEWPORT_SCENE_PATH := "res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn"
const LOCAL_VIEWPORT_PATH := "res://Assets/ARSpace/Scripts/SpatialWindows/spatial_viewport_2d_in_3d.gd"
const PanelWindow := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_panel_window.gd")
const PanelWindowZoom := preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
const LocalViewportBody := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_panel_surface.gd")
const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const HELPER_PORT := 8789

@export var cabinet_path := NodePath("../SharedSpaceOrigin/CalibrationCabinet")
@export var local_xr_origin_path := NodePath("")
@export_range(1, 65535) var helper_port: int = HELPER_PORT
@export var auto_start_receiver := true
# Kept for existing four-corner regression fixtures; the product entry uses CAD.
var use_legacy_panel := false
@export var visual_target_path := NodePath("../SpaceBox/SpaceBox/dashiyangui")

signal state_changed(state: Dictionary)

var state: Dictionary = {"status": "empty", "revision": 0}
var latest_frame: Dictionary = {}
var capture_epoch: int = 0
var _receiver: Node
var _panel: Node3D
var _window: Node
var _ui: Control
var _model: Node3D
var _cabinet: Node3D
var _local_origin: XROrigin3D
var _default_cabinet_pose: Transform3D
var _default_cabinet_dimensions: Vector3
var _head_history: Array[Dictionary] = []
var _last_pose_usec: int = 0
var _last_pose: Transform3D
var _clock_offset_usec: int = 0
var _clock_valid: bool = false
var _last_timestamp_ns: int = 0
var _alignment_settle_until_usec: int = 0
var _applied_alignment_revision: int = -1
var _visual_points := PackedVector3Array()
var _custom_visual := false
var _custom_dimensions := Vector3(0.45, 1.21, 0.80)
var _cad_visibility_before_custom := true


func is_local_calibrator() -> bool:
	var profile = RuntimeProfile.current()
	return profile.is_valid() and profile.is_sky() and (profile.uses_xr() or profile.is_test_mode())


func _ready() -> void:
	if not is_local_calibrator():
		set_process(false)
		return
	add_to_group("cabinet_calibration")
	_cabinet = get_node_or_null(cabinet_path) as Node3D
	if _cabinet == null:
		_cabinet = CabinetScene.instantiate() as Node3D
		add_child(_cabinet)
	_default_cabinet_pose = _cabinet.global_transform
	_default_cabinet_dimensions = _cabinet.get("dimensions")
	_model = Node3D.new()
	_model.name = "CabinetModel"
	add_child(_model)
	_receiver = FrameReceiver.new()
	_receiver.name = "LocalPicoReceiver"
	_receiver.set("server_only", false)
	_receiver.set("register_shared_receiver", false)
	_receiver.set("listen_port", helper_port)
	_receiver.set("auto_start", auto_start_receiver)
	_receiver.connect("frame_received", _on_frame)
	_receiver.connect("connection_changed", _on_capture_connection)
	add_child(_receiver)
	_render_state()
	call_deferred("_bind_services")


func _bind_services() -> void:
	var alignment := get_tree().get_first_node_in_group("shared_space_alignment")
	if alignment != null and not alignment.is_connected("alignment_succeeded", _on_recentered):
		alignment.connect("alignment_succeeded", _on_recentered)
	var xr := XRServer.find_interface("OpenXR")
	if xr != null and xr.has_signal("pose_recentered") and not xr.is_connected("pose_recentered", _on_runtime_recentered):
		xr.connect("pose_recentered", _on_runtime_recentered)


func open_panel(parent_panel: Node = null) -> void:
	if not is_local_calibrator():
		return
	var created := not is_instance_valid(_panel)
	if created:
		# The XR Tools scene references autoloads; load after those are ready,
		# including when this controller is exercised by a SceneTree self-test.
		_panel = (load(VIEWPORT_SCENE_PATH) as PackedScene).instantiate() as Node3D
		_panel.set_script(load(LOCAL_VIEWPORT_PATH))
		_panel.get_node("StaticBody3D").set_script(LocalViewportBody)
		_panel.name = "CabinetCalibrationPanel"
		_panel.visibility_changed.connect(_on_panel_visibility_changed)
		_panel.add_to_group("sky_always_visible_ui")
		_panel.set("viewport_size", Vector2(1280, 900))
		_panel.set("screen_size", Vector2(1.28, 0.9))
		_panel.set("unshaded", true)
		_panel.set("allow_window_drag", false)
		_panel.set("input_keyboard", false)
		_ui = CabinetUI.new() if use_legacy_panel else VisualUI.new()
		_ui.set("controller", self)
		_ui.size = Vector2(1280, 900)
		_panel.get_node("Viewport").add_child(_ui)
		_window = PanelWindow.new()
		_window.name = "SpatialWindowController"
		_window.set("calibration", self)
		_window.set("scope", PanelWindow.WindowScope.LOCAL_GROUND_VR)
		_window.set("window_id", &"cabinet_calibration")
		_window.set("window_category", &"local_calibration")
		_window.set("window_size_m", Vector2(1.28, 0.9))
		_window.set("event_source_path", NodePath(".."))
		_window.set("visibility_target_path", NodePath(".."))
		_panel.add_child(_window)
		add_child(_panel)
	_ui.show()
	# Reopening a closed panel preserves where the user dragged it.
	var parent_window := PanelWindowZoom._get_spatial_window_controller(parent_panel)
	_window.call("open_window", parent_window, created)
	_render_state()


func close_panel() -> void:
	if is_instance_valid(_ui) and _ui.has_method("suspend"):
		_ui.call("suspend")
	if is_instance_valid(_window):
		_window.call("close_window")
	_on_panel_visibility_changed()


func _on_panel_visibility_changed() -> void:
	# The overlay is a calibration aid, not part of the aligned scene content.
	# Also handle window-manager closure or an ancestor being hidden.
	if is_instance_valid(_model):
		_render_state()


func _show_calibration_overlay() -> bool:
	return is_instance_valid(_panel) and _panel.is_visible_in_tree() \
		and state.get("status") in ["preview", "confirmed"]


func toggle_panel_zoom() -> void:
	if is_instance_valid(_window):
		_window.call("toggle_zoom")


func _position_panel() -> void:
	# Recenter/whole-world alignment may move the UI out of reach. Relocate it
	# beside the main menu when visible, using the same placement as other tools.
	if not is_instance_valid(_window) or not _panel.visible:
		return
	var global_node := get_node_or_null("/root/Global")
	var main_menu: Node = global_node.get("main_menu_canvas") if global_node != null else null
	var parent_window := PanelWindowZoom._get_spatial_window_controller(main_menu)
	var head := get_head_sample()
	if parent_window != null and not head.is_empty():
		var pose: Transform3D = head.transform
		var parent_pose: Transform3D = parent_window.call("get_window_global_transform")
		var offset := parent_pose.origin - pose.origin
		if offset.length() > 3.0 or offset.dot(-pose.basis.z) < 0.0:
			parent_window = null
	_window.call("open_window", parent_window, true)


func get_capture_status() -> String:
	if _receiver == null:
		return "本地接收器未就绪"
	var info: Dictionary = _receiver.call("get_status_snapshot")
	if not bool(info.listening):
		return "相机接收失败：" + str(info.status)
	if bool(info.connected):
		return "PICO 已直连天上端 · %.1f FPS" % float(info.fps)
	var addresses: Array = _receiver.call("get_local_addresses")
	return "Helper 接收目标设为天上端电脑，端口 %d：%s" % [helper_port, " / ".join(addresses)]


func _process(_delta: float) -> void:
	var sample := get_head_sample()
	var now := Time.get_ticks_usec()
	if now < _alignment_settle_until_usec:
		_head_history.clear()
		_last_pose_usec = 0
		return
	if sample.is_empty():
		_head_history.clear()
		if _last_pose_usec > 0 and now - _last_pose_usec > 2_000_000:
			invalidate("本地头部跟踪丢失，请重新标定。")
			_last_pose_usec = 0
		return
	var pose: Transform3D = sample.transform
	if now - _last_pose_usec < 20_000:
		return
	if _last_pose_usec > 0 and _last_pose.origin.distance_to(pose.origin) > 0.6 and now - _last_pose_usec < 250_000:
		invalidate("头显跟踪原点发生变化，请重新标定。")
	_last_pose = pose
	_last_pose_usec = now
	_head_history.append({"time_usec": now, "transform": pose})
	while _head_history.size() > 180 or (not _head_history.is_empty() and now - int(_head_history[0].time_usec) > 1_500_000):
		_head_history.pop_front()


## Reads the LOCAL tracked XRCamera, without NetworkHead interpolation or ENet.
func get_head_sample() -> Dictionary:
	var origin := _get_local_xr_origin()
	if origin == null or not _has_head_tracking():
		return {}
	var camera := origin.get_node_or_null("XRCamera3D") as XRCamera3D
	if camera == null:
		return {}
	return {"transform": camera.global_transform}


func _has_head_tracking() -> bool:
	var tracker := XRServer.get_tracker("head")
	if tracker == null:
		return false
	var pose = tracker.get_pose("default")
	return pose != null and pose.has_tracking_data and pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_HIGH


func _get_local_xr_origin() -> XROrigin3D:
	if not local_xr_origin_path.is_empty():
		return get_node_or_null(local_xr_origin_path) as XROrigin3D
	# Cache this local node, so losing the multiplayer connection cannot switch
	# calibration to a remote player's pose or to the desktop spectator camera.
	if is_instance_valid(_local_origin):
		return _local_origin
	var scene := get_tree().current_scene
	if scene != null:
		_local_origin = scene.get_node_or_null("%d/XROrigin3D" % multiplayer.get_unique_id()) as XROrigin3D
	return _local_origin


func _on_frame(frame_id: int, timestamp_ns: int, width: int, height: int,
		metadata: Dictionary, jpeg: PackedByteArray) -> void:
	var now := Time.get_ticks_usec()
	if timestamp_ns <= 0:
		return
	if timestamp_ns <= _last_timestamp_ns:
		_on_capture_connection(false)
	_last_timestamp_ns = timestamp_ns
	var offset := now - int(timestamp_ns / 1000)
	if not _clock_valid or offset < _clock_offset_usec:
		_clock_offset_usec = offset
		_clock_valid = true
	latest_frame = {"frame_id": frame_id, "timestamp_ns": str(timestamp_ns),
		"receive_usec": now, "estimated_capture_usec": int(timestamp_ns / 1000) + _clock_offset_usec,
		"size": Vector2i(width, height), "metadata": metadata.duplicate(true), "jpeg": jpeg}


func _on_capture_connection(_connected: bool) -> void:
	latest_frame.clear()
	_clock_valid = false
	_last_timestamp_ns = 0
	capture_epoch += 1
	# A disconnected feed cannot authorize a pending CAD application. A completed
	# alignment is retained, just as in the existing calibration lifecycle.
	if state.get("method") in ["cad", "cuboid_auto"] and state.get("status") == "preview":
		_set_state({"status": "invalid", "reason": "相机已重新连接，请重新识别柜体。"})


## Low-accuracy deployment uses a stationary capture: keep the head still for
## one second. This avoids pretending the min-arrival clock map is hardware sync.
func freeze_frame() -> Dictionary:
	var now := Time.get_ticks_usec()
	if now < _alignment_settle_until_usec:
		return {"error": "正在应用整体空间标定，请稍后再取景。"}
	if latest_frame.is_empty() or now - int(latest_frame.receive_usec) > 500_000 \
			or now - int(latest_frame.estimated_capture_usec) > 500_000:
		return {"error": "没有新鲜的 PICO 画面，请检查 Helper 连接。"}
	var head := get_head_sample()
	if head.is_empty() or _head_history.size() < 2:
		return {"error": "本地头部跟踪尚未就绪，请戴好头显并等待定位。"}
	if now - int(_head_history[0].time_usec) < 1_000_000:
		return {"error": "请看向柜体并保持头部静止约 1 秒，再冻结画面。"}
	var current: Transform3D = head.transform
	for sample in _head_history:
		var previous: Transform3D = sample.transform
		if previous.origin.distance_to(current.origin) > 0.025 \
				or previous.basis.get_rotation_quaternion().angle_to(current.basis.get_rotation_quaternion()) > deg_to_rad(2.0):
			return {"error": "头部仍在移动，请停稳约 1.5 秒后再冻结。"}
	var result := latest_frame.duplicate(true)
	result["head_world"] = current
	result["epoch"] = capture_epoch
	result["offline"] = false
	return result


## Moving-view capture uses the image's mapped timestamp and interpolated local
## tracking, never the latest pose substituted for an older camera image.
## The arrival clock map still contains unknown fixed transport latency; this
## remains an experimental preview until device timing is physically verified.
func capture_moving_frame() -> Dictionary:
	var now := Time.get_ticks_usec()
	if now < _alignment_settle_until_usec:
		return {"error": "跟踪空间正在更新，请稍后重新扫描。"}
	if latest_frame.is_empty() or now - int(latest_frame.receive_usec) > 500_000:
		return {"error": "没有新鲜相机画面，请检查 Helper。"}
	var current := get_head_sample()
	if current.is_empty():
		return {"error": "头部跟踪不可用，当前画面已跳过。"}
	var history := _head_history.duplicate()
	history.append({"time_usec": now, "transform": current.transform})
	var matched := interpolate_capture_pose(history, int(latest_frame.estimated_capture_usec))
	if matched.has("error"):
		return matched
	var frame := latest_frame.duplicate(true)
	# Retain exposure-time alternatives rather than assuming arrival is exposure.
	# The worker selects one common delay using image feature geometry, before
	# any cabinet fit. Samples belong to this same tracking epoch.
	var pose_history: Array[Transform3D] = []
	for delay_ms in range(0, 401, 10):
		var sample := interpolate_capture_pose(history, int(latest_frame.estimated_capture_usec) - delay_ms * 1000)
		if sample.has("error"):
			return {"error": "等待完整的图像对应头姿历史，请缓慢移动。"}
		pose_history.append(sample.transform)
	frame["head_world"] = matched.transform
	frame["head_history"] = pose_history
	frame["epoch"] = capture_epoch
	frame["pose_timing"] = "interpolated_arrival_estimate"
	return frame


static func interpolate_capture_pose(history: Array, capture_usec: int) -> Dictionary:
	for i in range(1, history.size()):
		var before: Dictionary = history[i - 1]
		var after: Dictionary = history[i]
		var start := int(before.time_usec)
		var end := int(after.time_usec)
		if capture_usec < start or capture_usec > end or end <= start:
			continue
		if end - start > 100_000:
			return {"error": "图像对应的跟踪采样有间断，已跳过。"}
		var a: Transform3D = before.transform
		var b: Transform3D = after.transform
		var seconds := (end - start) / 1000000.0
		if a.origin.distance_to(b.origin) / seconds > 0.4 \
				or a.basis.get_rotation_quaternion().angle_to(b.basis.get_rotation_quaternion()) / seconds > deg_to_rad(45):
			return {"error": "移动过快，请缓慢横移并始终看向柜体。"}
		return {"transform": a.interpolate_with(b, float(capture_usec - start) / (end - start))}
	return {"error": "等待与相机时间匹配的头姿；不会使用当前头姿代替旧画面。"}


func show_preview(pose: Transform3D, dimensions: Vector3, offline: bool = false) -> bool:
	if not is_local_calibrator() or not Geometry.valid_dimensions(dimensions) or Geometry.decode_transform(Geometry.encode_transform(pose)) == null:
		return false
	if not offline and get_head_sample().is_empty():
		return false
	_set_state({"status": "preview", "pose": Geometry.encode_transform(pose),
		"dimensions": [dimensions.x, dimensions.y, dimensions.z], "offline": offline})
	return true


func confirm_preview() -> bool:
	if not is_local_calibrator() or str(state.get("status")) != "preview" or bool(state.get("offline", false)):
		return false
	if get_head_sample().is_empty():
		invalidate("本地头部跟踪不可用，不能确认旧标定。")
		return false
	if state.get("method") == "cad":
		return _confirm_visual_preview()
	if state.get("method") == "cuboid_auto" and int(state.get("epoch", -1)) != capture_epoch:
		invalidate("旧识别结果已失效，请重新识别。")
		return false
	var confirmed := state.duplicate(true)
	confirmed["revision"] = int(state.revision) + 1
	var measured: Transform3D = Geometry.decode_transform(state.pose)
	confirmed["world_alignment"] = Geometry.encode_transform(compute_world_alignment(measured, _default_cabinet_pose))
	var error := _apply_world_alignment(confirmed)
	if not error.is_empty():
		invalidate(error)
		return false
	confirmed["status"] = "confirmed"
	_alignment_settle_until_usec = Time.get_ticks_usec() + 200_000
	_head_history.clear()
	_last_pose_usec = 0
	latest_frame.clear()
	capture_epoch += 1
	_set_state(confirmed)
	# Keep controls in reach after rebasing tracking; world geometry stays fixed.
	_position_panel()
	return true


func _visual_target() -> Node3D:
	return get_node_or_null(visual_target_path) as Node3D


func configure_visual_model(kind: String, dimensions: Vector3) -> bool:
	if not is_local_calibrator() or kind not in ["cad", "cuboid"] or not Geometry.valid_dimensions(dimensions):
		return false
	var custom := kind == "cuboid"
	var target := _visual_target()
	if target != null and custom != _custom_visual:
		if custom:
			_cad_visibility_before_custom = target.visible
			target.visible = false
		else:
			target.visible = _cad_visibility_before_custom
	_custom_visual = custom
	_custom_dimensions = dimensions
	clear_cabinet()
	return true


func show_cuboid_visual_preview(pose: Transform3D, dimensions: Vector3, offline: bool, epoch: int) -> bool:
	if not is_local_calibrator() or not _custom_visual or not Geometry.valid_dimensions(dimensions) \
			or not dimensions.is_equal_approx(_custom_dimensions) or not VisualGeometry.is_rigid(pose):
		return false
	if epoch != capture_epoch or (not offline and get_head_sample().is_empty()):
		return false
	_set_state({"status": "preview", "method": "cuboid_auto", "pose": Geometry.encode_transform(pose),
		"dimensions": [dimensions.x, dimensions.y, dimensions.z], "offline": offline, "epoch": epoch})
	return true


func _visual_frame() -> Node3D:
	var target := _visual_target()
	return target.get_node_or_null("dashiyangui/MeshRenderer") as Node3D if target != null else null


func show_visual_preview(pose: Transform3D, physical_scale: float, points: Array,
		offline: bool, epoch: int) -> bool:
	if not is_local_calibrator() or _custom_visual or not VisualGeometry.is_rigid(pose) \
			or not is_finite(physical_scale) or physical_scale < 0.05 or physical_scale > 2.0 \
			or points.is_empty() or points.size() > 4000:
		return false
	var target_frame := _visual_frame()
	if not offline and (epoch != capture_epoch or get_head_sample().is_empty() or target_frame == null):
		return false
	var cloud := PackedVector3Array()
	for item in points:
		if not item is Array or item.size() != 3:
			return false
		for coordinate in item:
			if typeof(coordinate) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(coordinate)):
				return false
		var point := Vector3(item[0], item[1], item[2])
		if point.length() > 20:
			return false
		cloud.append(point)
	_visual_points = cloud
	var target_pose := target_frame.global_transform if target_frame != null else Transform3D.IDENTITY
	var target_basis := target_pose.basis.orthonormalized()
	if target_pose.basis.determinant() <= 0 or not VisualGeometry.is_rigid(Transform3D(target_basis, target_pose.origin)):
		return false
	_set_state({"status": "preview", "method": "cad", "pose": Geometry.encode_transform(pose),
		"physical_scale": physical_scale, "offline": offline, "epoch": epoch,
		"target_pose": Geometry.encode_transform(Transform3D(target_basis, target_pose.origin))})
	return true


func _confirm_visual_preview() -> bool:
	if int(state.get("epoch", -1)) != capture_epoch:
		invalidate("旧识别结果已失效，请重新识别。")
		return false
	var target := _visual_target()
	var target_frame := _visual_frame()
	var origin := _get_local_xr_origin()
	if target == null or target_frame == null or origin == null:
		return false
	var authored: Transform3D = Geometry.decode_transform(state.target_pose)
	var current := target_frame.global_transform
	# Do not silently follow animation/user movement of the alignment anchor.
	if not Transform3D(current.basis.orthonormalized(), current.origin).is_equal_approx(authored):
		invalidate("场景实验柜位置已变化，请重新识别。")
		return false
	var lengths := current.basis.get_scale()
	if minf(lengths.x, minf(lengths.y, lengths.z)) <= 0 \
			or absf(lengths.x - lengths.y) > 0.001 or absf(lengths.x - lengths.z) > 0.001:
		invalidate("场景柜体存在非均匀缩放，无法应用刚体标定。")
		return false
	var measured: Transform3D = Geometry.decode_transform(state.pose)
	var confirmed := state.duplicate(true)
	confirmed["revision"] = int(state.revision) + 1
	confirmed["world_alignment"] = Geometry.encode_transform(compute_world_alignment(measured, authored))
	# Scale ONLY cabinet content around its fixed-frame anchor. XR/world scale
	# remains one, and player head/hand tracking retains metric distances.
	var original_target := target.global_transform
	var adjusted := original_target
	adjusted.basis *= float(state.physical_scale) / lengths.x
	target.global_transform = adjusted
	target.global_position += authored.origin - target_frame.global_position
	var error := _apply_world_alignment(confirmed)
	if not error.is_empty():
		target.global_transform = original_target
		invalidate(error)
		return false
	confirmed["status"] = "confirmed"
	_alignment_settle_until_usec = Time.get_ticks_usec() + 200_000
	_head_history.clear()
	_last_pose_usec = 0
	latest_frame.clear()
	capture_epoch += 1
	_set_state(confirmed)
	_position_panel()
	return true


func clear_cabinet() -> void:
	if not is_local_calibrator():
		return
	if str(state.get("status")) == "confirmed":
		capture_epoch += 1
	_set_state({"status": "empty"})


func invalidate(reason: String) -> void:
	capture_epoch += 1
	_head_history.clear()
	latest_frame.clear()
	if str(state.get("status")) in ["preview", "confirmed"] and not bool(state.get("offline", false)):
		_set_state({"status": "invalid", "reason": reason})


func _set_state(value: Dictionary) -> void:
	value["revision"] = int(state.get("revision", 0)) + 1
	state = value.duplicate(true)
	_render_state()
	state_changed.emit(state.duplicate(true))


## Rebasing tracking is equivalent to moving the entire virtual world relative
## to reality. No cabinet, furniture, camera-local pose or world scale is edited.
static func compute_world_alignment(measured_cabinet: Transform3D, fixed_cabinet: Transform3D) -> Transform3D:
	return fixed_cabinet * measured_cabinet.affine_inverse()


func _apply_world_alignment(value: Dictionary) -> String:
	var revision := int(value.revision)
	if revision == _applied_alignment_revision:
		return ""
	var origin := _get_local_xr_origin()
	if origin == null:
		return "未找到本地 XR 空间原点。"
	var delta: Variant = Geometry.decode_transform(value.get("world_alignment"))
	if delta == null:
		return "整体空间变换无效。"
	origin.global_transform = (delta as Transform3D) * origin.global_transform
	_applied_alignment_revision = revision
	print("[CabinetCalibration] Local whole-world alignment applied; revision=", revision)
	return ""


func _on_recentered(_role: String, _anchor: Node3D) -> void:
	_on_runtime_recentered()


func _on_runtime_recentered() -> void:
	invalidate("本地空间原点已重置，请重新标定。")
	_last_pose_usec = 0
	_position_panel()


func _render_state() -> void:
	for child in _model.get_children():
		_model.remove_child(child)
		child.queue_free()
	if state.get("method") == "cad":
		_render_visual_state()
		return
	_render_cabinet()
	_model.visible = _show_calibration_overlay()
	if not _model.visible:
		return
	var pose: Variant = Geometry.decode_transform(state.get("pose"))
	if pose == null:
		_model.visible = false
		return
	_model.global_transform = _default_cabinet_pose if state.status == "confirmed" else pose as Transform3D
	# Dummy headless renderer cannot allocate the CylinderMesh surfaces.
	if DisplayServer.get_name() == "headless":
		return
	var d: Array = state.dimensions
	var dimensions := Vector3(d[0], d[1], d[2])
	var points := Geometry.corners(dimensions)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 1.0, 0.55) if state.status == "confirmed" else Color(1.0, 0.65, 0.1)
	for edge in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		var start := points[edge[0]]
		var end := points[edge[1]]
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.005
		mesh.bottom_radius = 0.005
		mesh.height = start.distance_to(end)
		mesh.radial_segments = 8
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = material
		instance.transform = Transform3D(Basis(Quaternion(Vector3.UP, (end - start).normalized())), (start + end) * 0.5)
		_model.add_child(instance)
	var label := Label3D.new()
	label.text = "柜体已确认" if state.status == "confirmed" else "柜体预览 · 待确认"
	if bool(state.get("offline", false)):
		label.text = "离线演练 · 不应用空间对齐"
	label.font_size = 40
	label.pixel_size = 0.002
	label.position = Vector3(dimensions.x * 0.5, dimensions.y + 0.1, 0)
	_model.add_child(label)


func _render_visual_state() -> void:
	# Hide the old cuboid only while showing CAD; align the real scene model.
	_cabinet.visible = false
	_model.visible = _show_calibration_overlay()
	if not _model.visible or DisplayServer.get_name() == "headless":
		return
	var confirmed: bool = state.get("status") == "confirmed"
	_model.global_transform = Geometry.decode_transform(state.target_pose if confirmed else state.pose)
	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _visual_points
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 1, 0.55) if confirmed else Color(1, 0.65, 0.1)
	material.use_point_size = true
	material.point_size = 3.0
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	_model.add_child(instance)


func _render_cabinet() -> void:
	var status := str(state.get("status"))
	var offline := bool(state.get("offline", false))
	_cabinet.visible = status != "invalid" and (use_legacy_panel or _custom_visual)
	if not _cabinet.visible:
		return
	# The authored cabinet transform NEVER changes. Its physical alignment is
	# achieved by rebasing the source headset's tracking origin on confirmation.
	if status == "empty" or offline:
		_cabinet.call("set_dimensions", _custom_dimensions if _custom_visual else _default_cabinet_dimensions)
		_cabinet.call("show_uncalibrated_label", true)
		return
	if status not in ["preview", "confirmed"]:
		_cabinet.visible = false
		return
	var d: Array = state.dimensions
	_cabinet.call("set_dimensions", Vector3(d[0], d[1], d[2]))
	_cabinet.call("show_uncalibrated_label", status != "confirmed")
