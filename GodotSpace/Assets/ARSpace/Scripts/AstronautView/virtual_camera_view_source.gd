extends "res://Assets/ARSpace/Scripts/AstronautView/astronaut_view_source.gd"

const SERVER_PEER_ID: int = 1
const CAMERA_VISUAL_LAYER_COUNT: int = 20
const DEFAULT_EXCLUDED_VISUAL_LAYER: int = 20
const SOURCE_RESOLVE_INTERVAL_MSEC: int = 200
const METADATA_UPDATE_INTERVAL_MSEC: int = 1000

@export var capture_resolution: Vector2i = Vector2i(960, 540)
@export_range(1, CAMERA_VISUAL_LAYER_COUNT, 1) var excluded_visual_layer: int = DEFAULT_EXCLUDED_VISUAL_LAYER
@export_range(1.0, 179.0, 0.1) var fallback_fov_degrees: float = 75.0
@export_range(250, 10000, 50) var pose_stall_timeout_msec: int = 2000

var _source_peer_id: int = 0
var _source_player: Node
var _source_head: Node3D
var _capture_viewport: SubViewport
var _capture_camera: Camera3D
var _next_resolve_msec: int = 0
var _next_metadata_msec: int = 0
var _last_frame_usec: int = 0
var _latest_frame_time_usec: int = 0
var _original_visual_layers: Dictionary = {}


func _ready() -> void:
	_ensure_capture_nodes()
	process_priority = 100
	set_process(false)


func _exit_tree() -> void:
	_restore_source_visual_layers()


func start(source_peer_id: int) -> void:
	if source_peer_id <= SERVER_PEER_ID:
		stop()
		_publish_status(Status.ERROR, "无效的天上端来源")
		return
	_ensure_capture_nodes()
	if _capture_viewport == null or _capture_camera == null:
		_publish_status(Status.ERROR, "第一视角渲染器初始化失败")
		return

	if _source_peer_id != source_peer_id:
		_restore_source_visual_layers()
		_source_player = null
		_source_head = null
	_source_peer_id = source_peer_id
	_capture_viewport.size = capture_resolution
	_capture_viewport.world_3d = get_viewport().find_world_3d()
	_capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_capture_camera.cull_mask = _make_capture_cull_mask()
	_capture_camera.fov = fallback_fov_degrees
	_capture_camera.make_current()
	_next_resolve_msec = 0
	_next_metadata_msec = 0
	_last_frame_usec = Time.get_ticks_usec()
	set_process(true)
	_publish_status(Status.CONNECTING, "正在等待天上端玩家视点")
	_resolve_source_nodes()


func stop() -> void:
	set_process(false)
	_restore_source_visual_layers()
	_source_peer_id = 0
	_source_player = null
	_source_head = null
	if _capture_viewport != null:
		_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_capture_viewport.world_3d = null
	if _capture_camera != null:
		_capture_camera.current = false
	_publish_texture(null)
	_publish_metadata({})
	_publish_status(Status.IDLE, "")


func get_texture() -> Texture2D:
	if _capture_viewport == null or _source_head == null:
		return null
	return _capture_viewport.get_texture()


func get_source_peer_id() -> int:
	return _source_peer_id


func get_capture_camera() -> Camera3D:
	return _capture_camera


func get_capture_viewport() -> SubViewport:
	return _capture_viewport


func _process(_delta: float) -> void:
	if _source_peer_id <= SERVER_PEER_ID:
		return
	if not _source_is_available():
		var now_msec := Time.get_ticks_msec()
		if now_msec >= _next_resolve_msec:
			_next_resolve_msec = now_msec + SOURCE_RESOLVE_INTERVAL_MSEC
			_resolve_source_nodes()
		return

	_capture_camera.global_transform = _source_head.global_transform
	_update_camera_projection()
	var now_usec := Time.get_ticks_usec()
	_latest_frame_time_usec = now_usec - _last_frame_usec if _last_frame_usec > 0 else 0
	_last_frame_usec = now_usec
	if _source_player.has_method("get_last_network_pose_received_msec"):
		var last_pose_msec := int(_source_player.call("get_last_network_pose_received_msec"))
		if last_pose_msec > 0 \
				and Time.get_ticks_msec() - last_pose_msec > pose_stall_timeout_msec:
			_publish_status(Status.STALLED, "天上端位姿暂时中断")
		else:
			_publish_status(Status.LIVE, "天上端第一视角")
	_update_metadata()


func _ensure_capture_nodes() -> void:
	_capture_viewport = get_node_or_null("CaptureViewport") as SubViewport
	if _capture_viewport == null:
		_capture_viewport = SubViewport.new()
		_capture_viewport.name = "CaptureViewport"
		_capture_viewport.size = capture_resolution
		_capture_viewport.handle_input_locally = false
		add_child(_capture_viewport)

	_capture_camera = _capture_viewport.get_node_or_null("Camera3D") as Camera3D
	if _capture_camera == null:
		_capture_camera = Camera3D.new()
		_capture_camera.name = "Camera3D"
		_capture_viewport.add_child(_capture_camera)
	_capture_camera.cull_mask = _make_capture_cull_mask()
	_capture_camera.fov = fallback_fov_degrees


func _resolve_source_nodes() -> void:
	var player := _find_player_node(_source_peer_id)
	var head := player.call("get_network_viewpoint") as Node3D \
		if player != null and player.has_method("get_network_viewpoint") \
		else player.get_node_or_null("NetworkHead") as Node3D if player != null else null
	var has_received_pose := bool(player.call("has_received_network_pose")) \
		if player != null and player.has_method("has_received_network_pose") \
		else head != null and head.visible
	if player == null or head == null or not head.is_inside_tree() or not has_received_pose:
		var was_live := get_status() in [Status.LIVE, Status.STALLED]
		_restore_source_visual_layers()
		_source_player = null
		_source_head = null
		_publish_texture(null)
		_publish_status(
			Status.STALLED if was_live else Status.CONNECTING,
			"天上端视点暂不可用" if was_live else "正在等待天上端玩家视点"
		)
		return

	_restore_source_visual_layers()
	_source_player = player
	_source_head = head
	_exclude_source_avatar_from_capture()
	_exclude_local_presentation_from_capture()
	_capture_camera.global_transform = _source_head.global_transform
	_update_camera_projection()
	_publish_texture(_capture_viewport.get_texture())
	_publish_status(Status.LIVE, "天上端第一视角")
	_update_metadata(true)


func _find_player_node(peer_id: int) -> Node:
	if peer_id <= SERVER_PEER_ID or get_tree() == null:
		return null
	var current_scene := get_tree().current_scene
	if current_scene != null:
		var direct_player := current_scene.get_node_or_null(str(peer_id))
		if direct_player != null:
			return direct_player
	return get_tree().root.find_child(str(peer_id), true, false)


func _source_is_available() -> bool:
	return _source_player != null \
		and is_instance_valid(_source_player) \
		and _source_player.is_inside_tree() \
		and _source_head != null \
		and is_instance_valid(_source_head) \
		and _source_head.is_inside_tree()


func _update_camera_projection() -> void:
	if _capture_camera == null:
		return
	var source_camera := _source_player.get_node_or_null("XROrigin3D/XRCamera3D") as Camera3D \
		if _source_player != null else null
	if source_camera == null:
		_capture_camera.fov = fallback_fov_degrees
		return
	_capture_camera.projection = source_camera.projection
	_capture_camera.fov = source_camera.fov
	_capture_camera.size = source_camera.size
	_capture_camera.near = source_camera.near
	_capture_camera.far = source_camera.far


func _update_metadata(force: bool = false) -> void:
	var now_msec := Time.get_ticks_msec()
	if not force and now_msec < _next_metadata_msec:
		return
	_next_metadata_msec = now_msec + METADATA_UPDATE_INTERVAL_MSEC
	_publish_metadata({
		"source_type": "virtual_camera",
		"source_name": "天上端 %d" % _source_peer_id,
		"peer_id": _source_peer_id,
		"resolution": capture_resolution,
		"aspect_ratio": float(capture_resolution.x) / float(maxi(capture_resolution.y, 1)),
		"frame_time_usec": _latest_frame_time_usec,
		"timestamp_msec": now_msec,
		"fov_degrees": _capture_camera.fov if _capture_camera != null else fallback_fov_degrees,
		"color_space": "srgb",
		"rotation_degrees": 0,
		"calibration_version": "",
	})


func _exclude_source_avatar_from_capture() -> void:
	if _source_player == null:
		return
	var exclusion_mask := 1 << (excluded_visual_layer - 1)
	for branch_name in ["NetworkHead", "NetworkLeftHand", "NetworkRightHand", "NetworkTorso"]:
		var branch := _source_player.get_node_or_null(branch_name)
		if branch != null:
			_set_visual_layer_recursive(branch, exclusion_mask)


func _exclude_local_presentation_from_capture() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var local_player := _find_player_node(multiplayer.get_unique_id())
	if local_player == null or local_player == _source_player:
		return
	var exclusion_mask := 1 << (excluded_visual_layer - 1)
	var xr_origin := local_player.get_node_or_null("XROrigin3D")
	if xr_origin != null:
		_set_visual_layer_recursive(xr_origin, exclusion_mask)


func _set_visual_layer_recursive(node: Node, layer_mask: int) -> void:
	if node is VisualInstance3D:
		var visual := node as VisualInstance3D
		if not _original_visual_layers.has(visual):
			_original_visual_layers[visual] = visual.layers
		visual.layers = layer_mask
	for child in node.get_children():
		_set_visual_layer_recursive(child, layer_mask)


func _restore_source_visual_layers() -> void:
	for visual_value in _original_visual_layers:
		var visual := visual_value as VisualInstance3D
		if visual != null and is_instance_valid(visual):
			visual.layers = int(_original_visual_layers[visual_value])
	_original_visual_layers.clear()


func _make_capture_cull_mask() -> int:
	var all_layers := (1 << CAMERA_VISUAL_LAYER_COUNT) - 1
	return all_layers & ~(1 << (excluded_visual_layer - 1))
