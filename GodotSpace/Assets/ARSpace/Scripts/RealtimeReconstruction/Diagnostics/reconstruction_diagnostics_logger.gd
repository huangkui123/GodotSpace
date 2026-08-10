class_name ReconstructionDiagnosticsLogger
extends RefCounted

## Persists one PC Server reconstruction session as JSONL plus inspectable
## first/latest PICO JPEGs. The directory is runtime-only under user:// and
## must never be copied into source control because it can contain camera
## images, device metadata and local network addresses.

const SCHEMA_VERSION := 1
const LOG_ROOT := "user://reconstruction_diagnostics"

var _event_file: FileAccess
var _session_directory := ""
var _globalized_session_directory := ""
var _session_id := ""
var _first_frame_saved := false
var _event_sequence := 0
var _last_error := ""


func start_session(session_id: String, configuration: Dictionary) -> bool:
	close_session()
	_last_error = ""
	_session_id = session_id
	var timestamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var directory_name := "%s_%s" % [timestamp, _sanitize_component(session_id)]
	_session_directory = "%s/%s" % [LOG_ROOT, directory_name]
	_globalized_session_directory = ProjectSettings.globalize_path(_session_directory)
	var create_error := DirAccess.make_dir_recursive_absolute(
		_globalized_session_directory
	)
	if create_error != OK:
		_last_error = "Could not create reconstruction diagnostics directory: %s" % (
			error_string(create_error)
		)
		_reset_paths()
		return false

	_event_file = FileAccess.open(
		"%s/godot_events.jsonl" % _session_directory,
		FileAccess.WRITE,
	)
	if _event_file == null:
		_last_error = "Could not open reconstruction diagnostics JSONL: %s" % (
			error_string(FileAccess.get_open_error())
		)
		_reset_paths()
		return false

	var manifest := {
		"schema_version": SCHEMA_VERSION,
		"session_id": _session_id,
		"created_at_utc": Time.get_datetime_string_from_system(true, true),
		"configuration": configuration.duplicate(true),
	}
	if not _write_json_file(
		"%s/godot_session.json" % _session_directory,
		manifest,
	):
		close_session()
		return false
	if not _write_text_file(
		"%s/latest_session.txt" % LOG_ROOT,
		_globalized_session_directory,
	):
		close_session()
		return false
	log_event("diagnostics_started", {
		"directory": _globalized_session_directory,
		"configuration": configuration.duplicate(true),
	})
	return true


func close_session(summary: Dictionary = {}) -> void:
	if _event_file != null:
		log_event("diagnostics_stopped", summary)
		_event_file.flush()
		_event_file = null
	_session_id = ""
	_first_frame_saved = false
	_event_sequence = 0


func is_active() -> bool:
	return _event_file != null


func get_session_directory() -> String:
	return _session_directory


func get_globalized_session_directory() -> String:
	return _globalized_session_directory


func get_last_error() -> String:
	return _last_error


func log_event(event_name: String, fields: Dictionary = {}) -> bool:
	if _event_file == null:
		return false
	_event_sequence += 1
	var record := fields.duplicate(true)
	record["schema_version"] = SCHEMA_VERSION
	record["event"] = event_name
	record["event_sequence"] = _event_sequence
	record["session_id"] = _session_id
	record["timestamp_utc"] = Time.get_datetime_string_from_system(true, true)
	record["server_ticks_usec"] = Time.get_ticks_usec()
	_event_file.store_line(JSON.stringify(record))
	_event_file.flush()
	return true


func log_pico_frame(
	frame_id: int,
	timestamp_ns: int,
	width: int,
	height: int,
	metadata: Dictionary,
	jpeg_bytes: PackedByteArray,
	forwarded_to_lab: bool,
	bridge_snapshot: Dictionary,
) -> void:
	var jpeg_sha256 := _sha256_hex(jpeg_bytes)
	var image_write_errors: Array[String] = []
	if not _first_frame_saved:
		var first_error := _write_bytes(
			"%s/first_received.jpg" % _session_directory,
			jpeg_bytes,
		)
		if first_error.is_empty():
			_first_frame_saved = true
		else:
			image_write_errors.append(first_error)
	var latest_error := _write_bytes(
		"%s/latest_received.jpg" % _session_directory,
		jpeg_bytes,
	)
	if not latest_error.is_empty():
		image_write_errors.append(latest_error)
	log_event("pico_frame_received", {
		"frame_id": frame_id,
		"frame_timestamp_ns": timestamp_ns,
		"width": width,
		"height": height,
		"jpeg_bytes": jpeg_bytes.size(),
		"jpeg_sha256": jpeg_sha256,
		"metadata": metadata.duplicate(true),
		"forwarded_to_lab": forwarded_to_lab,
		"bridge": bridge_snapshot.duplicate(true),
		"image_write_errors": image_write_errors,
	})


func _write_json_file(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_last_error = "Could not write diagnostics manifest: %s" % (
			error_string(FileAccess.get_open_error())
		)
		return false
	file.store_string(JSON.stringify(value, "\t"))
	file.flush()
	return true


func _write_text_file(path: String, value: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_last_error = "Could not write diagnostics pointer: %s" % (
			error_string(FileAccess.get_open_error())
		)
		return false
	file.store_string(value)
	file.flush()
	return true


func _write_bytes(path: String, bytes: PackedByteArray) -> String:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Could not write %s: %s" % [
			path,
			error_string(FileAccess.get_open_error()),
		]
	file.store_buffer(bytes)
	file.flush()
	return ""


func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _sanitize_component(value: String) -> String:
	var sanitized := ""
	for index in range(value.length()):
		var character := value.substr(index, 1)
		if character.to_lower() in "abcdefghijklmnopqrstuvwxyz0123456789-_":
			sanitized += character
		else:
			sanitized += "_"
	sanitized = sanitized.strip_edges().left(96)
	return sanitized if not sanitized.is_empty() else "session"


func _reset_paths() -> void:
	_event_file = null
	_session_directory = ""
	_globalized_session_directory = ""
	_session_id = ""
