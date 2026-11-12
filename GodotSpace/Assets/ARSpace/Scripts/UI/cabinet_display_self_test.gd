extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var cabinet := load("res://Assets/ARSpace/Prefabs/UI/MaterialCanvas/dashiyangui.prefab.tscn").instantiate() as Node3D
	var frame := cabinet.get_node("dashiyangui/MeshRenderer") as MeshInstance3D
	var source := load("res://Assets/ARSpace/Models/dashiyangui/dashiyangui-02.material") as BaseMaterial3D
	var source_alpha := source.albedo_color.a
	var tips := cabinet.get_node("zhouxinjigou/zhouxinjigou_a/xiaoshiyangui_d/OldTips")
	var tip_mesh := MeshInstance3D.new()
	tip_mesh.mesh = BoxMesh.new()
	tips.add_child(tip_mesh)
	var tip_material := StandardMaterial3D.new()
	tip_mesh.material_override = tip_material
	root.add_child(cabinet)
	var animated_materials: Dictionary = {}
	for path in ["xiaoshiyangui/xiaoshiyangui_b", "xiaoshiyangui/xiaoshiyangui_c", "zhouxinjigou"]:
		for mesh in cabinet.get_node(path).find_children("*", "MeshInstance3D", true, false):
			animated_materials[mesh] = mesh.get_active_material(0)
	var material := frame.get_active_material(0) as ShaderMaterial
	_expect(material != source, "cabinet must own material copies")
	var tree_ui := load("res://Assets/ARSpace/Scripts/UI/tree_list.gd").new() as Tree
	for alpha in [0.0, 0.25, 1.0, 0.0, 1.0]:
		cabinet.get_node("CabinetOpacity").call("set_opacity", alpha)
		_expect(is_equal_approx(float(material.get_shader_parameter("cabinet_opacity")), alpha), "absolute cabinet alpha %.2f" % alpha)
		_expect(cabinet.visible and frame.visible, "zero opacity must not hide animation/guidance ancestors")
		_expect(tip_mesh.get_active_material(0) == tip_material, "guidance materials must remain untouched")
		for mesh in animated_materials:
			_expect(mesh.get_active_material(0) == animated_materials[mesh], "animated part material must remain untouched: %s" % mesh.get_path())
		_expect((cabinet.get_node("CabinetOpacity/CabinetOpacityPanel/Screen") as MeshInstance3D).material_override.albedo_color.a == 1.0,
			"slider must remain opaque and reachable")
		if alpha < 1.0:
			_expect(material.shader.code.contains("depth_draw_never") and not material.shader.code.contains("ALPHA_HASH"),
				"faded CAD must use smooth alpha without writing scene depth")
		else:
			_expect(material.shader.code.contains("depth_draw_opaque") and not material.shader.code.contains("ALPHA ="),
				"solid endpoint uses opaque shading and depth")
	# Exercise the real highlight/clear code during a slider change. Restoring
	# the highlight must restore the CURRENT opacity, not the old one.
	tree_ui.call("highlight_part", frame)
	var highlight := frame.get_active_material(0)
	cabinet.get_node("CabinetOpacity").call("set_opacity", 0.0)
	_expect(frame.get_active_material(0) == highlight, "highlight must survive hidden cabinet")
	tree_ui.call("clear_highlight", frame)
	_expect(frame.get_active_material(0) == material and float(material.get_shader_parameter("cabinet_opacity")) == 0.0, "clearing highlight retains latest opacity")
	tree_ui.free()
	var xr_main := load("res://XR_Main.gd").new() as Node3D
	xr_main.call("_apply_sky_transparency_to_subtree", cabinet)
	_expect(not frame.has_meta(xr_main.SKY_TRANSPARENCY_STATE_META), "global Sky opacity cannot override cabinet")
	xr_main.free()
	_expect(source.albedo_color.a == source_alpha, "shared imported material unchanged")
	cabinet.get_node("CabinetOpacity").call("set_opacity", 1.0)
	if DisplayServer.get_name() != "headless":
		await _test_slider_input(cabinet)
		await _render_cabinet(cabinet, frame)
		await _render_window()
		await _render_correction()
	cabinet.queue_free()
	await process_frame
	if failures.is_empty():
		print("Cabinet display self-test passed (opacity, guidance, highlight, UI lighting/depth, cast correction).")
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _test_slider_input(cabinet: Node3D) -> void:
	cabinet.get_node("CabinetOpacity").call("set_opacity", 0.0)
	await _frames()
	var slider := cabinet.get_node("CabinetOpacity").get("_slider") as HSlider
	var viewport := slider.get_viewport()
	var body := cabinet.get_node("CabinetOpacity/CabinetOpacityPanel/StaticBody3D")
	_expect((body.call("global_to_viewport", body.global_position) as Vector2).is_equal_approx(Vector2(240, 60)),
		"XR ray maps center of slider surface into its viewport")
	var click := InputEventMouseButton.new()
	click.position = slider.global_position + slider.size * Vector2(0.75, 0.5)
	click.global_position = click.position
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	viewport.push_input(click, true)
	click = click.duplicate()
	click.pressed = false
	viewport.push_input(click, true)
	await _frames()
	_expect(float(cabinet.get_node("CabinetOpacity").get("opacity")) > 0.6, "slider input restores a hidden cabinet")
	cabinet.get_node("CabinetOpacity").call("set_opacity", 1.0)


func _render_cabinet(cabinet: Node3D, frame: MeshInstance3D) -> void:
	# Isolate the fixed housings for the pixel-alpha assertion. Animated parts
	# intentionally remain opaque at zero and are checked separately above.
	var visibility: Dictionary = {}
	for path in ["xiaoshiyangui/xiaoshiyangui_b", "xiaoshiyangui/xiaoshiyangui_c", "zhouxinjigou", "gongju"]:
		var part := cabinet.get_node(path) as Node3D
		visibility[part] = part.visible
		part.visible = false
	var original_parent := cabinet.get_parent()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1152, 648)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	cabinet.reparent(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	var bounds := frame.get_aabb()
	print("Cabinet mesh bounds: ", bounds)
	camera.global_transform = frame.global_transform.orthonormalized()
	camera.global_position = frame.to_global(bounds.get_center() + Vector3(bounds.size.y * 1.3, 0, 0))
	camera.look_at(frame.to_global(bounds.get_center()), Vector3.UP)
	camera.make_current()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, -30, 0)
	viewport.add_child(light)
	await _frames()
	var image := viewport.get_texture().get_image()
	_expect(image.get_pixel(10, 10).a < 0.01, "cabinet surroundings must have zero alpha")
	var center := viewport.size / 2
	_expect(image.get_pixelv(center).a > 0.95, "solid cabinet center must be opaque")
	image.save_png(OS.get_environment("TEMP").path_join("cabinet-opacity-solid.png"))
	# Compare the actual imported materials at the solid endpoint, not only a
	# synthetic unlit fixture. Preserve the cabinet's authored surface detail.
	var originals: Array[Material] = []
	for surface in frame.mesh.get_surface_count():
		originals.append(frame.get_active_material(surface))
		frame.set_surface_override_material(surface, load("res://Assets/ARSpace/Models/dashiyangui/dashiyangui-02%s.material" % ("" if surface == 0 else " 1")))
	await _frames()
	var authored := viewport.get_texture().get_image()
	var difference := 0.0
	var samples := 0
	for y in range(0, image.get_height(), 2):
		for x in range(0, image.get_width(), 2):
			var pixel := image.get_pixel(x, y)
			if pixel.a > 0.99:
				var baseline := authored.get_pixel(x, y)
				difference += absf(pixel.r - baseline.r) + absf(pixel.g - baseline.g) + absf(pixel.b - baseline.b)
				samples += 3
	print("Cabinet solid material RGB mean error=", difference / maxi(1, samples))
	_expect(difference / maxi(1, samples) < 0.015, "smooth material must preserve authored solid cabinet shading")
	for surface in frame.mesh.get_surface_count():
		frame.set_surface_override_material(surface, originals[surface])
	cabinet.get_node("CabinetOpacity").call("set_opacity", 0.71)
	await _frames()
	viewport.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("cabinet-opacity-71.png"))
	cabinet.get_node("CabinetOpacity").call("set_opacity", 0.15)
	await _frames()
	image = viewport.get_texture().get_image()
	_expect(image.get_pixel(10, 10).a < 0.01, "fading cabinet must not fill the transparent surroundings")
	image.save_png(OS.get_environment("TEMP").path_join("cabinet-opacity-faded.png"))
	cabinet.get_node("CabinetOpacity").call("set_opacity", 0.0)
	await _frames()
	image = viewport.get_texture().get_image()
	_expect(image.get_pixelv(center).a < 0.01, "hidden cabinet must expose zero alpha, not opaque black")
	print("Cabinet background alpha=", image.get_pixel(10, 10).a,
		" hidden center alpha=", image.get_pixelv(center).a)
	image.save_png(OS.get_environment("TEMP").path_join("cabinet-opacity-hidden.png"))
	cabinet.reparent(original_parent)
	for part in visibility:
		part.visible = visibility[part]
	viewport.queue_free()
	await process_frame


func _render_window() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(160, 160)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_energy = 0.0
	viewport.add_child(environment)
	var camera := Camera3D.new()
	camera.position.z = 3
	viewport.add_child(camera)
	camera.make_current()
	var content := ColorRect.new()
	content.color = Color(0.1, 0.6, 1.0)
	content.size = Vector2(128, 128)
	var packed := PackedScene.new()
	packed.pack(content)
	content.free()
	var window := load("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn").instantiate() as Node3D
	window.set_script(load("res://Assets/ARSpace/Scripts/SpatialWindows/spatial_viewport_2d_in_3d.gd"))
	window.scene = packed
	window.screen_size = Vector2(2, 2)
	window.viewport_size = Vector2(128, 128)
	viewport.add_child(window)
	await _frames()
	var pixel := viewport.get_texture().get_image().get_pixel(80, 80)
	_expect(pixel.b > 0.9 and pixel.g > 0.5, "UI must stay readable in an unlit world: %s" % pixel)
	var screen := window.get_node("Screen") as MeshInstance3D
	var material := screen.get_active_material(0) as BaseMaterial3D
	_expect(not material.no_depth_test, "UI depth testing must remain enabled")
	var lit_baseline := material.duplicate(false) as BaseMaterial3D
	lit_baseline.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	screen.set_surface_override_material(0, lit_baseline)
	await _frames()
	var dark := viewport.get_texture().get_image().get_pixel(80, 80)
	_expect(dark.b < 0.1, "legacy lit UI reproduces blackening without scene light: %s" % dark)
	screen.set_surface_override_material(0, material)
	# A real opaque object in front must occlude, not render as a black UI.
	var blocker := MeshInstance3D.new()
	blocker.mesh = BoxMesh.new()
	blocker.position.z = 1.0
	var green := StandardMaterial3D.new()
	green.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	green.albedo_color = Color.GREEN
	blocker.material_override = green
	viewport.add_child(blocker)
	await _frames()
	pixel = viewport.get_texture().get_image().get_pixel(80, 80)
	_expect(pixel.g > 0.9 and pixel.b < 0.1, "opaque foreground must still occlude UI: %s" % pixel)
	blocker.position.z = -1.0
	await _frames()
	pixel = viewport.get_texture().get_image().get_pixel(80, 80)
	_expect(pixel.b > 0.9, "moving UI in front of cabinet restores its colors")
	viewport.queue_free()
	await process_frame


func _render_correction() -> void:
	var panel := load("res://Assets/ARSpace/Scenes/AstronautView/AstronautViewPanel.tscn").instantiate() as Control
	root.add_child(panel)
	panel.call("set_view_metadata", {"source_type": "pico_cast"})
	var toggle := panel.get("_correction_toggle") as CheckButton
	toggle.set_pressed_no_signal(true)
	var slider := panel.get("_correction_strength") as HSlider
	slider.set_value_no_signal(0.25)
	panel.call("_refresh_correction")
	var material := (panel.get("view_texture") as TextureRect).material as ShaderMaterial
	_expect(material != null, "cast uses production correction shader")
	panel.call("set_view_metadata", {"source_type": "pico_cast", "rectified": true})
	_expect((panel.get("view_texture") as TextureRect).material == null, "rectified video bypasses correction")
	panel.call("set_view_metadata", {"source_type": "virtual_camera"})
	_expect((panel.get("view_texture") as TextureRect).material == null, "synthetic video bypasses correction")
	panel.queue_free()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(320, 240)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var image := Image.create(320, 240, false, Image.FORMAT_RGBA8)
	for y in range(240):
		for x in range(320):
			image.set_pixel(x, y, Color(float(x) / 319, float(y) / 239, 1))
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(image)
	rect.size = Vector2(320, 240)
	rect.material = material
	viewport.add_child(rect)
	material.set_shader_parameter("video_aspect", 4.0 / 3.0)
	await _frames()
	var output := viewport.get_texture().get_image()
	var sample := output.get_pixel(280, 30)
	var uv := Vector2(280.5 / 320.0, 30.5 / 240.0)
	var aspect := Vector2(4.0 / 3.0, 1.0)
	var p := (uv - Vector2(0.5, 0.5)) * 2.0 * aspect
	var expected := Vector2(0.5, 0.5) + p / (1.0 + 0.25 * p.length_squared() / aspect.length_squared()) / aspect * 0.5
	_expect(absf(sample.r - expected.x) < 0.015 and absf(sample.g - expected.y) < 0.015 and sample.b > 0.98,
		"GPU samples radial mapping without double texture/color multiplication: %s expected %s" % [sample, expected])
	material.set_shader_parameter("strength", 0.0)
	await _frames()
	sample = viewport.get_texture().get_image().get_pixel(280, 30)
	_expect(absf(sample.r - uv.x) < 0.01 and absf(sample.g - uv.y) < 0.01, "zero correction is identity")
	# Generate a known barrel-distorted straight grid, then check that the
	# production shader reduces its image error, independently of the UV test.
	var distorted := Image.create(320, 240, false, Image.FORMAT_RGBA8)
	for y in range(240):
		for x in range(320):
			var point := (Vector2(x + 0.5, y + 0.5) / Vector2(320, 240) - Vector2(0.5, 0.5)) * 2.0 * aspect
			var radius := point.length_squared() / aspect.length_squared()
			var original := point * 2.0 / (1.0 + sqrt(maxf(0.0, 1.0 - radius)))
			distorted.set_pixel(x, y, _grid_color(Vector2(0.5, 0.5) + original / aspect * 0.5))
	rect.texture = ImageTexture.create_from_image(distorted)
	material.set_shader_parameter("strength", 0.25)
	await _frames()
	output = viewport.get_texture().get_image()
	var raw_error := 0.0
	var corrected_error := 0.0
	for y in range(25, 215):
		for x in range(25, 295):
			var ideal := _grid_color(Vector2(x + 0.5, y + 0.5) / Vector2(320, 240))
			raw_error += absf(distorted.get_pixel(x, y).r - ideal.r)
			corrected_error += absf(output.get_pixel(x, y).r - ideal.r)
	_expect(corrected_error < raw_error * 0.35, "known barrel distortion straightens: error %.1f -> %.1f" % [raw_error, corrected_error])
	print("Cast grid correction error: %.1f -> %.1f" % [raw_error, corrected_error])
	var comparison := Image.create(640, 240, false, Image.FORMAT_RGBA8)
	output.convert(Image.FORMAT_RGBA8)
	comparison.blit_rect(distorted, Rect2i(0, 0, 320, 240), Vector2i.ZERO)
	comparison.blit_rect(output, Rect2i(0, 0, 320, 240), Vector2i(320, 0))
	comparison.save_png(OS.get_environment("TEMP").path_join("cast-correction-grid.png"))
	viewport.queue_free()
	await process_frame


func _grid_color(uv: Vector2) -> Color:
	if uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1:
		return Color(0.3, 0.3, 0.3)
	var grid := uv * 8.0
	var line := absf(grid.x - roundf(grid.x)) < 0.045 or absf(grid.y - roundf(grid.y)) < 0.045
	return Color(0.05, 0.1, 0.15) if line else Color(0.9, 0.9, 0.9)


func _frames() -> void:
	for _i in range(5):
		await process_frame
		await RenderingServer.frame_post_draw


func _expect(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
