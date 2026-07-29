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
const Runtime := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/reconstruction_point_cloud_runtime.gd"
)
var _failures: Array[String] = []
var _accepted_count: int = 0
var _stats_count: int = 0
var _error_count: int = 0
var _created_files: PackedStringArray = PackedStringArray()


class MockServerChannel extends Node:
	var published_packets: Array[PackedByteArray] = []
	var clear_count: int = 0
	var begin_count: int = 0
	var session_id: String = ""
	var map_id: String = ""

	func publish_packet(packet: PackedByteArray) -> Error:
		published_packets.append(packet.duplicate())
		return OK

	func clear_map_cache() -> void:
		clear_count += 1
		published_packets.clear()
		session_id = ""
		map_id = ""

	func begin_map(p_session_id: String, p_map_id: String) -> Error:
		begin_count += 1
		session_id = p_session_id
		map_id = p_map_id
		return OK


class MockClientChannel extends Node:
	signal packet_received(packet: PackedByteArray)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var workspace_text := FileAccess.get_file_as_string(
		"res://Assets/ARSpace/Scenes/RealtimeReconstruction/RealtimeReconstructionWorkspace.tscn"
	)
	var point_node_marker := (
		"[node name=\"PointCloudChunks\" type=\"Node3D\" parent=\"ReconstructionRoot\""
	)
	var point_node_offset := workspace_text.find(point_node_marker)
	var runtime_script_offset := workspace_text.find(
		"script = ExtResource(\"3_point_cloud_runtime\")",
		maxi(point_node_offset, 0)
	)
	_expect(
		workspace_text.contains(
			"path=\"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/reconstruction_point_cloud_runtime.gd\""
		) \
			and point_node_offset >= 0 \
			and runtime_script_offset > point_node_offset \
			and runtime_script_offset < point_node_offset + 256,
		"workspace PointCloudChunks must carry the point-cloud runtime"
	)

	var server := MockServerChannel.new()
	server.name = "ReconstructionDataChannel"
	root.add_child(server)
	server.add_to_group(Runtime.DATA_CHANNEL_GROUP)
	var runtime = Runtime.new()
	runtime.name = "PointCloudChunks"
	runtime.chunk_accepted.connect(_on_chunk_accepted)
	runtime.stats_changed.connect(_on_stats_changed)
	runtime.error_occurred.connect(_on_error)
	root.add_child(runtime)
	await process_frame
	await process_frame
	_expect(
		str(runtime.get_stats_snapshot().get("data_channel_role", "")) == "server",
		"runtime must auto-bind a grouped server data channel"
	)

	var first_chunk := _make_chunk("chunk-0001", 0.0)
	var first_packet := _encode(first_chunk)
	_expect(not first_packet.is_empty(), "self-test point chunk must encode")
	_expect(
		runtime.ingest_packet(first_packet, true) == OK,
		"server runtime must ingest a valid PCCH packet"
	)
	_expect(
		runtime.get_current_store().get_point_count() == first_chunk.point_count(),
		"runtime must append accepted points to its current store"
	)
	_expect(
		runtime.get_rendered_point_count() == first_chunk.point_count(),
		"runtime must render accepted points on the main thread"
	)
	_expect(
		server.published_packets.size() == 1,
		"server runtime must publish a newly accepted packet"
	)
	_expect(_accepted_count == 1, "new chunk must emit chunk_accepted once")
	_expect(
		runtime.ingest_packet(first_packet, true) == OK \
			and runtime.get_current_store().get_chunk_count() == 1,
		"duplicate packet must remain idempotent locally"
	)
	_expect(
		server.published_packets.size() == 2,
		"explicit server retry may republish an idempotent packet"
	)
	var overlap_packet := _encode(_make_chunk("chunk-overlap", 0.001))
	_expect(
		runtime.ingest_packet(overlap_packet, true) == OK \
			and runtime.get_current_store().get_point_count() == first_chunk.point_count() \
			and server.published_packets.size() == 2,
		"2.5 cm voxel filtering must not append or publish already occupied cells"
	)
	_expect(
		runtime.ingest_packet(PackedByteArray([1, 2, 3]), true) == ERR_INVALID_DATA,
		"invalid packet must be rejected"
	)
	_expect(_error_count >= 1, "invalid packet must emit error_occurred")
	_expect(_stats_count > 0, "runtime changes must emit stats_changed")

	var replacement := MapStore.new()
	var replacement_chunk := _make_chunk("replacement-0001", 10.0)
	_expect(
		replacement.append_chunk(replacement_chunk) == MapStore.AppendResult.APPENDED,
		"replacement source store must accept its chunk"
	)
	var registration := {
		"schema_version": 1,
		"automatic_sim3": _identity_sim3(),
		"manual_adjustment": {
			"scale": 1.02,
			"rotation_wxyz": [1.0, 0.0, 0.0, 0.0],
			"translation_xyz": [0.01, 0.02, 0.03],
		},
		"confirmed": true,
	}
	_expect(
		runtime.replace_store(
			replacement,
			{"registration": registration},
			true
		) == OK,
		"runtime must replace, rebuild and publish an imported map"
	)
	_expect(
		runtime.get_current_store().get_chunk_ids() \
			== PackedStringArray(["replacement-0001"]),
		"replace_store must replace rather than append to the previous map"
	)
	_expect(
		runtime.get_registration_options() == registration,
		"registration manifest options must pass through unchanged"
	)
	_expect(
		server.begin_count == 1 \
			and server.session_id == replacement.session_id \
			and server.map_id == replacement.map_id \
			and server.published_packets.size() == 1,
		"server cache synchronization must begin and publish the replacement map"
	)

	var display_name := "runtime_self_test_%d" % Time.get_ticks_usec()
	var export_result: Dictionary = runtime.export_current_map(display_name, {
		"model_name": "runtime-self-test",
		"model_version": "1",
	})
	_expect(bool(export_result.get("ok", false)), "runtime must export its current map")
	if bool(export_result.get("ok", false)):
		var exported_path := str(export_result.get("path", ""))
		var exported_name := str(export_result.get("file_name", ""))
		_created_files.append(exported_path)
		var exported_manifest := export_result.get("manifest", {}) as Dictionary
		_expect(
			exported_manifest.get("registration") == registration,
			"runtime export must inject current registration options"
		)
		runtime.clear_map(false)
		_expect(
			runtime.get_current_store().is_empty() \
				and runtime.get_rendered_point_count() == 0,
			"clear_map must clear both data and visuals"
		)
		var import_result: Dictionary = runtime.import_map(exported_name, false)
		_expect(bool(import_result.get("ok", false)), "runtime must import a library map")
		_expect(
			runtime.get_current_store().get_point_count() \
				== replacement.get_point_count(),
			"runtime import must replace the current store"
		)
		var imported_registration := runtime.get_registration_options()
		_expect(
			int(imported_registration.get("schema_version", -1)) == 1 \
				and bool(imported_registration.get("confirmed", false)) \
				and imported_registration.get("automatic_sim3") \
					== registration.get("automatic_sim3") \
				and imported_registration.get("manual_adjustment") \
					== registration.get("manual_adjustment"),
			"runtime import must restore registration options"
		)

	var client := MockClientChannel.new()
	client.name = "ClientDataChannel"
	root.add_child(client)
	runtime.clear_map(false)
	_expect(runtime.bind_data_channel(client), "runtime must bind a client data channel")
	var publish_count_before_client := server.published_packets.size()
	client.packet_received.emit(first_packet)
	_expect(
		runtime.get_current_store().get_chunk_count() == 1,
		"client packet_received must ingest the delivered point chunk"
	)
	_expect(
		server.published_packets.size() == publish_count_before_client,
		"client receive path must not publish a packet back to the server"
	)
	_expect(
		str(runtime.get_stats_snapshot().get("data_channel_role", "")) == "client",
		"runtime stats must report the bound client role"
	)

	runtime.queue_free()
	client.queue_free()
	server.queue_free()
	_cleanup_files()
	await process_frame
	if _failures.is_empty():
		print("RECONSTRUCTION_POINT_CLOUD_RUNTIME_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("RECONSTRUCTION_POINT_CLOUD_RUNTIME_SELF_TEST: %s" % failure)
	quit(1)


func _make_chunk(
	chunk_id: String,
	x_offset: float
) -> ReconstructionPointCloudChunk:
	var chunk := Chunk.create(
		"runtime-session",
		"runtime-map",
		chunk_id,
		PackedVector3Array([
			Vector3(x_offset, 0.0, 0.0),
			Vector3(x_offset + 0.25, 0.5, -0.25),
		]),
		PackedByteArray([
			255, 64, 32,
			32, 64, 255,
		]),
		PackedByteArray([255, 192]),
		123456789,
		7
	)
	chunk.metadata_extensions = {"confidence_filter_threshold": 2.5}
	return chunk


func _encode(chunk: ReconstructionPointCloudChunk) -> PackedByteArray:
	var result := ChunkCodec.encode(chunk)
	return result.get("data", PackedByteArray()) as PackedByteArray \
		if bool(result.get("ok", false)) \
		else PackedByteArray()


func _identity_sim3() -> Dictionary:
	return {
		"scale": 1.0,
		"rotation_wxyz": [1.0, 0.0, 0.0, 0.0],
		"translation_xyz": [0.0, 0.0, 0.0],
	}


func _cleanup_files() -> void:
	for path in _created_files:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _on_chunk_accepted(
	_chunk_id: String,
	_point_count: int,
	_total_points: int
) -> void:
	_accepted_count += 1


func _on_stats_changed(_snapshot: Dictionary) -> void:
	_stats_count += 1


func _on_error(_message: String) -> void:
	_error_count += 1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
