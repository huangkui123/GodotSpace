extends Node

signal status_changed(state: String, message: String)

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const PREFERENCE_PATH := "user://local_agent_runtime.cfg"
var compute_mode := "local"
var state := "idle"
var message := ""
var enabled := true
var _busy := false
var _ready_key := ""
var _managed_role := ""
var _next_health_check := 0
const HEALTH_CHECK_INTERVAL_MSEC := 30_000


func _ready() -> void:
	enabled = bool(ProjectSettings.get_setting("arspace/local_agent/enabled", false))
	var saved := ConfigFile.new()
	var saved_mode := ""
	if saved.load(PREFERENCE_PATH) == OK:
		saved_mode = str(saved.get_value("runtime", "compute", ""))
	var config = JSON.parse_string(FileAccess.get_file_as_string(_runtime_config_path("server")).trim_prefix("\ufeff")) if FileAccess.file_exists(_runtime_config_path("server")) else {}
	compute_mode = default_compute(config if config is Dictionary else {}, saved_mode)
	var network := get_node_or_null("/root/NetworkHandler")
	if network != null:
		network.network_role_selected.connect(_on_role_selected)


static func default_compute(config: Dictionary, saved_mode: String) -> String:
	# Preserve an explicit choice; never silently move inference to another host.
	if saved_mode in ["local", "remote"]:
		return saved_mode
	var modes: Dictionary = config.get("compute", {})
	return "remote" if modes.has("remote") and not modes.has("local") else "local"


func automatic_start_allowed() -> bool:
	return OS.get_name() == "Windows" and (DisplayServer.get_name() != "headless" or OS.get_cmdline_user_args().has("--local-agent-autostart"))


func prepare_launch(options: Dictionary) -> bool:
	enabled = bool(options.get("assistant", true))
	if not enabled:
		_managed_role = ""
		return true
	# A local launcher hosts both the coordinator and an XR child; a joining
	# workstation owns only ASR/TTS. No model connection is made from Clients.
	_managed_role = "client" if options.get("preset", "local_sky") == "join_sky" else "server_voice"
	_next_health_check = Time.get_ticks_msec() + HEALTH_CHECK_INTERVAL_MSEC
	return await _ensure_role_services(_managed_role, true)


func _process(_delta: float) -> void:
	if automatic_start_allowed():
		_poll_services(Time.get_ticks_msec())


func _poll_services(now_msec: int) -> void:
	if not enabled or _busy or _managed_role.is_empty() or now_msec < _next_health_check:
		return
	_next_health_check = now_msec + HEALTH_CHECK_INTERVAL_MSEC
	# The host controller reuses healthy services and restarts stopped ones.
	# Failed starts are retried without restarting Godot or opening a terminal.
	_ensure_role_services(_managed_role, true)


func select_compute(mode: String) -> void:
	if _busy or mode not in ["local", "remote"]:
		return
	compute_mode = mode
	var saved := ConfigFile.new()
	saved.set_value("runtime", "compute", mode)
	saved.save(PREFERENCE_PATH)


func _on_role_selected(_server: bool) -> void:
	# Test fixtures own their mock services. Production entrypoints that bypass
	# StartMenu still request the same host lifecycle, without blocking frames.
	if DisplayServer.get_name() == "headless" and not OS.get_cmdline_user_args().has("--local-agent-autostart"):
		return
	if not _busy and enabled:
		ensure_services(RuntimeProfile.current(), false)


func _publish(next: String, detail: String) -> void:
	state = next
	message = detail
	status_changed.emit(state, message)


func ensure_services(profile: RefCounted, recheck: bool = true) -> bool:
	if not enabled:
		return true
	var role := "client"
	if profile.is_server():
		role = "server_voice" if profile.uses_xr() else "server"
	if _managed_role != "server_voice":
		_managed_role = role
	_next_health_check = Time.get_ticks_msec() + HEALTH_CHECK_INTERVAL_MSEC
	return await _ensure_role_services(role, recheck)


func ensure_gateway() -> bool:
	var agent := get_node_or_null("/root/LocalAgentClient")
	if agent == null or not agent.can_host_gateway():
		_publish("failed", "智能助手后端需要由协作 Server 启动。")
		return false
	# An explicit assistant command may opt in after collaboration-only startup.
	# Start and verify the backend before enabling the WebSocket client.
	if not await _ensure_role_services("server", true):
		return false
	enabled = true
	if _managed_role.is_empty():
		_managed_role = "server"
	ProjectSettings.set_setting("arspace/local_agent/enabled", true)
	if not await _connect_gateway():
		_publish("failed", "智能助手服务已启动，但 Godot 未能连接 Gateway，请重试。")
		return false
	return true


func _connect_gateway() -> bool:
	return await get_node("/root/LocalAgentClient").ensure_connection()


func ensure_asr(endpoint: String = "") -> bool:
	# Speech recognition is also used with model/assistant startup disabled.
	# Recheck on every explicit request so a stopped WSL service can recover.
	if not endpoint.is_empty():
		var port := 8765
		var config_path := _runtime_config_path("asr")
		if FileAccess.file_exists(config_path):
			var config = JSON.parse_string(FileAccess.get_file_as_string(config_path).trim_prefix("\ufeff"))
			if config is Dictionary and config.get("asr") is Dictionary:
				port = int(config.asr.get("port", port))
		if endpoint not in ["ws://127.0.0.1:%d/ws/asr" % port, "ws://localhost:%d/ws/asr" % port]:
			# Explicit external endpoints remain owned by their administrator.
			return true
	return await _ensure_role_services("asr", true)


func _ensure_role_services(role: String, recheck: bool) -> bool:
	while _busy:
		await get_tree().process_frame
	var key := role + ":" + compute_mode
	if not recheck and _ready_key == key:
		return true
	_busy = true
	_ready_key = ""
	var success := await _start_services(role)
	_busy = false
	if success:
		_ready_key = key
	return success


func _runtime_config_path(role: String) -> String:
	var repo := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	var config := repo.path_join("Model/generated/local-agent-deploy/runtime.json")
	if role == "asr" and not FileAccess.file_exists(config):
		config = repo.path_join("Model/generated/local-agent-deploy/asr-runtime.json")
	return config


func _start_services(role: String) -> bool:
	var repo := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	var config := _runtime_config_path(role)
	var wrapper := repo.path_join("Model/scripts/start_local_agent_runtime.ps1")
	if OS.get_name() != "Windows" or not FileAccess.file_exists(config):
		_publish("failed", "尚未完成本机部署：请使用 deploy-local-agent skill 生成 runtime.json（当前一键入口支持 Windows + WSL）。")
		return false
	var status := repo.path_join("Model/generated/local-agent-deploy/start-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_msec()])
	_publish("starting", "正在检查并启动语音识别服务…" if role == "asr" else "正在检查并启动智能助手服务…")
	var pid := OS.create_process("powershell.exe", PackedStringArray([
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", wrapper,
		"-Config", config, "-Status", status, "-Role", role, "-Mode", compute_mode,
	]), false)
	if pid <= 0:
		_publish("failed", "无法启动本机服务管理程序。")
		return false
	var deadline := Time.get_ticks_msec() + 2_500_000
	while Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
		if FileAccess.file_exists(status):
			var result = JSON.parse_string(FileAccess.get_file_as_string(status).trim_prefix("\ufeff"))
			if result is Dictionary:
				var next := str(result.get("state", "starting"))
				_publish(next, str(result.get("message", "正在启动…")))
				if next == "failed":
					return false
				if next == "ready":
					for variable in result.get("endpoints", {}):
						OS.set_environment(str(variable), str(result["endpoints"][variable]))
					var speech := get_node_or_null("/root/AssistantSpeech")
					if speech != null and result.get("endpoints", {}).has("GODOTSPACE_TTS_ENDPOINT"):
						speech.endpoint = str(result["endpoints"]["GODOTSPACE_TTS_ENDPOINT"])
					_publish("ready", "语音识别服务已就绪" if role == "asr" else "智能助手服务已就绪")
					return true
		if not OS.is_process_running(pid):
			_publish("failed", "服务启动器退出但未报告就绪，请检查 Model/logs/local-agent-deploy。")
			return false
	_publish("failed", "服务启动超时，请检查日志；未停止其他进程。")
	return false
