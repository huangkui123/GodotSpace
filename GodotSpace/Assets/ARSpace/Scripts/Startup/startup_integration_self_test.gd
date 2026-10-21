extends SceneTree

## Runs real headless Server/Sky/Ground processes, the production managed child
## entry, authenticated role admission and SessionRuntime RPCs. No ADB or XR.
const Config := preload("res://Assets/ARSpace/Scripts/Startup/launch_config.gd")
const Profile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const SCRIPT := "res://Assets/ARSpace/Scripts/Startup/startup_integration_self_test.gd"
const URL := "http://192.0.2.10:39876/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/video.ts"

class GroundFixture extends "res://Assets/ARSpace/Scripts/Network/network_handler.gd":
	func _get_requested_local_role() -> String:
		return "ground_vr"

var runtime: Node
var network: Node
var folders: Array[String] = []
var children: Array[int] = []
var failures: Array[String] = []
var base: String
var previous_token: String
var next_heartbeat := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = root.get_node("SessionRuntime")
	network = root.get_node("NetworkHandler")
	if runtime.is_child:
		var profile = Profile.from_args([], ["--testmode", "--voice-role=client"])
		if Config.argument("--fixture=") == "ground":
			profile.semantic_role = Profile.SemanticRole.GROUND
			network.set_script(GroundFixture)
		Profile._session_override = profile
		change_scene_to_file("res://Assets/ARSpace/Scenes/StartMenu.tscn")
		runtime.cast_session_changed.connect(func(url: String, _meta: Dictionary):
			Config.write_json(runtime.get("_folder").path_join("cast-observed.json"), {"url": url})
			if profile.is_sky() and not url.is_empty():
				get_first_node_in_group("reconstruction_workspace_controller").request_enter_workspace())
		return
	base = OS.get_environment("TEMP").path_join("godot-startup-test-" + str(OS.get_process_id()))
	previous_token = OS.get_environment("GODOTSPACE_GROUND_VR_TOKEN")
	var token := Crypto.new().generate_random_bytes(24).hex_encode()
	OS.set_environment("GODOTSPACE_GROUND_VR_TOKEN", token)
	Profile.select_session_mode(Profile.Preset.PC_GROUND_SERVER)
	_check(network.start_server(), "Server must start")
	if not failures.is_empty():
		_finish()
		return
	runtime.active = true
	runtime.options = {"preset": "local_sky"}
	runtime.set_process(false)
	runtime.call("_start_cast_hub")
	change_scene_to_file("res://Assets/ARSpace/Scenes/ARSpace.tscn")
	await process_frame
	var sky := _spawn("sky", token)
	_check(await _wait_ready(sky), "Managed Sky should auto-connect through StartMenu")
	_check(network.get_sky_peer_id() > 1, "Server must register Sky")
	_check(not get_first_node_in_group("lingbot_stream_bridge").auto_connect, "Reconstruction must not connect at startup")
	_check(not root.get_node("VoiceChat").capture.is_setup, "Disabled startup must not open a microphone")
	runtime.call("_on_cast_received", URL, {"device_name": "Fixture", "transport": "usb"})
	_check(await _wait_cast(sky, URL), "Sky must receive current cast state")
	await _delay(0.5)
	_check(get_first_node_in_group("lingbot_stream_bridge").auto_connect, "Opening Sky reconstruction workspace must start preflight connections")
	var ground := _spawn("ground", token)
	_check(await _wait_ready(ground), "Managed Ground should auto-connect")
	_check(await _wait_cast(ground, URL), "Late Ground must receive cached cast URL")
	_write_stop(ground)
	_check(await _wait_exit(children.back()), "Managed Ground must exit on stop request")
	await _delay(1.0)
	ground = _spawn("ground-restart", token)
	_check(await _wait_ready(ground), "Replacement Ground must reclaim its role")
	_check(await _wait_cast(ground, URL), "Replacement Ground must receive cast URL")
	network._close_network_peer()
	await _delay(2.0)
	_check(network.start_server(), "Server should restart on the same port")
	_check(await _wait_roles(), "Both managed clients should reconnect after Server restart")
	runtime.call("_on_cast_received", URL, {"device_name": "Fixture", "transport": "usb"})
	_check(await _wait_cast(ground, URL), "Cast route should recover with Server")
	for folder in folders:
		_write_stop(folder)
	for pid in children:
		_check(await _wait_exit(pid), "All managed children must exit")
	_finish()


func _spawn(role: String, token: String) -> String:
	var folder := base.path_join(role)
	var options := Config.defaults()
	options.assistant = false # This fixture owns its network mocks, not backend services.
	options.version = 1
	options.session_id = Crypto.new().generate_random_bytes(16).hex_encode()
	options.ground_token = token
	options.server_ip = "127.0.0.1"
	options.capture = false
	options.cast = false
	options.preset = "local_ground" if role.begins_with("ground") else "local_sky"
	Config.write_json(folder.path_join("child.json"), options)
	folders.append(folder)
	_touch_parents()
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--log-file", folder.path_join("godot.log"), "--script", SCRIPT, "--",
		"--fixture=" + ("ground" if role.begins_with("ground") else "sky"),
		"--session-config=" + folder.path_join("child.json")])
	children.append(OS.create_process(OS.get_executable_path(), args))
	return folder


func _process(_delta: float) -> bool:
	if not folders.is_empty() and Time.get_ticks_msec() > next_heartbeat:
		next_heartbeat = Time.get_ticks_msec() + 1000
		_touch_parents()
	return false


func _touch_parents() -> void:
	for folder in folders:
		Config.write_json(folder.path_join("parent.json"), {"time": Time.get_unix_time_from_system()})


func _wait_ready(folder: String) -> bool:
	var until := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < until:
		if Config.read_json(folder.path_join("child-status.json")).get("state") == "ready":
			return true
		await _delay(0.2)
	return false


func _wait_cast(folder: String, expected: String) -> bool:
	var until := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < until:
		if Config.read_json(folder.path_join("cast-observed.json")).get("url") == expected:
			return true
		await _delay(0.1)
	return false


func _wait_roles() -> bool:
	var until := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < until:
		if network.get_sky_peer_id() > 1 and network.get_ground_vr_peer_id() > 1:
			return true
		await _delay(0.2)
	return false


func _write_stop(folder: String) -> void:
	var file := FileAccess.open(folder.path_join("stop"), FileAccess.WRITE)
	file.store_string("stop")


func _wait_exit(pid: int) -> bool:
	var until := Time.get_ticks_msec() + 10000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < until:
		await _delay(0.2)
	return not OS.is_process_running(pid)


func _delay(seconds: float) -> void:
	await create_timer(seconds).timeout


func _check(value: bool, detail: String) -> void:
	if not value:
		failures.append(detail)
		push_error(detail)


func _finish() -> void:
	network._close_network_peer()
	runtime.active = false
	OS.set_environment("GODOTSPACE_GROUND_VR_TOKEN", previous_token)
	print("Startup integration self-test %s; logs: %s" % ["passed" if failures.is_empty() else "FAILED", base])
	quit(0 if failures.is_empty() else 1)
