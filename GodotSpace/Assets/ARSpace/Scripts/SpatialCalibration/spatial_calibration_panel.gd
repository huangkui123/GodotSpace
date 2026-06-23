extends Control

const DEBUG_LOGS := false

const FrameProtocol := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd")

const FRAME_MAGIC_PSA2 := FrameProtocol.FRAME_MAGIC_PSA2
const ACK_MAGIC_PAA1 := FrameProtocol.ACK_MAGIC_PAA1
const FRAME_HEADER_SIZE := FrameProtocol.FRAME_HEADER_SIZE
const ACK_HEADER_SIZE := FrameProtocol.ACK_HEADER_SIZE

const DEFAULT_PORT := 8787
const MAX_FRAME_BYTES := 8 * 1024 * 1024
const MAX_METADATA_BYTES := 64 * 1024

const DEFAULT_CLICK_DEPTH_METERS := 1.0
const SCROLL_DEPTH_STEP_METERS := 0.05
const PREVIEW_MARKER_RADIUS := 0.05
const CONFIRMED_MARKER_RADIUS := 0.05
const CLICK_MARKER_SIZE := Vector2(16.0, 16.0)
const INVALID_IMAGE_POSITION := Vector2(-1.0, -1.0)
const DEFAULT_DEPTH_PREDICTION_ENDPOINT := "http://127.0.0.1:8765/predict"
const DEPTH_PREDICTION_ENDPOINT_SETTING := "godot_space/spatial_calibration/depth_prediction_endpoint"
const DEPTH_PREDICTION_ENDPOINT_ENV := "GODOTSPACE_DEPTH_PREDICTION_ENDPOINT"
const DEPTH_PREDICTION_PATCH_RADIUS := 5
const MIN_RAY_Z_FACTOR := 0.05

const PREVIEW_CAMERA_PATH := NodePath("UI/SubViewportContainer/SubViewport/Camera3D")

var server: TCPServer = TCPServer.new()
var client: StreamPeerTCP
var recv_buffer: PackedByteArray = PackedByteArray()
var ack_buffer: PackedByteArray = PackedByteArray()
var last_frame_jpeg_bytes: PackedByteArray = PackedByteArray()
var stream_texture: ImageTexture
var decode_image: Image = Image.new()
var depth_prediction_request: HTTPRequest

@onready var address_label: Label = $MarginContainer/Layout/AddressLabel
@onready var status_label: Label = $MarginContainer/Layout/StatusLabel
@onready var stats_label: Label = $MarginContainer/Layout/StatsLabel
@onready var port_input: LineEdit = $MarginContainer/Layout/Controls/PortInput
@onready var start_button: Button = $MarginContainer/Layout/Controls/StartButton
@onready var stop_button: Button = $MarginContainer/Layout/Controls/StopButton
@onready var texture_rect: TextureRect = $MarginContainer/Layout/PreviewTexture
@onready var click_marker: ColorRect = $MarginContainer/Layout/PreviewTexture/ClickMarker
@onready var depth_input: SpinBox = $MarginContainer/Layout/DepthControls/DepthInput
@onready var confirm_button: Button = $MarginContainer/Layout/DepthControls/ConfirmButton
@onready var clear_button: Button = $MarginContainer/Layout/DepthControls/ClearButton
@onready var result_label: Label = $MarginContainer/Layout/ResultLabel

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

var has_selection := false
var selected_image_position := INVALID_IMAGE_POSITION
var selected_frame_id := -1
var selected_frame_size := Vector2i.ZERO
var selected_depth_m := DEFAULT_CLICK_DEPTH_METERS
var selected_uv := Vector2.ZERO
var selected_ray_origin := Vector3.ZERO
var selected_ray_direction := Vector3.FORWARD
var selected_camera_z_per_ray_meter := 1.0
var selected_camera_name := ""
var selected_camera_path := ""
var selected_depth_source := "manual"
var selection_depth_ready := false
var depth_prediction_status_text := ""
var depth_prediction_endpoint: String = DEFAULT_DEPTH_PREDICTION_ENDPOINT
var depth_prediction_request_id := 0
var pending_depth_prediction_request_id := -1
var pending_depth_prediction_frame_id := -1
var pending_depth_prediction_revision := -1
var depth_manual_revision := 0
var current_projection: Dictionary = {}

var marker_root: Node3D
var preview_marker: MeshInstance3D
var confirmed_point_count := 0


func _ready() -> void:
	if not multiplayer.is_server():
		visible = false
		set_process(false)
		return

	ack_buffer.resize(ACK_HEADER_SIZE)
	_wire_static_ui()
	_load_depth_prediction_endpoint()
	_setup_depth_prediction_client()
	_reset_selection(false)
	_start_listening(DEFAULT_PORT)
	set_process(true)


func _exit_tree() -> void:
	_disconnect_client("")
	if server.is_listening():
		server.stop()
	_clear_remote_preview()


func _process(_delta: float) -> void:
	if server.is_connection_available():
		_accept_client()

	if client != null:
		var state := client.get_status()
		if state == StreamPeerTCP.STATUS_CONNECTED:
			_pump_socket()
		elif state == StreamPeerTCP.STATUS_ERROR:
			_disconnect_client("Pico helper connection error")
		elif state == StreamPeerTCP.STATUS_NONE:
			_disconnect_client("Pico helper disconnected")

	_update_fps_stats()


func _wire_static_ui() -> void:
	texture_rect.gui_input.connect(_on_preview_gui_input)
	start_button.pressed.connect(_on_start_pressed)
	stop_button.pressed.connect(_on_stop_pressed)
	confirm_button.pressed.connect(_confirm_current_point)
	clear_button.pressed.connect(_clear_confirmed_points)
	depth_input.value_changed.connect(_on_depth_input_changed)
	texture_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	click_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	depth_input.set_value_no_signal(DEFAULT_CLICK_DEPTH_METERS)


func _setup_depth_prediction_client() -> void:
	depth_prediction_request = HTTPRequest.new()
	depth_prediction_request.name = "DepthPredictionRequest"
	depth_prediction_request.timeout = 90.0
	add_child(depth_prediction_request)
	depth_prediction_request.request_completed.connect(_on_depth_prediction_completed)


func _load_depth_prediction_endpoint() -> void:
	var configured_endpoint: Variant = ProjectSettings.get_setting(
		DEPTH_PREDICTION_ENDPOINT_SETTING,
		DEFAULT_DEPTH_PREDICTION_ENDPOINT
	)
	depth_prediction_endpoint = str(configured_endpoint).strip_edges()

	var environment_endpoint: String = OS.get_environment(DEPTH_PREDICTION_ENDPOINT_ENV).strip_edges()
	if environment_endpoint != "":
		depth_prediction_endpoint = environment_endpoint
	if depth_prediction_endpoint == "":
		depth_prediction_endpoint = DEFAULT_DEPTH_PREDICTION_ENDPOINT


func _on_start_pressed() -> void:
	var port := port_input.text.to_int()
	if port <= 0 or port > 65535:
		_set_status("Invalid port. Use 1-65535.")
		return
	_start_listening(port)


func _on_stop_pressed() -> void:
	_disconnect_client("Stream listener stopped")
	if server.is_listening():
		server.stop()
	_set_status("Stream listener stopped")
	_refresh_stats()


func _start_listening(port: int) -> void:
	_disconnect_client("Switching stream listener")
	if server.is_listening():
		server.stop()

	var error := server.listen(port)
	if error != OK:
		_set_status("Failed to listen: %s" % error_string(error))
		return

	_refresh_addresses(port)
	_set_status("Listening for Pico helper on port %d" % port)
	_refresh_stats()


func _accept_client() -> void:
	_disconnect_client("New Pico helper connection")
	client = server.take_connection()
	recv_buffer = PackedByteArray()
	if client != null:
		client.set_no_delay(true)
		_set_status("Pico helper connected; waiting for frames")
		_refresh_stats()


func _disconnect_client(reason: String) -> void:
	if client != null:
		client.disconnect_from_host()
		client = null
	recv_buffer = PackedByteArray()
	last_received_frame_id = -1
	last_frame_metadata = {}
	last_frame_jpeg_bytes = PackedByteArray()
	if reason != "":
		_set_status(reason)
	_refresh_stats()


func _pump_socket() -> void:
	var available := client.get_available_bytes()
	if available <= 0:
		return

	var packet := client.get_data(available)
	if int(packet[0]) != OK:
		_disconnect_client("Read failed: %s" % error_string(int(packet[0])))
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
		_set_status("Discarded frame with oversized metadata")
		recv_buffer = PackedByteArray()
		return false
	if payload_size <= 0 or payload_size > MAX_FRAME_BYTES:
		_set_status("Discarded frame with invalid JPEG payload")
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
		_set_status("JPEG decode failed: %s" % error_string(error))
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
	last_frame_jpeg_bytes = jpeg_bytes
	_update_click_marker_position()

	frames_this_second += 1
	var decode_ms := float(Time.get_ticks_usec() - decode_start_us) / 1000.0
	decode_time_accum_ms += decode_ms
	decode_frames += 1
	_refresh_stats()
	_set_status("Showing Pico stream")


func _on_preview_gui_input(event: InputEvent) -> void:
	var mouse_event := event as InputEventMouseButton
	if mouse_event == null or not mouse_event.pressed:
		return

	match mouse_event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			_adjust_selection_depth(SCROLL_DEPTH_STEP_METERS)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_WHEEL_DOWN:
			_adjust_selection_depth(-SCROLL_DEPTH_STEP_METERS)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_RIGHT:
			_confirm_current_point()
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_LEFT:
			_select_preview_point(mouse_event.position)
			get_viewport().set_input_as_handled()


func _select_preview_point(local_position: Vector2) -> void:
	if last_frame_size.x <= 0 or last_frame_size.y <= 0:
		_set_result_text("No valid video frame yet.")
		return

	var image_position := _texture_local_to_image_position(local_position, last_frame_size)
	if image_position == INVALID_IMAGE_POSITION:
		_set_result_text("Click inside the displayed video image.")
		return

	var projection := _project_video_point(image_position, last_frame_size, float(depth_input.value), last_frame_id)
	if projection.has("error"):
		_reset_selection(true)
		_set_result_text(str(projection["error"]))
		return

	var uv: Vector2 = projection.get("uv", Vector2.ZERO)
	var ray_origin: Vector3 = projection.get("camera_position", Vector3.ZERO)
	var ray_direction: Vector3 = projection.get("ray_direction", Vector3.FORWARD)
	var z_per_ray_meter: float = float(projection.get("camera_z_per_ray_meter", 1.0))

	has_selection = true
	depth_manual_revision += 1
	selected_image_position = image_position
	selected_frame_id = last_frame_id
	selected_frame_size = last_frame_size
	selected_depth_m = float(projection.get("depth_m", depth_input.value))
	selected_uv = uv
	selected_ray_origin = ray_origin
	selected_ray_direction = ray_direction.normalized()
	if z_per_ray_meter < MIN_RAY_Z_FACTOR:
		z_per_ray_meter = MIN_RAY_Z_FACTOR
	selected_camera_z_per_ray_meter = z_per_ray_meter
	selected_camera_name = str(projection.get("camera_name", ""))
	selected_camera_path = str(projection.get("camera_path", ""))
	selected_depth_source = "pending_depth_pro"
	selection_depth_ready = false
	depth_prediction_status_text = ""
	_update_click_marker_position()
	_request_depth_prediction()


func _on_depth_input_changed(value: float) -> void:
	selected_depth_m = float(value)
	selected_depth_source = "manual"
	selection_depth_ready = true
	depth_prediction_status_text = "DepthPredict=manual depth %.2fm" % selected_depth_m
	depth_manual_revision += 1
	if has_selection:
		_recompute_selection()


func _adjust_selection_depth(delta_meters: float) -> void:
	if not has_selection:
		return

	selected_depth_m = clamp(
		selected_depth_m + delta_meters,
		float(depth_input.min_value),
		float(depth_input.max_value)
	)
	selected_depth_source = "manual"
	selection_depth_ready = true
	depth_prediction_status_text = "DepthPredict=manual depth %.2fm" % selected_depth_m
	depth_manual_revision += 1
	depth_input.set_value_no_signal(selected_depth_m)
	_recompute_selection()


func _request_depth_prediction() -> void:
	if depth_prediction_request == null:
		depth_prediction_status_text = "DepthPredict=unavailable: no HTTPRequest"
		_recompute_selection()
		return
	if last_frame_jpeg_bytes.is_empty():
		depth_prediction_status_text = "DepthPredict=unavailable: no JPEG frame"
		_recompute_selection()
		return

	var http_status := depth_prediction_request.get_http_client_status()
	if http_status != HTTPClient.STATUS_DISCONNECTED:
		depth_prediction_request.cancel_request()

	depth_prediction_request_id += 1
	pending_depth_prediction_request_id = depth_prediction_request_id
	pending_depth_prediction_frame_id = selected_frame_id
	pending_depth_prediction_revision = depth_manual_revision
	depth_prediction_status_text = "DepthPredict=requesting %s..." % depth_prediction_endpoint
	_set_status("Depth prediction requested")

	var body := {
		"request_id": pending_depth_prediction_request_id,
		"image_jpeg_base64": Marshalls.raw_to_base64(last_frame_jpeg_bytes),
		"x": selected_image_position.x,
		"y": selected_image_position.y,
		"patch_radius": DEPTH_PREDICTION_PATCH_RADIUS,
		"min_depth_m": float(depth_input.min_value),
		"max_depth_m": float(depth_input.max_value),
	}
	var headers := PackedStringArray(["Content-Type: application/json"])
	var error := depth_prediction_request.request(
		depth_prediction_endpoint,
		headers,
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		pending_depth_prediction_request_id = -1
		depth_prediction_status_text = "DepthPredict=request failed: %s" % error_string(error)
	_recompute_selection()


func _on_depth_prediction_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	var request_id := pending_depth_prediction_request_id
	pending_depth_prediction_request_id = -1
	if request_id < 0:
		return
	if not has_selection or pending_depth_prediction_frame_id != selected_frame_id:
		return
	if pending_depth_prediction_revision != depth_manual_revision:
		depth_prediction_status_text = "DepthPredict=ignored after manual edit"
		_recompute_selection()
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		depth_prediction_status_text = "DepthPredict=HTTP error %d" % result
		_set_status(depth_prediction_status_text)
		_recompute_selection()
		return

	var json := JSON.new()
	var parse_error := json.parse(body.get_string_from_utf8())
	if parse_error != OK or typeof(json.data) != TYPE_DICTIONARY:
		depth_prediction_status_text = "DepthPredict=invalid response HTTP %d" % response_code
		_set_status(depth_prediction_status_text)
		_recompute_selection()
		return

	var response: Dictionary = json.data
	if int(response.get("request_id", request_id)) != request_id:
		return
	if response_code < 200 or response_code >= 300:
		var service_error := str(response.get("error", "HTTP %d" % response_code))
		depth_prediction_status_text = "DepthPredict=service error: %s" % service_error
		_set_status(depth_prediction_status_text)
		push_warning(depth_prediction_status_text)
		_recompute_selection()
		return
	if not bool(response.get("ok", false)):
		depth_prediction_status_text = "DepthPredict=unavailable: %s" % str(response.get("error", "unknown"))
		_set_status(depth_prediction_status_text)
		push_warning(depth_prediction_status_text)
		_recompute_selection()
		return

	var camera_z_depth_m := float(response.get("depth_m", 0.0))
	if camera_z_depth_m <= 0.0:
		depth_prediction_status_text = "DepthPredict=invalid depth"
		_set_status(depth_prediction_status_text)
		_recompute_selection()
		return

	var z_per_ray_meter := selected_camera_z_per_ray_meter
	if z_per_ray_meter < MIN_RAY_Z_FACTOR:
		z_per_ray_meter = MIN_RAY_Z_FACTOR
	var predicted_ray_depth_m := camera_z_depth_m / z_per_ray_meter
	predicted_ray_depth_m = clamp(
		predicted_ray_depth_m,
		float(depth_input.min_value),
		float(depth_input.max_value)
	)
	selected_depth_m = predicted_ray_depth_m
	selected_depth_source = "depth_pro"
	selection_depth_ready = true
	depth_input.set_value_no_signal(selected_depth_m)
	depth_prediction_status_text = "DepthPredict=%.2fm z, %.2fm ray (%s)" % [
		camera_z_depth_m,
		predicted_ray_depth_m,
		str(response.get("model", "depth_pro")),
	]
	_set_status(depth_prediction_status_text)
	_recompute_selection()


func _recompute_selection() -> void:
	if not has_selection:
		return

	if not selection_depth_ready:
		current_projection = {}
		confirm_button.disabled = true
		_hide_local_preview_marker()
		_clear_remote_preview()
		_set_result_text(_build_pending_selection_text())
		return

	var projection := _build_projection_from_selection()
	current_projection = projection
	if projection.has("error"):
		confirm_button.disabled = true
		_hide_local_preview_marker()
		_clear_remote_preview()
		_set_result_text(str(projection["error"]))
		return

	confirm_button.disabled = false
	var position: Vector3 = projection.get("position", Vector3.ZERO)
	_update_local_preview_marker(position)
	_send_remote_preview(position, projection)
	_set_result_text(_build_projection_text(projection))


func _project_video_point(image_position: Vector2, frame_size: Vector2i, depth_m: float, frame_id: int = -1) -> Dictionary:
	var camera := _get_reference_camera()
	if camera == null:
		return {"error": "No virtual reference camera found."}
	if frame_size.x <= 0 or frame_size.y <= 0:
		return {"error": "Invalid video frame size."}

	var uv := Vector2(
		image_position.x / float(frame_size.x),
		image_position.y / float(frame_size.y)
	)
	var ray := _project_virtual_camera_ray(camera, uv, frame_size)
	if ray.has("error"):
		return ray

	var origin: Vector3 = ray.get("origin", camera.global_position)
	var direction: Vector3 = ray.get("direction", Vector3.FORWARD)
	direction = direction.normalized()
	var position := origin + direction * depth_m
	var projection_frame_id := frame_id if frame_id >= 0 else selected_frame_id
	return {
		"position": position,
		"camera_position": origin,
		"ray_direction": direction,
		"pixel": image_position,
		"uv": uv,
		"depth_m": depth_m,
		"camera_name": camera.name,
		"camera_path": str(camera.get_path()),
		"frame_id": projection_frame_id,
		"projection_aspect": float(ray.get("projection_aspect", 0.0)),
		"camera_z_per_ray_meter": float(ray.get("camera_z_per_ray_meter", 1.0)),
	}


func _project_virtual_camera_ray(camera: Camera3D, uv: Vector2, frame_size: Vector2i) -> Dictionary:
	if frame_size.x <= 0 or frame_size.y <= 0:
		return {"error": "Invalid video frame size."}

	var frame_height: float = float(frame_size.y)
	if frame_height < 1.0:
		frame_height = 1.0
	var aspect: float = float(frame_size.x) / frame_height
	var safe_aspect: float = aspect
	if safe_aspect < 0.0001:
		safe_aspect = 0.0001

	var ndc := Vector2(
		uv.x * 2.0 - 1.0,
		1.0 - uv.y * 2.0
	)
	var camera_transform := camera.global_transform

	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		var view_width: float = camera.size * safe_aspect
		var view_height: float = camera.size
		if camera.keep_aspect == Camera3D.KEEP_WIDTH:
			view_width = camera.size
			view_height = camera.size / safe_aspect

		var local_origin := Vector3(
			ndc.x * view_width * 0.5,
			ndc.y * view_height * 0.5,
			0.0
		)
		return {
			"origin": camera_transform.origin + camera_transform.basis * local_origin,
			"direction": (camera_transform.basis * Vector3.FORWARD).normalized(),
			"projection_aspect": aspect,
			"camera_z_per_ray_meter": 1.0,
		}

	var half_fov_tan: float = tan(deg_to_rad(camera.fov) * 0.5)
	var half_width_tan: float = half_fov_tan * safe_aspect
	var half_height_tan: float = half_fov_tan
	if camera.keep_aspect == Camera3D.KEEP_WIDTH:
		half_width_tan = half_fov_tan
		half_height_tan = half_fov_tan / safe_aspect

	var local_ray := Vector3(
		ndc.x * half_width_tan,
		ndc.y * half_height_tan,
		-1.0
	).normalized()
	return {
		"origin": camera_transform.origin,
		"direction": (camera_transform.basis * local_ray).normalized(),
		"projection_aspect": aspect,
		"camera_z_per_ray_meter": -local_ray.z,
	}


func _build_projection_from_selection() -> Dictionary:
	if selected_frame_size.x <= 0 or selected_frame_size.y <= 0:
		return {"error": "Invalid selected frame size."}
	if selected_ray_direction.length_squared() <= 0.0:
		return {"error": "Invalid selected ray."}

	var direction := selected_ray_direction.normalized()
	var position := selected_ray_origin + direction * selected_depth_m
	return {
		"position": position,
		"camera_position": selected_ray_origin,
		"ray_direction": direction,
		"pixel": selected_image_position,
		"uv": selected_uv,
		"depth_m": selected_depth_m,
		"camera_name": selected_camera_name,
		"camera_path": selected_camera_path,
		"frame_id": selected_frame_id,
		"projection_aspect": _get_frame_aspect(selected_frame_size),
		"camera_z_per_ray_meter": selected_camera_z_per_ray_meter,
		"depth_source": selected_depth_source,
	}


func _get_frame_aspect(frame_size: Vector2i) -> float:
	var frame_height: float = float(frame_size.y)
	if frame_height < 1.0:
		frame_height = 1.0
	return float(frame_size.x) / frame_height


func _get_reference_camera() -> Camera3D:
	var root := get_tree().current_scene
	if root == null:
		return null

	var preview_camera := root.get_node_or_null(PREVIEW_CAMERA_PATH) as Camera3D
	if preview_camera != null:
		return preview_camera

	var exported_preview_camera := root.get("subUI") as Camera3D
	if exported_preview_camera != null:
		return exported_preview_camera

	var xr_camera := root.find_child("XRCamera3D", true, false) as Camera3D
	if xr_camera != null:
		return xr_camera

	var viewport_camera := get_viewport().get_camera_3d()
	if viewport_camera != null:
		return viewport_camera

	return root.find_child("SpectatorCamera", true, false) as Camera3D


func _confirm_current_point() -> void:
	if not has_selection:
		_set_result_text("Left click a video point first.")
		return
	if current_projection.is_empty() or current_projection.has("error"):
		_recompute_selection()
	if current_projection.is_empty() or current_projection.has("error"):
		return

	var position: Vector3 = current_projection.get("position", Vector3.ZERO)
	var confirmed_depth_m: float = float(current_projection.get("depth_m", selected_depth_m))
	var confirmed_depth_source: String = str(current_projection.get("depth_source", selected_depth_source))
	var confirmed_depth_text := depth_prediction_status_text
	if confirmed_depth_text == "":
		confirmed_depth_text = "DepthPredict=confirmed %.2fm (%s)" % [
			confirmed_depth_m,
			confirmed_depth_source,
		]
	confirmed_point_count += 1
	_add_local_confirmed_marker(position)
	_send_confirmed_point(position, current_projection)
	_clear_remote_preview()
	_reset_selection(true)
	_set_result_text(confirmed_depth_text)


func _reset_selection(clear_text_only: bool) -> void:
	has_selection = false
	selected_image_position = INVALID_IMAGE_POSITION
	selected_frame_id = -1
	selected_frame_size = Vector2i.ZERO
	selected_depth_m = float(depth_input.value) if depth_input != null else DEFAULT_CLICK_DEPTH_METERS
	selected_uv = Vector2.ZERO
	selected_ray_origin = Vector3.ZERO
	selected_ray_direction = Vector3.FORWARD
	selected_camera_z_per_ray_meter = 1.0
	selected_camera_name = ""
	selected_camera_path = ""
	selected_depth_source = "manual"
	selection_depth_ready = false
	depth_prediction_status_text = ""
	pending_depth_prediction_request_id = -1
	current_projection = {}
	if confirm_button != null:
		confirm_button.disabled = true
	if click_marker != null:
		click_marker.visible = false
	_hide_local_preview_marker()
	_clear_remote_preview()
	if result_label != null and not clear_text_only:
		_set_result_text("Left click to preview. Mouse wheel changes depth. Right click confirms.")


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


func _update_local_preview_marker(position: Vector3) -> void:
	var root := _get_marker_root()
	if root == null:
		return

	if preview_marker == null or not is_instance_valid(preview_marker):
		preview_marker = _create_marker_mesh(Color(0.2, 1.0, 0.25, 1.0), PREVIEW_MARKER_RADIUS)
		preview_marker.name = "PreviewSpatialCalibrationPoint"
		root.add_child(preview_marker)
	preview_marker.global_position = position
	preview_marker.visible = true


func _hide_local_preview_marker() -> void:
	if preview_marker != null and is_instance_valid(preview_marker):
		preview_marker.visible = false


func _add_local_confirmed_marker(position: Vector3) -> void:
	var root := _get_marker_root()
	if root == null:
		return

	var marker := _create_marker_mesh(Color(1.0, 0.08, 0.03, 1.0), CONFIRMED_MARKER_RADIUS)
	marker.name = "SpatialCalibrationPoint%d" % confirmed_point_count
	root.add_child(marker)
	marker.global_position = position
	marker.visible = true


func _create_marker_mesh(color: Color, radius: float) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	marker.mesh = mesh
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.set_surface_override_material(0, _make_marker_material(color))
	return marker


func _make_marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	return material


func _send_remote_preview(position: Vector3, projection: Dictionary) -> void:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler == null or not network_handler.has_method("send_spatial_calibration_preview"):
		return

	network_handler.send_spatial_calibration_preview(position, _build_marker_payload(
		projection,
		Color(0.2, 1.0, 0.25, 1.0),
		PREVIEW_MARKER_RADIUS,
		"spatial_calibration_preview"
	))


func _clear_remote_preview() -> void:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler != null and network_handler.has_method("clear_spatial_calibration_preview"):
		network_handler.clear_spatial_calibration_preview()


func _send_confirmed_point(position: Vector3, projection: Dictionary) -> void:
	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler == null or not network_handler.has_method("send_remote_annotation"):
		_set_status("NetworkHandler unavailable; point is local only")
		return

	network_handler.send_remote_annotation(position, _build_marker_payload(
		projection,
		Color(1.0, 0.08, 0.03, 1.0),
		CONFIRMED_MARKER_RADIUS,
		"spatial_calibration"
	))
	_set_status("Synced calibration point #%d" % confirmed_point_count)


func _build_marker_payload(
	projection: Dictionary,
	color: Color,
	size: float,
	source: String,
) -> Dictionary:
	var pixel: Vector2 = projection.get("pixel", Vector2.ZERO)
	var uv: Vector2 = projection.get("uv", Vector2.ZERO)
	return {
		"source": source,
		"frame_id": int(projection.get("frame_id", selected_frame_id)),
		"frame_timestamp_ns": last_frame_timestamp_ns,
		"depth_m": float(projection.get("depth_m", selected_depth_m)),
		"depth_source": str(projection.get("depth_source", selected_depth_source)),
		"projection_aspect": float(projection.get("projection_aspect", 0.0)),
		"pixel": [pixel.x, pixel.y],
		"uv": [uv.x, uv.y],
		"camera_name": str(projection.get("camera_name", "")),
		"camera_path": str(projection.get("camera_path", "")),
		"color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a},
		"size": size,
		"lifetime": 0.0,
	}


func _clear_confirmed_points() -> void:
	if marker_root != null and is_instance_valid(marker_root):
		for child in marker_root.get_children():
			child.queue_free()
	preview_marker = null
	confirmed_point_count = 0
	_reset_selection(true)

	var network_handler := get_node_or_null("/root/NetworkHandler")
	if network_handler != null and network_handler.has_method("clear_all_remote_annotations"):
		network_handler.clear_all_remote_annotations()
	_set_status("Cleared spatial calibration points")


func _update_click_marker_position() -> void:
	if not has_selection:
		click_marker.visible = false
		return

	var local_position := _image_position_to_texture_local(selected_image_position, selected_frame_size)
	if local_position == INVALID_IMAGE_POSITION:
		click_marker.visible = false
		return

	click_marker.position = local_position - CLICK_MARKER_SIZE * 0.5
	click_marker.size = CLICK_MARKER_SIZE
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
		image_position.y / float(reference_image_size.y)
	)
	return displayed_rect.position + displayed_rect.size * uv


func _build_pending_selection_text() -> String:
	if depth_prediction_status_text != "":
		return depth_prediction_status_text
	return "DepthPredict=waiting for prediction"


func _build_projection_text(_projection: Dictionary) -> String:
	if depth_prediction_status_text != "":
		return depth_prediction_status_text
	return "DepthPredict=%.2fm (%s)" % [
		selected_depth_m,
		selected_depth_source,
	]


func _set_result_text(text: String) -> void:
	if result_label != null:
		result_label.text = text


func _refresh_addresses(port: int = DEFAULT_PORT) -> void:
	if address_label == null:
		return

	var addresses: Array[String] = []
	for address in IP.get_local_addresses():
		if "." in address and not address.begins_with("127.") and not address.begins_with("169.254."):
			addresses.append("%s:%d" % [address, port])

	if addresses.is_empty():
		address_label.text = "Local IPv4: not found"
	else:
		address_label.text = "Point Pico helper to: %s" % ", ".join(addresses)


func _update_fps_stats() -> void:
	var now_ms := Time.get_ticks_msec()
	if fps_tick_ms == 0:
		fps_tick_ms = now_ms
		return
	if now_ms - fps_tick_ms < 1000:
		return

	display_fps = frames_this_second * 1000.0 / float(now_ms - fps_tick_ms)
	decode_avg_ms_display = decode_time_accum_ms / float(max(1, decode_frames))
	dropped_frames_display = dropped_frames_this_second
	frames_this_second = 0
	decode_time_accum_ms = 0.0
	decode_frames = 0
	dropped_frames_this_second = 0
	fps_tick_ms = now_ms
	_refresh_stats()


func _refresh_stats() -> void:
	if stats_label == null:
		return

	var connection_text := "disconnected"
	if client != null and client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		connection_text = "connected"
	elif server.is_listening():
		connection_text = "listening"

	stats_label.text = "State: %s | Frame: %d | Size: %dx%d | FPS: %.1f | Dropped: %d | Decode avg: %.1fms" % [
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
	if DEBUG_LOGS:
		print("SpatialCalibration: %s" % text)


func _send_ack(frame_id: int) -> void:
	if client == null:
		return
	_write_u32_be(ack_buffer, 0, ACK_MAGIC_PAA1)
	_write_u32_be(ack_buffer, 4, frame_id)
	var error := client.put_data(ack_buffer)
	if error != OK:
		_disconnect_client("ACK failed: %s" % error_string(error))


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
		_set_status("Metadata JSON parse failed: %s" % error_string(error))
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
