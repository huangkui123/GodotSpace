extends SceneTree

const RuntimeProfileScript = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const VirtualSourceScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/virtual_camera_view_source.gd"
)
const STATUS_IDLE: int = 0
const STATUS_CONNECTING: int = 1
const STATUS_LIVE: int = 2
const STATUS_STALLED: int = 3
const STATUS_ERROR: int = 4
const SKY_PEER_ID: int = 20

var _failures: Array[String] = []
var _test_root: Node3D


class FakeViewSource extends Node:
	signal texture_changed(texture: Texture2D)
	signal status_changed(status: int, message: String)
	signal metadata_changed(metadata: Dictionary)

	var started_peer_id: int = 0
	var status: int = STATUS_IDLE
	var status_message: String = ""
	var metadata: Dictionary = {}
	var texture: Texture2D

	func _init() -> void:
		var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.1, 0.8, 0.35, 1.0))
		texture = ImageTexture.create_from_image(image)

	func start(source_peer_id: int) -> void:
		started_peer_id = source_peer_id
		status = STATUS_LIVE
		status_message = "Fake source live"
		metadata = {
			"source_type": "fake_texture",
			"source_name": "Fake Texture",
			"peer_id": source_peer_id,
			"resolution": Vector2i(4, 4),
			"aspect_ratio": 1.0,
			"fov_degrees": 0.0,
		}
		texture_changed.emit(texture)
		status_changed.emit(status, status_message)
		metadata_changed.emit(metadata)

	func stop() -> void:
		started_peer_id = 0
		status = STATUS_IDLE
		status_message = ""
		texture_changed.emit(null)
		status_changed.emit(status, status_message)
		metadata_changed.emit({})

	func get_texture() -> Texture2D:
		return texture if status == STATUS_LIVE else null

	func get_status() -> int:
		return status

	func get_status_message() -> String:
		return status_message

	func get_metadata() -> Dictionary:
		return metadata.duplicate(true)


class MockPanel extends Node:
	signal close_requested
	signal restore_requested

	var texture: Texture2D
	var status: int = STATUS_IDLE
	var status_message: String = ""
	var metadata: Dictionary = {}

	func set_view_texture(value: Texture2D) -> void:
		texture = value

	func set_view_status(value: int, message: String) -> void:
		status = value
		status_message = message

	func set_view_metadata(value: Dictionary) -> void:
		metadata = value.duplicate(true)

	func get_view_texture() -> Texture2D:
		return texture

	func get_view_status() -> int:
		return status

	func get_view_status_message() -> String:
		return status_message


class MockWindowSurface extends Node3D:
	var panel: MockPanel

	func _init() -> void:
		panel = MockPanel.new()
		panel.name = "MockPanel"
		add_child(panel)

	func get_scene_instance() -> Node:
		return panel


class MockSkyPlayer extends Node3D:
	var _has_received_network_pose: bool = false
	var _last_network_pose_received_usec: int = 0
	var network_head: Node3D

	func _init() -> void:
		network_head = Node3D.new()
		network_head.name = "NetworkHead"
		network_head.visible = false
		add_child(network_head)

	func get_network_viewpoint() -> Node3D:
		return network_head

	func has_received_network_pose() -> bool:
		return _has_received_network_pose

	func get_last_network_pose_received_msec() -> int:
		return _last_network_pose_received_usec / 1000

	func _accept_remote_pose(
		_sequence: int,
		head_transform: Transform3D,
		_left_hand_transform: Transform3D,
		_right_hand_transform: Transform3D
	) -> bool:
		network_head.global_transform = head_transform
		network_head.visible = true
		_has_received_network_pose = true
		_last_network_pose_received_usec = Time.get_ticks_usec()
		return true


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_root = Node3D.new()
	_test_root.name = "AstronautViewSelfTestRoot"
	root.add_child(_test_root)
	await process_frame
	await _test_virtual_camera_source()
	await _test_window_source_boundary_and_profiles()
	_test_production_scene_contract()
	_cleanup()
	_finish()


func _test_virtual_camera_source() -> void:
	var source: Node = VirtualSourceScript.new()
	source.name = "VirtualSource"
	source.set("pose_stall_timeout_msec", 250)
	_test_root.add_child(source)
	await process_frame

	source.call("start", SKY_PEER_ID)
	_expect(int(source.call("get_status")) == STATUS_CONNECTING, "Missing Sky player should keep the source CONNECTING.")
	_expect(source.call("get_texture") == null, "A source without a Sky player must not retain a texture.")

	var sky_player := _create_remote_player(SKY_PEER_ID)
	var head_transform := Transform3D(
		Basis(Vector3.UP, deg_to_rad(32.0)),
		Vector3(1.25, 1.72, -2.4)
	)
	_expect(
		bool(sky_player.call(
			"_accept_remote_pose",
			1,
			head_transform,
			Transform3D(Basis.IDENTITY, Vector3(1.0, 1.3, -2.3)),
			Transform3D(Basis.IDENTITY, Vector3(1.5, 1.3, -2.3))
		)),
		"The production Player should accept the first valid Sky pose."
	)
	source.call("_resolve_source_nodes")
	source.call("_process", 0.016)
	_expect(int(source.call("get_status")) == STATUS_LIVE, "A late Sky player and first pose should move the source to LIVE.")

	var capture_camera := source.call("get_capture_camera") as Camera3D
	var capture_viewport := source.call("get_capture_viewport") as SubViewport
	_expect(capture_camera != null, "Virtual source must expose its production capture camera.")
	_expect(capture_viewport != null, "Virtual source must expose its production capture viewport.")
	if capture_camera != null:
		_expect(
			capture_camera.global_transform.is_equal_approx(head_transform),
			"Capture camera should follow the Sky NetworkHead transform."
		)
		_expect(
			is_equal_approx(capture_camera.fov, float(source.get("fallback_fov_degrees"))),
			"Remote players without an XR camera should use the declared virtual-camera FOV."
		)
	if capture_viewport != null:
		_expect(
			capture_viewport.world_3d == source.get_viewport().find_world_3d(),
			"Capture viewport must share the main World3D."
		)
		_expect(capture_viewport.size == Vector2i(960, 540), "Capture viewport should keep the planned 16:9 resolution.")

	var metadata := source.call("get_metadata") as Dictionary
	_expect(int(metadata.get("peer_id", 0)) == SKY_PEER_ID, "View metadata should identify the authoritative Sky peer.")
	_expect(is_equal_approx(float(metadata.get("aspect_ratio", 0.0)), 16.0 / 9.0), "View metadata should expose the 16:9 aspect ratio.")
	_expect(str(metadata.get("source_type", "")) == "virtual_camera", "View metadata should identify the virtual-camera source.")

	if capture_camera != null:
		_expect((capture_camera.cull_mask & (1 << 19)) == 0, "Capture camera must exclude the local monitor/avatar layer.")

	source.set("pose_stall_timeout_msec", 1)
	sky_player.set("_last_network_pose_received_usec", 1000)
	source.call("_process", 0.016)
	_expect(int(source.call("get_status")) == STATUS_STALLED, "An overdue network pose should report STALLED.")
	_expect(
		bool(sky_player.call(
			"_accept_remote_pose",
			2,
			Transform3D(head_transform.basis, Vector3(1.6, 1.8, -2.0)),
			Transform3D(Basis.IDENTITY, Vector3(1.3, 1.3, -2.0)),
			Transform3D(Basis.IDENTITY, Vector3(1.8, 1.3, -2.0))
		)),
		"The production Player should accept a recovery pose."
	)
	source.call("_process", 0.016)
	_expect(int(source.call("get_status")) == STATUS_LIVE, "A new pose should recover a STALLED source to LIVE.")

	source.call("stop")
	if capture_viewport != null:
		_expect(capture_viewport.world_3d == null, "Stopping the source should release the shared World3D reference.")
	source.call("start", SKY_PEER_ID)
	source.call("_resolve_source_nodes")
	source.call("_process", 0.016)
	_expect(int(source.call("get_status")) == STATUS_LIVE, "A stopped source should restart cleanly for the same Sky peer.")

	sky_player.get_parent().remove_child(sky_player)
	sky_player.queue_free()
	await process_frame
	source.call("_resolve_source_nodes")
	_expect(int(source.call("get_status")) == STATUS_STALLED, "Removing the bound Sky player should stall the source.")
	_expect(source.call("get_texture") == null, "Disconnecting Sky should clear the old viewport texture.")

	source.call("stop")
	source.call("stop")
	_expect(int(source.call("get_status")) == STATUS_IDLE, "Repeated stop calls should be idempotent.")
	if capture_viewport != null:
		_expect(capture_viewport.world_3d == null, "Stopping the source should release the shared World3D reference.")
	source.queue_free()
	await process_frame


func _test_window_source_boundary_and_profiles() -> void:
	var network_handler := root.get_node_or_null("NetworkHandler")
	_expect(network_handler != null, "NetworkHandler autoload is required for the window self-test.")
	if network_handler == null:
		return
	network_handler.call("_reset_peer_roles", true)
	network_handler.call("_assign_requested_role", SKY_PEER_ID, "sky", "")

	RuntimeProfileScript.select_session_mode(RuntimeProfileScript.Preset.VR_GROUND_CLIENT, false)
	var controller_script := load(
		"res://Assets/ARSpace/Scripts/AstronautView/astronaut_view_window_controller.gd"
	) as Script
	_expect(controller_script != null, "Production astronaut-view window controller should load.")
	if controller_script == null:
		return
	var window := Node3D.new()
	window.name = "ProductionAstronautViewWindow"
	window.set_script(controller_script)
	var surface := MockWindowSurface.new()
	surface.name = "WindowSurface"
	window.add_child(surface)
	var initial_source := FakeViewSource.new()
	initial_source.name = "VirtualCameraViewSource"
	window.add_child(initial_source)
	_test_root.add_child(window)
	await process_frame
	await process_frame
	_expect(window.visible, "Ground VR Client should display the production astronaut-view window.")
	_expect(not _has_multiplayer_synchronizer(window), "The local astronaut-view window must not contain synchronized state.")

	var old_source := window.call("get_view_source") as Node
	var fake_source := FakeViewSource.new()
	fake_source.name = "FakeExternalVideoSource"
	window.add_child(fake_source)
	_expect(bool(window.call("set_view_source", fake_source)), "Window should accept a source that implements the view contract.")
	_expect(fake_source.started_peer_id == SKY_PEER_ID, "Replacement source should bind to the same authoritative Sky peer.")

	var panel := window.call("get_panel") as Node
	_expect(panel != null, "Production window should expose its production panel instance.")
	if panel != null:
		_expect(panel.call("get_view_texture") == fake_source.texture, "Panel should display the replacement source texture.")
		_expect(int(panel.call("get_view_status")) == STATUS_LIVE, "Panel should display the replacement source status.")
	if old_source != null:
		old_source.emit_signal("status_changed", STATUS_ERROR, "stale source error")
	if panel != null:
		_expect(int(panel.call("get_view_status")) == STATUS_LIVE, "Signals from a replaced source must not overwrite the active panel.")

	window.call("close_window")
	_expect(not bool(window.call("is_window_open")), "Close should mark the local window closed.")
	_expect(fake_source.started_peer_id == 0, "Closing the window should stop the active source.")
	window.call("open_window")
	_expect(bool(window.call("is_window_open")), "The local window should support reopening.")
	_expect(fake_source.started_peer_id == SKY_PEER_ID, "Reopening should restore the current Sky source.")

	RuntimeProfileScript.select_session_mode(RuntimeProfileScript.Preset.PC_GROUND_SERVER, false)
	window.call("refresh_profile")
	_expect(not window.visible, "PC Ground must hide the production astronaut-view window.")
	RuntimeProfileScript.select_session_mode(RuntimeProfileScript.Preset.SKY_XR_CLIENT, false)
	window.call("refresh_profile")
	_expect(not window.visible, "Sky XR must hide the production astronaut-view window.")
	RuntimeProfileScript.select_session_mode(RuntimeProfileScript.Preset.VR_GROUND_SERVER, false)
	window.call("refresh_profile")
	_expect(window.visible, "Ground VR Server should display the same local-only window.")

	network_handler.call("_remove_peer_role", SKY_PEER_ID)
	window.call("_refresh_source_binding", true)
	if panel != null:
		_expect(int(panel.call("get_view_status")) == STATUS_IDLE, "No Sky should leave the panel in an explicit waiting state.")
		_expect(panel.call("get_view_texture") == null, "Waiting state must not retain the old source texture.")
	var replacement_sky_peer_id := SKY_PEER_ID + 1
	network_handler.call("_assign_requested_role", replacement_sky_peer_id, "sky", "")
	window.call("_refresh_source_binding", true)
	_expect(
		fake_source.started_peer_id == replacement_sky_peer_id,
		"A replacement Sky should automatically rebind the existing local window."
	)
	if panel != null:
		_expect(int(panel.call("get_view_status")) == STATUS_LIVE, "Replacement Sky should restore the panel to LIVE.")

	window.queue_free()
	await process_frame
	RuntimeProfileScript.clear_session_override()
	network_handler.call("_reset_peer_roles", false)


func _test_production_scene_contract() -> void:
	_expect(
		str(ProjectSettings.get_setting("layer_names/3d_render/layer_20", "")) == "AstronautViewExcluded",
		"Visual layer 20 should be named for astronaut-view capture exclusion."
	)
	var arspace_scene := load("res://Assets/ARSpace/Scenes/ARSpace.tscn") as PackedScene
	_expect(arspace_scene != null, "Production ARSpace scene should load.")
	if arspace_scene == null:
		return
	var arspace_state := arspace_scene.get_state()
	_expect(
		_find_scene_node(arspace_state, "SharedSpaceOrigin/AstronautViewAnchor") >= 0,
		"ARSpace should expose an editor-adjustable astronaut-view anchor."
	)
	_expect(
		_find_scene_node(
			arspace_state,
			"SharedSpaceOrigin/AstronautViewAnchor/AstronautViewWindow3D"
		) >= 0,
		"ARSpace should mount the production astronaut-view window under SharedSpaceOrigin."
	)
	_expect(
		_find_scene_node(arspace_state, "UI/SubViewportContainer/SubViewport/Camera3D") >= 0,
		"PC Ground desktop preview should remain intact."
	)

	var window_scene := load(
		"res://Assets/ARSpace/Scenes/AstronautView/AstronautViewWindow3D.tscn"
	) as PackedScene
	_expect(window_scene != null, "Production astronaut-view window scene should load.")
	if window_scene == null:
		return
	var window_state := window_scene.get_state()
	for node_path in [
		"VirtualCameraViewSource",
		"VirtualCameraViewSource/CaptureViewport",
		"VirtualCameraViewSource/CaptureViewport/Camera3D",
		"WindowSurface",
	]:
		_expect(_find_scene_node(window_state, node_path) >= 0, "Astronaut-view scene is missing: %s" % node_path)
	var camera_index := _find_scene_node(window_state, "VirtualCameraViewSource/CaptureViewport/Camera3D")
	if camera_index >= 0:
		_expect(
			int(_get_scene_node_property(window_state, camera_index, &"cull_mask")) & (1 << 19) == 0,
			"Production capture camera must exclude visual layer 20."
		)
	for node_index in range(window_state.get_node_count()):
		_expect(
			str(window_state.get_node_type(node_index)) != "MultiplayerSynchronizer",
			"The local astronaut-view scene must not contain MultiplayerSynchronizer."
		)

	var panel_scene := load(
		"res://Assets/ARSpace/Scenes/AstronautView/AstronautViewPanel.tscn"
	) as PackedScene
	_expect(panel_scene != null, "Production astronaut-view panel should load.")
	if panel_scene != null:
		var panel_state := panel_scene.get_state()
		for node_path in [
			"Margin/VBox/Header/SourceLabel",
			"Margin/VBox/Header/RestoreButton",
			"Margin/VBox/Header/CloseButton",
			"Margin/VBox/ViewFrame/ViewTexture",
			"Margin/VBox/ViewFrame/StatusOverlay/StatusLabel",
		]:
			_expect(_find_scene_node(panel_state, node_path) >= 0, "Astronaut-view panel is missing: %s" % node_path)

	var player_script := load("res://Assets/ARSpace/Scenes/player.gd") as Script
	_expect(player_script != null, "Production Player script should load.")
	if player_script != null:
		var player_methods: Dictionary = {}
		for method_info in player_script.get_script_method_list():
			player_methods[str(method_info.get("name", ""))] = true
		for method_name in [
			"get_network_viewpoint",
			"has_received_network_pose",
			"get_last_network_pose_received_msec",
		]:
			_expect(player_methods.has(method_name), "Production Player is missing view-source interface: %s" % method_name)


func _create_remote_player(peer_id: int) -> Node:
	var player := MockSkyPlayer.new()
	player.name = str(peer_id)
	_test_root.add_child(player)
	return player


func _has_multiplayer_synchronizer(node: Node) -> bool:
	if node is MultiplayerSynchronizer:
		return true
	for child in node.get_children():
		if _has_multiplayer_synchronizer(child):
			return true
	return false


func _find_scene_node(state: SceneState, node_path: String) -> int:
	for node_index in range(state.get_node_count()):
		var path_text := str(state.get_node_path(node_index))
		if path_text == node_path or path_text.ends_with("/" + node_path):
			return node_index
	return -1


func _get_scene_node_property(state: SceneState, node_index: int, property_name: StringName):
	for property_index in range(state.get_node_property_count(node_index)):
		if state.get_node_property_name(node_index, property_index) == property_name:
			return state.get_node_property_value(node_index, property_index)
	return null


func _cleanup() -> void:
	RuntimeProfileScript.clear_session_override()
	if _test_root != null and is_instance_valid(_test_root):
		_test_root.queue_free()


func _finish() -> void:
	if _failures.is_empty():
		print("Astronaut view source self-test passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
