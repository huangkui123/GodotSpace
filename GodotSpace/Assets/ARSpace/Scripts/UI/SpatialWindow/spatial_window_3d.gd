class_name SpatialWindow3D
extends Node3D

## Business-owned 3D window shell. It deliberately does not depend on XR Tools RPCs.
## All transforms exposed to the registry are local to SharedSpaceOrigin.

signal close_requested(window_id: String)
signal maximize_changed(window_id: String, is_maximized: bool)
signal focus_changed(window_id: String, is_focused: bool)
signal size_changed(window_id: String, size_metres: Vector2)
signal state_commit_requested(window_id: String, state: Dictionary)
signal registry_registration_requested(window: SpatialWindow3D)
signal registry_unregistration_requested(window: SpatialWindow3D)

const STATE_NORMAL := "normal"
const STATE_MAXIMIZED := "maximized"
const STATE_SNAPPED := "snapped"
const STATE_CLOSED := "closed"
const HANDLE_NAMES: Array[String] = [
	"Top",
	"Bottom",
	"Left",
	"Right",
	"TopLeft",
	"TopRight",
	"BottomLeft",
	"BottomRight",
]

@export var window_id: String = "spatial_window"
@export var window_type: String = "generic"
@export var content_key: String = ""
@export_enum("unique", "multiple") var instance_policy: String = "unique"
@export var window_title: String = "Spatial Window"
@export var size_metres: Vector2 = Vector2(0.9, 0.55)
@export var minimum_size: Vector2 = Vector2(0.28, 0.18)
@export var maximum_size: Vector2 = Vector2(2.4, 1.5)
@export var maximized_size: Vector2 = Vector2(1.6, 0.95)
@export_range(0.035, 0.15, 0.005) var title_bar_height: float = 0.075
@export var preserve_aspect_ratio: bool = false
@export var registry_path: NodePath = NodePath("/root/SpatialWindowRegistryService")
@export var close_hides_window: bool = true

@onready var content_root: Node3D = $ContentRoot
@onready var title_label: Label3D = $TitleBar/TitleLabel
@onready var selected_outline: Node3D = $SelectedOutline
@onready var resize_handles: Node3D = $ResizeHandles

var state: String = STATE_NORMAL
var snap_slot: String = ""
var focus_order: int = 0
var _is_focused: bool = false
var _normal_size: Vector2
var _normal_transform: Transform3D
var _registry: Node
var _registered: bool = false
var _shared_origin: Node3D
var _local_interaction_active: bool = false


func _ready() -> void:
	add_to_group("spatial_window")
	_shared_origin = _resolve_shared_space_origin()
	_normal_size = clamp_size(size_metres)
	_normal_transform = get_shared_transform()
	size_metres = _normal_size
	if title_label != null and DisplayServer.get_name() != "headless":
		title_label.text = window_title
	_layout_window()
	set_focused(false)
	_bind_button($TitleBar/CloseButton, Callable(self, "request_close"))
	_bind_button($TitleBar/MaximizeButton, Callable(self, "toggle_maximized"))
	_register_with_service()


func _exit_tree() -> void:
	_unbind_registry_signals()
	if _registered and _registry != null and is_instance_valid(_registry) and _registry.has_method("unregister_window"):
		_registry.call("unregister_window", window_id)
	registry_unregistration_requested.emit(self)


func set_content(content: Node3D) -> void:
	if content == null:
		return
	if content.get_parent() != null:
		content.reparent(content_root, true)
	else:
		content_root.add_child(content)


func set_window_title(value: String) -> void:
	window_title = value.left(96)
	if title_label != null and DisplayServer.get_name() != "headless":
		title_label.text = window_title


func set_size_metres(value: Vector2, emit_commit: bool = true) -> bool:
	var next_size := clamp_size(value)
	if next_size.is_equal_approx(size_metres):
		return false
	size_metres = next_size
	if state == STATE_NORMAL:
		_normal_size = size_metres
	_layout_window()
	size_changed.emit(window_id, size_metres)
	if emit_commit:
		request_state_commit()
	return true


func resize_by(delta_size: Vector2, keep_aspect: bool = false, emit_commit: bool = true) -> bool:
	var next_size := size_metres + delta_size
	if keep_aspect or preserve_aspect_ratio:
		next_size = fit_aspect(next_size, get_aspect_ratio())
	return set_size_metres(next_size, emit_commit)


func clamp_size(value: Vector2) -> Vector2:
	return Vector2(
		clampf(value.x, minimum_size.x, maximum_size.x),
		clampf(value.y, minimum_size.y, maximum_size.y)
	)


func get_aspect_ratio() -> float:
	return size_metres.x / maxf(size_metres.y, 0.001)


static func fit_aspect(value: Vector2, aspect: float) -> Vector2:
	if aspect <= 0.001:
		return value
	var width_from_height := value.y * aspect
	var height_from_width := value.x / aspect
	if absf(width_from_height - value.x) <= absf(height_from_width - value.y):
		return Vector2(width_from_height, value.y)
	return Vector2(value.x, height_from_width)


func set_focused(value: bool, new_focus_order: int = -1) -> void:
	if new_focus_order >= 0:
		focus_order = new_focus_order
	if _is_focused == value:
		return
	_is_focused = value
	if selected_outline != null:
		selected_outline.visible = value
	if resize_handles != null:
		resize_handles.visible = value
	focus_changed.emit(window_id, value)


func is_focused() -> bool:
	return _is_focused


func set_local_interaction_active(value: bool) -> void:
	_local_interaction_active = value


func request_close() -> void:
	close_requested.emit(window_id)
	if _registry != null and is_instance_valid(_registry) and _is_network_session_active():
		_request_registry_operation("close")
	elif close_hides_window:
		visible = false


func toggle_maximized() -> void:
	set_maximized(state != STATE_MAXIMIZED)


func set_maximized(value: bool, emit_commit: bool = true) -> void:
	var target_mode := STATE_MAXIMIZED if value else STATE_NORMAL
	var target_size := clamp_size(maximized_size if value else _normal_size)
	if emit_commit and _registry != null and is_instance_valid(_registry) and _is_network_session_active():
		_request_registry_operation("set_mode", {
			"mode": target_mode,
			"size_m": target_size,
		})
		return
	if value and state != STATE_MAXIMIZED:
		_normal_size = size_metres
		_normal_transform = get_shared_transform()
		state = STATE_MAXIMIZED
		set_size_metres(maximized_size, false)
	elif not value and state == STATE_MAXIMIZED:
		state = STATE_NORMAL
		set_shared_transform(_normal_transform)
		set_size_metres(_normal_size, false)
	else:
		return
	maximize_changed.emit(window_id, state == STATE_MAXIMIZED)
	if emit_commit:
		request_state_commit()


func set_snap_slot(value: String, emit_commit: bool = true) -> void:
	var normalized := value.left(64)
	if snap_slot == normalized:
		return
	snap_slot = normalized
	if snap_slot.is_empty() and state == STATE_SNAPPED:
		state = STATE_NORMAL
	elif not snap_slot.is_empty():
		state = STATE_SNAPPED
	if emit_commit:
		request_state_commit()


func get_shared_transform() -> Transform3D:
	if _shared_origin != null and is_instance_valid(_shared_origin) and is_inside_tree():
		return _shared_origin.global_transform.affine_inverse() * global_transform
	return transform


func set_shared_transform(value: Transform3D) -> void:
	if _shared_origin != null and is_instance_valid(_shared_origin) and is_inside_tree():
		global_transform = _shared_origin.global_transform * value
	else:
		transform = value


func shared_to_global_transform(value: Transform3D) -> Transform3D:
	if _shared_origin != null and is_instance_valid(_shared_origin) and is_inside_tree():
		return _shared_origin.global_transform * value
	return value


func global_to_shared_transform(value: Transform3D) -> Transform3D:
	if _shared_origin != null and is_instance_valid(_shared_origin) and is_inside_tree():
		return _shared_origin.global_transform.affine_inverse() * value
	return value


func apply_authoritative_state(value: Dictionary) -> bool:
	if str(value.get("window_id", value.get("id", window_id))) != window_id:
		return false
	var incoming_transform = value.get("shared_transform", transform)
	var incoming_size = value.get("size_m", value.get("size", size_metres))
	if not incoming_transform is Transform3D or not incoming_size is Vector2:
		return false
	set_shared_transform(incoming_transform)
	var incoming_mode := str(value.get("mode", value.get("state", STATE_NORMAL)))
	state = incoming_mode if incoming_mode in [STATE_NORMAL, STATE_MAXIMIZED, STATE_SNAPPED, STATE_CLOSED] else STATE_NORMAL
	snap_slot = str(value.get("snap_slot", "")).left(64)
	focus_order = maxi(int(value.get("focus_order", 0)), 0)
	set_size_metres(incoming_size, false)
	visible = bool(value.get("visible", state != STATE_CLOSED)) and state != STATE_CLOSED
	return true


func get_window_state() -> Dictionary:
	return {
		"window_id": window_id,
		"shared_transform": get_shared_transform(),
		"size_m": size_metres,
		"mode": state,
		"visible": visible,
		"snap_slot": snap_slot,
		"focus_order": focus_order,
	}


func get_window_descriptor() -> Dictionary:
	return {
		"window_id": window_id,
		"window_type": window_type,
		"instance_policy": instance_policy,
		"content_key": content_key,
		"shared_transform": get_shared_transform(),
		"size_m": size_metres,
	}


func request_state_commit() -> void:
	var snapshot := get_window_state()
	state_commit_requested.emit(window_id, snapshot)


func _register_with_service() -> void:
	_registry = get_node_or_null(registry_path)
	if _registry == null:
		var candidates := get_tree().get_nodes_in_group("spatial_window_registry")
		if not candidates.is_empty():
			_registry = candidates[0]
	_bind_registry_signals()
	if _registry != null and _registry.has_method("get_window_state"):
		var current = _registry.call("get_window_state", window_id)
		if current is Dictionary and not (current as Dictionary).is_empty():
			apply_authoritative_state(current)
			registry_registration_requested.emit(self)
			return
	if _registry != null and _registry.has_method("register_window") and _is_local_server_authority():
		_registered = bool(_registry.call("register_window", get_window_descriptor()))
		if _registered and _registry.has_method("get_window_state"):
			var registered_state = _registry.call("get_window_state", window_id)
			if registered_state is Dictionary and not (registered_state as Dictionary).is_empty():
				apply_authoritative_state(registered_state)
	registry_registration_requested.emit(self)


func _request_registry_operation(operation: String, payload: Dictionary = {}) -> bool:
	if _registry == null or not is_instance_valid(_registry) or not _registry.has_method("request_operation"):
		return false
	return bool(_registry.call("request_operation", window_id, operation, payload))


func _bind_registry_signals() -> void:
	if _registry == null or not _registry.has_signal("window_state_changed"):
		return
	var callback := Callable(self, "_on_registry_window_state_changed")
	if not _registry.is_connected("window_state_changed", callback):
		_registry.connect("window_state_changed", callback)


func _unbind_registry_signals() -> void:
	if _registry == null or not is_instance_valid(_registry) or not _registry.has_signal("window_state_changed"):
		return
	var callback := Callable(self, "_on_registry_window_state_changed")
	if _registry.is_connected("window_state_changed", callback):
		_registry.disconnect("window_state_changed", callback)


func _on_registry_window_state_changed(changed_window_id: String, value: Dictionary) -> void:
	if changed_window_id != window_id:
		return
	if _local_interaction_active and str(value.get("mode", STATE_NORMAL)) != STATE_CLOSED:
		focus_order = maxi(int(value.get("focus_order", focus_order)), 0)
		return
	apply_authoritative_state(value)


func _resolve_shared_space_origin() -> Node3D:
	if not is_inside_tree():
		return null
	var candidates := get_tree().get_nodes_in_group("shared_space_origin")
	if candidates.size() == 1:
		return candidates[0] as Node3D
	return null


func _is_local_server_authority() -> bool:
	if not _is_network_session_active():
		return false
	return multiplayer.is_server() \
		and multiplayer.get_unique_id() == 1


func _is_network_session_active() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _bind_button(area: Area3D, callback: Callable) -> void:
	if area == null:
		return
	area.input_ray_pickable = true
	area.input_event.connect(func(_camera: Node, event: InputEvent, _position: Vector3, _normal: Vector3, _shape: int) -> void:
		var mouse_event := event as InputEventMouseButton
		if mouse_event != null and mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			callback.call()
	)


func _layout_window() -> void:
	if not is_node_ready():
		return
	var title_height := minf(title_bar_height, size_metres.y * 0.4)
	var content_height := maxf(size_metres.y - title_height, 0.04)
	_set_box($Surface, Vector3(size_metres.x, content_height, 0.018), Vector3(0.0, -title_height * 0.5, 0.0))
	_set_collision_box($SurfaceCollider/CollisionShape3D, Vector3(size_metres.x, content_height, 0.035))
	$SurfaceCollider.position = Vector3(0.0, -title_height * 0.5, 0.0)
	_set_box($TitleBar/Visual, Vector3(size_metres.x, title_height, 0.025), Vector3.ZERO)
	_set_collision_box($TitleBar/CollisionShape3D, Vector3(size_metres.x, title_height, 0.04))
	$TitleBar.position = Vector3(0.0, size_metres.y * 0.5 - title_height * 0.5, 0.006)
	$TitleBar/TitleLabel.position = Vector3(-size_metres.x * 0.45, 0.0, 0.025)
	$TitleBar/TitleLabel.font_size = 24
	var button_size := title_height * 0.62
	_layout_button($TitleBar/CloseButton, size_metres.x * 0.5 - button_size * 0.65, button_size)
	_layout_button($TitleBar/MaximizeButton, size_metres.x * 0.5 - button_size * 1.85, button_size)
	content_root.position = Vector3(0.0, -title_height * 0.5, 0.02)
	content_root.set_meta(&"content_size_metres", Vector2(size_metres.x, content_height))
	_layout_outline()
	_layout_resize_handles()


func _layout_button(area: Area3D, x_position: float, button_size: float) -> void:
	area.position = Vector3(x_position, 0.0, 0.025)
	_set_box(area.get_node("Visual") as MeshInstance3D, Vector3(button_size, button_size, 0.012), Vector3.ZERO)
	_set_collision_box(area.get_node("CollisionShape3D") as CollisionShape3D, Vector3(button_size, button_size, 0.025))


func _layout_outline() -> void:
	var thickness := 0.012
	var half_width := size_metres.x * 0.5
	var half_height := size_metres.y * 0.5
	_set_box($SelectedOutline/Top, Vector3(size_metres.x + thickness * 2.0, thickness, 0.01), Vector3(0.0, half_height + thickness * 0.5, -0.015))
	_set_box($SelectedOutline/Bottom, Vector3(size_metres.x + thickness * 2.0, thickness, 0.01), Vector3(0.0, -half_height - thickness * 0.5, -0.015))
	_set_box($SelectedOutline/Left, Vector3(thickness, size_metres.y, 0.01), Vector3(-half_width - thickness * 0.5, 0.0, -0.015))
	_set_box($SelectedOutline/Right, Vector3(thickness, size_metres.y, 0.01), Vector3(half_width + thickness * 0.5, 0.0, -0.015))


func _layout_resize_handles() -> void:
	var edge := 0.035
	var corner := 0.06
	var half_width := size_metres.x * 0.5
	var half_height := size_metres.y * 0.5
	_set_handle("Top", Vector3(0.0, half_height, 0.035), Vector3(size_metres.x - corner * 2.0, edge, 0.06))
	_set_handle("Bottom", Vector3(0.0, -half_height, 0.035), Vector3(size_metres.x - corner * 2.0, edge, 0.06))
	_set_handle("Left", Vector3(-half_width, 0.0, 0.035), Vector3(edge, size_metres.y - corner * 2.0, 0.06))
	_set_handle("Right", Vector3(half_width, 0.0, 0.035), Vector3(edge, size_metres.y - corner * 2.0, 0.06))
	_set_handle("TopLeft", Vector3(-half_width, half_height, 0.035), Vector3(corner, corner, 0.06))
	_set_handle("TopRight", Vector3(half_width, half_height, 0.035), Vector3(corner, corner, 0.06))
	_set_handle("BottomLeft", Vector3(-half_width, -half_height, 0.035), Vector3(corner, corner, 0.06))
	_set_handle("BottomRight", Vector3(half_width, -half_height, 0.035), Vector3(corner, corner, 0.06))


func _set_handle(handle_name: String, at: Vector3, dimensions: Vector3) -> void:
	var handle := resize_handles.get_node(handle_name) as Area3D
	handle.position = at
	handle.set_meta(&"spatial_window_resize_handle", handle_name)
	_set_collision_box(handle.get_node("CollisionShape3D") as CollisionShape3D, dimensions)


func _set_box(mesh_instance: MeshInstance3D, dimensions: Vector3, at: Vector3) -> void:
	if mesh_instance == null:
		return
	if not mesh_instance.has_meta(&"spatial_window_unique_mesh") and mesh_instance.mesh != null:
		mesh_instance.mesh = mesh_instance.mesh.duplicate()
		mesh_instance.set_meta(&"spatial_window_unique_mesh", true)
	var box := mesh_instance.mesh as BoxMesh
	if box != null:
		box.size = dimensions
	mesh_instance.position = at


func _set_collision_box(collision_shape: CollisionShape3D, dimensions: Vector3) -> void:
	if collision_shape == null:
		return
	if not collision_shape.has_meta(&"spatial_window_unique_shape") and collision_shape.shape != null:
		collision_shape.shape = collision_shape.shape.duplicate()
		collision_shape.set_meta(&"spatial_window_unique_shape", true)
	var box := collision_shape.shape as BoxShape3D
	if box != null:
		box.size = dimensions
