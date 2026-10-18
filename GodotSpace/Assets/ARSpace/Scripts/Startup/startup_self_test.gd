extends SceneTree

const Config := preload("res://Assets/ARSpace/Scripts/Startup/launch_config.gd")
const Profile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var options := Config.defaults()
	_check(not options.voice and options.assistant, "Assistant must prepare automatically; microphone remains opt-in")
	_check(options.capture and options.cast, "Capture and casting must default on")
	_check(options.transport == "usb", "Capture and casting must default to USB")
	for preset in Config.PRESETS:
		options.preset = preset
		options.server_ip = "192.0.2.10"
		var args := Config.child_arguments("C:/space project", "C:/config folder/child.json", options)
		var separator := args.find("--")
		_check(args.find("--xr-mode") < separator, "XR engine flag must precede user args")
		var profile = Profile.from_args(Array(args), Array(args.slice(separator + 1)))
		_check(profile.is_valid() and profile.is_client() and profile.uses_xr(), "Valid XR child: " + preset)
		_check(profile.is_ground() == (preset == "local_ground"), "Correct child role: " + preset)
	options.server_ip = ""
	_check(not Config.validate(options).is_empty(), "Remote Sky requires a server address")
	Profile.clear_session_override()
	root.size = Vector2i(920, 720)
	change_scene_to_file("res://Assets/ARSpace/Scenes/StartMenu.tscn")
	await process_frame
	await process_frame
	var menu := current_scene.get_node("UI")
	_check(menu.get("_launcher"), "Default entry must show launch presets")
	_check(menu.get("mode_selector").item_count == 3, "Launcher must expose three topologies")
	_check(menu.get("start_button").is_visible_in_tree(), "Start button must be visible")
	_check(menu.size.x >= 600 and menu.size.y >= 600, "Launcher must fill the viewport")
	var runtime := root.get_node("LocalAgentRuntime")
	if runtime.automatic_start_allowed() and menu.get("_agent_toggle").button_pressed:
		var deadline := Time.get_ticks_msec() + 45000
		while runtime.state not in ["ready", "failed"] and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(runtime.state == "ready", "Automatic service startup: " + str(runtime.message))
		_check(runtime._managed_role == "server_voice", "Local launcher prepares model, Gateway, ASR and TTS")
	else:
		_check(not runtime.enabled, "Offline headless test must not launch services")
	var voice := root.get_node("VoiceChat")
	_check(not voice.voice_enabled, "No automatic voice call")
	if DisplayServer.get_name() != "headless":
		await create_timer(0.5).timeout
		print("Startup layout: menu=%s scroll=%s button=%s" % [menu.get_global_rect(), menu.get_child(-1).get_global_rect(), menu.get("start_button").get_global_rect()])
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var path := Config.argument("--preview=")
		if not path.is_empty():
			_check(image.save_png(path) == OK, "Save launcher preview")
	if failures.is_empty():
		print("Startup self-test passed")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, description: String) -> void:
	if not condition:
		failures.append(description)
