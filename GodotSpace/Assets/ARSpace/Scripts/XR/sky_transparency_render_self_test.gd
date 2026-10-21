extends SceneTree

var failures: Array[String] = []
var viewport: SubViewport


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This test requires a rendering window; omit --headless and use --xr-mode off.")
		quit(1)
		return
	var xr_main_script := load("res://XR_Main.gd") as Script
	if xr_main_script == null or not xr_main_script.can_instantiate():
		push_error("XR_Main must compile before running the render test")
		quit(1)
		return
	var xr_main := xr_main_script.new() as Node3D
	viewport = SubViewport.new()
	viewport.size = Vector2i(160, 160)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position.z = 3
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2
	viewport.add_child(camera)
	camera.make_current()

	# Use a real imported cabinet material with its original Always depth mode.
	var imported := load("res://Assets/ARSpace/Models/dashiyangui/dashiyangui-02.material") as BaseMaterial3D
	var foreground_source := imported.duplicate(false) as BaseMaterial3D
	foreground_source.albedo_texture = null
	foreground_source.albedo_color = Color.WHITE
	foreground_source.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	foreground_source.render_priority = -1
	var foreground := _quad(0.4, foreground_source)
	# Check absolute alpha, not only whether another transparent surface remains
	# visible. Mobile's 2-bit intermediate alpha can turn 1/5/10% into zero and
	# jump by 1/3 near a threshold even though the depth-overlap test passes.
	await _test_alpha_precision(xr_main, foreground, foreground_source)
	await _test_pico_encoded_color(xr_main, foreground, foreground_source)
	var background_material := StandardMaterial3D.new()
	background_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	background_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	background_material.albedo_color = Color(0, 0, 1, 0.8)
	background_material.render_priority = 1
	var background := _quad(0, background_material)
	foreground.visible = false
	var background_pixel := await _center_pixel()
	_expect(background_pixel.b > 0.75 and background_pixel.a > 0.5,
		"render fixture must show the blue transparent background")
	foreground.visible = true
	# Force the far transparent surface to draw later, reproducing the order
	# that intersecting transparent meshes can produce. A faded front surface
	# must not leave an opaque depth mask that punches holes in the far one.
	for opacity in [0.0, 0.01, 0.05, 0.1]:
		foreground.material_override = xr_main.call("_get_sky_transparent_material", foreground_source, opacity)
		var center := await _center_pixel()
		_expect(center.b >= background_pixel.b - 0.02 and center.a >= background_pixel.a - 0.02,
			"opacity %.2f must not punch a depth hole in later transparent geometry; pixel=%s" % [opacity, center])

	# Disabling depth *writes* must not disable depth *testing*. An opaque
	# object in front still correctly occludes the faded virtual object.
	background.visible = false
	foreground.material_override = xr_main.call("_get_sky_transparent_material", foreground_source, 0.1)
	var opaque_material := StandardMaterial3D.new()
	opaque_material.albedo_color = Color(0, 1, 0)
	opaque_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_quad(0.8, opaque_material)
	var occluded := await _center_pixel()
	_expect(occluded.g > 0.95 and occluded.r < 0.02 and occluded.b < 0.02,
		"opaque foreground must still occlude transparent geometry; pixel=%s" % occluded)
	_expect(imported.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_ALWAYS,
		"Sky rendering must leave the authored cabinet material unchanged for other roles")
	xr_main.free()
	viewport.queue_free()
	await process_frame
	if failures.is_empty():
		print("Sky transparency render self-test passed (absolute alpha, moving view, smooth fade, transparent overlap, opaque occlusion).")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _test_alpha_precision(
	xr_main: Node3D,
	foreground: MeshInstance3D,
	source: BaseMaterial3D
) -> void:
	print("Sky alpha renderer: ", RenderingServer.get_current_rendering_method())
	var camera := viewport.get_camera_3d()
	# Sample well inside the surface while moving the camera, so silhouette
	# coverage cannot explain changes in alpha. Output is RGBA8: allow 2 codes.
	const ALPHA_TOLERANCE := 2.0 / 255.0
	for opacity in [0.0, 0.01, 0.02, 0.05, 0.1, 0.15, 0.2, 0.33, 0.5, 0.8, 1.0]:
		foreground.material_override = xr_main.call("_get_sky_transparent_material", source, opacity)
		var max_error := 0.0
		var min_alpha := 1.0
		var max_alpha := 0.0
		for sample in range(3):
			camera.position.x = (sample - 1) * 0.025
			var center := await _center_pixel()
			max_error = maxf(max_error, absf(center.a - opacity))
			min_alpha = minf(min_alpha, center.a)
			max_alpha = maxf(max_alpha, center.a)
		print("Sky alpha input=%.3f output=[%.4f, %.4f]" % [opacity, min_alpha, max_alpha])
		_expect(max_error <= ALPHA_TOLERANCE,
			"alpha %.3f must survive rendering (max error %.4f)" % [opacity, max_error])
		_expect(max_alpha - min_alpha <= ALPHA_TOLERANCE,
			"camera motion must not change interior opacity %.3f" % opacity)
	# Exercise the observed Mobile discontinuity without permitting an opacity
	# floor or snapping small values to zero as a workaround.
	var previous_alpha := -1.0
	for step in range(15, 23):
		var opacity := step / 100.0
		foreground.material_override = xr_main.call("_get_sky_transparent_material", source, opacity)
		var alpha := (await _center_pixel()).a
		if previous_alpha >= 0.0:
			_expect(absf(alpha - previous_alpha - 0.01) <= ALPHA_TOLERANCE,
				"1%% opacity step must remain smooth; %.4f -> %.4f" % [previous_alpha, alpha])
		previous_alpha = alpha
	camera.position.x = 0


func _test_pico_encoded_color(
	xr_main: Node3D,
	foreground: MeshInstance3D,
	source: BaseMaterial3D
) -> void:
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		return
	var camera := viewport.get_camera_3d()
	var compositor := Compositor.new()
	compositor.compositor_effects = [load("res://Assets/ARSpace/Scripts/XR/pico_streaming_alpha_effect.gd").new()]
	camera.compositor = compositor
	# The encoded RGB contribution must now equal straight sRGB * alpha,
	# not sRGB(linear RGB * alpha). Alpha and opaque endpoint are preserved.
	for color in [Color.WHITE, Color(0.8, 0.3, 0.1, 1)]:
		var colored_source := source.duplicate(false) as BaseMaterial3D
		colored_source.albedo_color = color
		for opacity in [0.0, 0.01, 0.05, 0.1, 0.5, 1.0]:
			foreground.material_override = xr_main.call("_get_sky_transparent_material", colored_source, opacity)
			var pixel := await _center_pixel()
			var expected := Color(color.r * opacity, color.g * opacity, color.b * opacity, opacity)
			var error := maxf(absf(pixel.r - expected.r), absf(pixel.g - expected.g))
			error = maxf(error, maxf(absf(pixel.b - expected.b), absf(pixel.a - expected.a)))
			print("PICO encoded alpha=%.2f pixel=%s expected=%s" % [opacity, pixel, expected])
			_expect(error <= 3.0 / 255.0,
				"PICO encoded premultiplication must preserve color/alpha/endpoints: %s vs %s" % [pixel, expected])
	camera.compositor = null
	# Reattaching a new instance must release the old GPU resources and work.
	compositor.compositor_effects = [load("res://Assets/ARSpace/Scripts/XR/pico_streaming_alpha_effect.gd").new()]
	camera.compositor = compositor
	foreground.material_override = xr_main.call("_get_sky_transparent_material", source, 0.05)
	var reattached := await _center_pixel()
	_expect(absf(reattached.r - 0.05) < 0.01 and absf(reattached.a - 0.05) < 0.01,
		"recreated PICO compositor must still render correctly")
	camera.compositor = null
	compositor = null


func _quad(z: float, material: Material) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.position.z = z
	mesh.material_override = material
	viewport.add_child(mesh)
	return mesh


func _center_pixel() -> Color:
	for _frame in range(4):
		await process_frame
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image().get_pixel(80, 80)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
