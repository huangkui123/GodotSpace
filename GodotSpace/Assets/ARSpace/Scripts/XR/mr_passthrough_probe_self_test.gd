extends SceneTree

const Probe := preload("res://Assets/ARSpace/Scripts/XR/mr_passthrough_probe.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := Node3D.new()
	viewport.add_child(scene)
	var camera := Camera3D.new()
	camera.position.z = 2.0
	scene.add_child(camera)
	camera.make_current()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.layers = 5
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.RED
	mesh.material_override = material
	scene.add_child(mesh)
	var overlay := ColorRect.new()
	overlay.size = Vector2(8, 8)
	scene.add_child(overlay)
	var offscreen := SubViewport.new()
	offscreen.own_world_3d = true
	scene.add_child(offscreen)
	var private_mesh := MeshInstance3D.new()
	private_mesh.mesh = BoxMesh.new()
	private_mesh.layers = 9
	offscreen.add_child(private_mesh)
	var probe := Probe.new()
	probe.duration = 0.8
	scene.add_child(probe)
	await _frames()
	if DisplayServer.get_name() != "headless":
		_expect(viewport.get_texture().get_image().get_pixel(32, 32).a > 0.99, "baseline is opaque")
	_expect(probe.start(scene), "probe starts")
	_expect(not probe.start(scene), "repeated clicks cannot extend the test")
	_expect(mesh.layers == 0 and mesh.visible and not overlay.visible, "probe hides drawing, not node visibility or processing")
	_expect(camera.current and private_mesh.layers == 9, "camera and other viewport data are untouched")
	var added := MeshInstance3D.new()
	added.layers = 17
	added.mesh = BoxMesh.new()
	scene.add_child(added)
	await _frames()
	_expect(added.layers == 0, "new geometry is also hidden during the probe")
	if DisplayServer.get_name() != "headless":
		var blank := viewport.get_texture().get_image()
		_expect(blank.get_pixel(32, 32).a < 0.01 and blank.get_pixel(4, 4).a < 0.01,
			"both model and overlay locations expose zero-alpha background")
	await create_timer(0.9).timeout
	_expect(not probe.active and mesh.layers == 5 and added.layers == 17 and overlay.visible,
		"automatic timeout restores exact original layers and canvas state")
	_expect(mesh.material_override == material and material.albedo_color == Color.RED, "no material or opacity mutation")
	_expect(not probe.start(scene, Probe.Mode.ONLY_CABINET), "missing cabinet cannot produce a misleading blank comparison")
	mesh.add_to_group("independent_cabinet_visuals")
	_expect(probe.start(scene, Probe.Mode.HIDE_CABINET), "cabinet-only hiding starts")
	_expect(mesh.layers == 0 and added.layers == 17 and overlay.visible,
		"hiding the cabinet preserves surrounding drawing and UI")
	var cabinet_child := MeshInstance3D.new()
	cabinet_child.layers = 3
	cabinet_child.mesh = BoxMesh.new()
	mesh.add_child(cabinet_child)
	await _frames()
	_expect(cabinet_child.layers == 0, "new cabinet descendants obey selective hiding")
	probe.finish()
	_expect(cabinet_child.layers == 3 and mesh.layers == 5, "selective hide restores descendant layers")
	_expect(probe.start(scene, Probe.Mode.ONLY_CABINET), "cabinet isolation starts")
	_expect(mesh.layers == 5 and cabinet_child.layers == 3 and added.layers == 0 and not overlay.visible,
		"isolation preserves the whole cabinet group and hides surrounding content")
	_expect(private_mesh.layers == 9, "selective probe leaves private viewport data alone")
	probe.finish()
	_expect(added.layers == 17 and overlay.visible, "isolation restores surrounding content")
	_expect(probe.start(scene), "probe can run again")
	added.queue_free()
	await process_frame
	probe.queue_free()
	await process_frame
	_expect(mesh.layers == 5 and overlay.visible, "removing probe also restores rendering")
	viewport.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("MR passthrough probe self-test ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _frames() -> void:
	for step in 3:
		await process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
