extends Node

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const CollaborationSchema := preload("res://Assets/ARSpace/Scripts/Network/collaboration_state_schema.gd")

const ROLE_ARG_PREFIX := "--runtime-startup-smoke-role="
const ROLE_SERVER := "server"
const ROLE_TEST_CLIENT := "test_client"
const ROLE_XR_CONFIG := "xr_config"
const ROLE_SHUTDOWN_SERVER := "shutdown_server"
const ROLE_SHUTDOWN_CLIENT := "shutdown_client"
const SERVER_PEER_ID: int = 1
const ROLE_PC_GROUND := "pc_ground"
const ROLE_ASTRONAUT := "astronaut"
const ARSPACE_SCENE := "res://Assets/ARSpace/Scenes/ARSpace.tscn"
const START_MENU_SCENE := "res://Assets/ARSpace/Scenes/StartMenu.tscn"
const STAGE_TIMEOUT_MSEC: int = 12000
const SHUTDOWN_STAGE_TIMEOUT_MSEC: int = 30000
const SERVER_FINALIZE_DELAY_MSEC: int = 250

var _smoke_role: String = ""
var _runtime_profile
var _deadline_msec: int = 0
var _hello_sent: bool = false
var _confirmed_client_peer_id: int = 0
var _server_finalize_at_msec: int = 0
var _finished: bool = false
var _shutdown_server_ready: bool = false
var _shutdown_client_ready_sent: bool = false
var _shutdown_client_peer_id: int = 0
var _shutdown_state_prepared: bool = false
var _shutdown_dirty_snapshot_reported: bool = false
var _shutdown_close_requested: bool = false
var _shutdown_connection_lost_observed: bool = false
var _shutdown_session_closed_observed: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_disable_unrelated_services()
	_smoke_role = _get_argument_value(ROLE_ARG_PREFIX).to_lower()
	_runtime_profile = RuntimeProfile.current()
	_deadline_msec = Time.get_ticks_msec() + (
		SHUTDOWN_STAGE_TIMEOUT_MSEC
		if _smoke_role in [ROLE_SHUTDOWN_SERVER, ROLE_SHUTDOWN_CLIENT]
		else STAGE_TIMEOUT_MSEC
	)

	match _smoke_role:
		ROLE_SERVER:
			_start_server_smoke()
		ROLE_TEST_CLIENT:
			_start_test_client_smoke()
		ROLE_XR_CONFIG:
			_validate_xr_client_configuration()
		ROLE_SHUTDOWN_SERVER:
			_start_shutdown_server_smoke()
		ROLE_SHUTDOWN_CLIENT:
			_start_shutdown_client_smoke()
		_:
			_fail("Unknown runtime startup smoke role: %s" % _smoke_role)


func _process(_delta: float) -> void:
	if _finished:
		return
	var now_msec := Time.get_ticks_msec()
	if now_msec >= _deadline_msec:
		_fail("Timed out while running the %s startup smoke stage." % _smoke_role)
		return
	if _smoke_role == ROLE_TEST_CLIENT:
		_try_confirm_test_client()
	elif _smoke_role == ROLE_SHUTDOWN_SERVER:
		_process_shutdown_server()
	elif _smoke_role == ROLE_SHUTDOWN_CLIENT:
		_process_shutdown_client()
	elif _smoke_role == ROLE_SERVER \
			and _server_finalize_at_msec > 0 \
			and now_msec >= _server_finalize_at_msec:
		_succeed()


func _start_server_smoke() -> void:
	if not _runtime_profile.is_valid():
		_fail("PC Server profile is invalid: %s" % _runtime_profile.validation_error)
		return
	if not _runtime_profile.is_server() \
			or not _runtime_profile.is_ground() \
			or _runtime_profile.uses_xr() \
			or _runtime_profile.is_test_mode() \
			or _runtime_profile.get_mode_label() != "PC GROUND SERVER":
		_fail("PC Server process resolved the wrong runtime profile: %s" % _runtime_profile.get_mode_label())
		return
	if not NetworkHandler.start_server():
		_fail(NetworkHandler.get_last_start_error())
		return
	print("RUNTIME_STARTUP_SMOKE_SERVER READY")


func _start_test_client_smoke() -> void:
	if not _runtime_profile.is_valid():
		_fail("Test Client profile is invalid: %s" % _runtime_profile.validation_error)
		return
	if not _runtime_profile.is_client() \
			or not _runtime_profile.is_astronaut() \
			or not _runtime_profile.is_test_mode() \
			or _runtime_profile.uses_xr() \
			or _runtime_profile.get_mode_label() != "ASTRONAUT TEST CLIENT":
		_fail("Test Client process resolved the wrong runtime profile: %s" % _runtime_profile.get_mode_label())
		return
	if not NetworkHandler.connection_failed.is_connected(_on_connection_failed):
		NetworkHandler.connection_failed.connect(_on_connection_failed)
	if not NetworkHandler.server_connection_lost.is_connected(_on_server_connection_lost):
		NetworkHandler.server_connection_lost.connect(_on_server_connection_lost)
	if not NetworkHandler.start_client("127.0.0.1"):
		_fail(NetworkHandler.get_last_start_error())


func _start_shutdown_server_smoke() -> void:
	if not _runtime_profile.is_valid():
		_fail("Shutdown Server profile is invalid: %s" % _runtime_profile.validation_error)
		return
	if not _runtime_profile.is_server() \
			or not _runtime_profile.is_ground() \
			or _runtime_profile.uses_xr() \
			or _runtime_profile.is_test_mode() \
			or _runtime_profile.get_mode_label() != "PC GROUND SERVER":
		_fail("Shutdown Server process resolved the wrong runtime profile: %s" % _runtime_profile.get_mode_label())
		return
	if not NetworkHandler.session_closed.is_connected(_on_session_closed):
		NetworkHandler.session_closed.connect(_on_session_closed)
	if not NetworkHandler.start_server():
		_fail(NetworkHandler.get_last_start_error())
		return
	_open_arspace_with_persistent_observer()


func _start_shutdown_client_smoke() -> void:
	if not _runtime_profile.is_valid():
		_fail("Shutdown Client profile is invalid: %s" % _runtime_profile.validation_error)
		return
	if not _runtime_profile.is_client() \
			or not _runtime_profile.is_astronaut() \
			or not _runtime_profile.is_test_mode() \
			or _runtime_profile.uses_xr() \
			or _runtime_profile.get_mode_label() != "ASTRONAUT TEST CLIENT":
		_fail("Shutdown Client process resolved the wrong runtime profile: %s" % _runtime_profile.get_mode_label())
		return
	if not NetworkHandler.connection_failed.is_connected(_on_connection_failed):
		NetworkHandler.connection_failed.connect(_on_connection_failed)
	if not NetworkHandler.server_connection_lost.is_connected(_on_server_connection_lost):
		NetworkHandler.server_connection_lost.connect(_on_server_connection_lost)
	if not NetworkHandler.session_closed.is_connected(_on_session_closed):
		NetworkHandler.session_closed.connect(_on_session_closed)
	if not NetworkHandler.start_client("127.0.0.1"):
		_fail(NetworkHandler.get_last_start_error())
		return
	_open_arspace_with_persistent_observer()


func _validate_xr_client_configuration() -> void:
	# Keep the XR flags after Godot's `--` separator for this parser-only stage.
	# Passing --xr-mode to the engine would create an OpenXR session before this
	# scene starts, which is deliberately outside this smoke test.
	var configuration_args := OS.get_cmdline_user_args()
	_runtime_profile = RuntimeProfile.from_args(configuration_args, configuration_args, false)
	if not _runtime_profile.is_valid():
		_fail("XR Client profile is invalid: %s" % _runtime_profile.validation_error)
		return
	if not _runtime_profile.is_client() \
			or not _runtime_profile.is_astronaut() \
			or not _runtime_profile.uses_xr() \
			or not _runtime_profile.uses_passthrough() \
			or _runtime_profile.is_test_mode() \
			or not _runtime_profile.xr_mode_requested \
			or _runtime_profile.get_mode_label() != "ASTRONAUT XR CLIENT":
		_fail("XR Client arguments resolved the wrong runtime profile: %s" % _runtime_profile.get_mode_label())
		return
	# This smoke stage deliberately does not load XR_Main or call initialize() on
	# the OpenXR interface. It verifies only the process-level argument contract.
	_succeed()


func _open_arspace_with_persistent_observer() -> void:
	# This smoke node starts as current_scene. Detaching it lets the real scene
	# transition replace ARSpace with StartMenu without destroying the observer.
	if get_tree().current_scene == self:
		get_tree().current_scene = null
	var error := get_tree().change_scene_to_file(ARSPACE_SCENE)
	if error != OK:
		_fail("Could not open the formal ARSpace scene (error %d)." % error)


func _process_shutdown_server() -> void:
	if _shutdown_server_ready:
		return
	if not _has_connected_multiplayer_peer() or not multiplayer.is_server():
		return
	if not _is_current_scene(ARSPACE_SCENE):
		return
	_shutdown_server_ready = true
	print("RUNTIME_STARTUP_SMOKE_SHUTDOWN_SERVER READY")


func _process_shutdown_client() -> void:
	if not _shutdown_client_ready_sent:
		if not _has_connected_multiplayer_peer() \
				or NetworkHandler.get_local_assigned_role() != ROLE_ASTRONAUT \
				or not _is_current_scene(ARSPACE_SCENE):
			return
		_shutdown_client_ready_sent = true
		rpc_id(SERVER_PEER_ID, "_server_prepare_shutdown_state", ARSPACE_SCENE)
		return
	if _shutdown_state_prepared and not _shutdown_dirty_snapshot_reported:
		_try_report_dirty_shutdown_snapshot()
		return
	if not _shutdown_connection_lost_observed or not _shutdown_session_closed_observed:
		return
	if not _is_current_scene(START_MENU_SCENE):
		return
	_assert_shutdown_client_cleanup()


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_prepare_shutdown_state(client_scene_path: String) -> void:
	if _smoke_role != ROLE_SHUTDOWN_SERVER or not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID \
			or sender_id not in multiplayer.get_peers() \
			or client_scene_path != ARSPACE_SCENE \
			or not _is_current_scene(ARSPACE_SCENE) \
			or NetworkHandler.get_peer_role(sender_id) != ROLE_ASTRONAUT:
		_fail("Shutdown Server received an invalid ARSpace readiness handshake.")
		return
	_shutdown_client_peer_id = sender_id
	if not _create_dirty_shutdown_state():
		return
	rpc_id(sender_id, "_client_shutdown_state_prepared")


func _create_dirty_shutdown_state() -> bool:
	CollaborationState.request_change(
		CollaborationSchema.DOMAIN_MENU,
		CollaborationSchema.OP_SET,
		{"mode": "work", "active_tab": "tasks", "page_id": "shutdown_smoke"}
	)
	if CollaborationState.get_session_revision() <= 0 \
			or str(CollaborationState.get_state().get("menu", {}).get("mode", "")) != "work":
		_fail("Shutdown Server could not create non-empty collaboration state.")
		return false
	if not SpatialCalibrationState.confirm_point(
		Vector3(0.25, 1.0, -1.5),
		{"source": "runtime_shutdown_smoke"}
	):
		_fail("Shutdown Server could not create a calibration point.")
		return false
	if SpatialCalibrationState.get_revision() <= 0 \
			or (SpatialCalibrationState.get_state().get("confirmed_points", []) as Array).is_empty():
		_fail("Shutdown Server calibration state remained empty.")
		return false
	var descriptor := {
		"window_type": "shutdown_smoke",
		"instance_policy": "unique",
		"content_key": "runtime_shutdown_smoke",
		"shared_transform": Transform3D(Basis.IDENTITY, Vector3(0.0, 1.25, -1.5)),
		"size_m": Vector2(0.8, 0.5),
	}
	if not SpatialWindowRegistryService.register_window(descriptor):
		_fail("Shutdown Server could not register the smoke window.")
		return false
	if SpatialWindowRegistryService.get_revision() <= 0 \
			or SpatialWindowRegistryService.get_windows_snapshot().is_empty():
		_fail("Shutdown Server window registry remained empty.")
		return false
	return true


@rpc("authority", "call_remote", "reliable", 0)
func _client_shutdown_state_prepared() -> void:
	if _smoke_role != ROLE_SHUTDOWN_CLIENT \
			or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_shutdown_state_prepared = true
	CollaborationState.request_snapshot()
	SpatialCalibrationState.request_snapshot()
	SpatialWindowRegistryService.request_snapshot()


func _try_report_dirty_shutdown_snapshot() -> void:
	var collaboration_revision := CollaborationState.get_session_revision()
	var calibration_revision := SpatialCalibrationState.get_revision()
	var window_revision := SpatialWindowRegistryService.get_revision()
	var collaboration_state := CollaborationState.get_state()
	var calibration_state := SpatialCalibrationState.get_state()
	var windows := SpatialWindowRegistryService.get_windows_snapshot()
	if collaboration_revision <= 0 \
			or str(collaboration_state.get("menu", {}).get("mode", "")) != "work" \
			or calibration_revision <= 0 \
			or (calibration_state.get("confirmed_points", []) as Array).is_empty() \
			or window_revision <= 0 \
			or windows.is_empty():
		return
	_shutdown_dirty_snapshot_reported = true
	rpc_id(
		SERVER_PEER_ID,
		"_server_acknowledge_dirty_shutdown_snapshot",
		collaboration_revision,
		calibration_revision,
		window_revision
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_acknowledge_dirty_shutdown_snapshot(
	collaboration_revision: int,
	calibration_revision: int,
	window_revision: int
) -> void:
	if _smoke_role != ROLE_SHUTDOWN_SERVER or not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != _shutdown_client_peer_id \
			or collaboration_revision <= 0 \
			or calibration_revision <= 0 \
			or window_revision <= 0 \
			or collaboration_revision != CollaborationState.get_session_revision() \
			or calibration_revision != SpatialCalibrationState.get_revision() \
			or window_revision != SpatialWindowRegistryService.get_revision():
		_fail("Shutdown Server could not validate the Client dirty-state snapshot.")
		return
	rpc_id(sender_id, "_client_arm_server_shutdown")


@rpc("authority", "call_remote", "reliable", 0)
func _client_arm_server_shutdown() -> void:
	if _smoke_role != ROLE_SHUTDOWN_CLIENT \
			or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	rpc_id(SERVER_PEER_ID, "_server_close_after_client_armed")


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_close_after_client_armed() -> void:
	if _smoke_role != ROLE_SHUTDOWN_SERVER or not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != _shutdown_client_peer_id:
		_fail("Shutdown Server received the final close acknowledgement from the wrong peer.")
		return
	_shutdown_close_requested = true
	call_deferred("_close_shutdown_server")


func _close_shutdown_server() -> void:
	NetworkHandler._close_network_peer()
	if not _shutdown_session_closed_observed:
		_fail("Shutdown Server did not observe session_closed.")
		return
	if not _is_network_session_cleared():
		_fail("Shutdown Server network role state was not cleared.")
		return
	if not _are_replicated_states_cleared():
		_fail("Shutdown Server replicated state was not cleared.")
		return
	_succeed()


func _assert_shutdown_client_cleanup() -> void:
	if not _is_network_session_cleared():
		_fail("Shutdown Client network peer or role state was not cleared.")
		return
	if not _are_replicated_states_cleared():
		_fail("Shutdown Client replicated state was not cleared.")
		return
	_succeed()


func _is_network_session_cleared() -> bool:
	return multiplayer.has_multiplayer_peer() \
		and multiplayer.multiplayer_peer is OfflineMultiplayerPeer \
		and NetworkHandler.peer == null \
		and NetworkHandler.get_peer_roles().is_empty() \
		and NetworkHandler.get_ground_vr_peer_id() == 0


func _are_replicated_states_cleared() -> bool:
	var calibration_state := SpatialCalibrationState.get_state()
	return CollaborationState.get_session_revision() == 0 \
		and CollaborationState.get_state() == CollaborationSchema.make_default_state() \
		and SpatialCalibrationState.get_revision() == 0 \
		and (calibration_state.get("preview", {}) as Dictionary).is_empty() \
		and (calibration_state.get("confirmed_points", []) as Array).is_empty() \
		and SpatialWindowRegistryService.get_revision() == 0 \
		and SpatialWindowRegistryService.get_windows_snapshot().is_empty()


func _is_current_scene(scene_path: String) -> bool:
	var current_scene := get_tree().current_scene
	return current_scene != null and current_scene.scene_file_path == scene_path


func _try_confirm_test_client() -> void:
	if _hello_sent or not _has_connected_multiplayer_peer():
		return
	if NetworkHandler.get_local_assigned_role() != ROLE_ASTRONAUT:
		return
	_hello_sent = true
	rpc_id(
		SERVER_PEER_ID,
		"_server_confirm_test_client",
		_runtime_profile.get_mode_label(),
		NetworkHandler.get_local_assigned_role()
	)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_confirm_test_client(client_mode_label: String, client_role: String) -> void:
	if _smoke_role != ROLE_SERVER or not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		_fail("Server received a startup confirmation from an invalid peer.")
		return
	if client_mode_label != "ASTRONAUT TEST CLIENT" \
			or client_role != ROLE_ASTRONAUT \
			or NetworkHandler.get_peer_role(sender_id) != ROLE_ASTRONAUT \
			or NetworkHandler.get_peer_role(SERVER_PEER_ID) != ROLE_PC_GROUND:
		_fail("Server observed an invalid Test Client role configuration.")
		return
	_confirmed_client_peer_id = sender_id
	rpc_id(
		sender_id,
		"_client_receive_server_confirmation",
		_runtime_profile.get_mode_label(),
		NetworkHandler.get_peer_role(SERVER_PEER_ID)
	)


@rpc("authority", "call_remote", "reliable", 0)
func _client_receive_server_confirmation(server_mode_label: String, server_role: String) -> void:
	if _smoke_role != ROLE_TEST_CLIENT \
			or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if server_mode_label != "PC GROUND SERVER" \
			or server_role != ROLE_PC_GROUND \
			or NetworkHandler.get_local_assigned_role() != ROLE_ASTRONAUT:
		_fail("Test Client observed an invalid PC Server role configuration.")
		return
	rpc_id(SERVER_PEER_ID, "_server_receive_client_completion", ROLE_ASTRONAUT)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_receive_client_completion(client_role: String) -> void:
	if _smoke_role != ROLE_SERVER or not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != _confirmed_client_peer_id \
			or client_role != ROLE_ASTRONAUT \
			or NetworkHandler.get_peer_role(sender_id) != ROLE_ASTRONAUT:
		_fail("Server could not validate the completed Test Client handshake.")
		return
	rpc_id(sender_id, "_client_finalize_connection_smoke")


@rpc("authority", "call_remote", "reliable", 0)
func _client_finalize_connection_smoke() -> void:
	if _smoke_role != ROLE_TEST_CLIENT \
			or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	rpc_id(SERVER_PEER_ID, "_server_finalize_connection_smoke")


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_finalize_connection_smoke() -> void:
	if _smoke_role != ROLE_SERVER or not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id != _confirmed_client_peer_id:
		_fail("Server received the final startup acknowledgement from the wrong peer.")
		return
	rpc_id(sender_id, "_client_startup_smoke_passed")
	_server_finalize_at_msec = Time.get_ticks_msec() + SERVER_FINALIZE_DELAY_MSEC


@rpc("authority", "call_remote", "reliable", 0)
func _client_startup_smoke_passed() -> void:
	if _smoke_role != ROLE_TEST_CLIENT \
			or multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_succeed()


func _on_connection_failed(reason: String) -> void:
	_fail("Client connection failed: %s" % reason)


func _on_server_connection_lost() -> void:
	if _smoke_role == ROLE_SHUTDOWN_CLIENT:
		_shutdown_connection_lost_observed = true
		return
	if not _finished:
		_fail("PC Server disconnected before the startup handshake completed.")


func _on_session_closed() -> void:
	if _smoke_role == ROLE_SHUTDOWN_CLIENT:
		_shutdown_session_closed_observed = true
	elif _smoke_role == ROLE_SHUTDOWN_SERVER and _shutdown_close_requested:
		_shutdown_session_closed_observed = true


func _has_connected_multiplayer_peer() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _disable_unrelated_services() -> void:
	for service_name in ["VoiceChat", "LLMAssistantService", "OrbitalManager"]:
		var service := get_tree().root.get_node_or_null(service_name)
		if service != null:
			service.process_mode = Node.PROCESS_MODE_DISABLED


func _get_argument_value(prefix: String) -> String:
	for value in OS.get_cmdline_user_args():
		var argument := str(value)
		if argument.begins_with(prefix):
			return argument.substr(prefix.length()).strip_edges()
	for value in OS.get_cmdline_args():
		var argument := str(value)
		if argument.begins_with(prefix):
			return argument.substr(prefix.length()).strip_edges()
	return ""


func _succeed() -> void:
	if _finished:
		return
	_finished = true
	print("RUNTIME_STARTUP_SMOKE_%s PASS" % _smoke_role.to_upper())
	get_tree().quit(0)


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("RUNTIME_STARTUP_SMOKE_%s: %s" % [_smoke_role.to_upper(), message])
	get_tree().quit(1)
