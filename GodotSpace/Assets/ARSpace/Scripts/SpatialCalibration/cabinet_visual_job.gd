extends Node

## A private child process per request. No shell, network listener or shared service.
signal completed(result: Dictionary)
signal progressed(result: Dictionary)
const JOB_ROOT := "user://cabinet_visual_jobs"
const WORKER := "res://tools/cabinet_calibration/visual_pose_worker.py"
const LAST_SCAN := "user://cabinet_visual_diagnostics/last_scan.json"
var _pid: int = -1
var _directory: String = ""
var _started: int = 0
var _request_id: String = ""
var _last_progress: int = 0
var _last_poll: int = 0


func start(request: Dictionary) -> String:
	cancel()
	_last_progress = 0
	_last_poll = 0
	var executable := OS.get_environment("GODOTSPACE_CABINET_PYTHON")
	if executable.is_empty():
		executable = OS.get_environment("LOCALAPPDATA").path_join("GodotSpace/cabinet-calibration-venv/Scripts/python.exe")
	if not FileAccess.file_exists(executable):
		return "未找到识别环境。请配置 GODOTSPACE_CABINET_PYTHON，或按柜体识别文档安装本地环境。"
	var artifacts := OS.get_environment("GODOTSPACE_CABINET_ARTIFACTS")
	if artifacts.is_empty():
		artifacts = ProjectSettings.globalize_path("res://tools/cabinet_calibration/artifacts")
	if request.get("model_kind", "cad") == "cad" and not FileAccess.file_exists(artifacts.path_join("templates/templates.json")):
		return "未找到 CAD 特征库。请先按柜体识别文档准备模型与模板。"
	_request_id = str(request.get("request_id", ""))
	_directory = ProjectSettings.globalize_path(JOB_ROOT).path_join("job_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if DirAccess.make_dir_recursive_absolute(_directory) != OK:
		_directory = ""
		return "无法创建本地识别临时目录。"
	var file := FileAccess.open(_directory.path_join("request.json"), FileAccess.WRITE)
	if file == null:
		cancel()
		return "无法写入识别请求。"
	file.store_string(JSON.stringify(request))
	file.close()
	var diagnostic := OS.get_environment("GODOTSPACE_CABINET_DIAGNOSTIC_PATH")
	if diagnostic.is_empty():
		diagnostic = ProjectSettings.globalize_path(LAST_SCAN)
	# Python imports and feature matching run outside the render/main thread.
	_pid = OS.create_process(executable, PackedStringArray([
		"-B", ProjectSettings.globalize_path(WORKER), "--request", _directory.path_join("request.json"),
		"--output", _directory.path_join("result.json"), "--artifacts", artifacts,
		"--diagnostic", diagnostic,
		"--progress", _directory.path_join("progress.json"),
	]), false)
	if _pid <= 0:
		cancel()
		return "无法启动本地 CAD 识别进程。"
	_started = Time.get_ticks_msec()
	return ""


func _process(_delta: float) -> void:
	if _pid <= 0:
		return
	if Time.get_ticks_msec() - _started > 120_000:
		_finish({"status": "error", "error": "识别超时，请检查本地 Python 环境和模型。"})
		return
	# Read only after process exit, so cleanup cannot race with result publication.
	if OS.is_process_running(_pid):
		_poll_progress()
		return
	_pid = -1
	var file := FileAccess.open(_directory.path_join("result.json"), FileAccess.READ)
	if file == null:
		_finish({"status": "error", "error": "识别进程未返回有效结果，请检查 Python 依赖。"})
		return
	if file.get_length() > 16 * 1024 * 1024:
		file.close()
		_finish({"status": "error", "error": "识别结果超过大小限制。"})
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary or str(parsed.get("request_id", "")) != _request_id:
		_finish({"status": "error", "error": "识别结果与当前请求不匹配。"})
		return
	_finish(parsed)


func _poll_progress() -> void:
	if Time.get_ticks_msec() - _last_poll < 200:
		return
	_last_poll = Time.get_ticks_msec()
	var path := _directory.path_join("progress.json")
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	if file.get_length() > 16 * 1024 * 1024:
		file.close()
		return
	var contents := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(contents)
	if not parsed is Dictionary or parsed.get("request_id") != _request_id or parsed.get("partial") != true:
		return
	var count := int(parsed.get("processed_frames", 0))
	if count <= _last_progress or count > 16 or count > int(parsed.get("total_frames", 0)):
		return
	_last_progress = count
	progressed.emit(parsed)


func _finish(result: Dictionary) -> void:
	result["worker_elapsed_seconds"] = maxf(0.0, (Time.get_ticks_msec() - _started) / 1000.0)
	print("[CabinetVisual] request=%s status=%s elapsed_seconds=%.3f reason=%s diagnostic=%s" % [
		_request_id, str(result.get("status", "unknown")),
		float(result.worker_elapsed_seconds),
		str(result.get("multiview_fit", {}).get("reason", result.get("error", ""))),
		str(result.get("diagnostic_path", "not saved"))])
	cancel()
	completed.emit(result)


func cancel() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	if not _directory.is_empty():
		# Only known files from this owned job are removed; never recurse.
		for filename in ["request.json", "result.json", "result.tmp", "progress.json", "progress.tmp"]:
			DirAccess.remove_absolute(_directory.path_join(filename))
		DirAccess.remove_absolute(_directory)
	_directory = ""


func _exit_tree() -> void:
	cancel()
