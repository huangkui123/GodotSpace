extends RefCounted

const PRESETS := ["local_sky", "local_ground", "join_sky"]
const PREFERENCE_PATH := "user://startup/preferences.json"


static func defaults() -> Dictionary:
	return {"preset": "local_sky", "server_ip": "", "adb_path": "", "device_serial": "",
		"streaming_path": "", "voice": false, "assistant": false, "capture": true,
		"cast": true, "transport": "usb", "input_device": "Default", "output_device": "Default"}


static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 65536:
		return {}
	var parsed = JSON.parse_string(file.get_as_text().trim_prefix("\ufeff"))
	return parsed if parsed is Dictionary else {}


static func write_json(path: String, value: Dictionary) -> Error:
	var absolute := ProjectSettings.globalize_path(path)
	var error := DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if error != OK:
		return error
	var file := FileAccess.open(absolute + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(value))
	file.close()
	return DirAccess.rename_absolute(absolute + ".tmp", absolute)


static func preferences() -> Dictionary:
	var result := defaults()
	var saved := read_json(PREFERENCE_PATH)
	for key in result:
		if saved.has(key) and typeof(saved[key]) == typeof(result[key]):
			result[key] = saved[key]
	if result.preset not in PRESETS:
		result.preset = "local_sky"
	result.transport = "usb"
	# Old wireless ADB selections must not silently keep a saved startup on Wi-Fi.
	if str(result.device_serial).contains(":") or str(result.device_serial).begins_with("adb-"):
		result.device_serial = ""
	return result


static func validate(options: Dictionary) -> String:
	if str(options.get("preset", "")) not in PRESETS:
		return "请选择启动方式"
	if options.preset == "join_sky" and str(options.get("server_ip", "")).strip_edges().is_empty():
		return "请选择发现的 Server，或填写 Server 地址"
	return ""


static func argument(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


static func child_arguments(project: String, config_path: String, options: Dictionary) -> PackedStringArray:
	var args := PackedStringArray(["--path", project, "--xr-mode", "on", "--",
		"--voice-role=client", "--session-config=" + config_path,
		"--server-ip=" + str(options.server_ip)])
	args.append("--ground-vr-client" if options.preset == "local_ground" else "--xr-client")
	return args
