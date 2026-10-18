extends SceneTree

const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
const Cabinet := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_calibration.gd")
const CabinetWindow := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_calibration_window.gd")
const CameraFixture := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/pico_camera_model_self_test.gd")

const Profile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const Protocol := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd")

class TestCabinet extends Cabinet:
	var tracking := true
	func _has_head_tracking() -> bool:
		return tracking

class ParentWindow extends Node3D:
	func open_window() -> void:
		pass
	func toggle_zoom() -> void:
		pass
	func get_window_global_transform() -> Transform3D:
		return global_transform
	func get_effective_window_size_m() -> Vector2:
		return Vector2(0.88, 0.65)
	func get_window_pixel_size() -> Vector2:
		return Vector2(620, 460)

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	Profile.select_session_mode(Profile.Preset.PC_GROUND_SERVER)
	var denied := Cabinet.new()
	root.add_child(denied)
	denied.open_panel()
	_expect(denied.get("_receiver") == null and denied.get("_panel") == null, "Ground cannot receive or operate cabinet calibration")
	denied.queue_free()
	Profile.select_session_mode(Profile.Preset.SKY_XR_CLIENT)
	var host := Node3D.new()
	root.add_child(host)
	var origin := XROrigin3D.new()
	origin.name = "LocalOrigin"
	host.add_child(origin)
	var camera := XRCamera3D.new()
	camera.name = "XRCamera3D"
	origin.add_child(camera)
	camera.position.y = 1.6
	var cabinet := TestCabinet.new()
	cabinet.auto_start_receiver = false
	cabinet.local_xr_origin_path = NodePath("../LocalOrigin")
	host.add_child(cabinet)
	var parent_window := ParentWindow.new()
	host.add_child(parent_window)
	parent_window.position = Vector3(0, 1.45, -1.5)
	cabinet.open_panel(parent_window)
	await process_frame
	var panel: Node3D = cabinet.get("_panel")
	_expect(panel.global_position.x - parent_window.global_position.x > 1.08, "first opening sits beside main menu without overlap")
	_expect(is_equal_approx(panel.global_position.y, parent_window.global_position.y), "child window follows main menu height")
	var window: Control = cabinet.get("_ui")
	_expect(window.size == Vector2(1280, 900), "calibration UI fits the XR viewport")
	var scene_cabinet: Node3D = cabinet.get("_cabinet")
	var authored_pose := scene_cabinet.global_transform
	var body := scene_cabinet.get_node("Body") as MeshInstance3D
	_expect(body.mesh is BoxMesh and scene_cabinet.visible, "solid cabinet exists before calibration")
	_expect(is_zero_approx((body.global_transform * Vector3(0, -(body.mesh as BoxMesh).size.y * 0.5, 0)).y), "default cabinet bottom rests on floor")
	var extrinsics: OptionButton = window.get("_extrinsics")
	_expect(extrinsics.get_selected_id() == 3, "live mode defaults to device camera model")
	(window.get("_source") as OptionButton).select(1)
	window.call("_on_source_changed", 1)
	var view: Control = window.get("_view")
	var corners: PackedVector2Array = view.get("wire_points")
	await _frames(3)
	for point in corners.slice(0, 4):
		await _pointer_click(cabinet, view.global_position + view.call("pixel_to_local", point))
	_expect((view.get("points") as PackedVector2Array).size() == 4, "XR ray events reach image with correct pixel mapping, without server RPC")
	window.call("_solve")
	_expect(bool(window.get("solved")), "demo solves through actual UI workflow")
	_expect(str(cabinet.state.get("status")) == "preview", "demo creates preview")
	_expect(bool(cabinet.state.get("offline", false)), "demo is isolated from live state")
	_expect(scene_cabinet.global_transform.is_equal_approx(authored_pose), "offline exercise cannot move fixed scene cabinet")
	_expect(not cabinet.has_method("_receive_state"), "calibration controller exposes no server RPC")
	_expect(not cabinet.confirm_preview(), "offline confirmation rejected")
	var path := OS.get_environment("TEMP").path_join("cabinet-self-test-snapshot.json")
	window.call("save_snapshot", path)
	_expect(FileAccess.file_exists(path), "snapshot saved")
	window.call("load_snapshot", path)
	window.call("_solve")
	_expect(bool(window.get("solved")), "snapshot replays through solver")
	_expect(bool(window.get("frame").get("offline", false)), "replay remains offline")
	_expect(extrinsics.get_selected_id() == 0, "legacy head approximation snapshot keeps stable mode ID")
	var current_frame: Dictionary = window.get("frame")
	current_frame.metadata.merge(CameraFixture.fixture(), true)
	current_frame.head_world = Transform3D(Basis(Vector3.UP, 0.6), Vector3(2, 1.65, -1))
	extrinsics.select(extrinsics.get_item_index(3))
	window.call("_solve")
	_expect(bool(window.get("solved")), "device camera model solves through actual UI")
	var expected_camera: Transform3D = current_frame.head_world * CameraFixture.Model.head_from_camera(current_frame.metadata).transform
	_expect((window.get("camera_world") as Transform3D).is_equal_approx(expected_camera), "UI composes tracked head with selected optical camera")
	window.call("save_snapshot", path)
	window.call("load_snapshot", path)
	_expect(extrinsics.get_selected_id() == 3, "device mode snapshot preserves ID instead of option index")
	window.call("_solve")
	_expect(bool(window.get("solved")), "device mode snapshot replays: " + (window.get("_status") as Label).text)
	var legacy: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	legacy.extrinsics_mode = 1
	var legacy_file := FileAccess.open(path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify(legacy))
	legacy_file.close()
	window.call("load_snapshot", path)
	_expect((window.get("_status") as Label).text.contains("旧版未转换外参"), "unsafe legacy matrix direction cannot silently replay")
	DirAccess.remove_absolute(path)
	window.call("_undo")
	_expect(not bool(window.get("solved")), "editing points invalidates result")
	_expect(str(cabinet.state.get("status")) == "empty", "editing clears published preview")
	_expect(not CabinetWindow._valid_snapshot({"schema_version": 1}), "incomplete snapshot rejected")
	var epoch := cabinet.capture_epoch
	cabinet.invalidate("recenter before solve")
	_expect(cabinet.capture_epoch > epoch, "recenter invalidates frozen frames even before preview")
	(window.get("_source") as OptionButton).select(0)
	window.call("_on_source_changed", 0)
	_expect(extrinsics.get_selected_id() == 3, "returning from replay restores live device model")
	if OS.get_cmdline_user_args().has("--capture-ui"):
		(window.get("_source") as OptionButton).select(1)
		window.call("_on_source_changed", 1)
		await process_frame
		await RenderingServer.frame_post_draw
		var viewport := (cabinet.get("_panel") as Node3D).get_node("Viewport") as SubViewport
		viewport.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("cabinet-calibration-ui.png"))
		var tabs := window.find_child("SettingsTabs", true, false) as TabContainer
		for tab in range(1, tabs.get_tab_count()):
			tabs.current_tab = tab
			await _frames(2)
			await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("cabinet-calibration-tab-%d.png" % tab))
			tabs.current_tab = 0
	await _panel_drag_tests(cabinet, origin)
	await _local_tests(cabinet, origin, camera)
	host.queue_free()
	await process_frame
	_expect(get_first_node_in_group("cabinet_calibration") == null, "scene cleanup removes local calibration")
	if failures.is_empty():
		print("Cabinet calibration self-test passed (Sky local pose, XR grip drag/zoom/reopen, ray UI, direct TCP + ACK, no server, replay, whole-world alignment, recenter, cleanup).")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _panel_drag_tests(cabinet: TestCabinet, origin: XROrigin3D) -> void:
	var panel := cabinet.get("_panel") as Node3D
	var window: Node = cabinet.get("_window")
	var view: Control = (cabinet.get("_ui") as Node).get("_view")
	var surface := panel.get_node("StaticBody3D") as Node3D
	var tracker := XRControllerTracker.new()
	tracker.type = XRServer.TRACKER_CONTROLLER
	tracker.name = &"cabinet_test_hand"
	tracker.set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(0, 1.3, 0)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	tracker.set_input(&"grip", 0.0)
	XRServer.add_tracker(tracker)
	var hand := XRController3D.new()
	hand.tracker = tracker.name
	origin.add_child(hand)
	var pointer := Node3D.new()
	hand.add_child(pointer)
	await _frames(3)
	var start := panel.global_transform
	var origin_pose := origin.global_transform
	var fixed := (cabinet.get("_cabinet") as Node3D).global_transform
	var epoch := cabinet.capture_epoch
	var points: PackedVector2Array = view.get("points")
	_expect(window.get("_state_manager") == null, "local panel has no Server window authority")
	tracker.set_input(&"grip", 1.0)
	surface.emit_signal("pointer_event", XRToolsPointerEvent.new(XRToolsPointerEvent.Type.MOVED, pointer, surface, panel.global_position, panel.global_position))
	_expect(bool(window.call("is_local_drag_active")), "real XR grip event begins panel drag")
	tracker.set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(0.25, 1.3, 0)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	await create_timer(0.2).timeout
	_expect(panel.global_position.distance_to(start.origin) > 0.1, "moving controller moves panel")
	surface.emit_signal("pointer_event", XRToolsPointerEvent.new(XRToolsPointerEvent.Type.PRESSED, pointer, surface, panel.global_position, panel.global_position))
	_expect((view.get("points") as PackedVector2Array) == points, "grip drag cannot add calibration points")
	tracker.set_input(&"grip", 0.0)
	await _frames(3)
	_expect(not bool(window.call("is_local_drag_active")), "releasing grip ends drag")
	var moved := panel.global_transform
	cabinet.close_panel()
	_expect(not panel.visible, "close hides the local window")
	cabinet.open_panel()
	_expect(panel.visible and panel.global_transform.is_equal_approx(moved), "reopen keeps user placement")
	cabinet.toggle_panel_zoom()
	_expect(panel.scale.x > moved.basis.get_scale().x, "header zoom enlarges window")
	cabinet.toggle_panel_zoom()
	_expect(panel.global_transform.is_equal_approx(moved), "restore keeps placement and size")
	tracker.set_input(&"grip", 1.0)
	surface.emit_signal("pointer_event", XRToolsPointerEvent.new(XRToolsPointerEvent.Type.MOVED, pointer, surface, panel.global_position, panel.global_position))
	cabinet.close_panel()
	_expect(not bool(window.call("is_local_drag_active")), "closing while dragging releases grip ownership")
	cabinet.open_panel()
	_expect(origin.global_transform.is_equal_approx(origin_pose), "UI drag cannot move XR origin")
	_expect((cabinet.get("_cabinet") as Node3D).global_transform.is_equal_approx(fixed), "UI drag leaves cabinet fixed")
	_expect(cabinet.capture_epoch == epoch, "window manipulation does not invalidate calibration")
	hand.queue_free()
	XRServer.remove_tracker(tracker)
	await process_frame


func _local_tests(cabinet: TestCabinet, origin: XROrigin3D, camera: XRCamera3D) -> void:
	var fixed := cabinet.get("_cabinet") as Node3D
	var fixed_pose := fixed.global_transform
	var before := Transform3D(Basis(Vector3.UP, -0.4), Vector3(2, 0, 1))
	origin.global_transform = before
	var head_local := camera.transform
	_expect((cabinet.get_head_sample().transform as Transform3D).is_equal_approx(camera.global_transform), "pose comes directly from local camera")
	_expect(not cabinet.has_method("_request_initial_state") and not cabinet.has_method("_report_alignment_result"), "no server state or acknowledgement dependency")
	cabinet.call("_on_runtime_recentered")
	await create_timer(1.6).timeout
	var receiver: Node = cabinet.get("_receiver")
	_expect(not receiver.is_in_group("pico_frame_receiver"), "local receiver cannot hijack legacy Server consumers")
	var port := 42890
	while port < 42910 and receiver.call("start_listening", port) != OK:
		port += 1
	_expect(port < 42910, "Sky receiver binds its own TCP port")
	var stream := StreamPeerTCP.new()
	_expect(stream.connect_to_host("127.0.0.1", port) == OK, "Helper connects directly to Sky")
	for _i in range(60):
		stream.poll()
		await process_frame
		if stream.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
	var packet := _frame_packet(17)
	stream.put_data(packet.slice(0, 17))
	await _frames(3)
	_expect(cabinet.latest_frame.is_empty(), "partial TCP frame is not exposed")
	stream.put_data(packet.slice(17))
	await _frames(5)
	stream.poll()
	_expect(int(cabinet.latest_frame.get("frame_id", -1)) == 17, "PSA2 frame received in Sky without Server")
	_expect(stream.get_available_bytes() >= 8, "Sky returns Helper ACK")
	if stream.get_available_bytes() >= 8:
		var ack: PackedByteArray = stream.get_data(8)[1]
		_expect(Protocol.read_u32_be(ack, 0) == Protocol.ACK_MAGIC_PAA1 and Protocol.read_u32_be(ack, 4) == 17, "correct PAA1 ACK")
	var snapshot := cabinet.freeze_frame()
	_expect(snapshot.has("head_world"), "stationary local capture succeeds")
	if snapshot.has("head_world"):
		_expect((snapshot.head_world as Transform3D).is_equal_approx(camera.global_transform), "freeze uses actual local pose")
	camera.position.x += 0.1
	_expect(cabinet.freeze_frame().has("error"), "moving local head cannot freeze")
	camera.transform = head_local
	cabinet.latest_frame["receive_usec"] = Time.get_ticks_usec() - 1_000_000
	_expect(cabinet.freeze_frame().has("error"), "stale frames rejected")
	var pose := Transform3D(Basis(Vector3.UP, 0.2), Vector3(0, 0, -3))
	_expect(cabinet.show_preview(pose, Vector3(1.2, 2, 0.6)), "local preview succeeds with no game server")
	_expect(origin.global_transform.is_equal_approx(before), "preview leaves origin unchanged")
	_expect(cabinet.confirm_preview() and str(cabinet.state.status) == "confirmed", "confirmation completes synchronously without server ACK")
	var delta := Cabinet.compute_world_alignment(pose, fixed_pose)
	_expect(origin.global_transform.is_equal_approx(delta * before), "whole-world correction composes in correct order")
	_expect(fixed.global_transform.is_equal_approx(fixed_pose), "fixed cabinet never moves within scene")
	_expect((origin.global_transform.affine_inverse() * fixed_pose).is_equal_approx(before.affine_inverse() * pose), "virtual cabinet matches measured physical pose")
	_expect(camera.transform.is_equal_approx(head_local), "physical head height is preserved")
	var furniture := Transform3D(Basis.IDENTITY, Vector3(3, 0, 4))
	_expect((origin.global_transform.affine_inverse() * furniture).is_equal_approx(before.affine_inverse() * delta.affine_inverse() * furniture), "all world objects share the same mapping")
	var confirmed_origin := origin.global_transform
	cabinet.call("_apply_world_alignment", cabinet.state)
	_expect(origin.global_transform.is_equal_approx(confirmed_origin), "duplicate confirmation cannot accumulate")
	stream.disconnect_from_host()
	await _frames(5)
	_expect(cabinet.latest_frame.is_empty(), "Helper disconnect clears stale frames")
	_expect(str(cabinet.state.status) == "confirmed", "capture disconnection does not undo completed local alignment")
	stream.connect_to_host("127.0.0.1", port)
	await _frames(5)
	stream.poll()
	stream.put_data(_frame_packet(18))
	await _frames(5)
	_expect(int(cabinet.latest_frame.get("frame_id", -1)) == 18, "Helper can reconnect directly")
	stream.disconnect_from_host()
	cabinet.clear_cabinet()
	_expect(origin.global_transform.is_equal_approx(confirmed_origin), "clearing record retains mapping until re-alignment")
	_expect(cabinet.show_preview(pose, Vector3.ONE) and cabinet.confirm_preview(), "second calibration succeeds locally")
	cabinet.call("_on_runtime_recentered")
	_expect(str(cabinet.state.status) == "invalid" and not fixed.visible, "local recenter invalidates calibration immediately")
	cabinet.clear_cabinet()
	cabinet.show_preview(pose, Vector3.ONE)
	cabinet.tracking = false
	_expect(not cabinet.confirm_preview(), "tracking loss blocks confirmation")
	cabinet.tracking = true
	_expect(not cabinet.show_preview(pose, Vector3(-1, 2, 1)), "invalid dimensions rejected")
	receiver.call("stop_listening")


func _pointer_click(cabinet: Node, position: Vector2) -> void:
	var panel := cabinet.get("_panel") as Node3D
	var body := panel.get_node("StaticBody3D") as Node3D
	var pointer := Node3D.new()
	panel.add_child(pointer)
	var surface_position := Vector3((position.x / 1280.0 - 0.5) * 1.28, (0.5 - position.y / 900.0) * 0.9, 0)
	var at := panel.global_transform * surface_position
	for kind in [XRToolsPointerEvent.Type.ENTERED, XRToolsPointerEvent.Type.MOVED, XRToolsPointerEvent.Type.PRESSED, XRToolsPointerEvent.Type.RELEASED, XRToolsPointerEvent.Type.EXITED]:
		body.emit_signal("pointer_event", XRToolsPointerEvent.new(kind, pointer, body, at, at))
		await process_frame
	pointer.queue_free()


func _frame_packet(frame_id: int) -> PackedByteArray:
	var image := Image.create(64, 64, false, Image.FORMAT_RGB8)
	image.fill(Color.DARK_SLATE_GRAY)
	var metadata := JSON.stringify({"render_mode": 0}).to_utf8_buffer()
	var jpeg := image.save_jpg_to_buffer()
	var packet := PackedByteArray()
	packet.resize(32)
	Protocol.write_u32_be(packet, 0, Protocol.FRAME_MAGIC_PSA2)
	Protocol.write_u32_be(packet, 4, frame_id)
	var stamp := Time.get_ticks_usec() * 1000
	for i in range(8):
		packet[8 + i] = (stamp >> (56 - i * 8)) & 0xff
	Protocol.write_u32_be(packet, 16, 64)
	Protocol.write_u32_be(packet, 20, 64)
	Protocol.write_u32_be(packet, 24, metadata.size())
	Protocol.write_u32_be(packet, 28, jpeg.size())
	packet.append_array(metadata)
	packet.append_array(jpeg)
	return packet


func _frames(count: int) -> void:
	for _i in range(count):
		await process_frame


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
