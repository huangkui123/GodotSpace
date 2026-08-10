class_name ReconstructionGsmapStore
extends RefCounted

# GSM1 is an atomic, uncompressed single-file container. Its body contains one
# bounded JSON manifest followed by length+SHA-256+PCCH records. Raw video is
# deliberately outside this format.
const ChunkCodec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)
const Chunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)
const MapStore := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_map_store.gd"
)

const MAGIC_TEXT: String = "GSM1"
const FORMAT_NAME: String = "GodotSpace Realtime Reconstruction Map"
const FORMAT_VERSION: int = 1
const HEADER_SIZE: int = 72
const DIGEST_OFFSET: int = 40
const DIGEST_SIZE: int = 32
const ENTRY_HEADER_SIZE: int = 36
const MAX_MANIFEST_BYTES: int = 1024 * 1024
const MAX_PACKAGE_BYTES: int = 64 * 1024 * 1024
const LIBRARY_DIR: String = "user://reconstruction_maps"


static func export_map(
	store: ReconstructionPointCloudMapStore,
	display_name: String,
	options: Dictionary = {}
) -> Dictionary:
	if store == null or store.is_empty():
		return _failure("cannot export an empty map")
	if store.get_point_count() > MapStore.DEFAULT_MAX_POINTS:
		return _failure("map exceeds the supported point limit")
	var library_error := _ensure_library_directory()
	if library_error != OK:
		return _failure("could not create reconstruction map library")
	var registration_result := _normalize_registration(options.get("registration", {}))
	if not bool(registration_result.get("ok", false)):
		return registration_result

	var encoded_chunks: Array[PackedByteArray] = []
	var chunk_records: Array[Dictionary] = []
	var chunks := store.get_chunks()
	for chunk_index in range(chunks.size()):
		var encoded_result := ChunkCodec.encode(chunks[chunk_index])
		if not bool(encoded_result.get("ok", false)):
			return _failure("could not encode chunk %d: %s" % [
				chunk_index,
				str(encoded_result.get("error", "unknown error")),
			])
		var encoded := encoded_result.get("data", PackedByteArray()) as PackedByteArray
		var digest := ChunkCodec.sha256_hex(encoded)
		encoded_chunks.append(encoded)
		chunk_records.append({
			"index": chunk_index,
			"chunk_id": chunks[chunk_index].chunk_id,
			"point_count": chunks[chunk_index].point_count(),
			"byte_length": encoded.size(),
			"sha256": digest,
		})

	var now := int(Time.get_unix_time_from_system())
	var manifest := {
		"format": FORMAT_NAME,
		"format_version": FORMAT_VERSION,
		"package_encoding": "GSM1-manifest-plus-PCCH",
		"point_chunk_codec_version": ChunkCodec.VERSION,
		"display_name": _clean_display_name(display_name),
		"session_id": store.session_id,
		"map_id": store.map_id,
		"created_at_unix_sec": int(options.get("created_at_unix_sec", now)),
		"exported_at_unix_sec": now,
		"point_count": store.get_point_count(),
		"chunk_count": store.get_chunk_count(),
		"bounds": _aabb_to_dictionary(store.get_bounds()),
		"coordinate_space": ChunkCodec.COORDINATE_SPACE,
		"position_unit": ChunkCodec.POSITION_UNIT,
		"voxel_size_m": float(options.get("voxel_size_m", 0.025)),
		"model": {
			"name": str(options.get("model_name", "lingbot-map")),
			"version": str(options.get("model_version", "unknown")),
		},
		"registration": registration_result.get("registration", {}),
		"contains_raw_video": false,
		"chunks": chunk_records,
	}
	var manifest_error := _validate_manifest(manifest)
	if not manifest_error.is_empty():
		return _failure("cannot export invalid manifest: %s" % manifest_error)
	var manifest_bytes := JSON.stringify(manifest).to_utf8_buffer()
	if manifest_bytes.is_empty() or manifest_bytes.size() > MAX_MANIFEST_BYTES:
		return _failure("manifest exceeds the supported byte size")

	var body := manifest_bytes.duplicate()
	for chunk_index in range(encoded_chunks.size()):
		var encoded := encoded_chunks[chunk_index]
		var entry_header := PackedByteArray()
		entry_header.resize(ENTRY_HEADER_SIZE)
		_write_u32_be(entry_header, 0, encoded.size())
		var digest := _sha256(encoded)
		for digest_index in range(DIGEST_SIZE):
			entry_header[4 + digest_index] = digest[digest_index]
		body.append_array(entry_header)
		body.append_array(encoded)
	var total_size := HEADER_SIZE + body.size()
	if total_size > MAX_PACKAGE_BYTES:
		return _failure("map package exceeds the supported byte size")

	var package := PackedByteArray()
	package.resize(HEADER_SIZE)
	package[0] = 0x47
	package[1] = 0x53
	package[2] = 0x4d
	package[3] = 0x31
	_write_u16_be(package, 4, FORMAT_VERSION)
	_write_u16_be(package, 6, HEADER_SIZE)
	_write_u32_be(package, 8, 0)
	_write_u32_be(package, 12, manifest_bytes.size())
	_write_u32_be(package, 16, encoded_chunks.size())
	_write_u32_be(package, 20, store.get_point_count())
	_write_u64_be(package, 24, total_size)
	_write_u32_be(package, 32, body.size())
	_write_u32_be(package, 36, 0)
	var body_digest := _sha256(body)
	for index in range(DIGEST_SIZE):
		package[DIGEST_OFFSET + index] = body_digest[index]
	package.append_array(body)

	var file_name := _unique_file_name(_sanitize_file_stem(display_name))
	var final_path := LIBRARY_DIR.path_join(file_name)
	var temporary_path := "%s.tmp-%d" % [final_path, Time.get_ticks_usec()]
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _failure("could not open temporary map package for writing")
	file.store_buffer(package)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		return _failure("failed while writing map package")
	var rename_error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temporary_path),
		ProjectSettings.globalize_path(final_path)
	)
	if rename_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		return _failure("could not finalize map package")
	return {
		"ok": true,
		"path": final_path,
		"file_name": file_name,
		"manifest": manifest,
		"error": "",
	}


static func import_map(file_name: String) -> Dictionary:
	var path_result := _resolve_library_file(file_name)
	if not bool(path_result.get("ok", false)):
		return path_result
	var path := str(path_result.get("path", ""))
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("map package does not exist or cannot be read")
	var file_size := file.get_length()
	if file_size < HEADER_SIZE or file_size > MAX_PACKAGE_BYTES:
		file.close()
		return _failure("map package size is outside the supported range")
	var package := file.get_buffer(file_size)
	var read_error := file.get_error()
	file.close()
	if read_error != OK or package.size() != file_size:
		return _failure("could not read the complete map package")
	return _decode_package(package, path)


static func list_maps() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _ensure_library_directory() != OK:
		return result
	var directory := DirAccess.open(LIBRARY_DIR)
	if directory == null:
		return result
	var file_names := directory.get_files()
	file_names.sort()
	for file_name in file_names:
		if not file_name.to_lower().ends_with(".gsmap"):
			continue
		var inspection := _read_manifest_header(LIBRARY_DIR.path_join(file_name))
		if bool(inspection.get("ok", false)):
			result.append({
				"file_name": file_name,
				"path": LIBRARY_DIR.path_join(file_name),
				"manifest": inspection.get("manifest", {}),
			})
	return result


static func _decode_package(package: PackedByteArray, path: String) -> Dictionary:
	if not _has_magic(package):
		return _failure("invalid map package magic")
	if _read_u16_be(package, 4) != FORMAT_VERSION:
		return _failure("unsupported map package version")
	if _read_u16_be(package, 6) != HEADER_SIZE:
		return _failure("unexpected map package header size")
	if _read_u32_be(package, 8) != 0 or _read_u32_be(package, 36) != 0:
		return _failure("reserved map package header fields must be zero")
	var manifest_size := _read_u32_be(package, 12)
	if manifest_size <= 0 or manifest_size > MAX_MANIFEST_BYTES:
		return _failure("manifest size is outside the supported range")
	var chunk_count := _read_u32_be(package, 16)
	if chunk_count <= 0 or chunk_count > MapStore.DEFAULT_MAX_POINTS:
		return _failure("chunk count is outside the supported range")
	var declared_point_count := _read_u32_be(package, 20)
	if declared_point_count <= 0 or declared_point_count > MapStore.DEFAULT_MAX_POINTS:
		return _failure("point count is outside the supported range")
	if _read_u64_be(package, 24) != package.size():
		return _failure("declared package size does not match file size")
	var body_size := _read_u32_be(package, 32)
	if body_size != package.size() - HEADER_SIZE:
		return _failure("declared package body size does not match file size")
	var body := package.slice(HEADER_SIZE)
	var declared_digest := package.slice(DIGEST_OFFSET, DIGEST_OFFSET + DIGEST_SIZE)
	if _sha256(body) != declared_digest:
		return _failure("map package SHA-256 validation failed")
	if manifest_size > body.size():
		return _failure("manifest extends beyond the package body")
	var manifest_result := _parse_manifest(body.slice(0, manifest_size))
	if not bool(manifest_result.get("ok", false)):
		return manifest_result
	var manifest := manifest_result.get("manifest", {}) as Dictionary
	if int(manifest.get("chunk_count", -1)) != chunk_count \
		or int(manifest.get("point_count", -1)) != declared_point_count:
		return _failure("manifest counts do not match the package header")
	var records := manifest.get("chunks", []) as Array
	if records.size() != chunk_count:
		return _failure("manifest chunk records do not match package chunk count")

	var store := MapStore.new()
	if not store.configure(MapStore.DEFAULT_MAX_POINTS):
		return _failure("could not initialize imported map store")
	var cursor := manifest_size
	for chunk_index in range(chunk_count):
		if cursor > body.size() - ENTRY_HEADER_SIZE:
			return _failure("map package ends inside a chunk entry header")
		var encoded_size := _read_u32_be(body, cursor)
		if encoded_size <= 0 or encoded_size > ChunkCodec.MAX_ENCODED_BYTES:
			return _failure("chunk entry size is outside the supported range")
		var entry_digest := body.slice(cursor + 4, cursor + ENTRY_HEADER_SIZE)
		cursor += ENTRY_HEADER_SIZE
		if encoded_size > body.size() - cursor:
			return _failure("map package ends inside a point chunk")
		var encoded := body.slice(cursor, cursor + encoded_size)
		cursor += encoded_size
		if _sha256(encoded) != entry_digest:
			return _failure("chunk entry SHA-256 validation failed")
		var record = records[chunk_index]
		if not record is Dictionary:
			return _failure("manifest chunk record must be an object")
		var record_dictionary := record as Dictionary
		if int(record_dictionary.get("index", -1)) != chunk_index \
			or int(record_dictionary.get("byte_length", -1)) != encoded_size \
			or str(record_dictionary.get("sha256", "")) != entry_digest.hex_encode():
			return _failure("manifest chunk record does not match package entry")
		var decoded_result := ChunkCodec.decode(encoded)
		if not bool(decoded_result.get("ok", false)):
			return _failure("invalid point chunk %d: %s" % [
				chunk_index,
				str(decoded_result.get("error", "unknown error")),
			])
		var chunk = decoded_result.get("chunk")
		if str(record_dictionary.get("chunk_id", "")) != chunk.chunk_id \
			or int(record_dictionary.get("point_count", -1)) != chunk.point_count():
			return _failure("manifest chunk identity does not match decoded chunk")
		var append_result := store.append_chunk(chunk)
		if append_result != MapStore.AppendResult.APPENDED:
			return _failure("decoded chunk could not be appended: %s" % store.get_last_error())
	if cursor != body.size():
		return _failure("map package contains trailing bytes")
	if store.get_point_count() != declared_point_count:
		return _failure("decoded map point count does not match manifest")
	if store.session_id != str(manifest.get("session_id", "")) \
		or store.map_id != str(manifest.get("map_id", "")):
		return _failure("decoded map identity does not match manifest")
	return {
		"ok": true,
		"path": path,
		"store": store,
		"manifest": manifest,
		"error": "",
	}


static func _read_manifest_header(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < HEADER_SIZE:
		return _failure("map package cannot be read")
	var header := file.get_buffer(HEADER_SIZE)
	if header.size() != HEADER_SIZE:
		file.close()
		return _failure("map package header is incomplete")
	if not _has_magic(header):
		file.close()
		return _failure("invalid map package magic")
	var manifest_size := _read_u32_be(header, 12)
	if manifest_size <= 0 or manifest_size > MAX_MANIFEST_BYTES \
		or HEADER_SIZE + manifest_size > file.get_length():
		file.close()
		return _failure("invalid manifest size")
	var bytes := file.get_buffer(manifest_size)
	file.close()
	return _parse_manifest(bytes)


static func _parse_manifest(bytes: PackedByteArray) -> Dictionary:
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return _failure("manifest is not valid UTF-8")
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		return _failure("manifest JSON root must be an object")
	var manifest := parsed as Dictionary
	var validation_error := _validate_manifest(manifest)
	if not validation_error.is_empty():
		return _failure("invalid map manifest: %s" % validation_error)
	return {"ok": true, "manifest": manifest, "error": ""}


static func _validate_manifest(manifest: Dictionary) -> String:
	if str(manifest.get("format", "")) != FORMAT_NAME:
		return "unsupported format name"
	if int(manifest.get("format_version", -1)) != FORMAT_VERSION:
		return "unsupported format version"
	if str(manifest.get("package_encoding", "")) != "GSM1-manifest-plus-PCCH":
		return "unsupported package encoding"
	if int(manifest.get("point_chunk_codec_version", -1)) != ChunkCodec.VERSION:
		return "unsupported point chunk codec version"
	if not manifest.get("display_name") is String \
		or str(manifest.get("display_name", "")).is_empty() \
		or str(manifest.get("display_name", "")).to_utf8_buffer().size() > 320:
		return "display_name must be a non-empty bounded string"
	if str(manifest.get("coordinate_space", "")) != ChunkCodec.COORDINATE_SPACE:
		return "unsupported coordinate space"
	if str(manifest.get("position_unit", "")) != ChunkCodec.POSITION_UNIT:
		return "unsupported position unit"
	if bool(manifest.get("contains_raw_video", true)):
		return "map packages must not contain raw video"
	for timestamp_field in ["created_at_unix_sec", "exported_at_unix_sec"]:
		if not _is_json_integer(manifest.get(timestamp_field)) \
			or int(manifest.get(timestamp_field)) < 0:
			return "%s must be a non-negative integer" % timestamp_field
	var point_count := int(manifest.get("point_count", -1))
	var chunk_count := int(manifest.get("chunk_count", -1))
	if point_count <= 0 or point_count > MapStore.DEFAULT_MAX_POINTS:
		return "point count is outside the supported range"
	if chunk_count <= 0 or chunk_count > point_count:
		return "chunk count is outside the supported range"
	if not manifest.get("chunks") is Array \
		or (manifest.get("chunks") as Array).size() != chunk_count:
		return "chunk records do not match chunk count"
	var chunk_records := manifest.get("chunks") as Array
	var recorded_point_count := 0
	for chunk_index in range(chunk_records.size()):
		if not chunk_records[chunk_index] is Dictionary:
			return "chunk record %d must be an object" % chunk_index
		var record := chunk_records[chunk_index] as Dictionary
		if not _is_json_integer(record.get("index")) \
			or int(record.get("index")) != chunk_index:
			return "chunk record index is invalid"
		if not _is_json_integer(record.get("point_count")) \
			or int(record.get("point_count")) <= 0:
			return "chunk record point_count is invalid"
		if not _is_json_integer(record.get("byte_length")) \
			or int(record.get("byte_length")) < ChunkCodec.HEADER_SIZE \
			or int(record.get("byte_length")) > ChunkCodec.MAX_ENCODED_BYTES:
			return "chunk record byte_length is invalid"
		if not _is_sha256_hex(str(record.get("sha256", ""))):
			return "chunk record SHA-256 is invalid"
		var record_id_probe := Chunk.new()
		record_id_probe.session_id = "manifest-session"
		record_id_probe.map_id = "manifest-map"
		record_id_probe.chunk_id = str(record.get("chunk_id", ""))
		var record_id_error := record_id_probe.validate_ids()
		if not record_id_error.is_empty():
			return "chunk record %s" % record_id_error
		recorded_point_count += int(record.get("point_count"))
	if recorded_point_count != point_count:
		return "chunk record point counts do not match map point count"
	if not manifest.get("bounds") is Dictionary:
		return "bounds must be an object"
	var bounds_error := _validate_bounds(manifest.get("bounds") as Dictionary)
	if not bounds_error.is_empty():
		return bounds_error
	var voxel_size := float(manifest.get("voxel_size_m", -1.0))
	if not is_finite(voxel_size) or voxel_size <= 0.0 or voxel_size > 1.0:
		return "voxel_size_m must be within (0, 1]"
	if not manifest.get("model") is Dictionary:
		return "model must be an object"
	var model := manifest.get("model") as Dictionary
	for model_field in ["name", "version"]:
		if not model.get(model_field) is String \
			or str(model.get(model_field, "")).is_empty() \
			or str(model.get(model_field, "")).to_utf8_buffer().size() > 256:
			return "model %s must be a non-empty bounded string" % model_field
	var id_probe := Chunk.new()
	id_probe.session_id = str(manifest.get("session_id", ""))
	id_probe.map_id = str(manifest.get("map_id", ""))
	id_probe.chunk_id = "manifest-validation"
	var id_error := id_probe.validate_ids()
	if not id_error.is_empty():
		return id_error
	var registration_result := _normalize_registration(manifest.get("registration", {}))
	if not bool(registration_result.get("ok", false)):
		return str(registration_result.get("error", "invalid registration"))
	return ""


static func _normalize_registration(value: Variant) -> Dictionary:
	var registration := value as Dictionary if value is Dictionary else {}
	if registration.is_empty():
		registration = {
			"schema_version": 1,
			"automatic_sim3": _identity_sim3(),
			"manual_adjustment": _identity_sim3(),
			"confirmed": false,
		}
	if int(registration.get("schema_version", -1)) != 1:
		return _failure("registration schema_version must be 1")
	for field_name in ["automatic_sim3", "manual_adjustment"]:
		if not registration.get(field_name) is Dictionary:
			return _failure("registration %s must be an object" % field_name)
		var transform_error := _validate_sim3(registration.get(field_name) as Dictionary)
		if not transform_error.is_empty():
			return _failure("registration %s: %s" % [field_name, transform_error])
	if not registration.get("confirmed") is bool:
		return _failure("registration confirmed must be boolean")
	return {
		"ok": true,
		"registration": registration.duplicate(true),
		"error": "",
	}


static func _identity_sim3() -> Dictionary:
	return {
		"scale": 1.0,
		"rotation_wxyz": [1.0, 0.0, 0.0, 0.0],
		"translation_xyz": [0.0, 0.0, 0.0],
	}


static func _validate_sim3(value: Dictionary) -> String:
	var scale := float(value.get("scale", -1.0))
	if not is_finite(scale) or scale <= 0.0 or scale > 1000.0:
		return "scale must be finite and within (0, 1000]"
	if not value.get("rotation_wxyz") is Array \
		or not value.get("translation_xyz") is Array:
		return "rotation_wxyz and translation_xyz must be arrays"
	var rotation := value.get("rotation_wxyz") as Array
	var translation := value.get("translation_xyz") as Array
	if rotation.size() != 4 or translation.size() != 3:
		return "rotation must have 4 values and translation must have 3"
	var length_squared := 0.0
	for item in rotation:
		if not _is_finite_number(item):
			return "rotation values must be finite numbers"
		length_squared += float(item) * float(item)
	if absf(length_squared - 1.0) > 0.001:
		return "rotation quaternion must be normalized"
	for item in translation:
		if not _is_finite_number(item):
			return "translation values must be finite numbers"
	return ""


static func _validate_bounds(bounds: Dictionary) -> String:
	if not bounds.get("minimum") is Array or not bounds.get("maximum") is Array:
		return "bounds minimum and maximum must be arrays"
	var minimum := bounds.get("minimum") as Array
	var maximum := bounds.get("maximum") as Array
	if minimum.size() != 3 or maximum.size() != 3:
		return "bounds vectors must contain 3 values"
	for index in range(3):
		if not _is_finite_number(minimum[index]) \
			or not _is_finite_number(maximum[index]):
			return "bounds values must be finite numbers"
		if float(maximum[index]) < float(minimum[index]):
			return "bounds maximum must not be smaller than minimum"
	return ""


static func _aabb_to_dictionary(bounds: AABB) -> Dictionary:
	var maximum := bounds.position + bounds.size
	return {
		"minimum": [bounds.position.x, bounds.position.y, bounds.position.z],
		"maximum": [maximum.x, maximum.y, maximum.z],
	}


static func _is_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _is_json_integer(value: Variant) -> bool:
	if not _is_finite_number(value):
		return false
	var number := float(value)
	return number == floor(number)


static func _is_sha256_hex(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if not character in "0123456789abcdef":
			return false
	return true


static func _ensure_library_directory() -> Error:
	return DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(LIBRARY_DIR)
	)


static func _resolve_library_file(file_name: String) -> Dictionary:
	if file_name.is_empty() or file_name.get_file() != file_name:
		return _failure("map file name must not contain a path")
	if file_name.contains("/") or file_name.contains("\\") \
		or not file_name.to_lower().ends_with(".gsmap"):
		return _failure("map file name must be a .gsmap library entry")
	return {
		"ok": true,
		"path": LIBRARY_DIR.path_join(file_name),
		"error": "",
	}


static func _clean_display_name(value: String) -> String:
	var clean := value.strip_edges()
	return clean.left(80) if not clean.is_empty() else "实时重建"


static func _sanitize_file_stem(value: String) -> String:
	var clean := _clean_display_name(value)
	for invalid_character in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]:
		clean = clean.replace(invalid_character, "_")
	var output := ""
	for character_index in range(clean.length()):
		var codepoint := clean.unicode_at(character_index)
		output += "_" if codepoint < 32 or codepoint == 127 else clean[character_index]
	clean = output.strip_edges().trim_suffix(".")
	if clean.is_empty() or clean == "." or clean == "..":
		clean = "reconstruction_map"
	return clean.left(64)


static func _unique_file_name(stem: String) -> String:
	var candidate := "%s.gsmap" % stem
	var suffix := 2
	while FileAccess.file_exists(LIBRARY_DIR.path_join(candidate)):
		candidate = "%s_%d.gsmap" % [stem, suffix]
		suffix += 1
	return candidate


static func _write_u16_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 8) & 0xff
	bytes[offset + 1] = value & 0xff


static func _has_magic(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 4 \
		and bytes[0] == 0x47 \
		and bytes[1] == 0x53 \
		and bytes[2] == 0x4d \
		and bytes[3] == 0x31


static func _write_u32_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 24) & 0xff
	bytes[offset + 1] = (value >> 16) & 0xff
	bytes[offset + 2] = (value >> 8) & 0xff
	bytes[offset + 3] = value & 0xff


static func _write_u64_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	for index in range(8):
		bytes[offset + index] = (value >> (56 - index * 8)) & 0xff


static func _read_u16_be(bytes: PackedByteArray, offset: int) -> int:
	return (int(bytes[offset]) << 8) | int(bytes[offset + 1])


static func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(int(bytes[offset]) << 24)
		| (int(bytes[offset + 1]) << 16)
		| (int(bytes[offset + 2]) << 8)
		| int(bytes[offset + 3])
	)


static func _read_u64_be(bytes: PackedByteArray, offset: int) -> int:
	var result := 0
	for index in range(8):
		result = (result << 8) | int(bytes[offset + index])
	return result


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return PackedByteArray()
	if context.update(bytes) != OK:
		return PackedByteArray()
	return context.finish()


static func _failure(message: String) -> Dictionary:
	return {
		"ok": false,
		"error": message,
	}
