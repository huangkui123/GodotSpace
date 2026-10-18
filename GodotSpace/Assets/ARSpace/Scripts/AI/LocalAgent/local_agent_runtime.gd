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


func _ready() -> void:
	enabled = bool(ProjectSettings.get_setting("arspace/local_agent/enabled", false))
	var saved := ConfigFile.new()
	if saved.load(PREFERENCE_PATH) == OK:
		compute_mode = str(saved.get_value("runtime", "compute", "local"))
	if compute_mode not in ["local", "remote"]:
		compute_mode = "local"
	var network := get_node_or_null("/root/NetworkHandler")
	if network != null:
		network.network_role_selected.connect(_on_role_selected)


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
	var key := role + ":" + compute_mode
	if not recheck and _ready_key == key:
		return true
	if _busy:
		return false
	_busy = true
	_ready_key = ""
	var success := await _start_services(role)
	_busy = false
	if success:
		_ready_key = key
	return success


func _start_services(role: String) -> bool:
	var repo := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	var config := repo.path_join("Model/generated/local-agent-deploy/runtime.json")
	var wrapper := repo.path_join("Model/scripts/start_local_agent_runtime.ps1")
	if OS.get_name() != "Windows" or not FileAccess.file_exists(config):
		_publish("failed", "尚未完成本机部署：请使用 deploy-local-agent skill 生成 runtime.json（当前一键入口支持 Windows + WSL）。")
		return false
	var status := repo.path_join("Model/generated/local-agent-deploy/start-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_msec()])
	_publish("starting", "正在检查并启动智能助手服务…")
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
					_publish("ready", "智能助手服务已就绪")
					return true
		if not OS.is_process_running(pid):
			_publish("failed", "服务启动器退出但未报告就绪，请检查 Model/logs/local-agent-deploy。")
			return false
	_publish("failed", "服务启动超时，请检查日志；未停止其他进程。")
	return false
