extends Node3D

const RuntimeProfileScript = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const SOURCE_REFRESH_INTERVAL_MSEC: int = 250

@export var window_surface_path: NodePath = NodePath("WindowSurface")
@export var pico_cast_source_path: NodePath = NodePath("PicoCastViewSource")
@export var pico_cast_control_receiver_path: NodePath = NodePath("PicoCastControlReceiver")
@export var spatial_window_controller_path: NodePath = NodePath("SpatialWindowController")
@export_range(1, 20, 1) var capture_exclusion_visual_layer: int = 20

var _runtime_profile
var _window_surface: Node3D
var _spatial_window_controller: Node
var _panel: Node
var _view_source: Node
var _pico_cast_view_source: Node
var _pico_cast_control_receiver: Node
var _window_open: bool = true
var _source_started: bool = false
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
	_pico_cast_view_source = get_node_or_null(pico_cast_source_path)
	_pico_cast_control_receiver = get_node_or_null(pico_cast_control_receiver_path)
	_connect_pico_cast_receiver()
	_bind_panel()
	set_view_source(_pico_cast_view_source)
	refresh_profile()


func _exit_tree() -> void:
	_stop_pico_cast_receiver()
	_disconnect_pico_cast_receiver()
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
	if should_show:
		_start_pico_cast_receiver()
	else:
		_stop_pico_cast_receiver()
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
	if force or not _source_started:
		_source_started = true
		_view_source.call("start", 0)


func _stop_source() -> void:
	_source_started = false
	if _view_source != null and _view_source.has_method("stop"):
		_view_source.call("stop")


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
	_source_started = false


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


func _connect_pico_cast_receiver() -> void:
	if _pico_cast_control_receiver == null:
		return
	if _pico_cast_control_receiver.has_signal("session_changed") \
			and not _pico_cast_control_receiver.session_changed.is_connected(_on_pico_cast_session_changed):
		_pico_cast_control_receiver.session_changed.connect(_on_pico_cast_session_changed)
	if _pico_cast_control_receiver.has_signal("receiver_status_changed") \
			and not _pico_cast_control_receiver.receiver_status_changed.is_connected(
				_on_pico_cast_receiver_status_changed
			):
		_pico_cast_control_receiver.receiver_status_changed.connect(
			_on_pico_cast_receiver_status_changed
		)
	if _pico_cast_control_receiver.has_method("get_current_rtmp_url"):
		_on_pico_cast_session_changed(
			str(_pico_cast_control_receiver.call("get_current_rtmp_url")),
			_pico_cast_control_receiver.call("get_current_metadata") as Dictionary
		)
	if _pico_cast_control_receiver.has_method("get_status_message"):
		_on_pico_cast_receiver_status_changed(
			str(_pico_cast_control_receiver.call("get_status_message"))
		)


func _disconnect_pico_cast_receiver() -> void:
	if _pico_cast_control_receiver != null \
			and _pico_cast_control_receiver.has_signal("session_changed") \
			and _pico_cast_control_receiver.session_changed.is_connected(_on_pico_cast_session_changed):
		_pico_cast_control_receiver.session_changed.disconnect(_on_pico_cast_session_changed)
	if _pico_cast_control_receiver != null \
			and _pico_cast_control_receiver.has_signal("receiver_status_changed") \
			and _pico_cast_control_receiver.receiver_status_changed.is_connected(
				_on_pico_cast_receiver_status_changed
			):
		_pico_cast_control_receiver.receiver_status_changed.disconnect(
			_on_pico_cast_receiver_status_changed
		)


func _start_pico_cast_receiver() -> void:
	if _pico_cast_control_receiver != null \
			and _pico_cast_control_receiver.has_method("start_receiver"):
		_pico_cast_control_receiver.call("start_receiver")


func _stop_pico_cast_receiver() -> void:
	if _pico_cast_control_receiver != null \
			and _pico_cast_control_receiver.has_method("stop_receiver"):
		_pico_cast_control_receiver.call("stop_receiver")


func _on_pico_cast_session_changed(rtmp_url: String, metadata: Dictionary) -> void:
	if _pico_cast_view_source != null and _pico_cast_view_source.has_method("set_cast_session"):
		_pico_cast_view_source.call("set_cast_session", rtmp_url, metadata)


func _on_pico_cast_receiver_status_changed(message: String) -> void:
	if _pico_cast_view_source != null and _pico_cast_view_source.has_method("set_control_status"):
		_pico_cast_view_source.call("set_control_status", message)


func _apply_capture_exclusion_layer(node: Node) -> void:
	var layer_mask := 1 << (capture_exclusion_visual_layer - 1)
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer_mask
	for child in node.get_children():
		_apply_capture_exclusion_layer(child)
