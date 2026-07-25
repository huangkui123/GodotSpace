extends SceneTree

const PointerScript := preload(
	"res://Assets/ARSpace/Scripts/XR/right_hand_ui_pointer.gd"
)

var _failures: PackedStringArray = []


class MockViewportBody extends StaticBody3D:
	signal pointer_event(event)

	func global_to_viewport(_at: Vector3) -> Vector2:
		return Vector2.ZERO


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_player_scene_configuration()
	_check_aim_stabilization()

	var controller := XRController3D.new()
	controller.name = "RightHand"
	var right_pointer: Node3D = _make_pointer()
	controller.add_child(right_pointer)
	root.add_child(controller)

	_check(right_pointer.get_script() == PointerScript, "right pointer should use the ARSpace visual subclass")
	_check(bool(right_pointer.get("enabled")), "right pointer interaction should be enabled")
	_check(int(right_pointer.get("laser_length")) == 1, "right beam should stop at its collision")
	_check(bool(right_pointer.get("show_target")), "right pointer target indicator should be enabled")
	_check(
		bool(right_pointer.get("aim_smoothing_enabled")),
		"right pointer aim stabilization should be enabled"
	)
	_check(
		not PointerScript.is_controller_tracking_ready(controller),
		"an untracked controller should not pass the runtime readiness gate"
	)
	right_pointer.set("wait_for_tracked_controller", true)
	right_pointer.call("set_interaction_requested", true)
	right_pointer.call("_physics_process", 1.0 / 60.0)
	_check(
		not bool(right_pointer.get("enabled")) and not right_pointer.visible,
		"the live-XR readiness gate should hide and disable an untracked pointer"
	)
	right_pointer.set("wait_for_tracked_controller", false)
	right_pointer.call("set_interaction_requested", true)
	_check(
		bool(right_pointer.get("enabled")) and right_pointer.visible,
		"bypassing the tracking gate should preserve desktop self-test interaction"
	)

	var laser := right_pointer.get_node_or_null("Laser") as MeshInstance3D
	var target := right_pointer.get_node_or_null("Target") as MeshInstance3D
	_check(laser != null and laser.mesh is ArrayMesh, "right beam should use a generated cone mesh")
	_check(
		right_pointer.find_children("Laser", "MeshInstance3D", true, false).size() == 1,
		"right pointer should render exactly one laser mesh"
	)
	_check(
		is_equal_approx(
			_beam_visual_length(laser),
			float(right_pointer.get("visual_taper_distance"))
		),
		"idle red beam should taper at a fixed nearby distance"
	)
	var ray := right_pointer.get_node_or_null("RayCast") as RayCast3D
	_check(
		is_equal_approx(absf(ray.target_position.z), float(right_pointer.get("distance"))),
		"fixed visual taper should not shorten the interaction raycast"
	)
	_check(target != null and target.mesh is TorusMesh, "right target should use a ring mesh")
	var ring_material := target.get_surface_override_material(0) as StandardMaterial3D
	_check(
		ring_material != null and ring_material.no_depth_test,
		"target ring should render above the transparent UI panel"
	)
	_check(
		ring_material != null and ring_material.render_priority == 127,
		"target ring should have the highest transparent render priority"
	)
	if laser != null and laser.mesh is ArrayMesh:
		_check_cone_mesh(laser.mesh as ArrayMesh)

	right_pointer.call("_update_laser_active_material", false)
	_check(
		laser.get_surface_override_material(0) == right_pointer.get("laser_material"),
		"miss state should use the red beam material"
	)
	right_pointer.call("_update_laser_active_material", true)
	_check(
		laser.get_surface_override_material(0) == right_pointer.get("laser_hit_material"),
		"window-hit state should use the blue beam material"
	)
	right_pointer.call("_set_beam_length", 0.5)
	_check(
		is_equal_approx(_beam_visual_length(laser), 0.5),
		"beam clipping should shorten the cone to the hit point"
	)
	_check_cone_mesh(laser.mesh as ArrayMesh)
	right_pointer.call("_visible_miss")

	var viewport_body := MockViewportBody.new()
	viewport_body.name = "InteractiveWindowBody"
	viewport_body.collision_layer = 1 << 22
	viewport_body.collision_mask = 0
	viewport_body.position = Vector3(0.0, 0.0, -2.0)
	var panel_shape := CollisionShape3D.new()
	var panel_box := BoxShape3D.new()
	panel_box.size = Vector3(1.0, 1.0, 0.02)
	panel_shape.shape = panel_box
	viewport_body.add_child(panel_shape)
	root.add_child(viewport_body)
	_check(
		PointerScript.is_interactable_window_target(viewport_body),
		"Viewport2Din3D collision bodies should be recognized as interactive windows"
	)
	viewport_body.rotation.y = deg_to_rad(22.0)
	var panel_normal := viewport_body.global_basis.z.normalized()
	var stable_normal: Vector3 = PointerScript.resolve_window_surface_normal(
		viewport_body,
		Vector3.RIGHT,
		Vector3(0.0, 0.0, -1.0)
	)
	_check(
		absf(stable_normal.dot(panel_normal)) > 0.999,
		"window ring should use the panel normal instead of an unstable box side normal"
	)
	viewport_body.rotation = Vector3.ZERO
	await physics_frame
	ray.force_raycast_update()
	right_pointer.call("_process", 0.0)
	_check(ray.is_colliding(), "right pointer should raycast the interactive window")
	_check(
		is_equal_approx(
			_beam_visual_length(laser),
			float(right_pointer.get("visual_taper_distance"))
		),
		"blue beam should use the same fixed one-meter taper distance"
	)
	_check(target.visible, "blue target ring should be visible on an interactive window")
	_check(
		laser.get_surface_override_material(0) == right_pointer.get("laser_hit_material"),
		"interactive window hits should switch the beam to blue"
	)
	viewport_body.position.z = -0.5
	await physics_frame
	ray.force_raycast_update()
	right_pointer.call("_process", 0.0)
	var clipped_length := _beam_visual_length(laser)
	_check(
		clipped_length < float(right_pointer.get("visual_taper_distance")),
		"a panel nearer than one meter should clip the hidden tail"
	)
	_check_cone_mesh(laser.mesh as ArrayMesh)

	var unrelated_body := StaticBody3D.new()
	_check(
		not PointerScript.is_interactable_window_target(unrelated_body),
		"unrelated 3D bodies should not trigger the blue window state"
	)
	unrelated_body.free()
	viewport_body.position.x = 2.0
	await physics_frame
	ray.force_raycast_update()
	right_pointer.call("_process", 0.0)
	_check(not target.visible, "target ring should hide after leaving the window")
	_check(
		is_equal_approx(
			_beam_visual_length(laser),
			float(right_pointer.get("visual_taper_distance"))
		),
		"red beam should restore its fixed taper distance after leaving the window"
	)
	_check(
		laser.get_surface_override_material(0) == right_pointer.get("laser_material"),
		"beam should return to red after leaving the window"
	)

	viewport_body.queue_free()
	controller.queue_free()
	await process_frame

	if _failures.is_empty():
		print("RIGHT_HAND_UI_POINTER_SELF_TEST: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _make_pointer() -> Node3D:
	var pointer := PointerScript.new() as Node3D
	pointer.name = "FunctionPointer"
	pointer.set("wait_for_tracked_controller", false)
	pointer.set("laser_length", XRToolsFunctionPointer.LaserLength.COLLIDE)
	pointer.set("show_target", true)
	pointer.set("target_radius", 0.012)

	var ray := RayCast3D.new()
	ray.name = "RayCast"
	pointer.add_child(ray)

	var laser := MeshInstance3D.new()
	laser.name = "Laser"
	laser.mesh = BoxMesh.new()
	pointer.add_child(laser)

	var target := MeshInstance3D.new()
	target.name = "Target"
	target.mesh = SphereMesh.new()
	pointer.add_child(target)

	var suppress_area := Area3D.new()
	suppress_area.name = "SuppressArea"
	var suppress_shape := CollisionShape3D.new()
	suppress_shape.name = "CollisionShape3D"
	suppress_shape.shape = SphereShape3D.new()
	suppress_area.add_child(suppress_shape)
	pointer.add_child(suppress_area)
	return pointer


func _check_player_scene_configuration() -> void:
	var scene_text := FileAccess.get_file_as_string(
		"res://Assets/ARSpace/Scenes/Player_XR.tscn"
	)
	_check(
		scene_text.contains("path=\"res://Assets/ARSpace/Scripts/XR/right_hand_ui_pointer.gd\""),
		"Player_XR should reference the ARSpace right-pointer script"
	)
	var left_start := scene_text.find(
		"[node name=\"FunctionPointer\" parent=\"LeftHand\""
	)
	var right_start := scene_text.find(
		"[node name=\"FunctionPointer\" parent=\"RightHand\""
	)
	_check(left_start >= 0 and right_start > left_start, "Player_XR should define both hand pointers")
	if left_start < 0 or right_start <= left_start:
		return
	var left_block := scene_text.substr(left_start, right_start - left_start)
	_check(left_block.contains("visible = false"), "Player_XR should hide the left pointer")
	_check(left_block.contains("enabled = false"), "Player_XR should disable left-pointer interaction")
	_check(left_block.contains("show_laser = 0"), "Player_XR should keep the left laser hidden")
	var right_block := scene_text.substr(right_start)
	_check(
		right_block.contains("script = ExtResource(\"8_right_pointer\")"),
		"Player_XR should apply the ARSpace script to the right pointer"
	)
	_check(right_block.contains("laser_length = 1"), "Player_XR should clip the right beam at hits")
	_check(right_block.contains("show_target = true"), "Player_XR should enable the hit ring")
	_check(
		right_block.contains("near_radius = 0.006"),
		"Player_XR should use the thicker near-hand beam radius"
	)
	_check(
		right_block.contains("visual_taper_distance = 1.0"),
		"Player_XR should keep both beam colors tapered at one meter"
	)
	_check(
		right_block.contains("aim_smoothing_enabled = true"),
		"Player_XR should enable stabilized pointer aiming"
	)
	_check(
		right_block.contains("aim_follow_speed = 30.0"),
		"Player_XR should configure the stabilized aim follow rate"
	)
	_check(
		right_block.contains("aim_deadzone_degrees = 0.15"),
		"Player_XR should filter small angular tracking noise"
	)
	_check(
		right_block.contains("aim_snap_angle_degrees = 15.0"),
		"Player_XR should snap large intentional pointer movements"
	)
	_check(
		right_block.contains("wait_for_tracked_controller = true"),
		"Player_XR should wait for the physical right controller"
	)
	_check(
		right_block.contains("tracking_ready_physics_frames = 2"),
		"Player_XR should require stable tracking across physics frames"
	)
	var player_script_text := FileAccess.get_file_as_string(
		"res://Assets/ARSpace/Scenes/player.gd"
	)
	_check(
		player_script_text.contains("set_interaction_requested"),
		"player startup should request interaction without bypassing the readiness gate"
	)


func _check_aim_stabilization() -> void:
	var current := Vector3.FORWARD
	var noise_target := current.rotated(Vector3.UP, deg_to_rad(0.1))
	var noise_result: Vector3 = PointerScript.stabilize_aim_direction(
		current,
		noise_target,
		1.0 / 90.0,
		30.0,
		0.15,
		15.0
	)
	_check(
		noise_result.is_equal_approx(current),
		"aim stabilization should reject motion inside its angular deadzone"
	)

	var deliberate_target := current.rotated(Vector3.UP, deg_to_rad(5.0))
	var deliberate_result: Vector3 = PointerScript.stabilize_aim_direction(
		current,
		deliberate_target,
		1.0 / 90.0,
		30.0,
		0.15,
		15.0
	)
	var deliberate_step := current.angle_to(deliberate_result)
	_check(
		deliberate_step > 0.0 \
			and deliberate_step < current.angle_to(deliberate_target),
		"ordinary aim motion should follow smoothly instead of freezing or snapping"
	)

	var snap_target := current.rotated(Vector3.UP, deg_to_rad(20.0))
	var snap_result: Vector3 = PointerScript.stabilize_aim_direction(
		current,
		snap_target,
		1.0 / 90.0,
		30.0,
		0.15,
		15.0
	)
	_check(
		snap_result.is_equal_approx(snap_target),
		"large intentional aim changes should bypass smoothing"
	)

	var frame_target := current.rotated(Vector3.UP, deg_to_rad(8.0))
	var one_frame: Vector3 = PointerScript.stabilize_aim_direction(
		current,
		frame_target,
		1.0 / 60.0,
		30.0,
		0.0,
		90.0
	)
	var two_frames: Vector3 = PointerScript.stabilize_aim_direction(
		current,
		frame_target,
		1.0 / 120.0,
		30.0,
		0.0,
		90.0
	)
	two_frames = PointerScript.stabilize_aim_direction(
		two_frames,
		frame_target,
		1.0 / 120.0,
		30.0,
		0.0,
		90.0
	)
	_check(
		one_frame.angle_to(two_frames) < 0.00001,
		"aim stabilization should behave consistently across render frame rates"
	)


func _beam_visual_length(laser: MeshInstance3D) -> float:
	if laser == null or laser.mesh == null:
		return 0.0
	return laser.mesh.get_aabb().size.z * absf(laser.scale.z)


func _check_cone_mesh(mesh: ArrayMesh) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var colors := arrays[Mesh.ARRAY_COLOR] as PackedColorArray
	var sides: int = vertices.size() / 2
	_check(sides >= 6, "cone beam should have a circular cross-section")
	if sides < 1 or colors.size() != vertices.size():
		return
	var near_width := Vector2(vertices[0].x, vertices[0].y).length()
	var far_width := Vector2(vertices[sides].x, vertices[sides].y).length()
	_check(near_width > far_width, "cone beam should become thinner toward its endpoint")
	_check(colors[0].a > colors[sides].a, "cone beam should become more transparent toward its endpoint")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
