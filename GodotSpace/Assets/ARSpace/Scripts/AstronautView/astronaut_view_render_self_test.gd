extends SceneTree

const VirtualSourceScript = preload(
	"res://Assets/ARSpace/Scripts/AstronautView/virtual_camera_view_source.gd"
)
const SKY_PEER_ID: int = 42
const OUTPUT_PATH: String = "user://astronaut_view_render_self_test.png"

var _failures: Array[String] = []
var _world: Node3D
var _sky_player: RenderSkyPlayer
var _source: Node


class RenderSkyPlayer extends Node3D:
	var network_head: Node3D
	var last_pose_msec: int = 0

	func _init() -> void:
		network_head = Node3D.new()
		network_head.name = "NetworkHead"
		network_head.visible = true
		add_child(network_head)
		last_pose_msec = Time.get_ticks_msec()

	func get_network_viewpoint() -> Node3D:
		return network_head

	func has_received_network_pose() -> bool:
		return true

	func get_last_network_pose_received_msec() -> int:
		return last_pose_msec

	func set_head_transform(value: Transform3D) -> void:
		network_head.global_transform = value
		last_pose_msec = Time.get_ticks_msec()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_world = Node3D.new()
	_world.name = "AstronautViewRenderWorld"
	root.add_child(_world)
	_add_test_box("VisibleRedTarget", Vector3(0.0, 1.0, -3.0), Color(0.95, 0.05, 0.02), 1)
	_add_test_box("ExcludedMagentaBlocker", Vector3(0.0, 1.0, -1.5), Color(1.0, 0.0, 1.0), 1 << 19)

	_sky_player = RenderSkyPlayer.new()
	_sky_player.name = str(SKY_PEER_ID)
	_world.add_child(_sky_player)
	_sky_player.set_head_transform(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0)))

	_source = VirtualSourceScript.new()
	_source.name = "VirtualCameraViewSource"
	_source.set("capture_resolution", Vector2i(320, 180))
	_source.set("fallback_fov_degrees", 55.0)
	_world.add_child(_source)
	await process_frame
	_source.call("start", SKY_PEER_ID)
	_source.call("_resolve_source_nodes")
	await _wait_for_render_frames(4)

	var viewport := _source.call("get_capture_viewport") as SubViewport
	_expect(viewport != null, "Render test requires the production capture viewport.")
	if viewport == null:
		_finish()
		return
	var first_image := viewport.get_texture().get_image()
	_expect(first_image != null and not first_image.is_empty(), "Astronaut-view capture should produce a non-empty image.")
	if first_image == null or first_image.is_empty():
		_finish()
		return
	first_image.save_png(OUTPUT_PATH)

	var center := first_image.get_pixel(first_image.get_width() / 2, first_image.get_height() / 2)
	_expect(center.r > 0.55 and center.r > center.b * 1.4, "Center pixel should show the red target, not the excluded magenta blocker.")
	_expect(_colored_pixel_ratio(first_image) > 0.02, "Rendered Sky view should contain a visible test target.")

	_sky_player.set_head_transform(Transform3D(Basis.IDENTITY, Vector3(2.0, 1.0, 0.0)))
	_source.call("_process", 0.016)
	await _wait_for_render_frames(3)
	var moved_image := viewport.get_texture().get_image()
	_expect(
		_image_difference_ratio(first_image, moved_image) > 0.015,
		"Moving the Sky head should materially change the captured image."
	)
	_finish()


func _add_test_box(node_name: String, position: Vector3, color: Color, layers: int) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	mesh_instance.position = position
	mesh_instance.layers = layers
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 1.2, 0.25)
	mesh_instance.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_instance.material_override = material
	_world.add_child(mesh_instance)


func _wait_for_render_frames(frame_count: int) -> void:
	for _frame in range(frame_count):
		await process_frame
		await RenderingServer.frame_post_draw


func _colored_pixel_ratio(image: Image) -> float:
	var colored_pixels := 0
	var sampled_pixels := 0
	for y in range(0, image.get_height(), 3):
		for x in range(0, image.get_width(), 3):
			var color := image.get_pixel(x, y)
			if maxf(color.r, maxf(color.g, color.b)) > 0.35:
				colored_pixels += 1
			sampled_pixels += 1
	return float(colored_pixels) / float(maxi(sampled_pixels, 1))


func _image_difference_ratio(first: Image, second: Image) -> float:
	if second == null \
			or first.get_width() != second.get_width() \
			or first.get_height() != second.get_height():
		return 1.0
	var accumulated_difference := 0.0
	var sample_count := 0
	for y in range(0, first.get_height(), 4):
		for x in range(0, first.get_width(), 4):
			var left := first.get_pixel(x, y)
			var right := second.get_pixel(x, y)
			accumulated_difference += absf(left.r - right.r)
			accumulated_difference += absf(left.g - right.g)
			accumulated_difference += absf(left.b - right.b)
			sample_count += 3
	return accumulated_difference / float(maxi(sample_count, 1))


func _finish() -> void:
	if _source != null and is_instance_valid(_source):
		_source.call("stop")
	if _world != null and is_instance_valid(_world):
		_world.queue_free()
	if _failures.is_empty():
		print("Astronaut view render self-test passed. Output: %s" % ProjectSettings.globalize_path(OUTPUT_PATH))
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
