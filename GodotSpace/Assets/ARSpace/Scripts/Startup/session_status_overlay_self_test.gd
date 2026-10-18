extends SceneTree

const Config := preload("res://Assets/ARSpace/Scripts/Startup/launch_config.gd")
const Profile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const Overlay := preload("res://Assets/ARSpace/Scripts/Startup/session_status_overlay.gd")
const STATUS := "协作已连接；XR 已就绪\n投屏：地址已收到\n透传：正在收帧"
var failures: Array[String] = []
var requested: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	Profile.select_session_mode(Profile.Preset.PC_GROUND_SERVER)
	var network := root.get_node("NetworkHandler")
	if not network.start_server():
		push_error("UI test needs a free Server port")
		quit(1)
		return
	change_scene_to_file("res://Assets/ARSpace/Scenes/ARSpace.tscn")
	await create_timer(0.5).timeout
	var overlay := Overlay.new()
	root.add_child(overlay)
	overlay.retry_xr_requested.connect(func(): requested.append("xr"))
	overlay.retry_helper_requested.connect(func(): requested.append("helper"))
	overlay.stop_requested.connect(func(): requested.append("stop"))
	overlay.set_status(STATUS)
	await create_timer(0.3).timeout
	_check(overlay.panel.position.x > 600, "Session card must not overlap the original left calibration panel")
	_check(overlay.panel.get_rect().end.x <= root.size.x, "Card must stay inside right edge")
	_check(overlay.status_label.text == STATUS, "Chinese status must reach the label unchanged")
	var preview := Config.argument("--preview=")
	if not preview.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		_check(root.get_texture().get_image().save_png(preview) == OK, "Save actual scene preview")
	root.size = Vector2i(920, 720)
	await create_timer(0.2).timeout
	_check(not overlay.details.visible, "Narrow windows default to a compact card")
	_check(overlay.panel.position.x > 600, "Collapsed card leaves calibration controls exposed")
	overlay.toggle.pressed.emit()
	await create_timer(0.2).timeout
	_check(overlay.details.visible, "User can expand the compact card")
	overlay.set_status(STATUS + ("\n网络等待：请检查头显与电脑的局域网连接。".repeat(30)))
	await create_timer(0.2).timeout
	_check(overlay.panel.get_rect().end.y <= root.size.y, "Long diagnostics must not push actions off screen")
	_check(overlay.scroll.get_v_scroll_bar().visible, "Long diagnostics must scroll")
	var actions := overlay.details.get_child(1)
	for action in actions.get_children():
		(action as Button).pressed.emit()
	_check(requested == ["xr", "helper", "stop"], "Action buttons must forward their individual signals")
	root.size = Vector2i(1920, 1080)
	overlay.set_collapsed(true)
	overlay.set_status(STATUS)
	await create_timer(0.2).timeout
	_check(not overlay.details.visible, "Status updates and resize must preserve user's collapsed choice")
	print("Session status overlay self-test: %s" % ("passed" if failures.is_empty() else "FAILED"))
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
