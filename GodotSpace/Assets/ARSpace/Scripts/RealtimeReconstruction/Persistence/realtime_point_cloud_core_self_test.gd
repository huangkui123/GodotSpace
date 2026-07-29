extends SceneTree

const Chunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)
const ChunkCodec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)
const MapStore := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_map_store.gd"
)
const Renderer := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_renderer.gd"
)
const GsmapStore := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Persistence/gsmap_store.gd"
)

var _failures: Array[String] = []
var _created_files: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var primary_chunk := _make_chunk("chunk-0001", 0.0, true)
	_test_chunk_codec(primary_chunk)
	var store := _test_map_store(primary_chunk)
	_test_renderer(store)
	_test_persistence(store)
	_cleanup_files()
	await process_frame
	if _failures.is_empty():
		print("REALTIME_POINT_CLOUD_CORE_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("REALTIME_POINT_CLOUD_CORE_SELF_TEST: %s" % failure)
	quit(1)


func _test_chunk_codec(chunk: ReconstructionPointCloudChunk) -> void:
	var encoded_result := ChunkCodec.encode(chunk)
	_expect(bool(encoded_result.get("ok", false)), "valid point chunk must encode")
	if not bool(encoded_result.get("ok", false)):
		return
	var encoded := encoded_result.get("data", PackedByteArray()) as PackedByteArray
	_expect(
		encoded.size() >= ChunkCodec.HEADER_SIZE \
			and encoded.slice(0, 4).get_string_from_ascii() == "PCCH",
		"encoded chunk must use PCCH magic"
	)
	_expect(
		encoded[4] == 0 and encoded[5] == ChunkCodec.VERSION,
		"PCCH version must be stored in big-endian order"
	)
	_expect(
		encoded[8] == 0 \
			and encoded[9] == 0 \
			and encoded[10] == 0 \
			and encoded[11] == (
				ChunkCodec.FLAG_HAS_CONFIDENCE_U8 | ChunkCodec.FLAG_HAS_CAMERA_POSE
			),
		"PCCH flags must be stored in big-endian order"
	)
	_expect(
		encoded[12] == 0 \
			and encoded[13] == 0 \
			and encoded[14] == 0 \
			and encoded[15] == chunk.point_count(),
		"PCCH point count must be stored in big-endian order"
	)
	var metadata_size := (
		(int(encoded[16]) << 24)
		| (int(encoded[17]) << 16)
		| (int(encoded[18]) << 8)
		| int(encoded[19])
	)
	var point_data_offset := ChunkCodec.HEADER_SIZE + metadata_size
	var second_point_offset := point_data_offset + 16
	_expect(
		encoded[second_point_offset] == 0x3e \
			and encoded[second_point_offset + 1] == 0x80 \
			and encoded[second_point_offset + 2] == 0x00 \
			and encoded[second_point_offset + 3] == 0x00,
		"PCCH float32 point values must use network byte order"
	)
	var metadata_text := encoded.slice(
		ChunkCodec.HEADER_SIZE,
		point_data_offset
	).get_string_from_utf8()
	_expect(
		metadata_text.contains("\"convention\":\"camera_to_lingbot_world\""),
		"PCCH metadata must state the camera pose direction"
	)
	var decoded_result := ChunkCodec.decode(encoded)
	_expect(bool(decoded_result.get("ok", false)), "encoded point chunk must decode")
	if bool(decoded_result.get("ok", false)):
		var decoded := decoded_result.get("chunk") as ReconstructionPointCloudChunk
		_expect(decoded.session_id == chunk.session_id, "session ID must round-trip")
		_expect(decoded.map_id == chunk.map_id, "map ID must round-trip")
		_expect(decoded.chunk_id == chunk.chunk_id, "chunk ID must round-trip")
		_expect(decoded.positions == chunk.positions, "point positions must round-trip")
		_expect(decoded.colors_rgb8 == chunk.colors_rgb8, "RGB values must round-trip")
		_expect(
			decoded.confidence_u8 == chunk.confidence_u8,
			"u8 confidence values must round-trip"
		)
		_expect(
			decoded.metadata_extensions == chunk.metadata_extensions,
			"bounded metadata extensions must round-trip"
		)
		_expect(decoded.has_camera_pose, "camera pose flag must round-trip")
		_expect(
			decoded.camera_to_lingbot_world.origin.is_equal_approx(
				chunk.camera_to_lingbot_world.origin
			),
			"camera pose translation must round-trip"
		)
		_expect(
			decoded.camera_to_lingbot_world.basis.is_equal_approx(
				chunk.camera_to_lingbot_world.basis
			),
			"camera pose rotation must round-trip"
		)

	var corrupted := encoded.duplicate()
	corrupted[corrupted.size() - 1] ^= 0x01
	_expect(
		not bool(ChunkCodec.decode(corrupted).get("ok", false)),
		"payload corruption must fail SHA-256 validation"
	)
	var truncated := encoded.slice(0, encoded.size() - 1)
	_expect(
		not bool(ChunkCodec.decode(truncated).get("ok", false)),
		"truncated chunks must be rejected"
	)
	var unknown_flags := encoded.duplicate()
	unknown_flags[11] |= 0x80
	_expect(
		not bool(ChunkCodec.decode(unknown_flags).get("ok", false)),
		"unknown PCCH flags must be rejected"
	)
	var invalid_chunk := chunk.duplicate_deep()
	invalid_chunk.colors_rgb8.resize(1)
	_expect(
		not bool(ChunkCodec.encode(invalid_chunk).get("ok", false)),
		"invalid RGB cardinality must be rejected before encoding"
	)
	var minimal_chunk := _make_single_point_chunk("minimal", 0.25)
	var minimal_result := ChunkCodec.encode(minimal_chunk)
	_expect(bool(minimal_result.get("ok", false)), "chunk without optional fields must encode")
	if bool(minimal_result.get("ok", false)):
		var minimal_data := minimal_result.get("data", PackedByteArray()) as PackedByteArray
		_expect(
			minimal_data[8] == 0 \
				and minimal_data[9] == 0 \
				and minimal_data[10] == 0 \
				and minimal_data[11] == 0,
			"absent confidence and camera pose must clear both flags"
		)
		_expect(
			bool(ChunkCodec.decode(minimal_data).get("ok", false)),
			"minimal point chunk must decode"
		)


func _test_map_store(
	primary_chunk: ReconstructionPointCloudChunk
) -> ReconstructionPointCloudMapStore:
	var store := MapStore.new()
	_expect(store.configure(4), "map store must accept a bounded capacity")
	_expect(
		store.append_chunk(primary_chunk) == MapStore.AppendResult.APPENDED,
		"first point chunk must append"
	)
	primary_chunk.positions[0] = Vector3(99.0, 99.0, 99.0)
	var stored_primary := store.get_chunk(primary_chunk.chunk_id)
	_expect(
		stored_primary != null and stored_primary.positions[0] != primary_chunk.positions[0],
		"map store must own an immutable deep copy"
	)
	var original_again := _make_chunk("chunk-0001", 0.0, true)
	_expect(
		store.append_chunk(original_again) == MapStore.AppendResult.DUPLICATE,
		"identical duplicate chunk must be idempotent"
	)
	var conflict := original_again.duplicate_deep()
	conflict.colors_rgb8[0] = 1
	_expect(
		store.append_chunk(conflict) == MapStore.AppendResult.CHUNK_CONFLICT,
		"same chunk ID with different payload must be a conflict"
	)
	var final_chunk := _make_single_point_chunk("chunk-0002", 3.0)
	_expect(
		store.append_chunk(final_chunk) == MapStore.AppendResult.APPENDED,
		"chunk within remaining capacity must append"
	)
	_expect(
		store.get_point_count() == 4 and store.get_chunk_count() == 2,
		"store counts must include appended chunks only"
	)
	var over_capacity := _make_single_point_chunk("chunk-0003", 4.0)
	_expect(
		store.append_chunk(over_capacity) == MapStore.AppendResult.CAPACITY_EXCEEDED,
		"store must reject chunks beyond configured capacity"
	)
	var wrong_session := _make_single_point_chunk("chunk-0004", 4.0)
	wrong_session.session_id = "another-session"
	_expect(
		store.append_chunk(wrong_session) == MapStore.AppendResult.SESSION_MISMATCH,
		"store must reject a different session"
	)
	var wrong_map := _make_single_point_chunk("chunk-0005", 4.0)
	wrong_map.map_id = "another-map"
	_expect(
		store.append_chunk(wrong_map) == MapStore.AppendResult.MAP_MISMATCH,
		"store must reject a different map"
	)
	_expect(store.has_bounds(), "non-empty map store must expose bounds")
	return store


func _test_renderer(store: ReconstructionPointCloudMapStore) -> void:
	var renderer := Renderer.new()
	renderer.max_points_per_batch = 2
	root.add_child(renderer)
	var point_material := Renderer.make_point_material(4.0)
	_expect(
		point_material is ShaderMaterial and point_material.shader != null,
		"renderer must use an explicit XR-safe point shader"
	)
	if point_material is ShaderMaterial and point_material.shader != null:
		_expect(
			point_material.shader.code.contains("ALBEDO = COLOR.rgb") \
				and point_material.shader.code.contains(
					"ALPHA = arspace_opacity"
				),
			"point shader must preserve RGB vertex colors with adjustable alpha"
		)
		_expect(
			is_equal_approx(
				float(point_material.get_shader_parameter("point_size")),
				4.0
			),
			"point shader must receive the requested point size"
		)
	_expect(renderer.rebuild_from_store(store), "renderer must rebuild from map store")
	_expect(
		renderer.get_rendered_point_count() == 4,
		"renderer must account for every accepted point"
	)
	_expect(
		renderer.get_mesh_batch_count() == 2,
		"renderer must split points into collision-free bounded batches"
	)
	for mesh in renderer.get_meshes_for_test():
		_expect(mesh.get_surface_count() == 1, "each point batch must have one mesh surface")
		if mesh.get_surface_count() == 1:
			_expect(
				mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_POINTS,
				"point batches must use PRIMITIVE_POINTS"
			)
	var duplicate := store.get_chunk("chunk-0001")
	_expect(
		not renderer.append_chunk(duplicate),
		"renderer must ignore an already rendered chunk key"
	)
	_expect(
		renderer.get_rendered_point_count() == 4,
		"renderer duplicate handling must not change point count"
	)
	renderer.clear_rendered()
	_expect(
		renderer.get_mesh_batch_count() == 0 \
			and renderer.get_rendered_point_count() == 0,
		"renderer clear must remove all local batches"
	)
	renderer.queue_free()


func _test_persistence(store: ReconstructionPointCloudMapStore) -> void:
	var display_name := "core_self_test_%d" % Time.get_ticks_usec()
	var export_result := GsmapStore.export_map(store, display_name, {
		"voxel_size_m": 0.025,
		"model_name": "self-test-model",
		"model_version": "1",
	})
	_expect(bool(export_result.get("ok", false)), "valid map must export to .gsmap")
	if not bool(export_result.get("ok", false)):
		return
	var file_name := str(export_result.get("file_name", ""))
	var path := str(export_result.get("path", ""))
	_created_files.append(path)
	_expect(path.begins_with(GsmapStore.LIBRARY_DIR), "exports must stay in map library")
	_expect(file_name.ends_with(".gsmap"), "export must use .gsmap extension")
	var manifest := export_result.get("manifest", {}) as Dictionary
	_expect(
		not bool(manifest.get("contains_raw_video", true)),
		"map manifest must explicitly exclude raw video"
	)
	_expect(
		int(manifest.get("point_count", -1)) == store.get_point_count(),
		"export manifest must record point count"
	)
	var import_result := GsmapStore.import_map(file_name)
	_expect(bool(import_result.get("ok", false)), "exported map must import")
	if bool(import_result.get("ok", false)):
		var imported := import_result.get("store") as ReconstructionPointCloudMapStore
		_expect(
			imported.get_point_count() == store.get_point_count(),
			"imported point count must match exported map"
		)
		_expect(
			imported.get_chunk_ids() == store.get_chunk_ids(),
			"imported append order must match exported map"
		)
		for chunk_id in store.get_chunk_ids():
			_expect(
				imported.get_chunk(chunk_id).payload_equals(store.get_chunk(chunk_id)),
				"imported chunk %s must match exported payload" % chunk_id
			)
	var library_entries := GsmapStore.list_maps()
	var found_export := false
	for entry in library_entries:
		if str(entry.get("file_name", "")) == file_name:
			found_export = true
			break
	_expect(found_export, "map library listing must include the new export")
	_expect(
		not bool(GsmapStore.import_map("../outside.gsmap").get("ok", false)),
		"map import must reject path traversal"
	)

	var original_bytes := FileAccess.get_file_as_bytes(path)
	if not original_bytes.is_empty():
		var corrupted := original_bytes.duplicate()
		corrupted[corrupted.size() - 1] ^= 0x01
		var corrupt_name := "corrupt_%d.gsmap" % Time.get_ticks_usec()
		var corrupt_path := GsmapStore.LIBRARY_DIR.path_join(corrupt_name)
		var corrupt_file := FileAccess.open(corrupt_path, FileAccess.WRITE)
		if corrupt_file != null:
			corrupt_file.store_buffer(corrupted)
			corrupt_file.close()
			_created_files.append(corrupt_path)
			_expect(
				not bool(GsmapStore.import_map(corrupt_name).get("ok", false)),
				"tampered .gsmap package must fail integrity validation"
			)


func _make_chunk(
	chunk_id: String,
	x_offset: float,
	include_confidence: bool
) -> ReconstructionPointCloudChunk:
	var positions := PackedVector3Array([
		Vector3(x_offset, 0.0, 0.0),
		Vector3(x_offset + 0.25, 0.5, -0.25),
		Vector3(x_offset + 0.5, 1.0, -0.5),
	])
	var colors := PackedByteArray([
		255, 0, 0,
		0, 255, 0,
		0, 0, 255,
	])
	var confidence := PackedByteArray([255, 192, 128]) \
		if include_confidence \
		else PackedByteArray()
	var camera_pose := Transform3D(
		Basis(Quaternion(Vector3.UP, 0.25)),
		Vector3(1.0, 2.0, 3.0)
	)
	var chunk := Chunk.create(
		"session-self-test",
		"map-self-test",
		chunk_id,
		positions,
		colors,
		confidence,
		123456789,
		42,
		true,
		camera_pose
	)
	chunk.metadata_extensions = {
		"confidence_source_max": 10.0,
		"confidence_filter_threshold": 2.5,
	}
	return chunk


func _make_single_point_chunk(
	chunk_id: String,
	x_position: float
) -> ReconstructionPointCloudChunk:
	return Chunk.create(
		"session-self-test",
		"map-self-test",
		chunk_id,
		PackedVector3Array([Vector3(x_position, 0.0, 0.0)]),
		PackedByteArray([120, 130, 140]),
		PackedByteArray(),
		123456790,
		43
	)


func _cleanup_files() -> void:
	for path in _created_files:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
