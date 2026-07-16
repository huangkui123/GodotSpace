extends Node

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

const ROLE_ARG_PREFIX := "--runtime-startup-smoke-role="
const ROLE_SERVER := "server"
const ROLE_TEST_CLIENT := "test_client"
const ROLE_XR_CONFIG := "xr_config"
const SERVER_PEER_ID: int = 1
const ROLE_PC_GROUND := "pc_ground"
const ROLE_ASTRONAUT := "astronaut"
const STAGE_TIMEOUT_MSEC: int = 12000
const SERVER_FINALIZE_DELAY_MSEC: int = 250

var _smoke_role: String = ""
var _runtime_profile
var _deadline_msec: int = 0
var _hello_sent: bool = false
var _confirmed_client_peer_id: int = 0
var _server_finalize_at_msec: int = 0
var _finished: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_disable_unrelated_services()
	_smoke_role = _get_argument_value(ROLE_ARG_PREFIX).to_lower()
	_runtime_profile = RuntimeProfile.current()
	_deadline_msec = Time.get_ticks_msec() + STAGE_TIMEOUT_MSEC

	match _smoke_role:
		ROLE_SERVER:
			_start_server_smoke()
		ROLE_TEST_CLIENT:
			_start_test_client_smoke()
		ROLE_XR_CONFIG:
			_validate_xr_client_configuration()
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
	_fail("Test Client connection failed: %s" % reason)


func _on_server_connection_lost() -> void:
	if not _finished:
		_fail("PC Server disconnected before the startup handshake completed.")


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
