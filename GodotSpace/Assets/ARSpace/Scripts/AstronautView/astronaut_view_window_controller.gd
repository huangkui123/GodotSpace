extends Node3D

const RuntimeProfileScript = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const AstronautViewSourceScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/astronaut_view_source.gd"
)
const SERVER_PEER_ID: int = 1
const SOURCE_REFRESH_INTERVAL_MSEC: int = 250

@export var network_handler_path: NodePath = NodePath("/root/NetworkHandler")
@export var window_surface_path: NodePath = NodePath("WindowSurface")
@export var default_source_path: NodePath = NodePath("VirtualCameraViewSource")
@export var spatial_window_controller_path: NodePath = NodePath("SpatialWindowController")
@export_range(1, 20, 1) var capture_exclusion_visual_layer: int = 20

var _runtime_profile
var _network_handler: Node
var _window_surface: Node3D
var _spatial_window_controller: Node
var _panel: Node
var _view_source: Node
var _window_open: bool = true
var _bound_sky_peer_id: int = 0
var _next_source_refresh_msec: int = 0
var _default_surface_transform: Transform3D = Transform3D.IDENTITY
var _source_generation: int = 0
var _texture_callback: Callable
var _status_callback: Callable
var _metadata_callback: Callable


func _ready() -> void:
	_window_surface = get_node_or_null(window_surface_path) as Node3D
	_spatial_window_controller = get_node_or_null(spatial_window_controller_path)
	if _window_surface != null:
		_default_surface_transform = _window_surface.transform
		_apply_capture_exclusion_layer(_window_surface)
	_network_handler = get_node_or_null(network_handler_path)
	_connect_network_signals()
	_bind_panel()
	set_view_source(get_node_or_null(default_source_path))
	refresh_profile()


func _exit_tree() -> void:
	_disconnect_network_signals()
	_disconnect_source()


func _process(_delta: float) -> void:
	var now_msec := Time.get_ticks_msec()
	if now_msec < _next_source_refresh_msec:
		return
	_next_source_refresh_msec = now_msec + SOURCE_REFRESH_INTERVAL_MSEC
	_refresh_source_binding()


func refresh_profile() -> void:
	_runtime_profile = RuntimeProfileScript.current()
	var should_show := _profile_shows_astronaut_view()
	visible = should_show
	if should_show and _window_open:
		if _spatial_window_controller != null:
			_spatial_window_controller.call("open_window", null, false)
		elif _window_surface != null:
			_window_surface.visible = true
		_refresh_source_binding(true)
	else:
		if _spatial_window_controller != null:
			_spatial_window_controller.call("close_window")
		elif _window_surface != null:
			_window_surface.visible = false
		_stop_source()


func set_view_source(source: Node) -> bool:
	if source == _view_source:
		return source != null
	if source != null and not _is_valid_view_source(source):
		push_error("Astronaut view source does not implement the required contract.")
		return false
	_disconnect_source()
	_view_source = source
	_source_generation += 1
	if _view_source != null:
		if _has_property(_view_source, "excluded_visual_layer"):
			_view_source.set("excluded_visual_layer", capture_exclusion_visual_layer)
		_connect_source(_view_source, _source_generation)
	_refresh_source_binding(true)
	return _view_source != null


func get_view_source() -> Node:
	return _view_source


func get_panel() -> Node:
	return _panel


func get_bound_sky_peer_id() -> int:
	return _bound_sky_peer_id


func is_window_open() -> bool:
	if _spatial_window_controller != null:
		return _window_open and bool(_spatial_window_controller.call("is_window_open"))
	return _window_open


func open_window() -> void:
	_window_open = true
	_runtime_profile = RuntimeProfileScript.current()
	if _profile_shows_astronaut_view() and _spatial_window_controller != null:
		_spatial_window_controller.call("open_window", null, true)
		_refresh_source_binding(true)
	else:
		refresh_profile()


func close_window() -> void:
	_window_open = false
	if _spatial_window_controller != null:
		_spatial_window_controller.call("close_window")
	elif _window_surface != null:
		_window_surface.visible = false
	_stop_source()


func restore_window_position() -> void:
	if _spatial_window_controller != null:
		_spatial_window_controller.call("restore_window_position")
	elif _window_surface != null:
		_window_surface.transform = _default_surface_transform


func _profile_shows_astronaut_view() -> bool:
	if _runtime_profile == null or not _runtime_profile.is_valid():
		return false
	if _runtime_profile.has_method("shows_astronaut_view"):
		return bool(_runtime_profile.call("shows_astronaut_view"))
	return _runtime_profile.is_ground() and _runtime_profile.uses_xr()


func _refresh_source_binding(force: bool = false) -> void:
	if not _profile_shows_astronaut_view() or not _window_open or _view_source == null:
		return
	var sky_peer_id := _get_sky_peer_id()
	if multiplayer.has_multiplayer_peer() and sky_peer_id == multiplayer.get_unique_id():
		_stop_source()
		if _panel != null:
			_panel.call(
				"set_view_status",
				AstronautViewSourceScript.Status.ERROR,
				"天上端来源不能是本机"
			)
		return
	if sky_peer_id <= SERVER_PEER_ID:
		if force or _bound_sky_peer_id != 0:
			_stop_source()
			_set_panel_waiting()
		return
	if not force and sky_peer_id == _bound_sky_peer_id:
		return
	_bound_sky_peer_id = sky_peer_id
	_view_source.call("start", sky_peer_id)


func _stop_source() -> void:
	_bound_sky_peer_id = 0
	if _view_source != null and _view_source.has_method("stop"):
		_view_source.call("stop")


func _get_sky_peer_id() -> int:
	if _network_handler != null and _network_handler.has_method("get_sky_peer_id"):
		return int(_network_handler.call("get_sky_peer_id"))
	return 0


func _is_valid_view_source(source: Node) -> bool:
	for method_name in ["start", "stop", "get_texture", "get_status", "get_metadata"]:
		if not source.has_method(method_name):
			return false
	for signal_name in ["texture_changed", "status_changed", "metadata_changed"]:
		if not source.has_signal(signal_name):
			return false
	return true


func _has_property(object: Object, property_name: String) -> bool:
	for property_info in object.get_property_list():
		if str(property_info.get("name", "")) == property_name:
			return true
	return false


func _connect_source(source: Node, generation: int) -> void:
	_texture_callback = Callable(self, "_on_source_texture_changed").bind(generation)
	_status_callback = Callable(self, "_on_source_status_changed").bind(generation)
	_metadata_callback = Callable(self, "_on_source_metadata_changed").bind(generation)
	source.connect("texture_changed", _texture_callback)
	source.connect("status_changed", _status_callback)
	source.connect("metadata_changed", _metadata_callback)
	_on_source_texture_changed(source.call("get_texture") as Texture2D, generation)
	_on_source_status_changed(
		int(source.call("get_status")),
		str(source.call("get_status_message")) if source.has_method("get_status_message") else "",
		generation
	)
	_on_source_metadata_changed(source.call("get_metadata") as Dictionary, generation)


func _disconnect_source() -> void:
	if _view_source == null:
		return
	for signal_data in [
		["texture_changed", _texture_callback],
		["status_changed", _status_callback],
		["metadata_changed", _metadata_callback],
	]:
		var signal_name := str(signal_data[0])
		var callback := signal_data[1] as Callable
		if callback.is_valid() and _view_source.is_connected(signal_name, callback):
			_view_source.disconnect(signal_name, callback)
	if _view_source.has_method("stop"):
		_view_source.call("stop")
	_view_source = null


func _on_source_texture_changed(texture: Texture2D, generation: int) -> void:
	if generation != _source_generation or _panel == null:
		return
	_panel.call("set_view_texture", texture)


func _on_source_status_changed(status: int, message: String, generation: int) -> void:
	if generation != _source_generation or _panel == null:
		return
	_panel.call("set_view_status", status, message)


func _on_source_metadata_changed(metadata: Dictionary, generation: int) -> void:
	if generation != _source_generation or _panel == null:
		return
	_panel.call("set_view_metadata", metadata)


func _bind_panel() -> void:
	if _window_surface == null:
		return
	if _window_surface.has_method("get_scene_instance"):
		_panel = _window_surface.call("get_scene_instance") as Node
	if _panel == null:
		call_deferred("_bind_panel")
		return
	if _panel.has_signal("close_requested") \
			and not _panel.close_requested.is_connected(close_window):
		_panel.close_requested.connect(close_window)
	if _panel.has_signal("restore_requested") \
			and not _panel.restore_requested.is_connected(restore_window_position):
		_panel.restore_requested.connect(restore_window_position)
	if _view_source != null:
		_panel.call("set_view_texture", _view_source.call("get_texture"))
		_panel.call(
			"set_view_status",
			int(_view_source.call("get_status")),
			str(_view_source.call("get_status_message"))
		)
		_panel.call("set_view_metadata", _view_source.call("get_metadata"))


func _set_panel_waiting() -> void:
	if _panel == null:
		return
	_panel.call("set_view_texture", null)
	_panel.call("set_view_metadata", {})
	_panel.call(
		"set_view_status",
		AstronautViewSourceScript.Status.IDLE,
		"等待天上端连接"
	)


func _connect_network_signals() -> void:
	if _network_handler != null \
			and _network_handler.has_signal("peer_role_changed") \
			and not _network_handler.peer_role_changed.is_connected(_on_peer_role_changed):
		_network_handler.peer_role_changed.connect(_on_peer_role_changed)
	if not multiplayer.peer_connected.is_connected(_on_peer_connection_changed):
		multiplayer.peer_connected.connect(_on_peer_connection_changed)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_connection_changed):
		multiplayer.peer_disconnected.connect(_on_peer_connection_changed)


func _disconnect_network_signals() -> void:
	if _network_handler != null \
			and _network_handler.has_signal("peer_role_changed") \
			and _network_handler.peer_role_changed.is_connected(_on_peer_role_changed):
		_network_handler.peer_role_changed.disconnect(_on_peer_role_changed)
	if multiplayer.peer_connected.is_connected(_on_peer_connection_changed):
		multiplayer.peer_connected.disconnect(_on_peer_connection_changed)
	if multiplayer.peer_disconnected.is_connected(_on_peer_connection_changed):
		multiplayer.peer_disconnected.disconnect(_on_peer_connection_changed)


func _on_peer_role_changed(_peer_id: int, _assigned_role: String) -> void:
	_refresh_source_binding(true)


func _on_peer_connection_changed(_peer_id: int) -> void:
	_refresh_source_binding(true)


func _apply_capture_exclusion_layer(node: Node) -> void:
	var layer_mask := 1 << (capture_exclusion_visual_layer - 1)
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer_mask
	for child in node.get_children():
		_apply_capture_exclusion_layer(child)
