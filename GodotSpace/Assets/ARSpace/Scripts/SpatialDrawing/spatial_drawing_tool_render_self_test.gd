extends SceneTree

const ToolScene := preload(
	"res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingTip.tscn"
)
const OUTPUT_PATH := "user://spatial_drawing_tool_preview.png"
const CAPTURE_SIZE := Vector2i(720, 720)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = CAPTURE_SIZE
	var world := Node3D.new()
	root.add_child(world)
	var tool := ToolScene.instantiate() as Node3D
	if tool == null:
		push_error("SPATIAL_DRAWING_TOOL_RENDER_SELF_TEST: tool failed to instantiate")
		quit(1)
		return
	world.add_child(tool)
	tool.call("set_tool_color", Color(1.0, 0.02, 0.92, 1.0))
	var bounds := _calculate_bounds(tool)
	if bounds.size.length_squared() <= 0.0:
		push_error("SPATIAL_DRAWING_TOOL_RENDER_SELF_TEST: tool has no mesh bounds")
		quit(1)
		return

	var camera := Camera3D.new()
	world.add_child(camera)
	var center := bounds.get_center()
	var radius := maxf(bounds.size.length() * 0.65, 0.1)
	camera.position = center \
		+ Vector3(0.85, 0.55, -1.35).normalized() * radius * 2.8
	camera.look_at(center, Vector3.UP)
	camera.fov = 34.0

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
	key_light.light_energy = 2.2
	world.add_child(key_light)
	var fill_light := DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(28.0, 145.0, 0.0)
	fill_light.light_energy = 0.9
	world.add_child(fill_light)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.14, 0.18, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.78, 0.95, 1.0)
	environment.ambient_light_energy = 0.7
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)

	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("SPATIAL_DRAWING_TOOL_RENDER_SELF_TEST: viewport capture is empty")
		quit(1)
		return
	var save_error := image.save_png(OUTPUT_PATH)
	if save_error != OK:
		push_error(
			"SPATIAL_DRAWING_TOOL_RENDER_SELF_TEST: PNG save failed with %s"
			% save_error
		)
		quit(1)
		return
	print(
		"SPATIAL_DRAWING_TOOL_RENDER_SELF_TEST PASS %s bounds=%s"
		% [ProjectSettings.globalize_path(OUTPUT_PATH), bounds]
	)
	quit(0)


func _calculate_bounds(node: Node3D) -> AABB:
	var has_bounds := false
	var result := AABB()
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		var local_bounds := mesh_instance.get_aabb()
		for corner_index in range(8):
			var point := mesh_instance.global_transform \
				* local_bounds.get_endpoint(corner_index)
			if not has_bounds:
				result = AABB(point, Vector3.ZERO)
				has_bounds = true
			else:
				result = result.expand(point)
	return result
