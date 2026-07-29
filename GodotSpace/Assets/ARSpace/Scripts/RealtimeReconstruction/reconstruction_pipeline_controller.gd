class_name RealtimeReconstructionPipelineController
extends Node

## Integrates the control state machine, PICO stream, LingBot tunnel, PCCH
## runtime, registration and map persistence. The PC Server is authoritative;
## clients only receive bounded status/registration snapshots and point chunks.

const SERVER_PEER_ID := 1
const ROLE_PC_GROUND := "pc_ground"
const ROLE_GROUND_VR := "ground_vr"
const ROLE_SKY := "sky"
const STATUS_SCHEMA_VERSION := 2
const STATUS_BROADCAST_INTERVAL_MSEC := 500
const STATUS_REQUEST_RETRY_MSEC := 1500
const PREFLIGHT_TIMEOUT_MSEC := 15_000
const SOLVE_RETRY_MSEC := 500
const MAP_VERSION_INTERVAL_MSEC := 5000
const MAX_STATUS_JSON_BYTES := 64 * 1024
const MAX_FRAME_LATENCY_SAMPLES := 1500
const MAX_MAP_LIBRARY_ENTRIES := 128
const SKY_POSE_HISTORY_WINDOW_USEC := 5_000_000
const PICO_POSE_SETTLE_USEC := 100_000
const MAX_PENDING_PICO_POSE_SAMPLES := 256
const NETWORK_POSE_INTERPOLATION_DELAY_USEC := 100_000
const MAX_NETWORK_POSE_AGE_MSEC := 1000
const MAX_POSE_ALIGNMENT_ERROR_USEC := 250_000
const STOP_DRAIN_MIN_MSEC := 2000
const STOP_DRAIN_MAX_MSEC := 5000
const STOP_DRAIN_QUIET_MSEC := 750
const POINT_DATA_PORT := 8791

const ChunkCodec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)
const GsmapStore := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Persistence/gsmap_store.gd"
)
const RegistrationController := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Registration/reconstruction_registration.gd"
)
const DiagnosticsLoggerScript := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Diagnostics/reconstruction_diagnostics_logger.gd"
)

signal pipeline_snapshot_changed(snapshot: Dictionary)
signal manual_adjustment_rejected(message: String)
signal map_saved(file_name: String, path: String)

var _session: Node
var _pico_receiver: Node
var _lingbot_bridge: Node
var _data_server: Node
var _data_client: Node
var _point_runtime: Node
var _registration: Node
var _workspace: Node
var _network_handler: Node

var _dependencies_bound := false
var _storage_ready := false
var _preflight_pending := false
var _preflight_started_msec := 0
var _collection_started_msec := 0
var _last_solve_attempt_msec := -SOLVE_RETRY_MSEC
var _pending_solve_result: Dictionary = {}
var _paired_sample_count := 0
var _last_map_version_msec := 0
var _last_status_broadcast_msec := -STATUS_BROADCAST_INTERVAL_MSEC
var _last_status_request_msec := -STATUS_REQUEST_RETRY_MSEC
var _last_status_json := ""
var _latest_snapshot: Dictionary = {}
var _map_library: Array[Dictionary] = []
var _frame_receive_usec: Dictionary = {}
var _input_frames_window := 0
var _point_packets_window := 0
var _chunks_since_map_version := false
var _stats_window_started_msec := 0
var _input_fps := 0.0
var _point_update_hz := 0.0
var _latency_ms := 0.0
var _last_autosave_file := ""
var _point_data_auth_token := ""
var _client_point_data_auth_token := ""
var _last_lab_session_id := ""
var _last_lab_chunk_number := 0
var _stale_lab_session_id := ""
var _awaiting_fresh_lab_session := false
var _accepting_lab_output := false
var _sky_pose_history: Array[Dictionary] = []
var _pending_pico_pose_samples: Dictionary = {}
var _pico_clock_offset_valid := false
var _pico_to_server_offset_usec := 0
var _stop_drain_pending := false
var _stop_drain_started_msec := 0
var _stop_drain_last_packet_msec := 0
var _diagnostics = DiagnosticsLoggerScript.new()


func _ready() -> void:
	add_to_group("reconstruction_pipeline_controller")
	set_process(true)
	call_deferred("_bind_dependencies")


func _exit_tree() -> void:
	if _diagnostics.is_active():
		_diagnostics.close_session({
			"reason": "pipeline_exit",
			"runtime": _build_diagnostics_runtime_snapshot(),
		})


func _process(_delta: float) -> void:
	if not _dependencies_bound:
		return
	_update_rate_stats()
	if multiplayer.is_server():
		_sample_sky_pose_history()
		_flush_pending_pico_pose_samples()
		_process_server_lifecycle()
		_publish_server_snapshot(false)
	else:
		_process_client_snapshot_request()


func _bind_dependencies() -> void:
	_session = get_parent().get_node_or_null("ReconstructionSession")
	_pico_receiver = get_parent().get_node_or_null("PicoFrameReceiver")
	_lingbot_bridge = get_parent().get_node_or_null("LingbotStreamBridge")
	_data_server = get_parent().get_node_or_null("PointCloudDataServer")
	_data_client = get_parent().get_node_or_null("PointCloudDataClient")
	_registration = get_parent().get_node_or_null("ReconstructionRegistration")
	_network_handler = get_node_or_null("/root/NetworkHandler")
	_workspace = get_tree().get_first_node_in_group("reconstruction_workspace_controller")
	if _workspace != null:
		_point_runtime = _workspace.get_node_or_null(
			"ReconstructionRoot/PointCloudChunks"
		)

	for dependency in [
		_session,
		_pico_receiver,
		_lingbot_bridge,
		_data_server,
		_data_client,
		_point_runtime,
		_registration,
		_workspace,
	]:
		if dependency == null:
			push_error("实时重建 pipeline 缺少场景依赖")
			return

	_connect_common_signals()
	if multiplayer.is_server():
		_configure_server()
	else:
		_configure_client()
	_dependencies_bound = true
	_stats_window_started_msec = Time.get_ticks_msec()
	_update_local_workspace()


func _connect_common_signals() -> void:
	_connect_once(
		_workspace,
		&"manual_adjustment_requested",
		Callable(self, "_on_manual_adjustment_requested"),
	)
	_connect_once(
		_point_runtime,
		&"stats_changed",
		Callable(self, "_on_point_runtime_stats_changed"),
	)
	_connect_once(
		_point_runtime,
		&"error_occurred",
		Callable(self, "_on_point_runtime_error"),
	)
	_connect_once(
		_point_runtime,
		&"chunk_accepted",
		Callable(self, "_on_point_chunk_accepted"),
	)
	_connect_once(
		_registration,
		&"sample_count_changed",
		Callable(self, "_on_registration_sample_count_changed"),
	)
	_connect_once(
		_registration,
		&"registration_changed",
		Callable(self, "_on_registration_changed"),
	)


func _configure_server() -> void:
	_connect_once(
		_pico_receiver,
		&"frame_received",
		Callable(self, "_on_pico_frame_received"),
	)
	_connect_once(
		_pico_receiver,
		&"stats_changed",
		Callable(self, "_on_service_status_changed"),
	)
	_connect_once(
		_lingbot_bridge,
		&"point_packet_received",
		Callable(self, "_on_lingbot_point_packet"),
	)
	_connect_once(
		_lingbot_bridge,
		&"status_changed",
		Callable(self, "_on_service_status_changed"),
	)
	_connect_once(
		_data_server,
		&"status_changed",
		Callable(self, "_on_service_status_changed"),
	)
	_connect_session_server_hooks()
	_data_server.add_to_group("reconstruction_data_channel")
	_point_data_auth_token = _generate_data_channel_token()
	_data_server.call("set_network_handler", _network_handler)
	var auth_error := int(_data_server.call(
		"set_auth_token",
		_point_data_auth_token,
	))
	if auth_error != OK:
		push_warning("实时重建点云通道认证初始化失败: %s" % error_string(auth_error))
	var listen_error := int(_data_server.call("start_server", POINT_DATA_PORT, "*"))
	if listen_error != OK:
		push_warning("实时重建点云通道启动失败: %s" % error_string(listen_error))
	_point_runtime.call("bind_data_channel", _data_server)
	_storage_ready = (
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(GsmapStore.LIBRARY_DIR)
		) == OK
	)
	_refresh_map_library()
	_publish_server_snapshot(true)


func _configure_client() -> void:
	_data_client.add_to_group("reconstruction_data_channel")
	_connect_once(
		_data_client,
		&"connection_changed",
		Callable(self, "_on_client_data_connection_changed"),
	)
	_connect_once(
		_data_client,
		&"status_changed",
		Callable(self, "_on_service_status_changed"),
	)
	_point_runtime.call("bind_data_channel", _data_client)
	_request_pipeline_snapshot()


func _connect_session_server_hooks() -> void:
	var hooks := {
		&"preflight_requested": Callable(self, "_on_preflight_requested"),
		&"collection_started": Callable(self, "_on_collection_started"),
		&"solve_requested": Callable(self, "_on_solve_requested"),
		&"live_started": Callable(self, "_on_live_started"),
		&"reconstruction_stopped": Callable(self, "_on_reconstruction_stopped"),
		&"map_reset_requested": Callable(self, "_on_map_reset_requested"),
		&"import_requested": Callable(self, "_on_import_requested"),
		&"export_requested": Callable(self, "_on_export_requested"),
		&"error_reported": Callable(self, "_on_session_error_reported"),
	}
	for signal_name: StringName in hooks:
		_connect_once(_session, signal_name, hooks[signal_name])


func _connect_once(source: Node, signal_name: StringName, callback: Callable) -> void:
	if source == null or not source.has_signal(signal_name):
		return
	if not source.is_connected(signal_name, callback):
		source.connect(signal_name, callback)


func _process_server_lifecycle() -> void:
	_process_stop_drain()
	if _preflight_pending:
		if _server_prerequisites_ready():
			_preflight_pending = false
			_session.call("server_mark_preflight_ready")
		elif Time.get_ticks_msec() - _preflight_started_msec >= PREFLIGHT_TIMEOUT_MSEC:
			_preflight_pending = false
			_session.call(
				"server_report_error",
				"preflight_timeout",
				"预检超时：请检查 PICO Helper、SSH 隧道和 LingBot-Map 服务。",
			)
	var state_name := str(_session.call("get_state_name"))
	if state_name == "collecting":
		_attempt_automatic_solve()
	if state_name == "live" \
			and Time.get_ticks_msec() - _last_map_version_msec >= MAP_VERSION_INTERVAL_MSEC \
			and _chunks_since_map_version:
		_last_map_version_msec = Time.get_ticks_msec()
		_chunks_since_map_version = false
		_session.call("server_note_map_update")


func _process_client_snapshot_request() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if Time.get_ticks_msec() - _last_status_request_msec < STATUS_REQUEST_RETRY_MSEC:
		return
	if not _latest_snapshot.is_empty():
		return
	_request_pipeline_snapshot()


func _on_preflight_requested(
	_session_id: String,
	_source_peer_id: int,
	options: Dictionary,
) -> void:
	var is_retry := bool(options.get("retry", false))
	var restart_stream := not is_retry or bool(options.get("restart_stream", false))
	if not is_retry or not _diagnostics.is_active():
		_start_diagnostics_session(_session_id, _source_peer_id, options)
	else:
		_diagnostics.log_event("preflight_retry_requested", {
			"source_peer_id": _source_peer_id,
			"options": options.duplicate(true),
			"restart_stream": restart_stream,
			"runtime": _build_diagnostics_runtime_snapshot(),
		})
	_cancel_stop_drain()
	if restart_stream:
		_stale_lab_session_id = _last_lab_session_id
		_awaiting_fresh_lab_session = not _stale_lab_session_id.is_empty()
		_point_runtime.call("clear_map", true)
		if _registration.has_method("reset_registration"):
			_registration.call("reset_registration")
		else:
			var root := _workspace.call("get_reconstruction_root") as Node3D
			if root != null:
				root.transform = Transform3D.IDENTITY
		_lingbot_bridge.call("restart_input_session")
	_last_autosave_file = ""
	_pending_solve_result.clear()
	_paired_sample_count = 0
	_sky_pose_history.clear()
	_pending_pico_pose_samples.clear()
	_pico_clock_offset_valid = false
	_pico_to_server_offset_usec = 0
	_accepting_lab_output = false
	_lingbot_bridge.call("set_forwarding_enabled", false)
	_preflight_pending = true
	_preflight_started_msec = Time.get_ticks_msec()
	_publish_server_snapshot(true)


func _on_collection_started(_session_id: String) -> void:
	_registration.call("begin_collection")
	_collection_started_msec = Time.get_ticks_msec()
	_last_solve_attempt_msec = -SOLVE_RETRY_MSEC
	_pending_solve_result.clear()
	_accepting_lab_output = true
	_lingbot_bridge.call("set_forwarding_enabled", true)
	_diagnostics.log_event("collection_started", {
		"runtime": _build_diagnostics_runtime_snapshot(),
	})
	_publish_server_snapshot(true)


func _on_solve_requested(_session_id: String) -> void:
	if not bool(_pending_solve_result.get("ok", false)):
		_diagnostics.log_event("solve_rejected", {
			"reason": "registration_solve_missing",
			"registration_error": str(_registration.call("get_last_error")),
			"runtime": _build_diagnostics_runtime_snapshot(),
		})
		_session.call(
			"server_report_error",
			"registration_solve_missing",
			"自动配准没有生成有效结果，请重新初始化。",
		)
		return
	var manifest := _pending_solve_result.get("manifest", {}) as Dictionary
	var quality := manifest.get("quality", {}) as Dictionary
	_diagnostics.log_event("solve_completed", {
		"manifest": manifest.duplicate(true),
		"quality": quality.duplicate(true),
	})
	_session.call("server_mark_solve_complete", quality)
	_publish_server_snapshot(true)


func _on_live_started(_session_id: String, _map_version: int) -> void:
	_apply_registration_to_runtime(true)
	_auto_save_map("已确认")
	_diagnostics.log_event("reconstruction_live", {
		"map_version": _map_version,
		"registration": (
			_registration.call("get_registration_manifest") as Dictionary
		).duplicate(true),
		"runtime": _build_diagnostics_runtime_snapshot(),
	})
	_publish_server_snapshot(true)


func _on_reconstruction_stopped(_session_id: String, _map_version: int) -> void:
	_lingbot_bridge.call("set_forwarding_enabled", false)
	_diagnostics.log_event("reconstruction_stop_requested", {
		"map_version": _map_version,
		"runtime": _build_diagnostics_runtime_snapshot(),
	})
	if _accepting_lab_output and not bool(_session.call("is_imported_session")):
		_stop_drain_pending = true
		_stop_drain_started_msec = Time.get_ticks_msec()
		_stop_drain_last_packet_msec = _stop_drain_started_msec
	else:
		_accepting_lab_output = false
		_auto_save_map("最终")
		_close_diagnostics_session("stopped")
	_publish_server_snapshot(true)


func _on_map_reset_requested(_previous_session_id: String, _map_version: int) -> void:
	_diagnostics.log_event("map_reset_requested", {
		"previous_session_id": _previous_session_id,
		"map_version": _map_version,
		"runtime": _build_diagnostics_runtime_snapshot(),
	})
	_cancel_stop_drain()
	_accepting_lab_output = false
	_lingbot_bridge.call("set_forwarding_enabled", false)
	_point_runtime.call("clear_map", true)
	if _registration.has_method("reset_registration"):
		_registration.call("reset_registration")
	_refresh_map_library()
	_close_diagnostics_session("map_reset")
	_publish_server_snapshot(true)


func _on_import_requested(_session_id: String, map_file_name: String) -> void:
	_cancel_stop_drain()
	_accepting_lab_output = false
	_lingbot_bridge.call("set_forwarding_enabled", false)
	var result := GsmapStore.import_map(map_file_name)
	if not bool(result.get("ok", false)):
		_session.call(
			"server_report_error",
			"map_import_failed",
			str(result.get("error", "地图导入失败")),
		)
		return
	var manifest := result.get("manifest", {}) as Dictionary
	var persisted_registration := manifest.get("registration", {}) as Dictionary
	var controller_manifest := persisted_registration.get(
		"controller_manifest",
		{},
	) as Dictionary
	if controller_manifest.is_empty():
		controller_manifest = _controller_manifest_from_gsmap(persisted_registration)
	var validator: Node = RegistrationController.new()
	var registration_is_valid := bool(validator.call(
		"set_registration_manifest",
		controller_manifest,
	))
	validator.free()
	if not registration_is_valid:
		_session.call(
			"server_report_error",
			"map_registration_invalid",
			"地图中的配准参数无效。",
		)
		return
	var previous_store: RefCounted = _point_runtime.call("get_current_store")
	var previous_registration := _registration.call(
		"get_registration_manifest"
	) as Dictionary
	var imported_store: RefCounted = result.get("store") as RefCounted
	var replace_error := int(_point_runtime.call(
		"replace_store",
		imported_store,
		manifest,
		false,
	))
	if replace_error != OK:
		_session.call(
			"server_report_error",
			"map_import_failed",
			"地图载入运行时失败：%s" % error_string(replace_error),
		)
		return
	if not _registration.call("set_registration_manifest", controller_manifest):
		_rollback_import(previous_store, previous_registration)
		_session.call(
			"server_report_error",
			"map_registration_invalid",
			"地图中的配准参数在应用时失效。",
		)
		return
	_apply_registration_to_runtime(bool(persisted_registration.get("confirmed", true)))
	var publish_error := int(_point_runtime.call("publish_current_map"))
	if publish_error != OK:
		_rollback_import(previous_store, previous_registration)
		_session.call(
			"server_report_error",
			"map_publish_failed",
			"导入地图无法发布：%s" % error_string(publish_error),
		)
		return
	var quality := controller_manifest.get("quality", {}) as Dictionary
	_session.call("server_mark_import_ready", map_file_name, quality)
	_refresh_map_library()
	_publish_server_snapshot(true)


func _on_export_requested(
	_session_id: String,
	suggested_name: String,
	_map_version: int,
) -> void:
	if _stop_drain_pending:
		push_warning("实时重建仍在排空 GPU 尾部结果，暂不能导出最终地图。")
		return
	var result := _export_current_map(suggested_name, true)
	if not bool(result.get("ok", false)):
		push_warning("实时重建地图导出失败: %s" % str(result.get("error", "")))


func _on_session_error_reported(
	_session_id: String,
	error_code: String,
	message: String,
) -> void:
	_diagnostics.log_event("session_error", {
		"error_code": error_code,
		"message": message,
		"runtime": _build_diagnostics_runtime_snapshot(),
	})
	_cancel_stop_drain()
	_accepting_lab_output = false
	_lingbot_bridge.call("set_forwarding_enabled", false)
	_close_diagnostics_session("error")
	_publish_server_snapshot(true)


func _on_pico_frame_received(
	frame_id: int,
	timestamp_ns: int,
	width: int,
	height: int,
	metadata: Dictionary,
	jpeg_bytes: PackedByteArray,
) -> void:
	var state_name := str(_session.call("get_state_name"))
	if state_name not in ["collecting", "solving", "preview", "live"]:
		return
	_input_frames_window += 1
	var receive_usec := Time.get_ticks_usec()
	_frame_receive_usec[frame_id] = receive_usec
	while _frame_receive_usec.size() > MAX_FRAME_LATENCY_SAMPLES:
		var oldest_key: Variant = _frame_receive_usec.keys()[0]
		_frame_receive_usec.erase(oldest_key)
	var sample_metadata := metadata.duplicate(true)
	if not sample_metadata.has("frame_timestamp_ns"):
		sample_metadata["frame_timestamp_ns"] = timestamp_ns
	if state_name == "collecting":
		_update_pico_clock_offset(timestamp_ns, receive_usec)
		while _pending_pico_pose_samples.size() >= MAX_PENDING_PICO_POSE_SAMPLES:
			var oldest_pending: Variant = _pending_pico_pose_samples.keys()[0]
			_pending_pico_pose_samples.erase(oldest_pending)
		_pending_pico_pose_samples[frame_id] = {
			"timestamp_ns": timestamp_ns,
			"metadata": sample_metadata,
			"resolve_after_usec": receive_usec + PICO_POSE_SETTLE_USEC,
		}
	var forwarded_to_lab := bool(_lingbot_bridge.call(
		"enqueue_frame",
		frame_id,
		timestamp_ns,
		width,
		height,
		metadata,
		jpeg_bytes,
	))
	if _diagnostics.is_active():
		_diagnostics.log_pico_frame(
			frame_id,
			timestamp_ns,
			width,
			height,
			metadata,
			jpeg_bytes,
			forwarded_to_lab,
			_lingbot_bridge.call("get_status_snapshot") as Dictionary,
		)


func _on_lingbot_point_packet(packet: PackedByteArray) -> void:
	if not _accepting_lab_output \
			or str(_session.call("get_state_name")) not in [
		"collecting",
		"solving",
		"preview",
		"live",
		"stopped",
	]:
		return
	var decode_result := ChunkCodec.decode(packet)
	if not bool(decode_result.get("ok", false)):
		_session.call(
			"server_report_error",
			"point_chunk_decode_failed",
			"点云数据无法解析：%s" % str(decode_result.get("error", "")),
		)
		return
	var source_chunk: RefCounted = decode_result.get("chunk") as RefCounted
	if source_chunk == null:
		_session.call(
			"server_report_error",
			"point_chunk_decode_failed",
			"点云数据没有包含有效点块。",
		)
		return
	if _diagnostics.is_active():
		var camera_pose: Dictionary = {}
		if bool(source_chunk.get("has_camera_pose")):
			camera_pose = _transform_to_diagnostics(
				source_chunk.get("camera_to_lingbot_world") as Transform3D
			)
		_diagnostics.log_event("lingbot_point_chunk_received", {
			"packet_bytes": packet.size(),
			"session_id": str(source_chunk.get("session_id")),
			"map_id": str(source_chunk.get("map_id")),
			"chunk_id": str(source_chunk.get("chunk_id")),
			"source_frame_id": int(source_chunk.get("source_frame_id")),
			"timestamp_usec": int(source_chunk.get("timestamp_usec")),
			"source_point_count": int(source_chunk.call("point_count")),
			"confidence_count": (
				source_chunk.get("confidence_u8") as PackedByteArray
			).size(),
			"has_camera_pose": bool(source_chunk.get("has_camera_pose")),
			"camera_to_lingbot_world": camera_pose,
			"metadata_extensions": (
				source_chunk.get("metadata_extensions") as Dictionary
			).duplicate(true),
		})
	var sequence_result := _accept_lab_chunk_sequence(
		str(source_chunk.get("session_id")),
		str(source_chunk.get("chunk_id")),
	)
	if sequence_result == "stale" or sequence_result == "duplicate":
		return
	if not sequence_result.is_empty():
		_lingbot_bridge.call("set_forwarding_enabled", false)
		_session.call(
			"server_report_error",
			"lab_chunk_sequence_invalid",
			sequence_result,
		)
		return
	if _stop_drain_pending:
		_stop_drain_last_packet_msec = Time.get_ticks_msec()
	var source_frame_id := int(source_chunk.get("source_frame_id"))
	if bool(source_chunk.get("has_camera_pose")):
		_registration.call(
			"add_lingbot_sample",
			source_frame_id,
			source_chunk.get("camera_to_lingbot_world"),
		)
	if _frame_receive_usec.has(source_frame_id):
		_latency_ms = maxf(
			0.0,
			float(
				Time.get_ticks_usec()
				- int(_frame_receive_usec[source_frame_id])
			) / 1000.0,
		)
		_frame_receive_usec.erase(source_frame_id)
	var ingest_error := int(_point_runtime.call("ingest_packet", packet, true))
	_diagnostics.log_event("lingbot_point_chunk_ingested", {
		"chunk_id": str(source_chunk.get("chunk_id")),
		"source_frame_id": source_frame_id,
		"latency_ms": _latency_ms,
		"result": error_string(ingest_error),
		"runtime_points": (
			_point_runtime.call("get_stats_snapshot") as Dictionary
		).duplicate(true),
	})
	if ingest_error != OK:
		_session.call(
			"server_report_error",
			"point_chunk_rejected",
			"点云数据被拒绝：%s" % error_string(ingest_error),
		)


func _on_point_chunk_accepted(
	chunk_id: String,
	point_count: int,
	total_points: int,
) -> void:
	_point_packets_window += 1
	_chunks_since_map_version = true
	_diagnostics.log_event("point_chunk_accepted", {
		"chunk_id": chunk_id,
		"filtered_point_count": point_count,
		"total_retained_points": total_points,
	})
	if not multiplayer.is_server():
		return
	if str(_session.call("get_state_name")) == "collecting":
		_attempt_automatic_solve()


func _attempt_automatic_solve() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_solve_attempt_msec < SOLVE_RETRY_MSEC:
		return
	if now - _collection_started_msec < 5000:
		return
	if _paired_sample_count < 6:
		return
	_last_solve_attempt_msec = now
	var result := _registration.call("solve_automatic") as Dictionary
	if not bool(result.get("ok", false)):
		_diagnostics.log_event("automatic_solve_attempt_failed", {
			"paired_sample_count": _paired_sample_count,
			"error": str(result.get(
				"error",
				_registration.call("get_last_error"),
			)),
		})
		return
	_pending_solve_result = result
	_diagnostics.log_event("automatic_solve_ready", {
		"result": result.duplicate(true),
	})
	_session.call("server_mark_collection_complete")


func _on_registration_sample_count_changed(
	_pico_count: int,
	_lingbot_count: int,
	paired_count: int,
) -> void:
	_paired_sample_count = paired_count


func _on_registration_changed(manifest: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	_diagnostics.log_event("registration_changed", {
		"manifest": manifest.duplicate(true),
	})
	_apply_registration_to_runtime(
		str(_session.call("get_state_name")) in ["live", "stopped"]
	)
	_publish_server_snapshot(true)


func _on_manual_adjustment_requested(kind: StringName, amount: float) -> void:
	if multiplayer.is_server():
		return
	if not multiplayer.has_multiplayer_peer():
		return
	rpc_id(
		SERVER_PEER_ID,
		"_server_request_manual_adjustment",
		kind,
		amount,
		int(_session.call("get_state_revision")),
	)


@rpc("any_peer", "call_remote", "reliable")
func _server_request_manual_adjustment(
	kind: StringName,
	amount: float,
	expected_state_revision: int,
) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if _get_peer_role(sender_id) != ROLE_SKY \
			or str(_session.call("get_state_name")) != "preview" \
			or expected_state_revision != int(_session.call("get_state_revision")) \
			or not is_finite(amount) \
			or absf(amount) > 10.0:
		rpc_id(
			sender_id,
			"_client_manual_adjustment_rejected",
			"手动配准请求无效或状态已变化。",
		)
		return
	if not bool(_registration.call("apply_manual_adjustment", kind, amount)):
		rpc_id(
			sender_id,
			"_client_manual_adjustment_rejected",
			str(_registration.call("get_last_error")),
		)


@rpc("authority", "call_remote", "reliable")
func _client_manual_adjustment_rejected(message: String) -> void:
	manual_adjustment_rejected.emit(message.left(256))


func _on_point_runtime_stats_changed(_snapshot: Dictionary) -> void:
	if multiplayer.is_server():
		_publish_server_snapshot(false)


func _on_point_runtime_error(message: String) -> void:
	if multiplayer.is_server() and str(_session.call("get_state_name")) != "idle":
		push_warning(message)


func _on_service_status_changed(_value: Variant = null) -> void:
	if not is_inside_tree() or multiplayer == null:
		return
	if multiplayer.is_server():
		_publish_server_snapshot(true)
	else:
		_update_local_workspace()


func _on_client_data_connection_changed(is_connected: bool) -> void:
	if not is_inside_tree():
		return
	if not is_connected and _point_runtime != null:
		# Server map replacement intentionally disconnects data clients. Clear
		# the local native-coordinate store so the reconnect replay can belong
		# to a new session/map without tripping MapStore's mismatch guard.
		_point_runtime.call("clear_map", false)
	_update_local_workspace()


func _server_prerequisites_ready() -> bool:
	return (
		bool(_pico_receiver.call("is_helper_connected"))
		and bool(_lingbot_bridge.call("is_ready"))
		and bool(_data_server.call("is_listening"))
		and _storage_ready
	)


func _publish_server_snapshot(force: bool) -> void:
	if not multiplayer.is_server() or not _dependencies_bound:
		return
	var now := Time.get_ticks_msec()
	if not force and now - _last_status_broadcast_msec < STATUS_BROADCAST_INTERVAL_MSEC:
		return
	var snapshot := _build_server_snapshot()
	var serialized := JSON.stringify(snapshot)
	if serialized.to_utf8_buffer().size() > MAX_STATUS_JSON_BYTES:
		push_warning("实时重建状态快照超过大小限制")
		return
	if not force and serialized == _last_status_json:
		return
	_last_status_json = serialized
	_last_status_broadcast_msec = now
	_latest_snapshot = snapshot
	pipeline_snapshot_changed.emit(snapshot.duplicate(true))
	if multiplayer.has_multiplayer_peer():
		for peer_id in multiplayer.get_peers():
			if _get_peer_role(int(peer_id)) in [ROLE_SKY, ROLE_GROUND_VR]:
				rpc_id(
					int(peer_id),
					"_client_receive_pipeline_snapshot",
					snapshot,
				)


func _build_server_snapshot() -> Dictionary:
	var helper := _pico_receiver.call("get_status_snapshot") as Dictionary
	var lab := _lingbot_bridge.call("get_status_snapshot") as Dictionary
	var channel := _data_server.call("get_status_snapshot") as Dictionary
	var points := _point_runtime.call("get_stats_snapshot") as Dictionary
	var registration_manifest := _registration.call(
		"get_registration_manifest"
	) as Dictionary
	var elapsed := 0.0
	if _collection_started_msec > 0:
		elapsed = float(Time.get_ticks_msec() - _collection_started_msec) / 1000.0
	var progress := minf(95.0, elapsed / 5.0 * 70.0 + minf(_paired_sample_count, 6) / 6.0 * 30.0)
	var quality := registration_manifest.get("quality", {}) as Dictionary
	return {
		"schema_version": STATUS_SCHEMA_VERSION,
		"point_data_auth_token": _point_data_auth_token,
		"stop_draining": _stop_drain_pending,
		"services": {
			"helper": {
				"ready": bool(helper.get("connected", false)),
				"detail": str(helper.get("status", "")),
			},
			"lab": {
				"ready": bool(lab.get("ready", false)),
				"detail": _lab_status_detail(lab),
			},
			"point_channel": {
				"ready": bool(channel.get("listening", false)),
				"detail": "%d 个客户端" % int(channel.get("client_count", 0)),
			},
			"storage": {
				"ready": _storage_ready,
				"detail": "%d 张地图" % _map_library.size(),
			},
		},
		"all_server_prerequisites_ready": _server_prerequisites_ready(),
		"collection_progress": progress,
		"collection_instruction": _collection_instruction(elapsed),
		"paired_sample_count": _paired_sample_count,
		"registration": registration_manifest,
		"quality": quality,
		"stats": {
			"input_fps": _input_fps,
			"point_update_hz": _point_update_hz,
			"latency_ms": _latency_ms,
			"point_count": int(points.get("point_count", 0)),
			"elapsed_seconds": elapsed,
		},
		"map_library": _map_library.duplicate(true),
		"last_autosave_file": _last_autosave_file,
	}


func _request_pipeline_snapshot() -> void:
	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		return
	_last_status_request_msec = Time.get_ticks_msec()
	rpc_id(SERVER_PEER_ID, "_server_request_pipeline_snapshot")


@rpc("any_peer", "call_remote", "reliable")
func _server_request_pipeline_snapshot() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if _get_peer_role(sender_id) not in [ROLE_SKY, ROLE_GROUND_VR]:
		return
	rpc_id(sender_id, "_client_receive_pipeline_snapshot", _build_server_snapshot())


@rpc("authority", "call_remote", "reliable")
func _client_receive_pipeline_snapshot(snapshot: Dictionary) -> void:
	if multiplayer.is_server() or not _validate_pipeline_snapshot(snapshot):
		return
	_latest_snapshot = snapshot.duplicate(true)
	_ensure_point_data_client(str(snapshot.get("point_data_auth_token", "")))
	var registration_manifest := snapshot.get("registration", {}) as Dictionary
	if bool(registration_manifest.get("solved", false)):
		_registration.call("set_registration_manifest", registration_manifest)
	elif bool(
		(_registration.call("get_registration_manifest") as Dictionary).get(
			"solved",
			false,
		)
	):
		_registration.call("reset_registration")
	pipeline_snapshot_changed.emit(_latest_snapshot.duplicate(true))
	_update_local_workspace()


func _validate_pipeline_snapshot(snapshot: Dictionary) -> bool:
	if int(snapshot.get("schema_version", -1)) != STATUS_SCHEMA_VERSION:
		return false
	if typeof(snapshot.get("services")) != TYPE_DICTIONARY \
			or typeof(snapshot.get("registration")) != TYPE_DICTIONARY \
			or typeof(snapshot.get("stats")) != TYPE_DICTIONARY \
			or typeof(snapshot.get("map_library")) != TYPE_ARRAY:
		return false
	var auth_token := str(snapshot.get("point_data_auth_token", ""))
	if auth_token.to_utf8_buffer().size() < 32 \
			or auth_token.to_utf8_buffer().size() > 128:
		return false
	return JSON.stringify(snapshot).to_utf8_buffer().size() <= MAX_STATUS_JSON_BYTES


func _ensure_point_data_client(auth_token: String) -> void:
	if auth_token == _client_point_data_auth_token:
		return
	if not _client_point_data_auth_token.is_empty():
		_data_client.call("stop_client", "Point-cloud authorization changed")
	_client_point_data_auth_token = auth_token
	var connect_error := int(_data_client.call(
		"start_client",
		"",
		POINT_DATA_PORT,
		auth_token,
	))
	if connect_error != OK:
		push_warning("实时重建点云客户端启动失败: %s" % error_string(connect_error))


func _update_local_workspace() -> void:
	if _workspace == null or not is_instance_valid(_workspace):
		return
	var snapshot := _latest_snapshot
	if multiplayer.is_server() and _dependencies_bound:
		snapshot = _build_server_snapshot()
	if snapshot.is_empty():
		_workspace.call(
			"set_start_prerequisites_ready",
			false,
			"等待 PC Server 实时重建服务状态",
		)
		return
	var services := snapshot.get("services", {}) as Dictionary
	var missing: Array[String] = []
	for service_name in [&"helper", &"lab", &"point_channel", &"storage"]:
		var service := services.get(service_name, {}) as Dictionary
		var ready := bool(service.get("ready", false))
		var detail := str(service.get("detail", ""))
		if service_name == &"point_channel" and not multiplayer.is_server():
			ready = bool(_data_client.call("is_connected_to_server"))
			if not ready:
				detail = "正在连接 PC Server"
		_workspace.call("set_service_status", service_name, ready, detail)
		if not ready:
			missing.append(_service_display_name(service_name))
	var ready_for_start := bool(snapshot.get("all_server_prerequisites_ready", false))
	if not multiplayer.is_server():
		ready_for_start = ready_for_start \
			and bool(_data_client.call("is_connected_to_server"))
	_workspace.call(
		"set_start_prerequisites_ready",
		ready_for_start,
		"" if ready_for_start else "等待：" + "、".join(missing),
	)
	_workspace.call(
		"set_collecting_progress",
		float(snapshot.get("collection_progress", 0.0)),
		str(snapshot.get("collection_instruction", "")),
	)
	var quality := snapshot.get("quality", {}) as Dictionary
	var registration_manifest := snapshot.get("registration", {}) as Dictionary
	var automatic := registration_manifest.get("automatic", {}) as Dictionary
	_workspace.call(
		"set_preview_metrics",
		float(quality.get("position_rms_cm", 0.0)),
		float(quality.get("rotation_rms_deg", 0.0)),
		float(automatic.get("scale", 1.0)),
	)
	var stats := snapshot.get("stats", {}) as Dictionary
	_workspace.call(
		"set_live_stats",
		float(stats.get("input_fps", 0.0)),
		float(stats.get("point_update_hz", 0.0)),
		float(stats.get("latency_ms", 0.0)),
		int(stats.get("point_count", 0)),
		float(stats.get("elapsed_seconds", 0.0)),
	)
	var library_values := snapshot.get("map_library", []) as Array
	var typed_library: Array[Dictionary] = []
	for entry in library_values:
		if entry is Dictionary:
			typed_library.append((entry as Dictionary).duplicate(true))
	_workspace.call("set_map_library", typed_library)
	_workspace.call(
		"set_stop_draining",
		bool(snapshot.get("stop_draining", false)),
	)


func _get_sky_camera_transform() -> Variant:
	var sky_peer_id := int(_session.call("get_sky_source_peer_id"))
	if sky_peer_id <= SERVER_PEER_ID:
		return null
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var player := scene.get_node_or_null(str(sky_peer_id))
	if player == null:
		return null
	if player.has_method("has_received_network_pose") \
			and not bool(player.call("has_received_network_pose")):
		return null
	if player.has_method("get_last_network_pose_received_msec"):
		var pose_age_msec := Time.get_ticks_msec() \
			- int(player.call("get_last_network_pose_received_msec"))
		if pose_age_msec < 0 or pose_age_msec > MAX_NETWORK_POSE_AGE_MSEC:
			return null
	var viewpoint: Node3D
	if player.has_method("get_network_viewpoint"):
		viewpoint = player.call("get_network_viewpoint") as Node3D
	if viewpoint == null:
		viewpoint = player.get_node_or_null("NetworkHead") as Node3D
	return viewpoint.global_transform if viewpoint != null else null


func _sample_sky_pose_history() -> void:
	var current_transform: Variant = _get_sky_camera_transform()
	if current_transform == null:
		return
	var now_usec := Time.get_ticks_usec()
	_sky_pose_history.append({
		# Player.gd intentionally renders remote poses 100 ms behind receipt.
		# Timestamp the history entry at the pose time, not the render tick.
		"server_usec": now_usec - NETWORK_POSE_INTERPOLATION_DELAY_USEC,
		"transform": current_transform as Transform3D,
	})
	var cutoff := now_usec - SKY_POSE_HISTORY_WINDOW_USEC
	while not _sky_pose_history.is_empty() \
			and int(_sky_pose_history[0].get("server_usec", 0)) < cutoff:
		_sky_pose_history.pop_front()


func _update_pico_clock_offset(timestamp_ns: int, receive_usec: int) -> void:
	if timestamp_ns <= 0:
		return
	var observed_offset := receive_usec - int(timestamp_ns / 1000)
	if not _pico_clock_offset_valid or observed_offset < _pico_to_server_offset_usec:
		var previous_offset := _pico_to_server_offset_usec
		_pico_to_server_offset_usec = observed_offset
		_pico_clock_offset_valid = true
		_diagnostics.log_event("pico_clock_offset_updated", {
			"frame_timestamp_ns": timestamp_ns,
			"server_receive_usec": receive_usec,
			"observed_offset_usec": observed_offset,
			"previous_offset_usec": previous_offset,
		})


func _flush_pending_pico_pose_samples() -> void:
	if _pending_pico_pose_samples.is_empty():
		return
	if str(_session.call("get_state_name")) != "collecting":
		_pending_pico_pose_samples.clear()
		return
	var now_usec := Time.get_ticks_usec()
	var completed: Array[Variant] = []
	for frame_id in _pending_pico_pose_samples:
		var pending := _pending_pico_pose_samples[frame_id] as Dictionary
		if now_usec < int(pending.get("resolve_after_usec", 0)):
			continue
		var timestamp_ns := int(pending.get("timestamp_ns", 0))
		var target_server_usec := now_usec
		if _pico_clock_offset_valid and timestamp_ns > 0:
			target_server_usec = int(timestamp_ns / 1000) \
				+ _pico_to_server_offset_usec
		var alignment := _closest_sky_pose_result(target_server_usec)
		var aligned_transform: Variant = alignment.get("transform")
		var aligned_metadata := (
			pending.get("metadata", {}) as Dictionary
		).duplicate(true)
		aligned_metadata["godot_pose_sample_server_usec"] = target_server_usec
		aligned_metadata["godot_pose_alignment"] = (
			"pico_monotonic_min_arrival_offset"
			if _pico_clock_offset_valid
			else "server_arrival_fallback"
		)
		var sample_accepted := bool(_registration.call(
			"add_pico_sample",
			frame_id,
			aligned_metadata,
			aligned_transform,
		))
		var aligned_transform_log: Dictionary = {}
		if aligned_transform is Transform3D:
			aligned_transform_log = _transform_to_diagnostics(
				aligned_transform as Transform3D
			)
		_diagnostics.log_event("pico_registration_sample", {
			"frame_id": frame_id,
			"frame_timestamp_ns": timestamp_ns,
			"target_server_usec": target_server_usec,
			"clock_offset_usec": _pico_to_server_offset_usec,
			"clock_offset_valid": _pico_clock_offset_valid,
			"pose_history_samples": _sky_pose_history.size(),
			"closest_pose_error_usec": int(
				alignment.get("error_usec", -1)
			),
			"aligned_transform_available": aligned_transform != null,
			"aligned_godot_camera": aligned_transform_log,
			"registration_accepted": sample_accepted,
			"registration_error": str(_registration.call("get_last_error")),
		})
		completed.append(frame_id)
	for frame_id in completed:
		_pending_pico_pose_samples.erase(frame_id)


func _closest_sky_pose_result(target_server_usec: int) -> Dictionary:
	if _sky_pose_history.is_empty():
		return {
			"transform": _get_sky_camera_transform(),
			"error_usec": -1,
		}
	var closest: Transform3D = _sky_pose_history[0].get(
		"transform",
		Transform3D.IDENTITY,
	) as Transform3D
	var closest_distance := absi(
		int(_sky_pose_history[0].get("server_usec", 0)) - target_server_usec
	)
	for index in range(1, _sky_pose_history.size()):
		var sample := _sky_pose_history[index]
		var distance := absi(
			int(sample.get("server_usec", 0)) - target_server_usec
		)
		if distance >= closest_distance:
			continue
		closest_distance = distance
		closest = sample.get("transform", closest) as Transform3D
	if closest_distance > MAX_POSE_ALIGNMENT_ERROR_USEC:
		return {
			"transform": null,
			"error_usec": closest_distance,
		}
	return {
		"transform": closest,
		"error_usec": closest_distance,
	}


func _apply_registration_to_runtime(confirmed: bool) -> void:
	var controller_manifest := _registration.call(
		"get_registration_manifest"
	) as Dictionary
	var persisted := _registration_for_gsmap(controller_manifest, confirmed)
	_point_runtime.call("set_registration_options", persisted)


func _registration_for_gsmap(
	controller_manifest: Dictionary,
	confirmed: bool,
) -> Dictionary:
	if not bool(controller_manifest.get("solved", false)):
		return {
			"schema_version": 1,
			"automatic_sim3": _identity_sim3(),
			"manual_adjustment": _identity_sim3(),
			"confirmed": false,
			"controller_manifest": controller_manifest.duplicate(true),
		}
	var automatic := controller_manifest.get("automatic", {}) as Dictionary
	var manual := controller_manifest.get("manual", {}) as Dictionary
	var auto_xyzw := automatic.get("rotation_quaternion", [0.0, 0.0, 0.0, 1.0]) as Array
	var manual_basis := (
		Basis(Vector3.UP, deg_to_rad(float(manual.get("yaw_degrees", 0.0))))
		* Basis(Vector3.RIGHT, deg_to_rad(float(manual.get("pitch_degrees", 0.0))))
		* Basis(Vector3.FORWARD, deg_to_rad(float(manual.get("roll_degrees", 0.0))))
	)
	var manual_quaternion := manual_basis.get_rotation_quaternion().normalized()
	var manual_scale := float(manual.get("scale", 1.0))
	var pivot := _array_to_vector3(manual.get("pivot", [0.0, 0.0, 0.0]) as Array)
	var translation := _array_to_vector3(
		manual.get("translation", [0.0, 0.0, 0.0]) as Array
	)
	var manual_origin := pivot + translation - manual_basis * pivot * manual_scale
	return {
		"schema_version": 1,
		"automatic_sim3": {
			"scale": float(automatic.get("scale", 1.0)),
			"rotation_wxyz": [
				float(auto_xyzw[3]),
				float(auto_xyzw[0]),
				float(auto_xyzw[1]),
				float(auto_xyzw[2]),
			],
			"translation_xyz": automatic.get(
				"translation",
				[0.0, 0.0, 0.0],
			),
		},
		"manual_adjustment": {
			"scale": manual_scale,
			"rotation_wxyz": [
				manual_quaternion.w,
				manual_quaternion.x,
				manual_quaternion.y,
				manual_quaternion.z,
			],
			"translation_xyz": [
				manual_origin.x,
				manual_origin.y,
				manual_origin.z,
			],
		},
		"confirmed": confirmed,
		"controller_manifest": controller_manifest.duplicate(true),
	}


func _controller_manifest_from_gsmap(registration: Dictionary) -> Dictionary:
	var automatic := registration.get("automatic_sim3", _identity_sim3()) as Dictionary
	var manual := registration.get("manual_adjustment", _identity_sim3()) as Dictionary
	var auto_wxyz := automatic.get("rotation_wxyz", [1.0, 0.0, 0.0, 0.0]) as Array
	var manual_wxyz := manual.get("rotation_wxyz", [1.0, 0.0, 0.0, 0.0]) as Array
	var manual_quaternion := Quaternion(
		float(manual_wxyz[1]),
		float(manual_wxyz[2]),
		float(manual_wxyz[3]),
		float(manual_wxyz[0]),
	).normalized()
	var manual_euler := Basis(manual_quaternion).get_euler()
	return {
		"schema_version": 1,
		"coordinate_contract": "lingbot_world_to_reconstruction_root_parent",
		"solved": true,
		"automatic": {
			"scale": float(automatic.get("scale", 1.0)),
			"rotation_quaternion": [
				float(auto_wxyz[1]),
				float(auto_wxyz[2]),
				float(auto_wxyz[3]),
				float(auto_wxyz[0]),
			],
			"translation": automatic.get("translation_xyz", [0.0, 0.0, 0.0]),
		},
		"manual": {
			"translation": manual.get("translation_xyz", [0.0, 0.0, 0.0]),
			"yaw_degrees": rad_to_deg(manual_euler.y),
			"pitch_degrees": rad_to_deg(manual_euler.x),
			# Manual roll is defined around Vector3.FORWARD (-Z), while
			# Basis.get_euler() reports the equivalent rotation around +Z.
			"roll_degrees": -rad_to_deg(manual_euler.z),
			"scale": float(manual.get("scale", 1.0)),
			"pivot": [0.0, 0.0, 0.0],
		},
		"quality": {},
	}


func _export_current_map(display_name: String, confirmed: bool) -> Dictionary:
	_apply_registration_to_runtime(confirmed)
	var options := {
		"registration": _registration_for_gsmap(
			_registration.call("get_registration_manifest") as Dictionary,
			confirmed,
		),
		"voxel_size_m": float(_point_runtime.get("voxel_size_model_units")),
		"model_name": "lingbot-map",
		"model_version": "stream-adapter-v1",
	}
	var result := _point_runtime.call(
		"export_current_map",
		display_name,
		options,
	) as Dictionary
	if bool(result.get("ok", false)):
		_last_autosave_file = str(result.get("file_name", ""))
		map_saved.emit(_last_autosave_file, str(result.get("path", "")))
		_refresh_map_library()
		_publish_server_snapshot(true)
	return result


func _auto_save_map(stage: String) -> void:
	var store: RefCounted = _point_runtime.call("get_current_store")
	if store == null or bool(store.call("is_empty")):
		return
	var timestamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	_export_current_map(_auto_save_display_name(timestamp, stage), true)


func _auto_save_display_name(timestamp: String, stage: String) -> String:
	return "%s_%s_自动保存" % [timestamp, stage]


func _refresh_map_library() -> void:
	_map_library.clear()
	for entry in GsmapStore.list_maps():
		if _map_library.size() >= MAX_MAP_LIBRARY_ENTRIES:
			break
		var manifest := entry.get("manifest", {}) as Dictionary
		_map_library.append({
			"file_name": str(entry.get("file_name", "")).left(128),
			"manifest": {
				"display_name": str(
					manifest.get("display_name", entry.get("file_name", ""))
				).left(128),
				"point_count": int(manifest.get("point_count", 0)),
				"chunk_count": int(manifest.get("chunk_count", 0)),
				"created_at_utc": str(
					manifest.get("created_at_utc", "")
				).left(64),
			},
		})


func _update_rate_stats() -> void:
	var now := Time.get_ticks_msec()
	if _stats_window_started_msec == 0:
		_stats_window_started_msec = now
		return
	var elapsed_msec := now - _stats_window_started_msec
	if elapsed_msec < 1000:
		return
	_input_fps = float(_input_frames_window) * 1000.0 / float(elapsed_msec)
	_point_update_hz = float(_point_packets_window) * 1000.0 / float(elapsed_msec)
	_input_frames_window = 0
	_point_packets_window = 0
	_stats_window_started_msec = now
	_diagnostics.log_event("periodic_stats", _build_diagnostics_runtime_snapshot())


func _collection_instruction(elapsed_seconds: float) -> String:
	if elapsed_seconds < 5.0:
		return "缓慢移动 30–50 cm，并做少量转头；还需约 %.1f 秒。" % (
			5.0 - elapsed_seconds
		)
	if _paired_sample_count < 6:
		return "已达到采集时长，正在等待 LingBot 返回足够的相机位姿。"
	var last_error := str(_registration.call("get_last_error"))
	if not last_error.is_empty():
		return "请继续水平移动：%s" % last_error
	return "样本已就绪，正在求解自动配准。"


func _lab_status_detail(snapshot: Dictionary) -> String:
	if bool(snapshot.get("ready", false)):
		return "输入/输出隧道已连接"
	var missing: Array[String] = []
	if not bool(snapshot.get("input_connected", false)):
		missing.append("18787 输入")
	if not bool(snapshot.get("output_connected", false)):
		missing.append("18790 输出")
	return "等待 " + "、".join(missing)


func _service_display_name(service_name: StringName) -> String:
	match service_name:
		&"helper":
			return "PICO Helper"
		&"lab":
			return "LingBot-Map"
		&"point_channel":
			return "点云通道"
		&"storage":
			return "地图存储"
	return str(service_name)


func _get_peer_role(peer_id: int) -> String:
	if _network_handler != null and _network_handler.has_method("get_peer_role"):
		return str(_network_handler.call("get_peer_role", peer_id))
	return ROLE_PC_GROUND if peer_id == SERVER_PEER_ID else ""


func _generate_data_channel_token() -> String:
	var random_bytes := Crypto.new().generate_random_bytes(32)
	if random_bytes.size() == 32:
		return random_bytes.hex_encode()
	# This fallback remains process-local and unpredictable enough to avoid
	# exposing 8791 when the platform crypto provider is unavailable.
	var fallback := "%s:%s:%s" % [
		Time.get_ticks_usec(),
		Time.get_unix_time_from_system(),
		OS.get_unique_id(),
	]
	return fallback.sha256_text()


func _accept_lab_chunk_sequence(session_id: String, chunk_id: String) -> String:
	if session_id.is_empty() or not chunk_id.is_valid_int():
		return "LingBot 点块缺少有效的会话或连续序号。"
	var chunk_number := int(chunk_id)
	if chunk_number <= 0:
		return "LingBot 点块序号必须从 1 开始。"
	if _awaiting_fresh_lab_session:
		if session_id == _stale_lab_session_id:
			return "stale"
		_awaiting_fresh_lab_session = false
		_last_lab_session_id = session_id
		_last_lab_chunk_number = 0
	elif not _stale_lab_session_id.is_empty() \
			and session_id == _stale_lab_session_id \
			and session_id != _last_lab_session_id:
		return "stale"
	elif _last_lab_session_id.is_empty():
		_last_lab_session_id = session_id
		_last_lab_chunk_number = 0
	elif session_id != _last_lab_session_id:
		return "LingBot 输出会话意外变化，请重新开始重建。"
	if chunk_number <= _last_lab_chunk_number:
		return "duplicate"
	if chunk_number != _last_lab_chunk_number + 1:
		return (
			"LingBot 点块缺失：期望 %d，收到 %d；请重试本次重建。"
			% [_last_lab_chunk_number + 1, chunk_number]
		)
	_last_lab_chunk_number = chunk_number
	return ""


func _rollback_import(
	previous_store: RefCounted,
	previous_registration: Dictionary,
) -> void:
	if previous_store != null:
		_point_runtime.call("replace_store", previous_store, {}, false)
	if bool(previous_registration.get("solved", false)):
		_registration.call("set_registration_manifest", previous_registration)
	else:
		_registration.call("reset_registration")
	_apply_registration_to_runtime(false)
	_point_runtime.call("publish_current_map")


func _process_stop_drain() -> void:
	if not _stop_drain_pending:
		return
	if str(_session.call("get_state_name")) != "stopped":
		_cancel_stop_drain()
		return
	var now := Time.get_ticks_msec()
	var elapsed := now - _stop_drain_started_msec
	var quiet := now - _stop_drain_last_packet_msec
	if elapsed < STOP_DRAIN_MAX_MSEC \
			and (elapsed < STOP_DRAIN_MIN_MSEC or quiet < STOP_DRAIN_QUIET_MSEC):
		return
	_stop_drain_pending = false
	_accepting_lab_output = false
	_auto_save_map("最终")
	_close_diagnostics_session("stopped_after_drain")
	_publish_server_snapshot(true)


func _cancel_stop_drain() -> void:
	_stop_drain_pending = false
	_stop_drain_started_msec = 0
	_stop_drain_last_packet_msec = 0


func _start_diagnostics_session(
	session_id: String,
	source_peer_id: int,
	options: Dictionary,
) -> void:
	if _diagnostics.is_active():
		_close_diagnostics_session("superseded")
	var configuration := {
		"source_peer_id": source_peer_id,
		"source_peer_role": _get_peer_role(source_peer_id),
		"start_options": options.duplicate(true),
		"session": (_session.call("get_snapshot") as Dictionary).duplicate(true),
		"engine": Engine.get_version_info().duplicate(true),
		"os": {
			"name": OS.get_name(),
			"version": OS.get_version(),
			"model_name": OS.get_model_name(),
			"command_line_user_args": Array(OS.get_cmdline_user_args()),
		},
		"pipeline_parameters": {
			"status_schema_version": STATUS_SCHEMA_VERSION,
			"preflight_timeout_msec": PREFLIGHT_TIMEOUT_MSEC,
			"solve_retry_msec": SOLVE_RETRY_MSEC,
			"map_version_interval_msec": MAP_VERSION_INTERVAL_MSEC,
			"sky_pose_history_window_usec": SKY_POSE_HISTORY_WINDOW_USEC,
			"pico_pose_settle_usec": PICO_POSE_SETTLE_USEC,
			"network_pose_interpolation_delay_usec": (
				NETWORK_POSE_INTERPOLATION_DELAY_USEC
			),
			"max_network_pose_age_msec": MAX_NETWORK_POSE_AGE_MSEC,
			"max_pose_alignment_error_usec": MAX_POSE_ALIGNMENT_ERROR_USEC,
			"stop_drain_min_msec": STOP_DRAIN_MIN_MSEC,
			"stop_drain_max_msec": STOP_DRAIN_MAX_MSEC,
			"stop_drain_quiet_msec": STOP_DRAIN_QUIET_MSEC,
			"point_data_port": POINT_DATA_PORT,
		},
		"point_runtime_parameters": {
			"enable_voxel_filter": bool(_point_runtime.get("enable_voxel_filter")),
			"voxel_size_model_units": float(
				_point_runtime.get("voxel_size_model_units")
			),
			"point_size_pixels": float(_point_runtime.get("point_size")),
			"max_points_per_batch": int(
				_point_runtime.get("max_points_per_batch")
			),
			"auto_bind_data_channel": bool(
				_point_runtime.get("auto_bind_data_channel")
			),
		},
		"effective_services": {
			"pico_receiver": (
				_pico_receiver.call("get_status_snapshot") as Dictionary
			).duplicate(true),
			"lingbot_bridge": (
				_lingbot_bridge.call("get_status_snapshot") as Dictionary
			).duplicate(true),
			"point_data_server": (
				_data_server.call("get_status_snapshot") as Dictionary
			).duplicate(true),
		},
		"registration": (
			_registration.call("get_registration_manifest") as Dictionary
		).duplicate(true),
	}
	if not _diagnostics.start_session(session_id, configuration):
		push_warning("实时重建诊断日志启动失败: %s" % _diagnostics.get_last_error())
		return
	print(
		"实时重建诊断目录: %s"
		% _diagnostics.get_globalized_session_directory()
	)


func _close_diagnostics_session(reason: String) -> void:
	if not _diagnostics.is_active():
		return
	_diagnostics.close_session({
		"reason": reason,
		"runtime": _build_diagnostics_runtime_snapshot(),
		"last_autosave_file": _last_autosave_file,
	})


func _build_diagnostics_runtime_snapshot() -> Dictionary:
	var snapshot := {
		"input_fps": _input_fps,
		"point_update_hz": _point_update_hz,
		"last_latency_ms": _latency_ms,
		"paired_sample_count": _paired_sample_count,
		"accepting_lab_output": _accepting_lab_output,
		"stop_drain_pending": _stop_drain_pending,
		"pico_clock_offset_valid": _pico_clock_offset_valid,
		"pico_to_server_offset_usec": _pico_to_server_offset_usec,
		"last_lab_session_id": _last_lab_session_id,
		"last_lab_chunk_number": _last_lab_chunk_number,
	}
	if _session != null:
		snapshot["session"] = (
			_session.call("get_snapshot") as Dictionary
		).duplicate(true)
	if _pico_receiver != null:
		snapshot["pico_receiver"] = (
			_pico_receiver.call("get_status_snapshot") as Dictionary
		).duplicate(true)
	if _lingbot_bridge != null:
		snapshot["lingbot_bridge"] = (
			_lingbot_bridge.call("get_status_snapshot") as Dictionary
		).duplicate(true)
	if _data_server != null:
		snapshot["point_data_server"] = (
			_data_server.call("get_status_snapshot") as Dictionary
		).duplicate(true)
	if _point_runtime != null:
		snapshot["point_runtime"] = (
			_point_runtime.call("get_stats_snapshot") as Dictionary
		).duplicate(true)
	if _registration != null:
		snapshot["registration"] = (
			_registration.call("get_registration_manifest") as Dictionary
		).duplicate(true)
	return snapshot


func _transform_to_diagnostics(transform: Transform3D) -> Dictionary:
	return {
		"basis_columns": [
			[transform.basis.x.x, transform.basis.x.y, transform.basis.x.z],
			[transform.basis.y.x, transform.basis.y.y, transform.basis.y.z],
			[transform.basis.z.x, transform.basis.z.y, transform.basis.z.z],
		],
		"origin_xyz": [
			transform.origin.x,
			transform.origin.y,
			transform.origin.z,
		],
	}


func _identity_sim3() -> Dictionary:
	return {
		"scale": 1.0,
		"rotation_wxyz": [1.0, 0.0, 0.0, 0.0],
		"translation_xyz": [0.0, 0.0, 0.0],
	}


func _array_to_vector3(values: Array) -> Vector3:
	if values.size() != 3:
		return Vector3.ZERO
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
