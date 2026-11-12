extends SceneTree

const Builder := preload("res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_animations.gd")
var failures: Array[String] = []
var rig: Node3D
var player: AnimationPlayer

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# Keep the real ARSpace overrides which originally saved the cover removed.
	var scene := load("res://Assets/ARSpace/Scenes/ARSpace.tscn").instantiate() as Node3D
	rig = scene.get_node("SpaceBox/SpaceBox/dashiyangui")
	rig.get_parent().remove_child(rig)
	scene.free()
	root.add_child(rig)
	player = rig.get_node("AnimationPlayer")
	var source := load("res://Assets/ARSpace/Scripts/WorkListCanvas/Containerless/dashiyangui.library.res") as AnimationLibrary
	_expect(source.get_animation("RESET").get_track_count() == 0, "shared source RESET remains untouched")
	_expect(not (rig.get_node("AnimationTree") as AnimationTree).active, "imported tree cannot compete with task playback")
	_expect(not player.is_playing() and rig.get_active_step() == 0, "idle does not play a task")
	_expect(_position(Builder.COVER).is_equal_approx(Vector3(-0.315,0,0)), "idle cover starts installed, despite scene exploded override")
	_check_hidden_parts("idle")
	var starts: Dictionary = {}
	for step in range(1, 21):
		rig.play_step(step)
		starts[step] = _snapshot()
		_expect(player.is_playing() and rig.get_active_step() == step, "step %d starts immediately" % step)
		if step in [1,3,4,20]: _check_hidden_parts("step %d" % step)
		if step <= 6:
			_expect(_position(Builder.COVER).is_equal_approx(Vector3(-0.315,0,0)), "cover stays installed before step7")
		if step in [12,13,14,15]:
			_expect(_position(Builder.CORE).is_equal_approx(Vector3(-0.3,0,0.5)), "core is fully withdrawn at step%d" % step)
		if step in [16,17,18,19,20]:
			_expect(_position(Builder.CORE).is_equal_approx(Vector3(-0.976,0,0)), "core is already inserted at step%d" % step)
		if step >= 15:
			_expect(_position(Builder.NEW_SAMPLE).is_equal_approx(Vector3(0.3481,0,-0.55)), "installed new sample never teleports away at step%d" % step)
		if step >= 13:
			_expect(not rig.get_node(Builder.OLD_SAMPLE).visible, "removed old sample never reappears")
		var animation := player.get_animation("Step%d" % step)
		for t in animation.get_track_count():
			_expect(rig.get_node_or_null(NodePath(str(animation.track_get_path(t).get_concatenated_names()))) != null, "step%d track resolves: %s" % [step,animation.track_get_path(t)])
		player.seek(animation.length, true)
		if step == 7:
			_expect(_position(Builder.COVER).is_equal_approx(Vector3(0.33,0.5,0)), "step7 removes cover")
		if step == 14:
			_expect(_position(Builder.NEW_SAMPLE).is_equal_approx(Vector3(0.3481,0,-0.55)), "step14 seats new sample")
		if step == 19:
			_expect(_position(Builder.COVER).distance_to(Vector3(-0.315,0,0)) < 0.003, "step19 closes cover")
			_expect(not rig.get_node(Builder.TOOL).visible, "step19 withdraws tool")
	# Arbitrary interrupted jumps, reverse navigation, and same-step replay.
	for from in range(1,21):
		for to in range(1,21):
			rig.play_step(from)
			player.seek(player.current_animation_length * 0.43, true)
			rig.play_step(to)
			_compare(starts[to], _snapshot(), "%d -> %d" % [from,to])
	for step in [6,7,9,11,12,14,15,17,19]:
		rig.play_step(step)
		var initial := _snapshot()
		player.advance(player.current_animation_length * 0.5)
		_expect(_different_pose(initial, _snapshot()), "step%d still animates motion" % step)
	rig.play_step(15)
	player.advance(1.2)
	rig.clear_step()
	await process_frame
	_expect(not player.is_playing(), "clearing interrupts the previous clip")
	_check_hidden_parts("cleared")
	rig.play_step(16)
	_compare(starts[16], _snapshot(), "reopen step16")
	var before := _snapshot()
	rig.play_step(0)
	rig.play_step(21)
	_compare(before, _snapshot(), "invalid steps are ignored")
	_expect(source.get_animation("Step16").get_track_count() == 11, "source Step16 remains unchanged")
	if OS.get_cmdline_user_args().has("--capture-steps"):
		await _capture_steps()
	rig.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("CABINET STEP TEST ", "PASS" if failures.is_empty() else "FAIL", " (20 steps, 400 interrupted transitions, replay, completion, idle)")
	quit(0 if failures.is_empty() else 1)

func _capture_steps() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(960, 720)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	rig.reparent(viewport)
	var frame := rig.get_node("dashiyangui/MeshRenderer") as MeshInstance3D
	var bounds := frame.get_aabb()
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.global_position = frame.to_global(bounds.get_center() + Vector3(bounds.size.y * 1.4, 0, 0))
	camera.look_at(frame.to_global(bounds.get_center()), Vector3.UP)
	camera.make_current()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, -30, 0)
	viewport.add_child(light)
	for sample in [[5,0.0],[7,1.0],[11,1.0],[14,1.0],[15,0.5],[16,0.0],[19,1.0],[20,0.0]]:
		rig.play_step(sample[0])
		player.seek(player.current_animation_length * sample[1], true)
		player.pause()
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("cabinet-step-%02d.png" % sample[0]))
	rig.reparent(root)
	viewport.queue_free()
	await process_frame

func _snapshot() -> Dictionary:
	var result := {}
	for node in rig.find_children("*", "Node3D", true, false):
		if str(rig.get_path_to(node)).begins_with("CabinetOpacity"): continue
		result[str(rig.get_path_to(node))] = [node.transform,node.visible]
	return result

func _compare(expected: Dictionary, actual: Dictionary, label: String) -> void:
	for path: String in expected:
		var e: Array = expected[path]
		var a: Array = actual[path]
		_expect((e[0] as Transform3D).is_equal_approx(a[0]) and e[1] == a[1], "%s differs at %s" % [label,path])

func _different_pose(a: Dictionary, b: Dictionary) -> bool:
	for path: String in a:
		if not (a[path][0] as Transform3D).is_equal_approx(b[path][0]): return true
	return false

func _position(path: String) -> Vector3:
	return (rig.get_node(path) as Node3D).position

func _check_hidden_parts(label: String) -> void:
	for path in [Builder.COVER,Builder.COVER_BOLTS,Builder.CORE_BOLTS,Builder.CORE + "/MeshRenderer",Builder.OLD_SAMPLE,Builder.NEW_SAMPLE,Builder.TOOL]:
		_expect(not rig.get_node(path).is_visible_in_tree(), "%s hides %s" % [label,path])
	_expect(rig.get_node("dashiyangui/MeshRenderer").is_visible_in_tree(), "fixed housing remains available")

func _expect(condition: bool, message: String) -> void:
	if not condition: failures.append(message)
