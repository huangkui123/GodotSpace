extends SceneTree

const DiagnosticsLogger := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Diagnostics/reconstruction_diagnostics_logger.gd"
)


func _init() -> void:
	var logger: RefCounted = DiagnosticsLogger.new()
	_expect(
		logger.call("start_session", "diagnostics-self-test", {
			"model": "test",
			"threshold": 1.5,
		}),
		"diagnostics session must start",
	)
	var session_directory := str(logger.call("get_session_directory"))
	var global_directory := str(logger.call("get_globalized_session_directory"))
	_expect(not session_directory.is_empty(), "session directory must be reported")
	_expect(DirAccess.dir_exists_absolute(global_directory), "session directory must exist")

	var jpeg := PackedByteArray([0xFF, 0xD8, 0xFF, 0xD9])
	logger.call(
		"log_pico_frame",
		42,
		123456789,
		640,
		480,
		{"camera": "rgb", "intrinsics": [1.0, 2.0, 3.0]},
		jpeg,
		true,
		{"queued_input_frames": 1},
	)
	logger.call("log_event", "point_chunk_received", {
		"chunk_id": "1",
		"source_point_count": 1234,
	})
	logger.call("close_session", {"reason": "self_test"})

	_expect(
		FileAccess.file_exists("%s/godot_session.json" % session_directory),
		"session manifest must exist",
	)
	_expect(
		FileAccess.file_exists("%s/godot_events.jsonl" % session_directory),
		"event JSONL must exist",
	)
	_expect(
		FileAccess.file_exists("%s/first_received.jpg" % session_directory),
		"first frame must exist",
	)
	_expect(
		FileAccess.file_exists("%s/latest_received.jpg" % session_directory),
		"latest frame must exist",
	)
	_expect(
		FileAccess.get_file_as_string(
			"%s/latest_session.txt" % DiagnosticsLogger.LOG_ROOT
		) == global_directory,
		"latest-session pointer must identify the new diagnostics directory",
	)
	var event_text := FileAccess.get_file_as_string(
		"%s/godot_events.jsonl" % session_directory
	)
	_expect("\"metadata\":{\"camera\":\"rgb\"" in event_text, "PICO metadata must be logged")
	_expect("\"jpeg_sha256\":" in event_text, "JPEG digest must be logged")
	_expect("\"source_point_count\":1234" in event_text, "point stats must be logged")

	_cleanup_self_test_sessions()
	print("RECONSTRUCTION_DIAGNOSTICS_LOGGER_SELF_TEST PASS")
	quit(0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("RECONSTRUCTION_DIAGNOSTICS_LOGGER_SELF_TEST FAIL: %s" % message)
	quit(1)


func _cleanup_self_test_sessions() -> void:
	var root := ProjectSettings.globalize_path(DiagnosticsLogger.LOG_ROOT)
	var directory := DirAccess.open(root)
	if directory == null:
		return
	for directory_name in directory.get_directories():
		if not directory_name.ends_with("_diagnostics-self-test"):
			continue
		var session_root := root.path_join(directory_name)
		for file_name in [
			"first_received.jpg",
			"latest_received.jpg",
			"godot_events.jsonl",
			"godot_session.json",
		]:
			var file_path := session_root.path_join(file_name)
			if FileAccess.file_exists(file_path):
				DirAccess.remove_absolute(file_path)
		DirAccess.remove_absolute(session_root)
	var latest_pointer := root.path_join("latest_session.txt")
	if FileAccess.file_exists(latest_pointer):
		DirAccess.remove_absolute(latest_pointer)
