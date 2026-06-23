extends Node

const IP_ADDRESS: String = "127.0.0.1"
const PORT: int = 42069
const MAX_CLIENTS: int = 8
const CHANNEL_COUNT: int = 3

signal network_ready
signal network_role_selected(is_server: bool)
signal remote_annotation_received(position: Vector3, data: Dictionary)

@export var marker_scene: PackedScene = preload("res://Assets/ARSpace/Prefabs/Marker.prefab.tscn")

var peer: ENetMultiplayerPeer
var spatial_calibration_preview_marker: Node3D


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)


func _on_peer_connected(peer_id: int) -> void:
	print("Peer %d connected" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("Peer %d disconnected" % peer_id)


func start_server() -> bool:
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, MAX_CLIENTS, CHANNEL_COUNT)
	if error != OK:
		push_error("Failed to start server on port %d. Error: %d" % [PORT, error])
		return false

	multiplayer.multiplayer_peer = peer
	shutdown_xr_for_server()
	print("Server started")
	network_role_selected.emit(true)
	network_ready.emit()
	return true


func start_client(ip: String = IP_ADDRESS) -> bool:
	var target_ip := _get_server_ip_from_args(ip)
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_client(target_ip, PORT, CHANNEL_COUNT)
	if error != OK:
		push_error("Failed to connect to %s:%d. Error: %d" % [target_ip, PORT, error])
		return false

	multiplayer.multiplayer_peer = peer
	network_role_selected.emit(false)
	print("Client connecting to ", target_ip)
	return true


func _get_server_ip_from_args(default_ip: String) -> String:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--server-ip="):
			var value := arg.get_slice("=", 1).strip_edges()
			if value != "":
				return value
	return default_ip


func shutdown_xr_for_server() -> void:
	get_viewport().use_xr = false

	var openxr_interface := XRServer.find_interface("OpenXR")
	if openxr_interface and openxr_interface.is_initialized():
		openxr_interface.uninitialize()
		print("OpenXR disabled for server instance")


func _on_connected_to_server() -> void:
	print("Connected to server")
	network_ready.emit()


@rpc("authority", "call_local", "reliable")
func create_marker_at_position(position: Vector3) -> void:
	if marker_scene == null:
		return

	var marker: Node = marker_scene.instantiate()
	var main_scene := get_tree().current_scene
	if main_scene == null:
		return

	main_scene.add_child(marker)
	if marker.has_method("setup"):
		marker.setup(position)
	elif marker is Node3D:
		(marker as Node3D).global_position = position


@rpc("authority", "call_local", "reliable")
func highlight_model_part(node_path: String, is_highlight: bool) -> void:
	var tree_list = get_tree().get_first_node_in_group("tree_list")
	if not tree_list:
		return

	var target_node = get_tree().get_root().get_node_or_null(node_path)
	if not target_node:
		return

	var mesh_instance = tree_list.find_mesh_instance_child(target_node)
	if not mesh_instance:
		return

	if is_highlight:
		tree_list.highlight_part(mesh_instance)
		tree_list.highlighted_parts[mesh_instance] = null
	else:
		tree_list.clear_highlight(mesh_instance)
		tree_list.highlighted_parts.erase(mesh_instance)
	tree_list.update_tree_item_color(target_node, is_highlight)


func send_spatial_calibration_preview(position: Vector3, data: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_receive_spatial_calibration_preview", position, data)


@rpc("authority", "call_local", "reliable")
func _receive_spatial_calibration_preview(position: Vector3, data: Dictionary) -> void:
	if spatial_calibration_preview_marker == null or not is_instance_valid(spatial_calibration_preview_marker):
		spatial_calibration_preview_marker = _create_simple_annotation_marker(position, data)
		spatial_calibration_preview_marker.name = "SpatialCalibrationPreviewMarker"
		spatial_calibration_preview_marker.add_to_group("spatial_calibration_preview_marker")

	var main_scene := get_tree().current_scene
	if main_scene != null and spatial_calibration_preview_marker.get_parent() == null:
		main_scene.add_child(spatial_calibration_preview_marker)

	spatial_calibration_preview_marker.global_position = position
	spatial_calibration_preview_marker.visible = true


func clear_spatial_calibration_preview() -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_clear_spatial_calibration_preview")


@rpc("authority", "call_local", "reliable")
func _clear_spatial_calibration_preview() -> void:
	if spatial_calibration_preview_marker != null and is_instance_valid(spatial_calibration_preview_marker):
		spatial_calibration_preview_marker.queue_free()
	spatial_calibration_preview_marker = null

	for candidate in get_tree().get_nodes_in_group("spatial_calibration_preview_marker"):
		var marker_node := candidate as Node
		if marker_node != null and is_instance_valid(marker_node):
			marker_node.queue_free()


func send_remote_annotation(position: Vector3, data: Dictionary = {}) -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_receive_remote_annotation", position, data)


@rpc("authority", "call_local", "reliable")
func _receive_remote_annotation(position: Vector3, data: Dictionary) -> void:
	remote_annotation_received.emit(position, data)
	_create_annotation_marker(position, data)


func _create_annotation_marker(position: Vector3, data: Dictionary) -> void:
	var marker: Node3D = _create_simple_annotation_marker(position, data)
	var main_scene := get_tree().current_scene
	if main_scene == null:
		return

	main_scene.add_child(marker)
	marker.global_position = position


func _create_simple_annotation_marker(position: Vector3, data: Dictionary) -> Node3D:
	var marker: Node3D = Node3D.new()
	marker.name = "RemoteAnnotationMarker"
	marker.global_position = position
	marker.add_to_group("remote_annotation_marker")

	var marker_size := float(data.get("size", 0.05))
	var color := _read_payload_color(data, Color.RED)

	var mesh_instance := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = marker_size
	sphere.height = marker_size * 2.0
	mesh_instance.mesh = sphere
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.material_override = _make_marker_material(color, 2.0, false)
	marker.add_child(mesh_instance)

	var outer_mesh := MeshInstance3D.new()
	var outer_sphere := SphereMesh.new()
	outer_sphere.radius = marker_size * 1.5
	outer_sphere.height = marker_size * 3.0
	outer_mesh.mesh = outer_sphere
	outer_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outer_mesh.material_override = _make_marker_material(Color(color.r, color.g, color.b, 0.3), 1.0, true)
	marker.add_child(outer_mesh)

	_add_pulse_animation(marker, mesh_instance)

	var lifetime := float(data.get("lifetime", 0.0))
	if lifetime > 0.0:
		get_tree().create_timer(lifetime).timeout.connect(func():
			if is_instance_valid(marker):
				marker.queue_free()
		)

	return marker


func _read_payload_color(data: Dictionary, fallback: Color) -> Color:
	if not data.has("color"):
		return fallback

	var value = data["color"]
	if value is Color:
		return value
	if value is Dictionary:
		var color_data := value as Dictionary
		return Color(
			float(color_data.get("r", fallback.r)),
			float(color_data.get("g", fallback.g)),
			float(color_data.get("b", fallback.b)),
			float(color_data.get("a", fallback.a))
		)
	return fallback


func _make_marker_material(color: Color, emission_energy: float, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = emission_energy
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


func _add_pulse_animation(marker: Node3D, mesh_instance: MeshInstance3D) -> void:
	if not is_instance_valid(marker) or not is_instance_valid(mesh_instance):
		return

	var tween := create_tween()
	tween.set_loops()
	tween.bind_node(marker)
	tween.tween_property(mesh_instance, "scale", Vector3(1.3, 1.3, 1.3), 0.6).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tween.tween_property(mesh_instance, "scale", Vector3.ONE, 0.6).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)


func send_remote_annotations_batch(annotations: Array) -> void:
	for annotation in annotations:
		if annotation is Dictionary:
			send_remote_annotation(annotation.get("position", Vector3.ZERO), annotation.get("data", {}))
		elif annotation is Vector3:
			send_remote_annotation(annotation)


func clear_all_remote_annotations() -> void:
	if not multiplayer.is_server():
		return

	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_clear_remote_annotations")
		rpc_id(peer_id, "_clear_spatial_calibration_preview")


@rpc("authority", "call_local", "reliable")
func _clear_remote_annotations() -> void:
	for candidate in get_tree().get_nodes_in_group("remote_annotation_marker"):
		var marker_node := candidate as Node
		if marker_node != null and is_instance_valid(marker_node):
			marker_node.queue_free()
	_clear_spatial_calibration_preview()
