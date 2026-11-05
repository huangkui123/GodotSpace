extends Node

## One controller per workstation. Children own their XR session and report
## readiness through private local files. Only the Server distributes cast state.
signal status_changed(message: String)
signal cast_session_changed(url: String, metadata: Dictionary)
signal servers_changed(servers: Dictionary)

const Config := preload("res://Assets/ARSpace/Scripts/Startup/launch_config.gd")
const Profile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const CastReceiver := preload("res://Assets/ARSpace/Scripts/AstronautView/pico_cast_control_receiver.gd")
const CastEndpoint := preload("res://Assets/ARSpace/Scripts/AstronautView/pico_cast_endpoint.gd")
const HelperHealth := preload("res://Assets/ARSpace/Scripts/Startup/helper_health.gd")
const StatusOverlay := preload("res://Assets/ARSpace/Scripts/Startup/session_status_overlay.gd")
const DISCOVERY_PORT := 42070
const CONTROLLER_PORT := 42071
const GAME_SCENE := "res://Assets/ARSpace/Scenes/ARSpace.tscn"

var options: Dictionary = {}
var active := false
var is_child := false
var message := ""
var discovered_servers: Dictionary = {}
var cast_url := ""
var cast_metadata: Dictionary = {}
var _folder := ""
var _child_pid := -1
var _helper_pid := -1
var _helper_status := ""
var _helper_generation := 0
var _helper_health := HelperHealth.new()
var _helper_health_state := ""
var _helper_launch_error := ""
var _helper_started := false
var _stopping := false
var _next_tick := 0
var _next_retry := 0
var _retry_seconds := 2
var _controller_lock := TCPServer.new()
var _discovery := PacketPeerUDP.new()
var _discovery_server := PacketPeerUDP.new()
var _discovery_targets: Array[String] = []
var _discovery_retries := 0
var _discovery_next_send := 0
var _cast_receiver: Node
var _cast_token := ""
var _cast_owner := 0
var _cast_updated := 0
var _cast_problem := ""
var _session_requested := false
var _overlay: CanvasLayer
var _child_started_at := 0
var _child_report: Dictionary = {}
var _last_parent_seen := 0


func _enter_tree() -> void:
	var path := Config.argument("--session-config=")
	if path.is_empty():
		return
	options = Config.read_json(path)
	var session_id := str(options.get("session_id", ""))
	if options.get("version", 0) != 1 or session_id.length() != 32 or not session_id.is_valid_hex_number(false):
		options = {}
		return
	is_child = true
	active = true
	_folder = path.get_base_dir()
	_apply_feature_settings()
	OS.set_environment("GODOTSPACE_GROUND_VR_TOKEN", str(options.get("ground_token", "")))
	# Keep simultaneous processes out of the same voice log.
	OS.set_environment("GODOTSPACE_VOICE_LOG_PATH", _folder.path_join("xr-voice.log"))


func _ready() -> void:
	call_deferred("_bind_network")
	if is_child:
		_last_parent_seen = Time.get_ticks_msec()
		get_tree().auto_accept_quit = false
		_report_child("starting", "正在启动 XR Client")
	else:
		_discovery.bind(0, "0.0.0.0")
		_discovery.set_broadcast_enabled(true)


func _bind_network() -> void:
	NetworkHandler.local_role_assigned.connect(_on_role_assigned)
	NetworkHandler.peer_role_changed.connect(_on_peer_role_changed)
	NetworkHandler.connection_failed.connect(_on_connection_failed)
	NetworkHandler.server_connection_lost.connect(_on_connection_lost)


func start_session(selected: Dictionary) -> bool:
	if active or _stopping:
		return false
	var validation := Config.validate(selected)
	if not validation.is_empty():
		_publish(validation)
		return false
	if _controller_lock.listen(CONTROLLER_PORT, "127.0.0.1") != OK:
		_publish("本机已有协作启动台正在运行，请使用原窗口结束或继续会话")
		return false
	Config.write_json(Config.PREFERENCE_PATH, selected)
	options = selected.duplicate(true)
	options.version = 1
	options.session_id = Crypto.new().generate_random_bytes(16).hex_encode()
	options.ground_token = Crypto.new().generate_random_bytes(24).hex_encode()
	options.server_ip = str(selected.server_ip).strip_edges() if selected.preset == "join_sky" else "127.0.0.1"
	_folder = ProjectSettings.globalize_path("user://startup/sessions/" + options.session_id)
	if Config.write_json(_folder.path_join("child.json"), options) != OK:
		_controller_lock.stop()
		_publish("无法保存本次启动配置")
		return false
	active = true
	get_tree().auto_accept_quit = false
	_apply_feature_settings()
	# The desktop Server is a coordinator. Microphone belongs to the XR child.
	VoiceChat.set_voice_enabled(false)
	if selected.preset != "join_sky":
		Profile.select_session_mode(Profile.Preset.PC_GROUND_SERVER)
		OS.set_environment("GODOTSPACE_GROUND_VR_TOKEN", options.ground_token)
		if not NetworkHandler.start_server():
			_publish(NetworkHandler.get_last_start_error())
			active = false
			get_tree().auto_accept_quit = true
			_controller_lock.stop()
			return false
		_start_cast_hub()
		_discovery_server.bind(DISCOVERY_PORT, "0.0.0.0")
		get_tree().change_scene_to_file(GAME_SCENE)
		if bool(options.assistant):
			LocalAgentRuntime.ensure_services(Profile.current())
	_create_overlay()
	start_child()
	return true


func start_child() -> void:
	if not active or is_child or (_child_pid > 0 and OS.is_process_running(_child_pid)):
		return
	if _child_pid == -2:
		return
	if _child_started_at > 0:
		# Give each XR generation its own identity/files. A delayed watchdog from
		# the previous process must not stop or reconfigure its replacement.
		options.session_id = Crypto.new().generate_random_bytes(16).hex_encode()
		_folder = ProjectSettings.globalize_path("user://startup/sessions/" + options.session_id)
		if Config.write_json(_folder.path_join("child.json"), options) != OK:
			_publish("无法创建新的 XR 启动配置")
			return
	_child_pid = -2
	var attempt_id := str(options.session_id)
	_child_report = {}
	DirAccess.remove_absolute(_folder.path_join("child-status.json"))
	DirAccess.remove_absolute(_folder.path_join("stop"))
	_touch_parent()
	if OS.get_name() == "Windows" and DisplayServer.get_name() != "headless":
		_publish("正在准备 PICO 串流连接…")
		var prepare_pid := _run_helper_wrapper("Prepare", _folder.path_join("child.json"))
		var deadline := Time.get_ticks_msec() + 45000
		while prepare_pid > 0 and OS.is_process_running(prepare_pid) and Time.get_ticks_msec() < deadline and active and not _stopping:
			await get_tree().create_timer(0.25).timeout
		if str(options.session_id) != attempt_id:
			return
		if not active or _stopping:
			_child_pid = -1
			return
		var device := Config.read_json(_folder.path_join("device.json"))
		if device.has("device_serial"):
			options.device_serial = device.device_serial
			Config.write_json(_folder.path_join("child.json"), options)
	var args := Config.child_arguments(ProjectSettings.globalize_path("res://"), _folder.path_join("child.json"), options)
	args = PackedStringArray(["--log-file", _folder.path_join("xr.log")]) + args
	_child_pid = OS.create_process(OS.get_executable_path(), args, false)
	_child_started_at = Time.get_ticks_msec()
	_publish("正在启动 XR Client；请保持 PICO 串流连接" if _child_pid > 0 else "XR 进程启动失败，可点击重试 XR")


func _apply_feature_settings() -> void:
	var enabled := bool(options.get("assistant", false))
	ProjectSettings.set_setting("arspace/local_agent/enabled", enabled)
	ProjectSettings.set_setting("arspace/assistant_speech/enabled", enabled)
	var runtime := get_node_or_null("/root/LocalAgentRuntime")
	if runtime != null:
		runtime.enabled = enabled
	var speech := get_node_or_null("/root/AssistantSpeech")
	if speech != null:
		speech.enabled = enabled


func _process(_delta: float) -> void:
	_poll_discovery()
	if _discovery_retries > 0 and Time.get_ticks_msec() >= _discovery_next_send:
		_send_discovery()
	if not active or _stopping or Time.get_ticks_msec() < _next_tick:
		return
	_next_tick = Time.get_ticks_msec() + 1000
	if is_child:
		if FileAccess.file_exists(_folder.path_join("stop")):
			stop_session(true)
			return
		var parent := Config.read_json(_folder.path_join("parent.json"))
		if parent.has("time") and Time.get_unix_time_from_system() - float(parent.time) < 15:
			_last_parent_seen = Time.get_ticks_msec()
		# A transient read/rename collision must not terminate a live XR child.
		if Time.get_ticks_msec() - _last_parent_seen > 15000:
			stop_session(true)
			return
		if FileAccess.file_exists(_folder.path_join("retry-helper")):
			DirAccess.remove_absolute(_folder.path_join("retry-helper"))
			_helper_started = false
			_session_requested = false
			_helper_health.reset()
		_poll_child()
	else:
		_touch_parent()
		_child_report = Config.read_json(_folder.path_join("child-status.json"))
		if _child_pid > 0 and not OS.is_process_running(_child_pid):
			_publish("XR Client 已退出；可重试 XR 或结束协作")
		elif not _child_report.is_empty():
			var detail := str(_child_report.get("message", "正在启动"))
			if not _cast_problem.is_empty():
				detail += "\n" + _cast_problem
			_publish(detail)
		elif Time.get_ticks_msec() - _child_started_at > 30000:
			_publish("仍在等待 XR 初始化，请检查 PICO 串流连接；日志：" + _folder.path_join("xr.log"))
	if is_instance_valid(_cast_receiver) and _cast_owner > 0 and Time.get_ticks_msec() - _cast_updated > 15000:
		_set_cast("", {})


func _poll_child() -> void:
	var connected := NetworkHandler.get_local_assigned_role() in ["sky", "ground_vr"]
	var scene := get_tree().current_scene
	var in_game := scene != null and scene.scene_file_path == GAME_SCENE
	if not connected:
		if NetworkHandler.peer != null and NetworkHandler.peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
			return
		if not NetworkHandler.get_last_start_error().contains("名额") and not NetworkHandler.get_last_start_error().contains("凭据") \
				and Time.get_ticks_msec() >= _next_retry and scene != null and scene.scene_file_path.ends_with("StartMenu.tscn"):
			_next_retry = Time.get_ticks_msec() + _retry_seconds * 1000
			_retry_seconds = mini(_retry_seconds * 2, 15)
			var menu := scene.get_node_or_null("UI")
			if menu != null:
				menu.call("_on_start_pressed")
		return
	_retry_seconds = 2
	if not in_game:
		return
	if not _session_requested:
		_session_requested = true
		rpc_id(1, "_request_session")
	var xr := XRServer.find_interface("OpenXR")
	var xr_ready: bool = Profile.current().is_test_mode() or (xr != null and xr.is_initialized())
	var local_capture := get_tree().get_first_node_in_group("cabinet_calibration")
	var frame_recent := false
	var listener_ready := false
	if local_capture != null:
		var latest: Dictionary = local_capture.get("latest_frame")
		frame_recent = not latest.is_empty() and Time.get_ticks_usec() - int(latest.get("receive_usec", 0)) <= 5_000_000
		var receiver := local_capture.get_node_or_null("LocalPicoReceiver")
		listener_ready = receiver != null and bool(receiver.call("is_listening"))
	var helper_state := Config.read_json(_helper_status) if not _helper_status.is_empty() else {}
	var health_detail := _poll_helper_health(xr_ready, listener_ready, frame_recent, helper_state)
	var detail := "协作已连接；XR 已就绪" if xr_ready else "协作已连接；等待 PICO / OpenXR 就绪"
	if Profile.current().is_sky():
		detail += "\n采集 / 投屏：USB"
	if Profile.current().is_ground():
		detail += "\n地面端不会采集本机相机，等待天上端加入"
	elif bool(options.get("cast", true)):
		detail += "\n投屏：USB 视频已收到" if not cast_url.is_empty() else "\n投屏：等待 USB 视频"
	if not health_detail.is_empty():
		detail += "\n" + health_detail
	if not _helper_launch_error.is_empty():
		detail += "\n" + _helper_launch_error
	elif not helper_state.is_empty() and int(helper_state.get("generation", -1)) == _helper_generation \
			and str(helper_state.get("state", "")) not in ["launching", "starting", "started"]:
		detail += "\n" + str(helper_state.get("message", "正在连接 PICO helper…"))
	if bool(options.get("assistant", false)):
		detail += "\n助手：" + LocalAgentRuntime.message
	if local_capture != null and bool(options.get("capture", true)):
		detail += "\n透传：正在收帧" if frame_recent else "\n透传：等待新的相机帧"
	_report_child("ready" if xr_ready else "waiting_xr", detail)


func _poll_helper_health(xr_ready: bool, listener_ready: bool, frame_recent: bool, helper_status: Dictionary) -> String:
	if not Profile.current().is_sky() or _cast_token.is_empty():
		return ""
	var state := str(helper_status.get("state", ""))
	if int(helper_status.get("generation", -1)) != _helper_generation:
		state = "launching"
	if _helper_started and _helper_pid > 0 and not OS.is_process_running(_helper_pid) and state != "failed":
		state = "worker_exited"
	if not _helper_launch_error.is_empty():
		state = "failed"
	var now := Time.get_ticks_msec()
	var result := _helper_health.evaluate(now, xr_ready, listener_ready,
		bool(options.get("capture", true)), bool(options.get("cast", true)),
		frame_recent, not cast_url.is_empty(), state)
	var next_state := str(result.state)
	if next_state != _helper_health_state:
		_helper_health_state = next_state
		_log_helper_event(next_state, frame_recent)
	if next_state in ["start", "retry"]:
		_start_helper()
		_helper_health.mark_launched(now, next_state == "retry")
	return str(result.message)


func _log_helper_event(state: String, frame_recent: bool) -> void:
	if _folder.is_empty():
		return
	var path := _folder.path_join("helper-lifecycle.jsonl")
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file != null:
		file.seek_end()
		file.store_line(JSON.stringify({"time": Time.get_unix_time_from_system(), "state": state,
			"generation": _helper_generation, "recent_frame": frame_recent, "cast_available": not cast_url.is_empty()}))


func _on_role_assigned(_role: String, _annotate: bool) -> void:
	_session_requested = false


func _on_connection_failed(reason: String) -> void:
	if is_child:
		_session_requested = false
		_report_child("waiting_server", reason + "；正在等待 Server")


func _on_connection_lost() -> void:
	_on_connection_failed("Server 已断开")
	_set_cast("", {})


func _on_peer_role_changed(peer_id: int, role: String) -> void:
	if not active or is_child or options.get("preset") == "join_sky":
		return
	if role == "unknown" and peer_id == _cast_owner:
		_cast_owner = 0
		_set_cast("", {})


func _start_cast_hub() -> void:
	_cast_token = Crypto.new().generate_random_bytes(24).hex_encode()
	OS.set_environment("GODOTSPACE_PICO_CAST_CONTROL_TOKEN", _cast_token)
	_cast_receiver = CastReceiver.new()
	_cast_receiver.session_changed.connect(_on_cast_received)
	add_child(_cast_receiver)
	_cast_problem = "" if _cast_receiver.start_receiver() else str(_cast_receiver.get_status_message())


func _on_cast_received(url: String, metadata: Dictionary) -> void:
	_cast_owner = NetworkHandler.get_sky_peer_id()
	if _cast_owner <= 1:
		return
	_cast_updated = Time.get_ticks_msec()
	_set_cast(url, metadata)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_session() -> void:
	if not active or not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var role: String = NetworkHandler.get_peer_role(sender)
	if role not in ["sky", "ground_vr"]:
		return
	if role == "sky":
		rpc_id(sender, "_receive_helper_config", _cast_token)
	if not cast_url.is_empty():
		rpc_id(sender, "_receive_cast", cast_url, cast_metadata)


@rpc("authority", "call_remote", "reliable", 0)
func _receive_helper_config(token: String) -> void:
	if multiplayer.get_remote_sender_id() != 1 or not is_child or not Profile.current().is_sky():
		return
	if token.length() != 48 or not token.is_valid_hex_number(false):
		return
	if _cast_token != token:
		_helper_started = false
		_helper_health.reset()
	_cast_token = token
	# _poll_child starts only after XR and its local receiver are ready.


@rpc("authority", "call_remote", "reliable", 0)
func _receive_cast(url: String, metadata: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != 1 or url.length() > 2048 or JSON.stringify(metadata).length() > 8192:
		return
	if not url.is_empty() and not CastEndpoint.is_valid(url, metadata):
		return
	_set_cast(url, metadata)


func _set_cast(url: String, metadata: Dictionary) -> void:
	if cast_url == url and cast_metadata == metadata:
		return
	cast_url = url
	cast_metadata = metadata.duplicate(true)
	cast_session_changed.emit(url, metadata)
	if active and not is_child and options.get("preset") != "join_sky" and NetworkHandler.peer != null:
		for peer_id in multiplayer.get_peers():
			if NetworkHandler.get_peer_role(peer_id) in ["sky", "ground_vr"]:
				rpc_id(peer_id, "_receive_cast", url, metadata)


func _start_helper() -> void:
	_helper_launch_error = ""
	if not bool(options.get("capture", true)) and not bool(options.get("cast", true)):
		return
	if OS.get_name() != "Windows" or DisplayServer.get_name() == "headless":
		_helper_launch_error = "自动采集需要 Windows 桌面运行环境"
		return
	_helper_started = true
	_helper_generation += 1
	var config := options.duplicate(true)
	config.cast_token = _cast_token
	config.parent_pid = OS.get_process_id()
	config.generation = _helper_generation
	var path := _folder.path_join("helper.json")
	_helper_status = _folder.path_join("helper-status.json")
	if Config.write_json(path, config) != OK:
		_helper_started = false
		_helper_launch_error = "无法写入 helper 启动配置，请检查会话目录权限"
		return
	if _helper_pid > 0 and OS.is_process_running(_helper_pid):
		return
	_helper_pid = _run_helper_wrapper("Start", path)
	if _helper_pid <= 0:
		_helper_started = false
		_helper_launch_error = "无法启动 PowerShell 采集管理进程，请检查系统权限"


func _run_helper_wrapper(action: String, path: String) -> int:
	var script := ProjectSettings.globalize_path("res://tools/startup/pico_helper.ps1")
	return OS.create_process("powershell.exe", PackedStringArray(["-NoProfile", "-NonInteractive",
		"-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", script,
		"-Action", action, "-Config", path, "-Status", _folder.path_join("helper-status.json")]), false)


func retry_helper() -> void:
	if not active:
		return
	var file := FileAccess.open(_folder.path_join("retry-helper"), FileAccess.WRITE)
	if file != null:
		file.store_string("retry")


func _report_child(state: String, detail: String) -> void:
	Config.write_json(_folder.path_join("child-status.json"), {"session_id": options.session_id,
		"state": state, "message": detail, "pid": OS.get_process_id()})


func _touch_parent() -> void:
	Config.write_json(_folder.path_join("parent.json"), {"time": Time.get_unix_time_from_system()})


func _publish(detail: String) -> void:
	if message == detail:
		return
	message = detail
	if is_instance_valid(_overlay):
		_overlay.call("set_status", detail)
	status_changed.emit(detail)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and active:
		stop_session(true)


func stop_session(quit_after: bool = false) -> void:
	if _stopping:
		return
	_stopping = true
	if is_child:
		if _helper_started:
			# Signal the owning watcher before asking the Android helper to stop;
			# it also owns USB reverse/forward mappings and the video encoder.
			var stop_file := FileAccess.open(_folder.path_join("stop"), FileAccess.WRITE)
			if stop_file != null:
				stop_file.store_string("stop")
				stop_file.close()
			var pid := _run_helper_wrapper("Stop", _folder.path_join("child.json"))
			var deadline := Time.get_ticks_msec() + 6000
			while pid > 0 and OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.2).timeout
			while _helper_pid > 0 and OS.is_process_running(_helper_pid) and Time.get_ticks_msec() < deadline:
				await get_tree().create_timer(0.2).timeout
		get_tree().quit()
		return
	if not _folder.is_empty():
		var file := FileAccess.open(_folder.path_join("stop"), FileAccess.WRITE)
		if file != null:
			file.store_string("stop")
	var deadline := Time.get_ticks_msec() + 9000
	while (_child_pid == -2 or (_child_pid > 0 and OS.is_process_running(_child_pid))) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.2).timeout
	if _child_pid > 0 and OS.is_process_running(_child_pid):
		_publish("XR 尚未退出，请关闭 XR 窗口后再结束；未强制终止其他进程")
		_stopping = false
		return
	if is_instance_valid(_cast_receiver):
		_cast_receiver.queue_free()
	_cast_receiver = null
	_cast_owner = 0
	_cast_token = ""
	_discovery_server.close()
	NetworkHandler._close_network_peer()
	_controller_lock.stop()
	active = false
	get_tree().auto_accept_quit = true
	_stopping = false
	_child_pid = -1
	_set_cast("", {})
	if is_instance_valid(_overlay):
		_overlay.queue_free()
	if quit_after:
		get_tree().quit()
	else:
		Profile.clear_session_override()
		get_tree().change_scene_to_file("res://Assets/ARSpace/Scenes/StartMenu.tscn")


func _create_overlay() -> void:
	_overlay = StatusOverlay.new()
	add_child(_overlay)
	_overlay.retry_xr_requested.connect(start_child)
	_overlay.retry_helper_requested.connect(retry_helper)
	_overlay.stop_requested.connect(stop_session)
	_overlay.set_status(message)


func discover_servers() -> void:
	discovered_servers.clear()
	_discovery_targets.assign(["127.0.0.1", "255.255.255.255"])
	if OS.get_name() == "Windows":
		var output: Array = []
		var code := OS.execute("powershell.exe", PackedStringArray(["-NoProfile", "-NonInteractive",
			"-ExecutionPolicy", "Bypass", "-File", ProjectSettings.globalize_path("res://tools/startup/discovery_targets.ps1")]), output)
		if code == 0 and not output.is_empty():
			var targets: Variant = JSON.parse_string(str(output[0]).strip_edges())
			if targets is Array:
				for target in targets:
					if target is String and target.is_valid_ip_address() and not _discovery_targets.has(target):
						_discovery_targets.append(target)
	_discovery_retries = 3
	_send_discovery()
	servers_changed.emit(discovered_servers)


func _send_discovery() -> void:
	_discovery_retries -= 1
	_discovery_next_send = Time.get_ticks_msec() + 1000
	for target in _discovery_targets:
		if _discovery.set_dest_address(target, DISCOVERY_PORT) == OK:
			_discovery.put_packet("GODOTSPACE_DISCOVER_1".to_utf8_buffer())


func _poll_discovery() -> void:
	for socket in [_discovery_server, _discovery]:
		var count := 0
		while socket.get_available_packet_count() > 0 and count < 16:
			count += 1
			var packet: PackedByteArray = socket.get_packet()
			var ip: String = socket.get_packet_ip()
			var port: int = socket.get_packet_port()
			if packet.size() > 1024:
				continue
			if socket == _discovery_server and active and packet.get_string_from_utf8() == "GODOTSPACE_DISCOVER_1":
				socket.set_dest_address(ip, port)
				socket.put_packet(JSON.stringify({"type": "godotspace_server", "version": 1,
					"name": OS.get_environment("COMPUTERNAME"), "port": 42069}).to_utf8_buffer())
			elif socket == _discovery:
				var data = JSON.parse_string(packet.get_string_from_utf8())
				if data is Dictionary and data.get("type") == "godotspace_server" and data.get("version") == 1:
					discovered_servers[ip] = str(data.get("name", "Server")).left(80)
					servers_changed.emit(discovered_servers.duplicate())
