extends CanvasLayer

const DEBUG_LOGS := false

const FrameProtocol := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd")
const DepthEstimator := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/visual_depth_estimator.gd")

const FRAME_MAGIC_PSA2 := FrameProtocol.FRAME_MAGIC_PSA2
const ACK_MAGIC_PAA1 := FrameProtocol.ACK_MAGIC_PAA1
const FRAME_HEADER_SIZE := FrameProtocol.FRAME_HEADER_SIZE
const ACK_HEADER_SIZE := FrameProtocol.ACK_HEADER_SIZE
const DEFAULT_PORT := 8787
const MAX_FRAME_BYTES := 8 * 1024 * 1024
const MAX_METADATA_BYTES := 64 * 1024
const DEFAULT_CLICK_DEPTH_METERS := 1.0
const SCROLL_DEPTH_STEP_METERS := 0.05
const CLICK_MARKER_SIZE := Vector2(16.0, 16.0)
const INVALID_IMAGE_POSITION := Vector2(-1.0, -1.0)
const XR_DIRECT_PIXEL_SCALE := 0.6

var server: TCPServer = TCPServer.new()
var client: StreamPeerTCP
var recv_buffer: PackedByteArray = PackedByteArray()
var ack_buffer: PackedByteArray = PackedByteArray()
var stream_texture: ImageTexture
var decode_image: Image = Image.new()

@onready var root_panel: PanelContainer = $SpatialCalibrationWindow
@onready var collapsed_button: Button = $CollapsedButton
@onready var address_label: Label = $SpatialCalibrationWindow/MarginContainer/Layout/AddressLabel
@onready var status_label: Label = $SpatialCalibrationWindow/MarginContainer/Layout/StatusLabel
@onready var stats_label: Label = $SpatialCalibrationWindow/MarginContainer/Layout/StatsLabel
@onready var port_input: LineEdit = $SpatialCalibrationWindow/MarginContainer/Layout/Controls/PortInput
@onready var start_button: Button = $SpatialCalibrationWindow/MarginContainer/Layout/Controls/StartButton
@onready var stop_button: Button = $SpatialCalibrationWindow/MarginContainer/Layout/Controls/StopButton
@onready var texture_rect: TextureRect = $SpatialCalibrationWindow/MarginContainer/Layout/PreviewTexture
@onready var click_marker: ColorRect = $SpatialCalibrationWindow/MarginContainer/Layout/PreviewTexture/ClickMarker
@onready var depth_input: SpinBox = $SpatialCalibrationWindow/MarginContainer/Layout/DepthControls/DepthInput
@onready var confirm_button: Button = $SpatialCalibrationWindow/MarginContainer/Layout/DepthControls/ConfirmButton
@onready var clear_button: Button = $SpatialCalibrationWindow/MarginContainer/Layout/DepthControls/ClearButton
@onready var result_label: Label = $SpatialCalibrationWindow/MarginContainer/Layout/ResultLabel

var last_frame_size := Vector2i.ZERO
var last_frame_id := -1
var last_frame_timestamp_ns := 0
var last_frame_metadata: Dictionary = {}
var last_received_frame_id := -1
var frames_this_second := 0
var fps_tick_ms := 0
var display_fps := 0.0
var dropped_frames_this_second := 0
var dropped_frames_display := 0
var decode_time_accum_ms := 0.0
var decode_frames := 0
var decode_avg_ms_display := 0.0
var last_status_text := ""

var has_click_selection := false
var last_click_image_position := INVALID_IMAGE_POSITION
var last_click_frame_id := -1
var last_click_frame_size := Vector2i.ZERO
var last_click_frame_metadata: Dictionary = {}
var click_depth_source := "manual"
var click_depth_estimate: Dictionary = {}
var last_display_projection: Dictionary = {}
var confirmed_point_count := 0
var marker_root: Node3D
var preview_marker: MeshInstance3D


func _ready() -> void:
	if not multiplayer.is_server():
		queue_free()
		return

	layer = 50
	ack_buffer.resize(ACK_HEADER_SIZE)
	_wire_static_ui()
	_set_status("等待 Pico helper 连接")
	_reset_click_selection(false)
	_start_listening(DEFAULT_PORT)
	set_process(true)


func _exit_tree() -> void:
	_disconnect_client("")
	if server.is_listening():
		server.stop()


func _process(_delta: float) -> void:
	if server.is_connection_available():
		_accept_client()

	if client != null:
		var state := client.get_status()
		if state == StreamPeerTCP.STATUS_CONNECTED:
			_pump_socket()
		elif state == StreamPeerTCP.STATUS_ERROR:
			_disconnect_client("Pico helper 连接出错")
		elif state == StreamPeerTCP.STATUS_NONE:
			_disconnect_client("Pico helper 已断开")

	var now_ms := Time.get_ticks_msec()
	if fps_tick_ms == 0:
		fps_tick_ms = now_ms
	elif now_ms - fps_tick_ms >= 1000:
		display_fps = frames_this_second * 1000.0 / float(now_ms - fps_tick_ms)
		decode_avg_ms_display = decode_time_accum_ms / float(max(1, decode_frames))
		dropped_frames_display = dropped_frames_this_second
		frames_this_second = 0
		decode_time_accum_ms = 0.0
		decode_frames = 0
		dropped_frames_this_second = 0
		fps_tick_ms = now_ms
		_refresh_stats()


func _wire_static_ui() -> void:
	texture_rect.gui_input.connect(_on_preview_gui_input)
	start_button.pressed.connect(_on_start_pressed)
	stop_button.pressed.connect(_on_stop_pressed)
	confirm_button.pressed.connect(_confirm_current_point)
	clear_button.pressed.connect(_clear_confirmed_points)
	depth_input.value_changed.connect(_on_click_depth_changed)
	root_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	texture_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	click_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	collapsed_button.pressed.connect(_on_expand_pressed)

	var collapse_button := root_panel.get_node("MarginContainer/Layout/TitleBar/CollapseButton") as Button
	collapse_button.pressed.connect(_on_collapse_pressed)


func _create_ui() -> void:
	root_panel = PanelContainer.new()
	root_panel.name = "SpatialCalibrationWindow"
	root_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root_panel.offset_left = 16.0
	root_panel.offset_top = 16.0
	root_panel.offset_right = 620.0
	root_panel.offset_bottom = 760.0
	root_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root_panel)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.06, 0.08, 0.92)
	panel_style.border_color = Color(0.22, 0.75, 0.95, 0.72)
	panel_style.border_width_left = 1
	panel_style.border_width_top = 1
	panel_style.border_width_right = 1
	panel_style.border_width_bottom = 1
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	root_panel.add_theme_stylebox_override("panel", panel_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 12)
	root_panel.add_child(margin)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	margin.add_child(layout)

	var title_bar := HBoxContainer.new()
	title_bar.add_theme_constant_override("separation", 8)
	layout.add_child(title_bar)

	var title := Label.new()
	title.text = "空间标定"
	title.add_theme_font_size_override("font_size", 18)
	title_bar.add_child(title)

	var title_spacer := Control.new()
	title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(title_spacer)

	var collapse_button := Button.new()
	collapse_button.text = "隐藏"
	collapse_button.pressed.connect(_on_collapse_pressed)
	title_bar.add_child(collapse_button)

	address_label = Label.new()
	address_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(address_label)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	layout.add_child(controls)

	var port_label := Label.new()
	port_label.text = "监听端口"
	controls.add_child(port_label)

	port_input = LineEdit.new()
	port_input.custom_minimum_size = Vector2(90, 0)
	port_input.text = str(DEFAULT_PORT)
	controls.add_child(port_input)

	start_button = Button.new()
	start_button.text = "开始监听"
	start_button.pressed.connect(_on_start_pressed)
	controls.add_child(start_button)

	stop_button = Button.new()
	stop_button.text = "停止监听"
	stop_button.pressed.connect(_on_stop_pressed)
	controls.add_child(stop_button)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(status_label)

	stats_label = Label.new()
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(stats_label)

	texture_rect = TextureRect.new()
	texture_rect.name = "PreviewTexture"
	texture_rect.custom_minimum_size = Vector2(560, 360)
	texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	texture_rect.gui_input.connect(_on_preview_gui_input)
	layout.add_child(texture_rect)

	click_marker = ColorRect.new()
	click_marker.name = "ClickMarker"
	click_marker.custom_minimum_size = CLICK_MARKER_SIZE
	click_marker.size = CLICK_MARKER_SIZE
	click_marker.color = Color(1.0, 0.14, 0.04, 0.95)
	click_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	click_marker.visible = false
	texture_rect.add_child(click_marker)

	var depth_controls := HBoxContainer.new()
	depth_controls.add_theme_constant_override("separation", 8)
	layout.add_child(depth_controls)

	var depth_label := Label.new()
	depth_label.text = "深度(m)"
	depth_controls.add_child(depth_label)

	depth_input = SpinBox.new()
	depth_input.custom_minimum_size = Vector2(110, 0)
	depth_input.min_value = 0.05
	depth_input.max_value = 20.0
	depth_input.step = 0.05
	depth_input.value = DEFAULT_CLICK_DEPTH_METERS
	depth_input.value_changed.connect(_on_click_depth_changed)
	depth_controls.add_child(depth_input)

	confirm_button = Button.new()
	confirm_button.text = "确认标定点"
	confirm_button.disabled = true
	confirm_button.pressed.connect(_confirm_current_point)
	depth_controls.add_child(confirm_button)

	clear_button = Button.new()
	clear_button.text = "清除标定点"
	clear_button.pressed.connect(_clear_confirmed_points)
	depth_controls.add_child(clear_button)

	result_label = Label.new()
	result_label.text = "点击 Pico 预览画面选点；滚轮调深度，右键或按钮确认。"
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result_label.custom_minimum_size = Vector2(0, 110)
	layout.add_child(result_label)

	collapsed_button = Button.new()
	collapsed_button.text = "空间标定"
	collapsed_button.visible = false
	collapsed_button.set_anchors_preset(Control.PRESET_TOP_LEFT)
	collapsed_button.offset_left = 16.0
	collapsed_button.offset_top = 16.0
	collapsed_button.offset_right = 120.0
	collapsed_button.offset_bottom = 48.0
	collapsed_button.pressed.connect(_on_expand_pressed)
	add_child(collapsed_button)


func _on_collapse_pressed() -> void:
	root_panel.visible = false
	collapsed_button.visible = true


func _on_expand_pressed() -> void:
	root_panel.visible = true
	collapsed_button.visible = false


func _on_start_pressed() -> void:
	var port := port_input.text.to_int()
	if port <= 0 or port > 65535:
		_set_status("端口无效，请输入 1-65535")
		return
	_start_listening(port)


func _on_stop_pressed() -> void:
	_disconnect_client("监听已停止")
	if server.is_listening():
		server.stop()
	_set_status("监听已停止")
	_refresh_stats()


func _start_listening(port: int) -> void:
	_disconnect_client("切换监听端口")
	if server.is_listening():
		server.stop()

	var error := server.listen(port)
	if error != OK:
		_set_status("启动监听失败: %s" % error_string(error))
		return

	_refresh_addresses(port)
	_set_status("监听中，等待 Pico helper 连接到端口 %d" % port)
	_refresh_stats()


func _accept_client() -> void:
	_disconnect_client("收到新的 Pico helper 连接")
	client = server.take_connection()
	recv_buffer = PackedByteArray()
	if client != null:
		client.set_no_delay(true)
		_set_status("Pico helper 已连接，等待首帧")
		_refresh_stats()


func _disconnect_client(reason: String) -> void:
	if client != null:
		client.disconnect_from_host()
		client = null
	recv_buffer = PackedByteArray()
	last_received_frame_id = -1
	last_frame_metadata = {}
	_reset_click_selection(false)
	if reason != "":
		_set_status(reason)
	_refresh_stats()


func _pump_socket() -> void:
	var available := client.get_available_bytes()
	if available <= 0:
		return

	var packet := client.get_data(available)
	if int(packet[0]) != OK:
		_disconnect_client("读取失败: %s" % error_string(int(packet[0])))
		return

	recv_buffer.append_array(packet[1])
	while _try_consume_frame():
		pass


func _try_consume_frame() -> bool:
	if recv_buffer.size() < FRAME_HEADER_SIZE:
		return false

	var magic := _read_u32_be(recv_buffer, 0)
	if magic != FRAME_MAGIC_PSA2:
		_resync_buffer()
		return recv_buffer.size() >= FRAME_HEADER_SIZE

	var metadata_size := _read_u32_be(recv_buffer, 24)
	var payload_size := _read_u32_be(recv_buffer, 28)
	if metadata_size > MAX_METADATA_BYTES:
		_set_status("收到异常元数据，已丢弃")
		recv_buffer = PackedByteArray()
		return false
	if payload_size <= 0 or payload_size > MAX_FRAME_BYTES:
		_set_status("收到异常 JPEG 数据，已丢弃")
		recv_buffer = PackedByteArray()
		return false

	var total_size := FRAME_HEADER_SIZE + metadata_size + payload_size
	if recv_buffer.size() < total_size:
		return false

	var frame_id := _read_u32_be(recv_buffer, 4)
	var timestamp_ns := _read_u64_be(recv_buffer, 8)
	var width := _read_u32_be(recv_buffer, 16)
	var height := _read_u32_be(recv_buffer, 20)
	if last_received_frame_id >= 0 and frame_id > last_received_frame_id + 1:
		dropped_frames_this_second += frame_id - last_received_frame_id - 1
	last_received_frame_id = frame_id

	var metadata: Dictionary = {}
	if metadata_size > 0:
		var metadata_bytes := recv_buffer.slice(FRAME_HEADER_SIZE, FRAME_HEADER_SIZE + metadata_size)
		metadata = _parse_metadata(metadata_bytes)
	var jpeg_bytes := recv_buffer.slice(FRAME_HEADER_SIZE + metadata_size, total_size)
	recv_buffer = recv_buffer.slice(total_size, recv_buffer.size())
	_send_ack(frame_id)
	_show_frame(jpeg_bytes, width, height, frame_id, timestamp_ns, metadata)
	return true


func _show_frame(
	jpeg_bytes: PackedByteArray,
	_width: int,
	_height: int,
	frame_id: int,
	timestamp_ns: int,
	metadata: Dictionary,
) -> void:
	var decode_start_us := Time.get_ticks_usec()
	var error := decode_image.load_jpg_from_buffer(jpeg_bytes)
	if error != OK:
		_set_status("JPEG 解码失败: %s" % error_string(error))
		return

	var image_size := Vector2i(decode_image.get_width(), decode_image.get_height())
	if stream_texture == null or last_frame_size != image_size:
		stream_texture = ImageTexture.create_from_image(decode_image)
		texture_rect.texture = stream_texture
	else:
		stream_texture.update(decode_image)

	last_frame_id = frame_id
	last_frame_size = image_size
	last_frame_timestamp_ns = timestamp_ns
	last_frame_metadata = metadata
	_update_click_marker_position()
	if has_click_selection:
		_recompute_click_result()

	frames_this_second += 1
	var decode_ms := float(Time.get_ticks_usec() - decode_start_us) / 1000.0
	decode_time_accum_ms += decode_ms
	decode_frames += 1
	_refresh_stats()
	_set_status("正在显示 Pico 画面")


func _on_preview_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event == null or not mouse_event.pressed:
		return

	if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_adjust_click_depth(SCROLL_DEPTH_STEP_METERS)
		get_viewport().set_input_as_handled()
		return
	if mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_adjust_click_depth(-SCROLL_DEPTH_STEP_METERS)
		get_viewport().set_input_as_handled()
		return
	if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
		_confirm_current_point()
		get_viewport().set_input_as_handled()
		return
	if mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if last_frame_size.x <= 0 or last_frame_size.y <= 0:
		result_label.text = "还没有有效视频帧，无法点击取点。"
		return

	var image_position := _texture_local_to_image_position(mouse_event.position, last_frame_size)
	if image_position == INVALID_IMAGE_POSITION:
		result_label.text = "点击落在黑边区域，未命中实际视频内容。"
		return

	has_click_selection = true
	last_click_image_position = image_position
	last_click_frame_id = last_frame_id
	last_click_frame_size = last_frame_size
	last_click_frame_metadata = last_frame_metadata.duplicate(true)
	_apply_initial_depth_estimate(image_position)
	_update_click_marker_position()
	_recompute_click_result()
	get_viewport().set_input_as_handled()


func _on_click_depth_changed(_value: float) -> void:
	if has_click_selection:
		click_depth_source = "manual"
		click_depth_estimate = {}
	_recompute_click_result()


func _apply_initial_depth_estimate(image_position: Vector2) -> void:
	click_depth_source = "manual"
	click_depth_estimate = DepthEstimator.estimate_initial_depth(
		decode_image,
		image_position,
		last_click_frame_metadata,
		float(depth_input.min_value),
		float(depth_input.max_value),
	)
	if not bool(click_depth_estimate.get("available", false)):
		return

	var estimated_depth := float(click_depth_estimate.get("depth_m", depth_input.value))
	depth_input.set_value_no_signal(estimated_depth)
	click_depth_source = str(click_depth_estimate.get("source", "visual_initial"))


func _adjust_click_depth(delta_meters: float) -> void:
	var next_depth: float = clamp(
		float(depth_input.value) + delta_meters,
		float(depth_input.min_value),
		float(depth_input.max_value),
	)
	depth_input.value = next_depth


func _reset_click_selection(clear_marker_only: bool) -> void:
	has_click_selection = false
	last_click_image_position = INVALID_IMAGE_POSITION
	last_click_frame_id = -1
	last_click_frame_size = Vector2i.ZERO
	last_click_frame_metadata = {}
	click_depth_source = "manual"
	click_depth_estimate = {}
	last_display_projection = {}
	if confirm_button != null:
		confirm_button.disabled = true
	if click_marker != null:
		click_marker.visible = false
	_hide_preview_marker()
	if result_label != null and not clear_marker_only:
		result_label.text = "点击 Pico 预览画面选点；滚轮调深度，右键或按钮确认。"


func _recompute_click_result() -> void:
	if not has_click_selection:
		return

	var projection := _compute_virtual_camera_projection(
		last_click_image_position,
		last_click_frame_size,
		float(depth_input.value),
	)
	var capture_debug := _compute_capture_debug_projection(
		last_click_image_position,
		last_click_frame_size,
		last_click_frame_metadata,
		float(depth_input.value),
	)
	projection["capture_debug"] = capture_debug
	last_display_projection = projection

	if projection.has("error"):
		confirm_button.disabled = true
		result_label.text = str(projection["error"])
		_hide_preview_marker()
		return

	confirm_button.disabled = false
	_update_preview_marker(projection.get("position", Vector3.ZERO))
	result_label.text = _build_result_text(projection)


func _compute_virtual_camera_projection(
	image_position: Vector2,
	frame_size: Vector2i,
	depth_m: float,
) -> Dictionary:
	var camera := _get_reference_camera()
	if camera == null:
		return {"error": "未找到 server 虚拟相机，无法计算空间标定点。"}
	if frame_size.x <= 0 or frame_size.y <= 0:
		return {"error": "当前帧尺寸无效，无法计算空间标定点。"}

	var uv := Vector2(
		image_position.x / float(frame_size.x),
		image_position.y / float(frame_size.y),
	)
	var ray := _virtual_camera_ray_from_uv(camera, uv, frame_size)
	var origin := camera.global_transform.origin
	var point := origin + ray * depth_m
	return {
		"position": point,
		"camera_position": origin,
		"ray_direction": ray,
		"uv": uv,
		"pixel": image_position,
		"depth_m": depth_m,
		"camera_name": camera.name,
	}


func _virtual_camera_ray_from_uv(camera: Camera3D, uv: Vector2, frame_size: Vector2i) -> Vector3:
	var pixel_x := (uv.x - 0.5) * 2.0
	var pixel_y := (0.5 - uv.y) * 2.0
	if camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		var aspect: float = float(frame_size.x) / max(1.0, float(frame_size.y))
		var vertical_tan := tan(deg_to_rad(camera.fov) * 0.5)
		var local_ray := Vector3(
			pixel_x * vertical_tan * aspect * XR_DIRECT_PIXEL_SCALE,
			pixel_y * vertical_tan * XR_DIRECT_PIXEL_SCALE,
			-1.0
		).normalized()
		return (camera.global_transform.basis * local_ray).normalized()

	var local_orthographic_ray := Vector3(
		pixel_x * XR_DIRECT_PIXEL_SCALE,
		pixel_y * XR_DIRECT_PIXEL_SCALE,
		-1.0
	).normalized()
	return (camera.global_transform.basis * local_orthographic_ray).normalized()


func _compute_capture_debug_projection(
	image_position: Vector2,
	frame_size: Vector2i,
	metadata: Dictionary,
	depth_m: float,
) -> Dictionary:
	if metadata.is_empty():
		return {"available": false, "reason": "missing_metadata"}
	if frame_size.x <= 0 or frame_size.y <= 0:
		return {"available": false, "reason": "invalid_frame_size"}

	var fx := float(metadata.get("camera_intrinsics_fx", 0.0))
	var fy := float(metadata.get("camera_intrinsics_fy", 0.0))
	if abs(fx) < 0.000001 or abs(fy) < 0.000001:
		return {"available": false, "reason": "missing_intrinsics"}

	var cx := float(metadata.get("camera_intrinsics_cx", float(frame_size.x) * 0.5))
	var cy := float(metadata.get("camera_intrinsics_cy", float(frame_size.y) * 0.5))
	var ray_camera := Vector3(
		(image_position.x - cx) / fx,
		(cy - image_position.y) / fy,
		-1.0
	).normalized()

	var hmd_position := Vector3(
		float(metadata.get("head_pose_x", 0.0)),
		float(metadata.get("head_pose_y", 0.0)),
		float(metadata.get("head_pose_z", 0.0)),
	)
	var hmd_rotation := Quaternion(
		float(metadata.get("head_pose_rx", 0.0)),
		float(metadata.get("head_pose_ry", 0.0)),
		float(metadata.get("head_pose_rz", 0.0)),
		float(metadata.get("head_pose_rw", 1.0)),
	)
	var ray_world := (Basis(hmd_rotation) * ray_camera).normalized()
	var point_world := hmd_position + ray_world * depth_m
	return {
		"available": true,
		"point_world": point_world,
		"hmd_position": hmd_position,
		"ray_world": ray_world,
		"head_pose_available": bool(metadata.get("head_pose_available", false)),
		"intrinsics_probe": str(metadata.get("camera_intrinsics_probe", "")),
		"extrinsics_status": str(metadata.get("camera_extrinsics_status", "")),
	}


func _confirm_current_point() -> void:
	if not has_click_selection:
		result_label.text = "请先在 Pico 预览画面点击一个点。"
		return
	if last_display_projection.is_empty() or last_display_projection.has("error"):
		_recompute_click_result()
	if last_display_projection.is_empty() or last_display_projection.has("error"):
		return

	var position: Vector3 = last_display_projection.get("position", Vector3.ZERO)
	confirmed_point_count += 1
	_add_confirmed_marker(position)
	_send_confirmed_point(position, last_display_projection)
	result_label.text = "%s\n已确认并同步标定点 #%d。" % [
		_build_result_text(last_display_projection),
		confirmed_point_count,
	]


func _send_confirmed_point(position: Vector3, projection: Dictionary) -> void:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	var color := Color(1.0, 0.08, 0.03, 1.0)
	var pixel: Vector2 = projection.get("pixel", Vector2.ZERO)
	var uv: Vector2 = projection.get("uv", Vector2.ZERO)
	var payload := {
		"source": "spatial_calibration",
		"frame_id": last_click_frame_id,
		"frame_timestamp_ns": last_frame_timestamp_ns,
		"depth_m": float(projection.get("depth_m", depth_input.value)),
		"depth_source": click_depth_source,
		"pixel": [pixel.x, pixel.y],
		"uv": [uv.x, uv.y],
		"camera_name": str(projection.get("camera_name", "")),
		"color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a},
		"size": 0.05,
		"lifetime": 5.0,
	}
	if network_handler != null and network_handler.has_method("send_remote_annotation"):
		network_handler.send_remote_annotation(position, payload)
		_set_status("已通过 NetworkHandler 同步标定点 #%d" % confirmed_point_count)
	else:
		_set_status("NetworkHandler 不可用，标定点仅在 server 本地显示")


func _clear_confirmed_points() -> void:
	if marker_root != null and is_instance_valid(marker_root):
		for child in marker_root.get_children():
			child.queue_free()
		preview_marker = null
	confirmed_point_count = 0
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler != null and network_handler.has_method("clear_all_remote_annotations"):
		network_handler.clear_all_remote_annotations()
	_set_status("已清除空间标定点")


func _update_click_marker_position() -> void:
	if not has_click_selection:
		click_marker.visible = false
		return

	var local_position := _image_position_to_texture_local(
		last_click_image_position,
		last_click_frame_size,
	)
	if local_position == INVALID_IMAGE_POSITION:
		click_marker.visible = false
		return

	click_marker.position = local_position - click_marker.size * 0.5
	click_marker.visible = true


func _get_displayed_image_rect(image_size: Vector2i) -> Rect2:
	var rect_size := texture_rect.size
	if image_size.x <= 0 or image_size.y <= 0 or rect_size.x <= 0.0 or rect_size.y <= 0.0:
		return Rect2(Vector2.ZERO, rect_size)

	var image_aspect := float(image_size.x) / float(image_size.y)
	var rect_aspect := rect_size.x / rect_size.y
	var display_size := rect_size
	if rect_aspect > image_aspect:
		display_size.x = rect_size.y * image_aspect
	else:
		display_size.y = rect_size.x / image_aspect

	var offset := (rect_size - display_size) * 0.5
	return Rect2(offset, display_size)


func _texture_local_to_image_position(local_position: Vector2, image_size: Vector2i) -> Vector2:
	var displayed_rect := _get_displayed_image_rect(image_size)
	if not displayed_rect.has_point(local_position):
		return INVALID_IMAGE_POSITION

	var uv := (local_position - displayed_rect.position) / displayed_rect.size
	return Vector2(uv.x * float(image_size.x), uv.y * float(image_size.y))


func _image_position_to_texture_local(image_position: Vector2, reference_image_size: Vector2i) -> Vector2:
	if reference_image_size.x <= 0 or reference_image_size.y <= 0:
		return INVALID_IMAGE_POSITION

	var displayed_rect := _get_displayed_image_rect(reference_image_size)
	var uv := Vector2(
		image_position.x / float(reference_image_size.x),
		image_position.y / float(reference_image_size.y),
	)
	return displayed_rect.position + displayed_rect.size * uv


func _get_reference_camera() -> Camera3D:
	var root := get_tree().current_scene
	if root == null:
		return null

	var xr_camera := root.find_child("XRCamera3D", true, false) as Camera3D
	if xr_camera != null:
		return xr_camera

	var viewport_camera := get_viewport().get_camera_3d()
	if viewport_camera != null:
		return viewport_camera

	return root.find_child("SpectatorCamera", true, false) as Camera3D


func _get_marker_root() -> Node3D:
	if marker_root != null and is_instance_valid(marker_root):
		return marker_root

	var scene := get_tree().current_scene
	if scene == null:
		return null
	marker_root = scene.get_node_or_null("SpatialCalibrationMarkers") as Node3D
	if marker_root == null:
		marker_root = Node3D.new()
		marker_root.name = "SpatialCalibrationMarkers"
		scene.add_child(marker_root)
	return marker_root


func _update_preview_marker(position: Vector3) -> void:
	var root := _get_marker_root()
	if root == null:
		return
	if preview_marker == null or not is_instance_valid(preview_marker):
		preview_marker = _create_marker_mesh(Color(0.2, 1.0, 0.25, 1.0), 0.05)
		preview_marker.name = "PreviewSpatialCalibrationPoint"
		root.add_child(preview_marker)
	preview_marker.global_position = position
	preview_marker.visible = true


func _hide_preview_marker() -> void:
	if preview_marker != null and is_instance_valid(preview_marker):
		preview_marker.visible = false


func _add_confirmed_marker(position: Vector3) -> void:
	var root := _get_marker_root()
	if root == null:
		return
	var marker := _create_marker_mesh(Color(1.0, 0.08, 0.03, 1.0), 0.05)
	marker.name = "SpatialCalibrationPoint%d" % confirmed_point_count
	root.add_child(marker)
	marker.global_position = position
	marker.visible = true
	get_tree().create_timer(5.0).timeout.connect(func():
		if is_instance_valid(marker):
			marker.queue_free()
	)


func _create_marker_mesh(color: Color, radius: float) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	marker.mesh = mesh
	marker.set_surface_override_material(0, _make_marker_material(color))
	return marker


func _make_marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 1.6
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _build_result_text(projection: Dictionary) -> String:
	if projection.has("error"):
		return str(projection["error"])

	var pixel: Vector2 = projection.get("pixel", Vector2.ZERO)
	var uv: Vector2 = projection.get("uv", Vector2.ZERO)
	var point: Vector3 = projection.get("position", Vector3.ZERO)
	var camera_position: Vector3 = projection.get("camera_position", Vector3.ZERO)
	var ray: Vector3 = projection.get("ray_direction", Vector3.FORWARD)
	var lines := [
		"帧=%d  像素=%s  UV=%s" % [last_click_frame_id, _format_vector2(pixel), _format_vector2(uv)],
		"虚拟相机=%s  深度=%.2fm (%s)" % [
			str(projection.get("camera_name", "")),
			float(projection.get("depth_m", depth_input.value)),
			click_depth_source,
		],
		"Camera=%s" % _format_vector3(camera_position),
		"Ray=%s" % _format_vector3(ray),
		"标定点=%s" % _format_vector3(point),
	]

	var capture_debug: Dictionary = projection.get("capture_debug", {})
	if bool(capture_debug.get("available", false)):
		lines.append("Pico metadata参考点=%s  head_pose=%s" % [
			_format_vector3(capture_debug.get("point_world", Vector3.ZERO)),
			str(capture_debug.get("head_pose_available", false)),
		])
	else:
		lines.append("Pico metadata参考不可用: %s" % str(capture_debug.get("reason", "unknown")))
	return "\n".join(lines)


func _refresh_addresses(port: int = DEFAULT_PORT) -> void:
	if address_label == null:
		return

	var addresses: Array[String] = []
	for address in IP.get_local_addresses():
		if "." in address and not address.begins_with("127.") and not address.begins_with("169.254."):
			addresses.append("%s:%d" % [address, port])

	if addresses.is_empty():
		address_label.text = "本机 IPv4: 未找到"
	else:
		address_label.text = "把 Pico helper 指向: %s" % ", ".join(addresses)


func _refresh_stats() -> void:
	if stats_label == null:
		return

	var connection_text := "未连接"
	if client != null and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		connection_text = "已连接"
	elif server.is_listening():
		connection_text = "监听中"

	stats_label.text = "状态: %s | 帧: %d | 分辨率: %dx%d | FPS: %.1f | 丢帧: %d | 解码均值: %.1fms" % [
		connection_text,
		last_frame_id,
		last_frame_size.x,
		last_frame_size.y,
		display_fps,
		dropped_frames_display,
		decode_avg_ms_display,
	]


func _set_status(text: String) -> void:
	if text == last_status_text:
		return
	last_status_text = text
	if status_label != null:
		status_label.text = text
	if DEBUG_LOGS: print("SpatialCalibration: %s" % text)


func _send_ack(frame_id: int) -> void:
	if client == null:
		return
	_write_u32_be(ack_buffer, 0, ACK_MAGIC_PAA1)
	_write_u32_be(ack_buffer, 4, frame_id)
	var error := client.put_data(ack_buffer)
	if error != OK:
		_disconnect_client("ACK 回传失败: %s" % error_string(error))


func _resync_buffer() -> void:
	for index in range(1, recv_buffer.size() - 3):
		if _read_u32_be(recv_buffer, index) == FRAME_MAGIC_PSA2:
			recv_buffer = recv_buffer.slice(index, recv_buffer.size())
			return
	recv_buffer = PackedByteArray()


func _parse_metadata(metadata_bytes: PackedByteArray) -> Dictionary:
	if metadata_bytes.is_empty():
		return {}

	var json := JSON.new()
	var error := json.parse(metadata_bytes.get_string_from_utf8())
	if error != OK:
		_set_status("元数据 JSON 解析失败: %s" % error_string(error))
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data


func _format_vector2(value: Vector2) -> String:
	return "(%s, %s)" % [_format_float(value.x), _format_float(value.y)]


func _format_vector3(value: Vector3) -> String:
	return "(%s, %s, %s)" % [
		_format_float(value.x),
		_format_float(value.y),
		_format_float(value.z),
	]


func _format_float(value: Variant) -> String:
	return "%.3f" % float(value)


func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return FrameProtocol.read_u32_be(bytes, offset)


func _read_u64_be(bytes: PackedByteArray, offset: int) -> int:
	return FrameProtocol.read_u64_be(bytes, offset)


func _write_u32_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	FrameProtocol.write_u32_be(bytes, offset, value)
