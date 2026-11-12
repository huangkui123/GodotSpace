extends SceneTree

var failures: Array[String] = []
var viewport: SubViewport


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This test requires GPU rendering; use --xr-mode off without --headless")
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = Vector2i(256, 256)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 3.0
	viewport.add_child(camera)
	camera.make_current()
	await _check_merged_geometry()
	await _check_symbols()
	viewport.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("Cabinet material render test ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _check_merged_geometry() -> void:
	# A small red part in front of a white panel, but later triangles draw the
	# panel last. This reproduces the CAD's unsortable triangles in one surface.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for item in [[0.35, 0.3, Color.RED], [0.8, 0.0, Color.WHITE]]:
		var s: float = item[0]
		var z: float = item[1]
		for point in [Vector2(-s, -s), Vector2(s, -s), Vector2(s, s), Vector2(-s, -s), Vector2(s, s), Vector2(-s, s)]:
			surface.set_color(item[2])
			surface.add_vertex(Vector3(point.x, point.y, z))
	var mesh := MeshInstance3D.new()
	mesh.mesh = surface.commit()
	var source := StandardMaterial3D.new()
	source.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	source.vertex_color_use_as_albedo = true
	source.cull_mode = BaseMaterial3D.CULL_DISABLED
	var controller := load("res://Assets/ARSpace/Scripts/UI/cabinet_opacity.gd").new() as Node3D
	var material: ShaderMaterial = controller.call("_copy_material", source)
	mesh.material_override = material
	viewport.add_child(mesh)
	var capture := load("res://Assets/ARSpace/Scripts/UI/cabinet_depth_capture.gd").new() as Node
	capture.sources.append(mesh)
	capture.materials.append(material)
	viewport.add_child(capture)
	controller.set("_capture", capture)
	var red_counts: Array[int] = []
	for alpha in [1.0, 0.99, 0.71, 0.25, 0.0]:
		controller.call("set_opacity", alpha)
		var image := await _capture()
		var reds := 0
		var coverage := 0
		for y in range(92, 164):
			for x in range(92, 164):
				var pixel := image.get_pixel(x, y)
				if pixel.r > 0.1 and pixel.g < 0.1 and pixel.a > 0.01:
					reds += 1
				_expect(absf(pixel.a - alpha) < 0.015, "every interior pixel must have continuous alpha %.2f, got %.3f" % [alpha, pixel.a])
				if pixel.a > 0.01:
					coverage += 1
		red_counts.append(reds)
		if alpha == 0.0:
			_expect(coverage == 0, "zero coverage must clear the entire CAD including its small part")
	print("Merged CAD red-detail counts at 100/99/71/25/0%: ", red_counts)
	_expect(red_counts[1] > red_counts[0] * 0.95, "99% must not abruptly lose small foreground parts")
	_expect(red_counts[2] > red_counts[0] * 0.55, "71% must preserve foreground detail instead of overwriting it with the back panel")
	# Sweep the reported low-alpha range without settling between steps, through
	# the same PICO compositor used by the headset. Include repeated zero starts.
	var low_camera := viewport.get_camera_3d()
	var pico_compositor := Compositor.new()
	pico_compositor.compositor_effects = [load("res://Assets/ARSpace/Scripts/XR/pico_streaming_alpha_effect.gd").new()]
	low_camera.compositor = pico_compositor
	var low_alpha_error := 0.0
	var low_color_error := 0.0
	for step in 96:
		var alpha := absf((step % 32) - 16) / 100.0
		controller.call("set_opacity", alpha)
		low_camera.position.z = 3.0 + sin(step * 0.3) * 0.2
		await process_frame
		await RenderingServer.frame_post_draw
		var pixel := viewport.get_texture().get_image().get_pixel(128, 128)
		low_alpha_error = maxf(low_alpha_error, absf(pixel.a - alpha))
		low_color_error = maxf(low_color_error, maxf(absf(pixel.r - alpha), maxf(pixel.g, pixel.b)))
	print("Low-alpha moving sweep through PICO effect: alpha error=", low_alpha_error, " RGB error=", low_color_error)
	_expect(low_alpha_error < 0.006 and low_color_error < 0.012, "0-16% must stay continuous through PICO color correction and zero restarts")
	low_camera.compositor = null
	low_camera.position.z = 3.0
	# The private cabinet depth must not block a transparent UI behind it.
	controller.call("set_opacity", 0.71)
	var main_camera := viewport.get_camera_3d()
	main_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	main_camera.position = Vector3(0.15, 0.1, 3)
	main_camera.look_at(Vector3(0, 0, 0.3))
	viewport.size = Vector2i(320, 240)
	var moved := await _capture()
	var moved_pixel := moved.get_pixel(160, 120)
	_expect(absf(moved_pixel.a - 0.71) < 0.015 and moved_pixel.g < 0.05 and moved_pixel.r > 0.5,
		"moving camera and resizing viewport must keep smooth nearest surface")
	var unstable_frames := 0
	for step in 90:
		mesh.position.x = cos(step * 0.13) * 0.2
		mesh.rotation.y = sin(step * 0.09) * 0.18
		main_camera.position = Vector3(sin(step * 0.17) * 0.4, cos(step * 0.11) * 0.2, 3.0 + sin(step * 0.23) * 0.7)
		main_camera.look_at(mesh.to_global(Vector3(0, 0, 0.3)))
		await process_frame
		await RenderingServer.frame_post_draw
		var moving_pixel := viewport.get_texture().get_image().get_pixel(160, 120)
		if absf(moving_pixel.a - 0.71) > 0.015 or moving_pixel.g > 0.05:
			unstable_frames += 1
	print("Continuous moving-camera unstable frames: ", unstable_frames, "/90")
	_expect(unstable_frames == 0, "continuous head motion must not change alpha or lose foreground detail")
	mesh.transform = Transform3D.IDENTITY
	main_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	main_camera.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 3))
	viewport.size = Vector2i(256, 256)
	var ui := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)
	ui.mesh = quad
	ui.position.z = -0.5
	var blue := StandardMaterial3D.new()
	blue.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	blue.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	blue.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	blue.albedo_color = Color(0, 0, 1, 0.6)
	ui.material_override = blue
	viewport.add_child(ui)
	var behind := await _capture()
	_expect(behind.get_pixel(128, 128).b > 0.2, "transparent background UI must remain visible through the cabinet")
	ui.position.z = 0.6
	var ahead := await _capture()
	_expect(ahead.get_pixel(128, 128).b > behind.get_pixel(128, 128).b, "front UI must blend in front of the cabinet")
	blue.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	blue.albedo_color = Color.GREEN
	var occluded := await _capture()
	_expect(occluded.get_pixel(128, 128).g > 0.95 and occluded.get_pixel(128, 128).r < 0.01, "opaque foreground still occludes faded cabinet")
	ui.queue_free()
	await process_frame
	# Exercise asymmetric optical projections for both eyes without hardware.
	for eye in 2:
		var projection := Projection.create_frustum(-0.07 + eye * 0.01, 0.09 + eye * 0.01, -0.08, 0.06, 0.1, 100.0)
		var pose := Transform3D(Basis.IDENTITY, Vector3(-0.032 if eye == 0 else 0.032, 0, 3))
		capture.call("_configure_xr_view", eye, projection, pose, 512, 0.1, 100.0)
		var actual: Projection = capture.get("_cameras")[eye].get_camera_projection()
		_expect(absf(actual.z.x - projection.z.x) < 0.001 and absf(actual.z.y - projection.z.y) < 0.001,
			"eye %d must preserve off-axis projection" % eye)
		_expect(absf(actual.x.x - projection.x.x) < 0.003 and absf(actual.y.y - projection.y.y) < 0.003,
			"eye %d must preserve field of view" % eye)
	RenderingServer.frame_pre_draw.disconnect(capture._update_views)
	var right_camera: Camera3D = capture.get("_cameras")[1]
	capture.get("_views")[1].render_target_update_mode = SubViewport.UPDATE_ALWAYS
	material.set_shader_parameter("capture_view_right", right_camera.global_transform.affine_inverse())
	material.set_shader_parameter("capture_projection_right", right_camera.get_camera_projection())
	var right_shader := Shader.new()
	right_shader.code = material.shader.code.replace("VIEW_INDEX == 0", "false")
	material.shader = right_shader
	var right_image := await _capture()
	var right_pixel := right_image.get_pixel(128, 128)
	_expect(absf(right_pixel.a - 0.71) < 0.015 and right_pixel.g < 0.05 and right_pixel.r > 0.5,
		"right-eye texture and asymmetric projection must preserve smooth front detail: %s" % right_pixel)
	# Confirm the previous alpha-blend approach actually fails this fixture.
	mesh.material_override = source
	source.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	source.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	source.albedo_color.a = 0.71
	var legacy := await _capture()
	_expect(legacy.get_pixel(128, 128).g > 0.4, "legacy fixture must reproduce white back-panel overwriting red foreground")
	mesh.queue_free()
	capture.queue_free()
	controller.free()
	await process_frame


func _check_symbols() -> void:
	var effects := load("res://Assets/ARSpace/Models/WorkEffect.prefab.tscn").instantiate() as Node3D
	var originals: Dictionary = {}
	for mesh in effects.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or mesh.mesh.get_surface_count() == 0:
			continue
		var source := mesh.get_active_material(0) as BaseMaterial3D
		if source != null and source.resource_path.get_file() in ["M_Arrow.material", "M_Arrow_L.material"]:
			originals[mesh] = source
	root.add_child(effects)
	_expect(originals.size() == 4, "fixture must include all three green arrows and the red curved arrow")
	var tested: Dictionary = {}
	for original_mesh in originals:
		var original := originals[original_mesh] as BaseMaterial3D
		var symbol := original_mesh.get_active_material(0) as ShaderMaterial
		_expect(symbol != null, "real WorkEffect must adapt arrow materials")
		_expect(original.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_ALWAYS, "shared source must remain unchanged")
		if tested.has(original) or symbol == null:
			continue
		tested[original] = true
		var mesh := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(2, 2)
		mesh.mesh = quad
		viewport.add_child(mesh)
		mesh.material_override = original
		var before := await _capture()
		mesh.material_override = symbol
		var after := await _capture()
		var old_halo := 0
		var new_halo := 0
		var solid := 0
		for y in 256:
			for x in 256:
				var old_pixel := before.get_pixel(x, y)
				var new_pixel := after.get_pixel(x, y)
				if old_pixel.a > 0.05 and old_pixel.a < 0.8:
					old_halo += 1
					if new_pixel.a > 0.01:
						new_halo += 1
				if new_pixel.a > 0.99:
					solid += 1
		print(original.resource_path.get_file(), " halo pixels ", old_halo, " -> ", new_halo, "; solid symbol=", solid)
		_expect(old_halo > 1000 and new_halo == 0, "original glow must be reproduced and removed")
		_expect(solid > 500, "removing glow must retain a solid arrow")
		after.save_png(OS.get_environment("TEMP").path_join(original.resource_path.get_file() + "-clean.png"))
		mesh.queue_free()
		await process_frame
	effects.queue_free()
	await process_frame


func _capture() -> Image:
	for _i in 5:
		await process_frame
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
