class_name ReconstructionPointCloudRuntime
extends "res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_renderer.gd"

signal stats_changed(snapshot: Dictionary)
signal error_occurred(message: String)
signal chunk_accepted(chunk_id: String, point_count: int, total_points: int)

const ChunkCodec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)
const PointMapStore := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_map_store.gd"
)
const GsmapStore := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Persistence/gsmap_store.gd"
)
const PointChunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)

const DATA_CHANNEL_GROUP: String = "reconstruction_data_channel"
const DATA_CHANNEL_FALLBACK_GROUP: String = "reconstruction_point_cloud_data_channel"
const DATA_CHANNEL_RETRY_MSEC: int = 1000

@export var auto_bind_data_channel: bool = true
@export var enable_voxel_filter: bool = true
@export_range(0.005, 0.1, 0.001) var voxel_size_model_units: float = 0.01

var _store: ReconstructionPointCloudMapStore = PointMapStore.new()
var _data_channel: Node
var _registration_options: Dictionary = {}
var _last_runtime_error: String = ""
var _next_channel_search_msec: int = 0
var _occupied_voxels: Dictionary = {}
var _source_chunk_digests: Dictionary = {}


func _ready() -> void:
	set_process(auto_bind_data_channel)
	if auto_bind_data_channel:
		call_deferred("_try_auto_bind_data_channel")
	_emit_stats()


func _exit_tree() -> void:
	_disconnect_data_channel()


func _process(_delta: float) -> void:
	if _data_channel != null and is_instance_valid(_data_channel):
		set_process(false)
		return
	if not auto_bind_data_channel:
		set_process(false)
		return
	var now := Time.get_ticks_msec()
	if now < _next_channel_search_msec:
		return
	_next_channel_search_msec = now + DATA_CHANNEL_RETRY_MSEC
	_try_auto_bind_data_channel()


func ingest_packet(
	packet: PackedByteArray,
	publish_if_server: bool = true
) -> Error:
	if not _is_main_thread_context():
		call_deferred(
			"_ingest_packet_on_main",
			packet.duplicate(),
			publish_if_server
		)
		return OK
	return _ingest_packet_on_main(packet, publish_if_server)


func clear_map(clear_published_cache: bool = true) -> void:
	if not _is_main_thread_context():
		call_deferred("clear_map", clear_published_cache)
		return
	_store.reset()
	_occupied_voxels.clear()
	_source_chunk_digests.clear()
	clear_rendered()
	_registration_options.clear()
	_last_runtime_error = ""
	if clear_published_cache and _is_server_channel():
		_data_channel.call("clear_map_cache")
	_emit_stats()


func replace_store(
	new_store: ReconstructionPointCloudMapStore,
	manifest_options: Dictionary = {},
	publish_if_server: bool = true
) -> Error:
	if not _is_main_thread_context():
		return ERR_BUSY
	if new_store == null:
		return _report_error("Cannot replace point cloud with a null store", ERR_INVALID_PARAMETER)
	var replacement := PointMapStore.new()
	if not replacement.configure(PointMapStore.DEFAULT_MAX_POINTS):
		return _report_error(
			"Could not initialize replacement point-cloud store",
			ERR_CANT_CREATE
		)
	for chunk in new_store.get_chunks():
		var append_result := replacement.append_chunk(chunk)
		if append_result != PointMapStore.AppendResult.APPENDED:
			return _report_error(
				"Replacement map contains an invalid chunk: %s" % replacement.get_last_error(),
				ERR_INVALID_DATA
			)

	var previous_store := _store
	_store = replacement
	_rebuild_voxel_index()
	_rebuild_source_chunk_digests()
	if not rebuild_from_store(_store):
		var render_error := get_last_error()
		_store = previous_store
		_rebuild_voxel_index()
		_rebuild_source_chunk_digests()
		rebuild_from_store(_store)
		return _report_error(
			"Could not rebuild replacement point cloud: %s" % render_error,
			ERR_CANT_CREATE
		)
	_registration_options = _extract_registration_options(manifest_options)
	_last_runtime_error = ""
	var publish_error := OK
	if publish_if_server and _is_server_channel():
		publish_error = _synchronize_server_cache()
	_emit_stats()
	return publish_error


func import_map(
	file_name: String,
	publish_if_server: bool = true
) -> Dictionary:
	if not _is_main_thread_context():
		return {
			"ok": false,
			"error": "Map import must run on the main thread",
		}
	var result := GsmapStore.import_map(file_name)
	if not bool(result.get("ok", false)):
		_report_error(
			"Could not import reconstruction map: %s" % str(result.get("error", "")),
			ERR_INVALID_DATA
		)
		return result
	var imported_store := result.get("store") as ReconstructionPointCloudMapStore
	var manifest := result.get("manifest", {}) as Dictionary
	var replace_error := replace_store(imported_store, manifest, publish_if_server)
	if replace_error != OK:
		return {
			"ok": false,
			"error": _last_runtime_error,
			"manifest": manifest,
		}
	return result


func export_current_map(
	display_name: String,
	options: Dictionary = {}
) -> Dictionary:
	var export_options := options.duplicate(true)
	if not export_options.has("registration") and not _registration_options.is_empty():
		export_options["registration"] = _registration_options.duplicate(true)
	var result := GsmapStore.export_map(_store, display_name, export_options)
	if not bool(result.get("ok", false)):
		_report_error(
			"Could not export reconstruction map: %s" % str(result.get("error", "")),
			ERR_CANT_CREATE
		)
	return result


func export_map(display_name: String, options: Dictionary = {}) -> Dictionary:
	return export_current_map(display_name, options)


func get_current_store() -> ReconstructionPointCloudMapStore:
	return _store


func get_registration_options() -> Dictionary:
	return _registration_options.duplicate(true)


func set_registration_options(options: Dictionary) -> void:
	_registration_options = _extract_registration_options(options)
	_emit_stats()


func publish_current_map() -> Error:
	if not _is_main_thread_context():
		return ERR_BUSY
	return _synchronize_server_cache()


func get_stats_snapshot() -> Dictionary:
	var channel_role := "none"
	if _is_server_channel():
		channel_role = "server"
	elif _is_client_channel():
		channel_role = "client"
	return {
		"session_id": _store.session_id,
		"map_id": _store.map_id,
		"chunk_count": _store.get_chunk_count(),
		"point_count": _store.get_point_count(),
		"rendered_point_count": get_rendered_point_count(),
		"mesh_batch_count": get_mesh_batch_count(),
		"data_channel_bound": _data_channel != null and is_instance_valid(_data_channel),
		"data_channel_role": channel_role,
		"registration": _registration_options.duplicate(true),
		"last_error": _last_runtime_error,
	}


func bind_data_channel(channel: Node) -> bool:
	if channel == null or not is_instance_valid(channel):
		_report_error("Cannot bind an invalid reconstruction data channel", ERR_INVALID_PARAMETER)
		return false
	if not channel.has_method("publish_packet") and not channel.has_signal("packet_received"):
		_report_error(
			"Reconstruction data channel has no publish or receive API",
			ERR_INVALID_PARAMETER
		)
		return false
	if _data_channel == channel:
		return true
	_disconnect_data_channel()
	_data_channel = channel
	var exit_callable := Callable(self, "_on_data_channel_tree_exited")
	if not _data_channel.is_connected("tree_exited", exit_callable):
		_data_channel.connect("tree_exited", exit_callable)
	if _is_client_channel():
		var receive_callable := Callable(self, "_on_data_channel_packet_received")
		if not _data_channel.is_connected("packet_received", receive_callable):
			_data_channel.connect("packet_received", receive_callable)
	set_process(false)
	_last_runtime_error = ""
	if _is_server_channel() and not _store.is_empty():
		var synchronize_error := _synchronize_server_cache()
		if synchronize_error != OK:
			return false
	_emit_stats()
	return true


func unbind_data_channel() -> void:
	_disconnect_data_channel()
	if auto_bind_data_channel:
		_next_channel_search_msec = 0
		set_process(true)
	_emit_stats()


func _ingest_packet_on_main(
	packet: PackedByteArray,
	publish_if_server: bool
) -> Error:
	var decode_result := ChunkCodec.decode(packet)
	if not bool(decode_result.get("ok", false)):
		return _report_error(
			"Rejected PCCH packet: %s" % str(decode_result.get("error", "")),
			ERR_INVALID_DATA
		)
	var chunk = decode_result.get("chunk")
	if chunk == null:
		return _report_error("PCCH decoder returned no chunk", ERR_INVALID_DATA)
	var source_digest := ChunkCodec.sha256_hex(packet)
	if _source_chunk_digests.has(chunk.chunk_id):
		if str(_source_chunk_digests[chunk.chunk_id]) != source_digest:
			return _report_error(
				"Rejected point chunk: source chunk_id conflicts with prior content",
				ERR_ALREADY_EXISTS
			)
		var prior_chunk := _store.get_chunk(chunk.chunk_id)
		if prior_chunk == null:
			return OK
		var prior_encode := ChunkCodec.encode(prior_chunk)
		if not bool(prior_encode.get("ok", false)):
			return _report_error(
				"Could not re-encode an idempotent point chunk",
				ERR_INVALID_DATA
			)
		return _publish_packet_if_server(
			prior_encode.get("data", PackedByteArray()) as PackedByteArray
		) if publish_if_server else OK
	var filter_result := _filter_novel_voxels(chunk)
	if not bool(filter_result.get("ok", false)):
		return _report_error(
			str(filter_result.get("error", "Could not filter point chunk")),
			ERR_INVALID_DATA
		)
	var filtered_chunk: ReconstructionPointCloudChunk = filter_result.get(
		"chunk"
	) as ReconstructionPointCloudChunk
	if filtered_chunk == null:
		# A valid frame may contribute no new spatial cells. Its camera pose is
		# consumed by the pipeline before this method, so dropping the empty
		# geometry does not weaken registration.
		_source_chunk_digests[chunk.chunk_id] = source_digest
		return OK
	var publish_packet := packet
	if filtered_chunk.point_count() != chunk.point_count():
		var encode_result := ChunkCodec.encode(filtered_chunk)
		if not bool(encode_result.get("ok", false)):
			return _report_error(
				"Could not encode voxel-filtered point chunk: %s" % str(
					encode_result.get("error", "")
				),
				ERR_INVALID_DATA
			)
		publish_packet = encode_result.get("data", PackedByteArray()) as PackedByteArray
	var append_result := _store.append_chunk(filtered_chunk)
	if append_result == PointMapStore.AppendResult.DUPLICATE:
		return _publish_packet_if_server(publish_packet) if publish_if_server else OK
	if append_result != PointMapStore.AppendResult.APPENDED:
		return _report_error(
			"Rejected point chunk: %s" % _store.get_last_error(),
			_append_result_to_error(append_result)
		)
	_commit_voxel_cells(filter_result.get("cells", []) as Array)
	_source_chunk_digests[chunk.chunk_id] = source_digest
	if not append_chunk(filtered_chunk):
		var renderer_error := get_last_error()
		rebuild_from_store(_store)
		return _report_error(
			"Point chunk was stored but could not be rendered: %s" % renderer_error,
			ERR_CANT_CREATE
		)

	_last_runtime_error = ""
	var publish_error := OK
	if publish_if_server:
		publish_error = _publish_packet_if_server(publish_packet)
	chunk_accepted.emit(
		filtered_chunk.chunk_id,
		filtered_chunk.point_count(),
		_store.get_point_count()
	)
	_emit_stats()
	return publish_error


func _filter_novel_voxels(chunk: ReconstructionPointCloudChunk) -> Dictionary:
	if not enable_voxel_filter or voxel_size_model_units <= 0.0:
		return {"ok": true, "chunk": chunk, "cells": []}
	var positions := PackedVector3Array()
	var colors := PackedByteArray()
	var confidence := PackedByteArray()
	var cells: Array[Vector3i] = []
	var cells_in_chunk: Dictionary = {}
	var has_confidence := chunk.has_confidence()
	for point_index in range(chunk.point_count()):
		var point := chunk.positions[point_index]
		var cell := Vector3i(
			floori(point.x / voxel_size_model_units),
			floori(point.y / voxel_size_model_units),
			floori(point.z / voxel_size_model_units)
		)
		if _occupied_voxels.has(cell) or cells_in_chunk.has(cell):
			continue
		cells_in_chunk[cell] = true
		cells.append(cell)
		positions.append(point)
		var color_offset := point_index * 3
		colors.append(chunk.colors_rgb8[color_offset])
		colors.append(chunk.colors_rgb8[color_offset + 1])
		colors.append(chunk.colors_rgb8[color_offset + 2])
		if has_confidence:
			confidence.append(chunk.confidence_u8[point_index])
	if positions.is_empty():
		return {"ok": true, "chunk": null, "cells": []}
	return {
		"ok": true,
		"chunk": PointChunk.create(
			chunk.session_id,
			chunk.map_id,
			chunk.chunk_id,
			positions,
			colors,
			confidence,
			chunk.timestamp_usec,
			chunk.source_frame_id,
			chunk.has_camera_pose,
			chunk.camera_to_lingbot_world,
			chunk.metadata_extensions,
		),
		"cells": cells,
	}


func _commit_voxel_cells(cells: Array) -> void:
	for cell in cells:
		_occupied_voxels[cell] = true


func _rebuild_voxel_index() -> void:
	_occupied_voxels.clear()
	if not enable_voxel_filter or voxel_size_model_units <= 0.0:
		return
	for chunk in _store.get_chunks():
		for point in chunk.positions:
			var cell := Vector3i(
				floori(point.x / voxel_size_model_units),
				floori(point.y / voxel_size_model_units),
				floori(point.z / voxel_size_model_units)
			)
			_occupied_voxels[cell] = true


func _rebuild_source_chunk_digests() -> void:
	_source_chunk_digests.clear()
	for chunk in _store.get_chunks():
		var encoded := ChunkCodec.encode(chunk)
		if bool(encoded.get("ok", false)):
			_source_chunk_digests[chunk.chunk_id] = ChunkCodec.sha256_hex(
				encoded.get("data", PackedByteArray()) as PackedByteArray
			)


func _on_data_channel_packet_received(packet: PackedByteArray) -> void:
	# Client delivery is never republished. This is the loop-prevention boundary.
	ingest_packet(packet, false)


func _on_data_channel_tree_exited() -> void:
	_data_channel = null
	if auto_bind_data_channel:
		_next_channel_search_msec = 0
		set_process(true)
	_emit_stats()


func _try_auto_bind_data_channel() -> void:
	if _data_channel != null and is_instance_valid(_data_channel):
		set_process(false)
		return
	var candidate := _find_data_channel()
	if candidate != null:
		bind_data_channel(candidate)


func _find_data_channel() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	for group_name in [DATA_CHANNEL_GROUP, DATA_CHANNEL_FALLBACK_GROUP]:
		var grouped := tree.get_first_node_in_group(group_name)
		if _is_compatible_channel(grouped):
			return grouped
	for absolute_path in [
		"/root/ReconstructionDataChannel",
		"/root/reconstruction_data_channel",
		"/root/PointCloudDataChannel",
	]:
		var autoload_candidate := tree.root.get_node_or_null(absolute_path)
		if _is_compatible_channel(autoload_candidate):
			return autoload_candidate
	for node_name in [
		"ReconstructionDataChannel",
		"reconstruction_data_channel",
		"PointCloudDataChannel",
	]:
		var named_candidate := tree.root.find_child(node_name, true, false)
		if _is_compatible_channel(named_candidate):
			return named_candidate
	return null


func _is_compatible_channel(candidate: Node) -> bool:
	return candidate != null \
		and candidate != self \
		and is_instance_valid(candidate) \
		and (
			candidate.has_method("publish_packet")
			or candidate.has_signal("packet_received")
		)


func _disconnect_data_channel() -> void:
	if _data_channel != null and is_instance_valid(_data_channel):
		var receive_callable := Callable(self, "_on_data_channel_packet_received")
		if _data_channel.has_signal("packet_received") \
			and _data_channel.is_connected("packet_received", receive_callable):
			_data_channel.disconnect("packet_received", receive_callable)
		var exit_callable := Callable(self, "_on_data_channel_tree_exited")
		if _data_channel.is_connected("tree_exited", exit_callable):
			_data_channel.disconnect("tree_exited", exit_callable)
	_data_channel = null


func _is_server_channel() -> bool:
	return _data_channel != null \
		and is_instance_valid(_data_channel) \
		and _data_channel.has_method("publish_packet")


func _is_client_channel() -> bool:
	return _data_channel != null \
		and is_instance_valid(_data_channel) \
		and _data_channel.has_signal("packet_received")


func _publish_packet_if_server(packet: PackedByteArray) -> Error:
	if not _is_server_channel():
		return OK
	var publish_error := int(_data_channel.call("publish_packet", packet))
	if publish_error != OK:
		return _report_error(
			"Point-cloud data channel rejected a packet: %s" % error_string(publish_error),
			publish_error
		)
	return OK


func _synchronize_server_cache() -> Error:
	if not _is_server_channel():
		return OK
	if _data_channel.has_method("clear_map_cache"):
		_data_channel.call("clear_map_cache")
	if _store.is_empty():
		return OK
	if _data_channel.has_method("begin_map"):
		var begin_error := int(_data_channel.call(
			"begin_map",
			_store.session_id,
			_store.map_id
		))
		if begin_error != OK:
			return _report_error(
				"Could not begin point-cloud data map: %s" % error_string(begin_error),
				begin_error
			)
	for chunk in _store.get_chunks():
		var encoded_result := ChunkCodec.encode(chunk)
		if not bool(encoded_result.get("ok", false)):
			return _report_error(
				"Could not encode replacement point chunk: %s" % str(
					encoded_result.get("error", "")
				),
				ERR_INVALID_DATA
			)
		var publish_error := _publish_packet_if_server(
			encoded_result.get("data", PackedByteArray()) as PackedByteArray
		)
		if publish_error != OK:
			return publish_error
	return OK


func _extract_registration_options(options: Dictionary) -> Dictionary:
	if options.get("registration") is Dictionary:
		return (options.get("registration") as Dictionary).duplicate(true)
	if int(options.get("schema_version", -1)) == 1:
		return options.duplicate(true)
	return {}


func _append_result_to_error(append_result: int) -> Error:
	match append_result:
		PointMapStore.AppendResult.CAPACITY_EXCEEDED:
			return ERR_OUT_OF_MEMORY
		PointMapStore.AppendResult.CHUNK_CONFLICT:
			return ERR_ALREADY_EXISTS
		PointMapStore.AppendResult.SESSION_MISMATCH, PointMapStore.AppendResult.MAP_MISMATCH:
			return ERR_INVALID_DATA
		_:
			return ERR_INVALID_DATA


func _report_error(message: String, error: int) -> Error:
	_last_runtime_error = message
	error_occurred.emit(message)
	_emit_stats()
	return error


func _is_main_thread_context() -> bool:
	if OS.has_method("get_thread_caller_id") and OS.has_method("get_main_thread_id"):
		return int(OS.call("get_thread_caller_id")) == int(OS.call("get_main_thread_id"))
	# The current Godot build always provides these methods. The fallback keeps
	# custom builds usable and assumes their scene callbacks run on the main thread.
	return true


func _emit_stats() -> void:
	stats_changed.emit(get_stats_snapshot())
