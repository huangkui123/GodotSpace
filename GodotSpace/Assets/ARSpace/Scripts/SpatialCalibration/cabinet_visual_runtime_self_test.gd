extends SceneTree

const Cabinet := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_calibration.gd")
const Visual := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_geometry.gd")
const Geometry := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry.gd")
const Profile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const CameraFixture := preload("res://Assets/ARSpace/Scripts/SpatialCalibration/pico_camera_model_self_test.gd")
var failures: Array[String] = []

class TestCabinet extends Cabinet:
	var tracking := true
	var injected_frames: Array[Dictionary] = []
	func _has_head_tracking() -> bool:
		return tracking
	func freeze_frame() -> Dictionary:
		if not injected_frames.is_empty():
			return injected_frames.pop_front()
		return super.freeze_frame()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_batches()
	Profile.select_session_mode(Profile.Preset.SKY_XR_CLIENT)
	var host := Node3D.new()
	root.add_child(host)
	var origin := XROrigin3D.new()
	origin.name = "Origin"
	host.add_child(origin)
	var camera := XRCamera3D.new()
	camera.name = "XRCamera3D"
	origin.add_child(camera)
	camera.position = Vector3(0.2, 1.6, 0.1)
	var target := Node3D.new()
	target.name = "Target"
	host.add_child(target)
	target.transform = Transform3D(Basis(Vector3.UP, 0.3), Vector3(2, 0, -3))
	var fixed := Node3D.new()
	fixed.name = "dashiyangui"
	target.add_child(fixed)
	var anchor := Node3D.new()
	anchor.name = "MeshRenderer"
	fixed.add_child(anchor)
	anchor.position = Vector3(1.374, 0, 5.383)
	var cabinet := TestCabinet.new()
	cabinet.auto_start_receiver = false
	cabinet.local_xr_origin_path = NodePath("../Origin")
	cabinet.visual_target_path = NodePath("../Target")
	host.add_child(cabinet)
	cabinet.set_process(false)
	var original_target := target.global_transform
	var original_anchor := anchor.global_transform
	var original_head := camera.transform
	var measured := Transform3D(Basis(Vector3.UP, -0.5), Vector3(-0.4, 0, -2))
	var points: Array = [[0, 0, 0], [0.2, 1, 0.2], [-0.2, 0.4, 0.1]]
	_expect(cabinet.show_visual_preview(measured, 1, points, false, cabinet.capture_epoch), "CAD live preview")
	_expect(target.global_transform.is_equal_approx(original_target), "preview never moves target")
	_expect(origin.transform == Transform3D.IDENTITY, "preview never moves origin")
	_expect(cabinet.confirm_preview(), "CAD applies without four image points")
	var expected := original_anchor * measured.affine_inverse()
	_expect(origin.global_transform.is_equal_approx(expected), "uses actual scene CAD anchor, not cuboid origin")
	_expect(target.global_transform.is_equal_approx(original_target), "1:1 preserves target geometry")
	_expect(camera.transform == original_head, "local head tracking remains unchanged")
	_expect(not cabinet.confirm_preview(), "duplicate confirmation cannot apply twice")
	cabinet.clear_cabinet()
	_expect(origin.global_transform.is_equal_approx(expected), "clear preserves applied mapping")
	_expect(cabinet.show_visual_preview(measured, 1.0 / 3.0, points, false, cabinet.capture_epoch), "scaled preview")
	_expect(cabinet.confirm_preview(), "scaled model applies")
	_expect(anchor.global_position.is_equal_approx(original_anchor.origin), "scale preserves actual CAD anchor")
	_expect(anchor.global_basis.get_scale().is_equal_approx(Vector3.ONE / 3), "only cabinet content is scaled")
	_expect(origin.global_basis.get_scale().is_equal_approx(Vector3.ONE), "XR/world scale remains one")
	cabinet.clear_cabinet()
	_expect(cabinet.show_visual_preview(measured, 1, points, true, cabinet.capture_epoch), "offline CAD preview")
	_expect(not cabinet.confirm_preview(), "offline cannot apply")
	cabinet.clear_cabinet()
	var epoch := cabinet.capture_epoch
	_expect(cabinet.show_visual_preview(measured, 1, points, false, epoch), "pre-disconnect preview")
	cabinet.call("_on_capture_connection", false)
	_expect(not cabinet.confirm_preview(), "disconnect invalidates pending CAD result")
	_expect(not cabinet.show_visual_preview(measured, 1, points, false, epoch), "late response rejected")
	cabinet.clear_cabinet()
	_expect(cabinet.show_visual_preview(measured, 1, points, false, cabinet.capture_epoch), "before tracking loss")
	cabinet.tracking = false
	_expect(not cabinet.confirm_preview(), "tracking loss blocks apply")
	cabinet.tracking = true
	cabinet.clear_cabinet()
	cabinet.open_panel()
	await process_frame
	var ui: Control = cabinet.get("_ui")
	_expect(ui.name == "CabinetVisualUI", "product entry defaults to CAD UI")
	_expect(is_equal_approx(ui.call("physical_scale"), 1), "default physical scale is 1:1")
	_expect(ui.get("_image") is TextureRect, "CAD image has no manual point collector")
	if OS.get_cmdline_user_args().has("--cad-worker"):
		# Send actual JPEG bytes through the live capture + Python path. A blank
		# scene must fail without moving tracking or inventing manual corners.
		var blank := Image.create(64, 64, false, Image.FORMAT_RGB8)
		blank.fill(Color.GRAY)
		var metadata := CameraFixture.fixture()
		metadata.merge({"camera_intrinsics_width": 64, "camera_intrinsics_height": 64,
			"camera_intrinsics_fx": 60.0, "camera_intrinsics_fy": 60.0,
			"camera_intrinsics_cx": 32.0, "camera_intrinsics_cy": 32.0})
		for i in range(3):
			cabinet.injected_frames.append({"timestamp_ns": str(i + 100), "size": Vector2i(64, 64),
				"metadata": metadata, "head_world": camera.global_transform,
				"jpeg": blank.save_jpg_to_buffer(), "epoch": cabinet.capture_epoch})
		var before_rejection := origin.global_transform
		ui.call("_begin")
		for i in range(3):
			ui.call("_capture")
		var rejection_end := Time.get_ticks_msec() + 120_000
		while bool(ui.get("_busy")) and Time.get_ticks_msec() < rejection_end:
			await create_timer(0.05).timeout
		_expect((ui.get("_result") as Dictionary).is_empty() and (ui.get("_apply") as Button).disabled,
			"blank live JPEG must not enable alignment")
		_expect((ui.get("_status") as Label).text.contains("未找到可靠"), "live rejection returns actionable status")
		_expect(origin.global_transform.is_equal_approx(before_rejection), "rejection preserves world mapping")
		(ui.get("_source") as OptionButton).select(1)
		ui.call("_begin")
		var end := Time.get_ticks_msec() + 120_000
		while bool(ui.get("_busy")) and Time.get_ticks_msec() < end:
			await create_timer(0.05).timeout
		_expect(not (ui.get("_result") as Dictionary).is_empty(), "real Python CAD demo completes: " + str((ui.get("_status") as Label).text))
		_expect((ui.get("_apply") as Button).disabled, "synthetic worker result cannot apply")
		_expect((ui.get("_image") as TextureRect).texture != null, "actual CAD overlay reaches XR panel")
		if OS.get_cmdline_user_args().has("--capture-ui") and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			ui.get_viewport().get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("cabinet-visual-ui.png"))
		ui.call("_begin")
		var job: Node = ui.get("_job")
		var pid: int = job.get("_pid")
		cabinet.close_panel()
		_expect(not bool(ui.get("_busy")) and int(job.get("_pid")) == -1, "closing cancels owned worker")
		_expect(pid <= 0 or not OS.is_process_running(pid), "cancel terminates worker process")
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("Cabinet CAD runtime self-test passed")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _test_batches() -> void:
	var measured := Transform3D(Basis.from_euler(Vector3(0.2, 0.4, -0.1)), Vector3(0.3, 0.4, -2))
	var captures: Array[Dictionary] = []
	var rows: Array = []
	for i in range(3):
		var camera := Transform3D(Basis(Vector3.UP, i * 0.04), Vector3(i * 0.01, 1.6, 0))
		captures.append({"capture_id": str(i), "camera_world": camera})
		var pose := Visual.OPENCV_TO_GODOT.affine_inverse() * camera.affine_inverse() * measured
		rows.append({"capture_id": str(i), "status": "candidate", "inliers": 20,
			"reprojection_rms_px": 1.0, "camera_from_model": _matrix(pose)})
	var response := {"schema_version": 1, "status": "candidate", "units": "meters", "physical_scale": 1.0,
		"coordinate_system": "opencv_camera_x_right_y_down_z_forward",
		"model_coordinates": "godot_frame_mesh_local_right_handed_y_up", "mode": "live", "frames": rows}
	var result := Visual.validate_batch(response, captures, 1.0)
	_expect(result.has("pose") and (result.pose as Transform3D).is_equal_approx(measured), "camera motion composes into consistent world pose")
	var bad := response.duplicate(true)
	bad.frames[2].camera_from_model[0][3] += 0.2
	_expect(Visual.validate_batch(bad, captures, 1).has("error"), "inconsistent object pose rejected")
	bad = response.duplicate(true)
	bad.frames[0].status = "ambiguous"
	_expect(Visual.validate_batch(bad, captures, 1).has("error"), "ambiguous result rejected")
	bad = response.duplicate(true)
	bad.frames[1].capture_id = "0"
	_expect(Visual.validate_batch(bad, captures, 1).has("error"), "duplicate/reordered frames rejected")
	_expect(Visual.validate_batch(response, captures, 1.0 / 3).has("error"), "scale mismatch rejected")


func _matrix(t: Transform3D) -> Array:
	return [[t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x],
		[t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y],
		[t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z], [0, 0, 0, 1]]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
