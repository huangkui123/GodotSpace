extends SceneTree

const Controller := preload("res://Assets/ARSpace/Scenes/SpaceBox.gd")
const Guidance := preload("res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_guidance.gd")
# Independent expectations from the Unity manager, active effect nodes and images.
const IMAGE_STEPS := [1,2,3,5,6,8,9,10,12,13,16,17,18,19,20]
const SYMBOL_COUNTS := {1:0,2:1,3:4,4:0,5:1,6:8,7:0,8:2,9:6,10:3,11:0,12:3,13:4,14:0,15:0,16:3,17:6,18:2,19:8,20:0}
const LABELS := {
	1:["应用系统综合包","TZ3货船D区III象限"], 2:["准备工具","A区III象限"],
	5:["科学实验操作盖"], 6:["51","52","53","54","55","56","57","58"],
	8:["X01","X02"],12:["按压解锁"],13:["按压解锁"],16:["定位凸耳"],18:["X01","X02"],
	19:["51","52","53","54","55","56","57","58"],20:["撤收工具"],
}
var failures: Array[String] = []
var viewport: SubViewport
var controller: Node3D
var rig: Node3D
var effects: Node3D
var view
var item: WorkListInfoItem
var data: WorkListInfoDataResult

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# Load UI scripts after autoloads are registered (they reference Global).
	var list = load("res://Assets/ARSpace/Scripts/WorkListCanvas/WorkListUIView.gd").new()
	list.sample_data_init()
	data = list._info_save_list[0].info_data_result
	list.free()
	_expect(data.list.size() == 20, "the audited task has 20 steps")
	var scene := load("res://Assets/ARSpace/Scenes/ARSpace.tscn").instantiate() as Node3D
	rig = scene.get_node("SpaceBox/SpaceBox/dashiyangui")
	effects = scene.get_node("SpaceBox/SpaceBox/WorkEffect")
	rig.get_parent().remove_child(rig)
	effects.get_parent().remove_child(effects)
	scene.free()
	viewport = SubViewport.new()
	viewport.size = Vector2i(1100,900)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	controller = Controller.new()
	var box := Node3D.new()
	box.name = "SpaceBox"
	controller.add_child(box)
	var environment := Node3D.new()
	environment.name = "Environment_Life"
	box.add_child(environment)
	box.add_child(rig)
	box.add_child(effects)
	viewport.add_child(controller)
	var panel := load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn").instantiate() as Node
	root.add_child(panel)
	view = panel.get_node("Canvas")
	item = view.info_[0]
	await process_frame
	var menu := load("res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/MainMenuCanvasAR2D.tscn").instantiate() as Node
	root.add_child(menu)
	menu.get_node("Canvas").call("_on_work_list_pressed")
	_expect(menu.get_node("Canvas/WorkTabView/WorkListView").visible, "work-list entry opens the catalog")
	_expect(not effects.get_node("WorkList1").visible and rig.get_active_step() == 0,
		"browsing the catalog does not reveal all guidance or animate parts")
	view.open_task(1, data)
	for step in range(1,21):
		_check_page(step)
		view.next_click()
	for step in range(20,0,-1):
		_check_page(step)
		view.pre_click()
	# Installation is idempotent and disabled Unity numeric labels stay disabled.
	Guidance.install(effects)
	for step in range(1,21): _check_guidance(step)
	var anchored := effects.get_node("WorkList1/WorkInfo16") as Node3D
	_expect(is_equal_approx(anchored.position.y, -0.18), "guidance compensates the Unity/Godot cabinet height difference without accumulating on reinstall")
	# A failed load, or a switch to 3D/text, must never leave the last step's image.
	item.refresh_info(data.list[17])
	item.refresh_info(WorkListInfoData.new(16,1,"missing-step.png","缺图检查",""))
	_expect(item.banner_img.texture == null and item.media_hint.visible, "missing image clears previous X01/X02 picture")
	item.refresh_info(data.list[16])
	item.refresh_info(WorkListInfoData.new(4,2,"missing-step.mp4","缺视频检查",""))
	_expect(item.banner_img.texture == null and item.banner_video.stream == null and item.media_hint.visible, "missing video clears all previous media")
	if OS.get_cmdline_user_args().has("--capture-content"):
		await _capture()
	if OS.get_cmdline_user_args().has("--check-video"):
		await _check_video()
	view.close_task_guide()
	_expect(not effects.get_node("WorkList1").visible and rig.get_active_step() == 0, "closing clears guidance and animation")
	menu.get_node("Canvas").call("_on_work_list_pressed")
	_expect(not effects.get_node("WorkList1").visible and rig.get_active_step() == 0,
		"reopening the catalog does not restore a closed task's guidance")
	view.open_task(1,data)
	_check_page(1)
	panel.queue_free()
	menu.queue_free()
	viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("CABINET CONTENT TEST ", "PASS" if failures.is_empty() else "FAIL", " (20 pages forward/back, media pixels, Unity guidance, close/reopen)")
	quit(0 if failures.is_empty() else 1)

func _check_page(step: int) -> void:
	var entry := data.list[step-1]
	_expect(entry.step == step and item.item_data == entry, "page %d binds its own data" % step)
	_expect(item.title_label.text == entry.title and item.info_label.text == entry.info, "page %d text matches" % step)
	_expect(rig.get_active_step() == step, "page %d selects Step%d animation" % [step,step])
	for n in range(1,21):
		_expect(effects.get_node("WorkList1/WorkInfo%d" % n).is_visible_in_tree() == (n == step), "page%d exclusively shows WorkInfo%d" % [step,step])
	if step in IMAGE_STEPS:
		var expected := "step%d.png" % step
		_expect(entry.type == 1 and entry.path == expected, "page%d uses audited %s" % [step,expected])
		var original := Image.new()
		original.load_png_from_buffer(FileAccess.get_file_as_bytes("res://Assets/StreamingAssets/Images/" + expected))
		_expect(item.banner_img.texture != null, "page%d image loads" % step)
		if item.banner_img.texture != null:
			_expect(item.banner_img.texture.get_image().get_data() == original.get_data(), "page%d actually renders its image, not stale media" % step)
		_expect(not item.media_hint.visible, "page%d has no unavailable hint" % step)
	else:
		_expect(entry.type == (0 if step == 4 else 3) and entry.path.is_empty(), "page%d does not use demo video" % step)
		_expect(item.banner_img.texture == null and item.banner_video.stream == null and item.media_hint.visible, "page%d clears the previous media and explains its presentation" % step)
	_check_guidance(step)

func _check_guidance(step: int) -> void:
	var branch := effects.get_node("WorkList1/WorkInfo%d" % step)
	var labels: Array[String] = []
	for label: Label3D in branch.find_children("*","Label3D",true,false): labels.append(label.text)
	var expected: Array = LABELS.get(step, []).duplicate()
	labels.sort()
	expected.sort()
	_expect(labels == expected, "step%d labels match enabled Unity TextMeshes" % step)
	var symbols := 0
	for mesh: MeshInstance3D in branch.find_children("*","MeshInstance3D",true,false):
		if mesh.mesh != null: symbols += 1
	_expect(symbols == SYMBOL_COUNTS[step], "step%d has all %d guidance symbols" % [step,SYMBOL_COUNTS[step]])
	for canvas: Node3D in branch.find_children("Canvas*","Node3D",true,false):
		if canvas.has_node("Image/RestoredSymbol"):
			_expect(canvas.position.y > 1.3 and absf(canvas.position.x) > 0.1, "restored marker is anchored at the cabinet, not on the floor")

func _capture() -> void:
	var camera := Camera3D.new()
	viewport.add_child(camera)
	# Preserve the common ARSpace transform for both the cabinet and guidance.
	var frame := rig.get_node("dashiyangui/MeshRenderer") as MeshInstance3D
	var bounds := frame.get_aabb()
	camera.global_position = frame.to_global(bounds.get_center() + Vector3(bounds.size.y * 0.95, 0.2, 0))
	camera.look_at(frame.to_global(bounds.get_center() + Vector3(0,0.2,0)), Vector3.UP)
	camera.make_current()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30,-30,0)
	viewport.add_child(light)
	for step in [6,8,9,12,13,16,17,18,19,20]:
		view.page_index = step
		view.bind_page(step)
		var player := rig.get_node("AnimationPlayer") as AnimationPlayer
		player.seek(player.current_animation_length if step == 19 else 0.0,true)
		player.pause()
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("cabinet-content-%02d.png" % step))
		root.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join("cabinet-page-%02d.png" % step))

func _check_video() -> void:
	# Exercise the retained general video renderer with an explicit test fixture.
	var fixture := WorkListInfoData.new(4,2,"Demo1.mp4","媒体回归测试","")
	item.refresh_info(fixture)
	await create_timer(2.0).timeout
	var texture := item.banner_video.get_video_texture()
	_expect(texture != null and item.banner_video.get_stream_length() > 40.0, "FFmpeg opens the globalized filesystem path")
	item.banner_video.paused = true
	await process_frame
	item.banner_video.paused = false
	item.banner_video.loop = true
	for interval in 4:
		await create_timer(30.0).timeout
		_expect(item.banner_video.is_playing(), "video remains playing during the two-minute regression")
		print("VIDEO STABILITY ", (interval+1)*30, " seconds")
	view.hide()
	_expect(not item.banner_video.is_playing(), "closing an ancestor stops video")
	view.show()
	item.refresh_info(fixture)
	await create_timer(1.0).timeout
	_expect(item.banner_video.is_playing(), "reopening video restarts playback")
	item.refresh_info(data.list[17])
	_expect(item.banner_video.stream == null and not item.banner_video.is_playing(), "switching video to image releases playback")

func _expect(condition: bool, message: String) -> void:
	if not condition: failures.append(message)
