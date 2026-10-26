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
	_test_temporal_batches()
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
	# Exercise timed acquisition independently of detection and hardware.
	ui.set_process(false)
	ui.call("_begin")
	var started: int = ui.get("_capture_start")
	_expect(int(ui.get("_deadline")) - started == 8000, "capture window lasts eight seconds")
	var capture_metadata := CameraFixture.fixture()
	capture_metadata.merge({"camera_intrinsics_width": 64, "camera_intrinsics_height": 64,
		"camera_intrinsics_fx": 60.0, "camera_intrinsics_fy": 60.0,
		"camera_intrinsics_cx": 32.0, "camera_intrinsics_cy": 32.0})
	var capture_image := Image.create(64, 64, false, Image.FORMAT_RGB8)
	capture_image.fill(Color.GRAY)
	for id in ["a", "a", "b", "c"]:
		cabinet.injected_frames.append({"timestamp_ns": id, "size": Vector2i(64, 64),
			"metadata": capture_metadata, "head_world": camera.global_transform,
			"jpeg": capture_image.save_jpg_to_buffer(), "epoch": cabinet.capture_epoch})
		ui.call("_capture")
	_expect((ui.get("_captures") as Array).size() == 3 and int(ui.get("_skipped")) == 1,
		"repeated frame skipped without ending acquisition")
	_expect(bool(ui.get("_collecting")) and int(ui.get("_job").get("_pid")) == -1,
		"three captured frames do not end the continuous window early")
	cabinet.close_panel()
	_expect(not bool(ui.get("_busy")) and (ui.get("_captures") as Array).is_empty(),
		"closing during capture clears the sequence")
	cabinet.open_panel()
	ui.call("_begin")
	ui.call("_finish_capture")
	_expect(not bool(ui.get("_busy")) and (ui.get("_apply") as Button).disabled,
		"empty capture window fails without launching or applying")
	ui.call("_begin")
	cabinet.call("_on_capture_connection", false)
	ui.call("_process", 0.01)
	_expect(not bool(ui.get("_busy")), "disconnect cancels a live capture window")
	ui.set_process(true)
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
		var rejection_end := Time.get_ticks_msec() + 120_000
		while bool(ui.get("_busy")) and Time.get_ticks_msec() < rejection_end:
			await create_timer(0.05).timeout
		_expect((ui.get("_result") as Dictionary).is_empty() and (ui.get("_apply") as Button).disabled,
			"blank live JPEG must not enable alignment")
		_expect((ui.get("_status") as Label).text.contains("未找到可靠"), "live rejection returns actionable status")
		_expect(bool(ui.get("_hold_rejected_image")) and (ui.get("_image") as TextureRect).texture != null,
			"rejection retains actual last frame without authorizing application")
		_expect(origin.global_transform.is_equal_approx(before_rejection), "rejection preserves world mapping")
		(ui.get("_source") as OptionButton).select(1)
		ui.call("_begin")
		_expect(not bool(ui.get("_hold_rejected_image")), "new request releases rejected-frame preview")
		var end := Time.get_ticks_msec() + 120_000
		while bool(ui.get("_busy")) and Time.get_ticks_msec() < end:
			await create_timer(0.05).timeout
		_expect(not (ui.get("_result") as Dictionary).is_empty(), "real Python CAD demo completes: " + str((ui.get("_status") as Label).text))
		_expect((ui.get("_apply") as Button).disabled, "synthetic worker result cannot apply")
		_expect((ui.get("_image") as TextureRect).texture != null, "actual CAD overlay reaches XR panel")
		if OS.get_cmdline_user_args().has("--capture-ui") and DisplayServer.get_name() != "headless":
			await _capture_ui(ui, "cabinet-visual-ui.png")
		ui.call("_begin")
		var job: Node = ui.get("_job")
		var pid: int = job.get("_pid")
		cabinet.close_panel()
		_expect(not bool(ui.get("_busy")) and int(job.get("_pid")) == -1, "closing cancels owned worker")
		_expect(pid <= 0 or not OS.is_process_running(pid), "cancel terminates worker process")
	# Both product modes use the same image-only workflow; no point collector.
	cabinet.open_panel()
	await process_frame
	(ui.get("_kind") as OptionButton).select(1)
	ui.call("_options_changed")
	_expect((ui.call("dimensions_m") as Vector3).is_equal_approx(Vector3(0.45, 1.21, 0.80)), "custom defaults are width 45 height 121 depth 80 cm")
	_expect((ui.get("_dimension_row") as Control).visible and not (ui.get("_scale") as Control).visible, "custom dimensions replace CAD scale")
	_expect(not target.visible and (cabinet.get("_cabinet") as Node3D).visible, "model selector swaps CAD and cuboid")
	var dimension_buttons: Array = ui.get("_dimension_buttons")
	(dimension_buttons[1] as Button).pressed.emit()
	_expect((ui.call("dimensions_m") as Vector3).is_equal_approx(Vector3(0.46, 1.21, 0.8)), "VR plus changes width only in centimetres")
	(dimension_buttons[0] as Button).pressed.emit()
	var custom_size: Vector3 = ui.call("dimensions_m")
	_expect(cabinet.show_cuboid_visual_preview(measured, custom_size, false, cabinet.capture_epoch), "custom automatic pose previews without clicked corners")
	_expect(cabinet.confirm_preview(), "custom automatic result aligns scene")
	_expect(origin.global_basis.get_scale().is_equal_approx(Vector3.ONE), "custom dimensions do not scale XR tracking")
	_expect((cabinet.get("_cabinet").get("dimensions") as Vector3).is_equal_approx(custom_size), "virtual body uses requested physical dimensions")
	_expect(not cabinet.confirm_preview(), "custom result cannot apply twice")
	var applied_origin := origin.global_transform
	(ui.get("_dimensions")[1] as SpinBox).value = 130
	_expect(cabinet.state.status == "empty" and origin.global_transform.is_equal_approx(applied_origin), "size edit clears pending state but keeps applied mapping")
	_expect(not cabinet.show_cuboid_visual_preview(measured, custom_size, false, cabinet.capture_epoch), "old dimensions cannot authorize a preview")
	custom_size = ui.call("dimensions_m")
	_expect(cabinet.show_cuboid_visual_preview(measured, custom_size, false, cabinet.capture_epoch), "new dimensions preview")
	cabinet.call("_on_capture_connection", false)
	_expect(not cabinet.confirm_preview(), "disconnect invalidates custom automatic result")
	if OS.get_cmdline_user_args().has("--cad-worker") or OS.get_cmdline_user_args().has("--cuboid-worker"):
		(ui.get("_dimensions")[1] as SpinBox).value = 121
		(ui.get("_source") as OptionButton).select(1)
		var prior_artifacts := OS.get_environment("GODOTSPACE_CABINET_ARTIFACTS")
		OS.set_environment("GODOTSPACE_CABINET_ARTIFACTS", OS.get_environment("TEMP").path_join("no-cad-assets-required"))
		ui.call("_begin")
		OS.set_environment("GODOTSPACE_CABINET_ARTIFACTS", prior_artifacts)
		var custom_end := Time.get_ticks_msec() + 120_000
		while bool(ui.get("_busy")) and Time.get_ticks_msec() < custom_end:
			await create_timer(0.05).timeout
		_expect((ui.get("_result") as Dictionary).get("model_kind") == "cuboid", "real custom worker runs without CAD bank: " + str((ui.get("_status") as Label).text))
		_expect((ui.get("_apply") as Button).disabled, "custom synthetic result cannot apply")
		if OS.get_cmdline_user_args().has("--capture-ui") and DisplayServer.get_name() != "headless":
			await _capture_ui(ui, "cabinet-cuboid-ui.png")
		(ui.get("_dimensions")[0] as SpinBox).value = 50
		_expect((ui.get("_result") as Dictionary).is_empty(), "changing dimensions clears actual worker result")
	(ui.get("_kind") as OptionButton).select(0)
	ui.call("_options_changed")
	_expect(target.visible and not (cabinet.get("_cabinet") as Node3D).visible, "returning to CAD restores original model visibility")
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("Cabinet CAD/custom visual runtime self-test passed")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _capture_ui(ui: Control, filename: String) -> void:
	# The 3D panel may be outside the desktop test camera frustum after origin
	# rebasing. Render its SubViewport explicitly; never save a stale texture.
	var viewport := ui.get_viewport() as SubViewport
	var previous := viewport.render_target_update_mode
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await process_frame
	RenderingServer.force_draw()
	viewport.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join(filename))
	viewport.render_target_update_mode = previous


func _test_batches() -> void:
	var measured := Transform3D(Basis.from_euler(Vector3(0.2, 0.4, -0.1)), Vector3(0.3, 0.4, -2))
	var captures: Array[Dictionary] = []
	var rows: Array = []
	for i in range(3):
		var camera := Transform3D(Basis(Vector3.UP, i * 0.04), Vector3(i * 0.01, 1.6, 0))
		captures.append({"capture_id": str(i), "camera_world": camera, "captured_msec": i * 500})
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
	var custom := response.duplicate(true)
	custom["model_kind"] = "cuboid"
	custom["model_coordinates"] = "cabinet_front_bottom_left_x_right_y_up_depth_negative_z"
	custom["dimensions_m"] = [0.45, 1.21, 0.8]
	for row in custom.frames:
		row["inliers"] = 6
		row["edge_support"] = 1.0
		row["silhouette_iou"] = 0.99
	var dimensions := Vector3(0.45, 1.21, 0.8)
	_expect(Visual.validate_batch(custom, captures, 1, "cuboid", dimensions).has("pose"), "custom batch accepts automatic silhouette geometry")
	_expect(Visual.validate_batch(custom, captures, 1).has("error"), "custom result cannot be used for CAD")
	_expect(Visual.validate_batch(custom, captures, 1, "cuboid", Vector3.ONE).has("error"), "custom dimensions are bound to result")
	custom.frames[0]["edge_support"] = 0.1
	_expect(Visual.validate_batch(custom, captures, 1, "cuboid", dimensions).has("error"), "weak custom edges rejected")


func _matrix(t: Transform3D) -> Array:
	return [[t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x],
		[t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y],
		[t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z], [0, 0, 0, 1]]


func _sequence(offsets: Array, missing: Array = []) -> Dictionary:
	var captures: Array[Dictionary] = []
	var rows: Array = []
	for i in range(offsets.size()):
		var camera := Transform3D(Basis(Vector3.UP, i * 0.03), Vector3(i * 0.02, 1.6, 0))
		captures.append({"capture_id": str(i), "camera_world": camera, "captured_msec": i * 500})
		var world_pose := Transform3D(Basis(Vector3.UP, 0.4), Vector3(0.3 + offsets[i], 0.4, -2))
		var pose := Visual.OPENCV_TO_GODOT.affine_inverse() * camera.affine_inverse() * world_pose
		rows.append({"capture_id": str(i), "status": "not_found" if missing.has(i) else "candidate",
			"inliers": 20, "reprojection_rms_px": 1.0, "camera_from_model": _matrix(pose)})
	return {"captures": captures, "response": {"schema_version": 1, "status": "candidate",
		"units": "meters", "physical_scale": 1.0, "coordinate_system": "opencv_camera_x_right_y_down_z_forward",
		"model_coordinates": "godot_frame_mesh_local_right_handed_y_up", "mode": "live", "frames": rows}}


func _test_temporal_batches() -> void:
	var sequence := _sequence([0, 0, 0, 0.008, -0.008, 0.3, 0, 0.004], [0, 2, 6])
	# A very sharp but inconsistent frame must not become the overlay/pose.
	sequence.response.frames[5].reprojection_rms_px = 0.01
	sequence.response.frames[2].status = "ambiguous"
	var result := Visual.validate_batch(sequence.response, sequence.captures, 1)
	_expect(result.has("pose"), "dropouts and one outlier do not reject consistent remaining frames")
	if result.has("pose"):
		_expect(result.support_count == 4 and result.rejected_count == 3 and result.outlier_count == 1,
			"sequence reports actual accepted/rejected/outlier counts")
		_expect((result.pose as Transform3D).origin.is_equal_approx(Vector3(0.301, 0.4, -2)),
			"fusion averages accepted world positions rather than using last frame")
		_expect(result.representative_index != 5, "preview image belongs to accepted consensus")
	sequence = _sequence([0, 0, 0, 0, 0.2, 0.2, 0.2])
	_expect(Visual.validate_batch(sequence.response, sequence.captures, 1).has("error"),
		"two persistent poses rejected even when one has a majority")
	sequence = _sequence([0, 0.02, 0.04, 0.06, 0.08])
	_expect(Visual.validate_batch(sequence.response, sequence.captures, 1).has("error"),
		"transitive chain cannot manufacture consensus")
	sequence = _sequence([0, 0, 0])
	sequence.captures[1].captured_msec = 300
	sequence.captures[2].captured_msec = 600
	_expect(Visual.validate_batch(sequence.response, sequence.captures, 1).has("error"),
		"brief detection shorter than one second cannot apply")
	sequence.captures[1].captured_msec = 0
	_expect(Visual.validate_batch(sequence.response, sequence.captures, 1).has("error"),
		"duplicate capture times cannot count as independent samples")
	var offsets: Array = []
	for i in range(16):
		offsets.append(0)
	sequence = _sequence(offsets)
	result = Visual.validate_batch(sequence.response, sequence.captures, 1)
	_expect(result.get("support_count") == 16, "full sixteen-frame consensus stays bounded and succeeds")
	for i in range(16):
		if i not in [1, 5, 15]:
			sequence.response.frames[i].status = "not_found"
	result = Visual.validate_batch(sequence.response, sequence.captures, 1)
	_expect(result.get("support_count") == 3, "sparse but stable detections across window can succeed")
	sequence = _sequence([0, 0, 0])
	for i in range(3):
		var world_pose := Transform3D(Basis(Vector3.UP, deg_to_rad([179.8, -179.8, 180.0][i])), Vector3(0.3, 0.4, -2))
		var camera: Transform3D = sequence.captures[i].camera_world
		sequence.response.frames[i].camera_from_model = _matrix(Visual.OPENCV_TO_GODOT.affine_inverse() * camera.affine_inverse() * world_pose)
	result = Visual.validate_batch(sequence.response, sequence.captures, 1)
	_expect(result.has("pose") and (result.pose as Transform3D).basis.is_equal_approx(Basis(Vector3.UP, PI)),
		"quaternion fusion handles rotations crossing plus/minus 180 degrees")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
