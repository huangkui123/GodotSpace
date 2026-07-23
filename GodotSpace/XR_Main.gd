extends Node3D

const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const TEST_PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const TEST_PLAYER_DEFAULT_ID: int = 1
const TEST_LEFT_HAND_OFFSET: Vector3 = Vector3(-0.28, -0.22, -0.45)
const TEST_RIGHT_HAND_OFFSET: Vector3 = Vector3(0.28, -0.22, -0.45)
const PASSTHROUGH_REFRESH_INTERVAL_MS: int = 1000
const XR_RETRY_INTERVAL_MS: int = 2000

var xr_interface: XRInterface
var runtime_profile

@onready var spectator_camera: Camera3D = $SpectatorCamera
@onready var preview_container: SubViewportContainer = $UI/SubViewportContainer
@export var subUI: Camera3D

## 是否启用MR透视模式（打开后可同时看到现实世界和虚拟物体）
@export var enable_passthrough: bool = true

var is_test_mode: bool = false
var xr_runtime_active: bool = false
var xr_retry_after_ms: int = 0
var last_xr_failure_reason: String = ""
var passthrough_api_started: bool = false
var passthrough_refresh_ms: int = 0
var passthrough_supported_modes_logged: bool = false
var passthrough_unavailable_warned: bool = false

func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	runtime_profile = RuntimeProfile.current()
	if not runtime_profile.is_valid():
		push_error("Invalid runtime profile: %s" % runtime_profile.validation_error)
		set_process(false)
		return

	is_test_mode = runtime_profile.is_test_mode()
	if is_test_mode:
		print("Starting in test mode (no XR)")

	if NetworkHandler.has_signal("network_role_selected") and not NetworkHandler.network_role_selected.is_connected(_on_network_role_selected):
		NetworkHandler.network_role_selected.connect(_on_network_role_selected)

	_update_preview_container_visibility()
	_apply_runtime_profile()


func _exit_tree() -> void:
	_shutdown_openxr()

func _on_network_role_selected(is_server_role: bool) -> void:
	if not runtime_profile.has_explicit_mode:
		var preset := RuntimeProfile.Preset.PC_GROUND_SERVER \
			if is_server_role \
			else RuntimeProfile.Preset.SKY_XR_CLIENT
		runtime_profile = RuntimeProfile.select_session_mode(preset)
	elif runtime_profile.is_server() != is_server_role:
		push_error("Network role does not match runtime profile %s" % runtime_profile.get_mode_label())
		return
	_apply_runtime_profile()


func _apply_runtime_profile() -> void:
	if runtime_profile.uses_xr():
		_enter_xr_runtime()
	else:
		_enter_desktop_runtime()


func _enter_desktop_runtime() -> void:
	xr_runtime_active = false
	_shutdown_openxr()
	_ensure_spectator_camera_current()
	if is_test_mode:
		call_deferred("_ensure_test_player")


func _enter_xr_runtime() -> void:
	if spectator_camera != null:
		spectator_camera.current = false

	if xr_interface == null:
		xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null:
		_fallback_to_spectator("OpenXR interface not found for %s." % runtime_profile.get_mode_label())
		return
	if not _ensure_openxr_initialized():
		_fallback_to_spectator("OpenXR not initialized, please check if your headset is connected.")
		return

	print("OpenXR initialized successfully")
	xr_runtime_active = true
	xr_retry_after_ms = 0
	last_xr_failure_reason = ""
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_tree().root.use_xr = true
	get_viewport().use_xr = true

	if runtime_profile.uses_passthrough() and enable_passthrough:
		_ensure_passthrough_active()
	else:
		_ensure_opaque_environment()


func _shutdown_openxr() -> void:
	xr_runtime_active = false
	xr_retry_after_ms = 0
	last_xr_failure_reason = ""
	get_tree().root.use_xr = false
	get_viewport().use_xr = false
	get_tree().root.transparent_bg = false
	get_viewport().transparent_bg = false
	if xr_interface != null and xr_interface.is_initialized():
		_stop_passthrough()
		xr_interface.uninitialize()
	passthrough_api_started = false
	passthrough_supported_modes_logged = false
	passthrough_unavailable_warned = false


func _ensure_opaque_environment() -> void:
	if xr_interface == null or not xr_interface.is_initialized():
		return
	var supported_blend_modes: Array = xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in supported_blend_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
	if passthrough_api_started:
		xr_interface.stop_passthrough()
	passthrough_api_started = false
	get_tree().root.transparent_bg = false
	get_viewport().transparent_bg = false


func _ensure_openxr_initialized() -> bool:
	if xr_interface == null:
		return false
	if xr_interface.is_initialized():
		return true

	return xr_interface.initialize()


## 启动MR透视模式
func _start_passthrough() -> bool:
	return _ensure_passthrough_active()


## 停止MR透视模式
func _ensure_passthrough_active() -> bool:
	if xr_interface == null:
		push_warning("MR passthrough: OpenXR interface is not ready")
		return false
	if not _ensure_openxr_initialized():
		push_warning("MR passthrough: OpenXR initialization failed")
		return false

	var enabled: bool = false
	var supported_blend_modes: Array = xr_interface.get_supported_environment_blend_modes()
	if not passthrough_supported_modes_logged:
		passthrough_supported_modes_logged = true
		print("MR passthrough supported blend modes = ", supported_blend_modes)

	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in supported_blend_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		enabled = true

	if xr_interface.is_passthrough_supported():
		if not passthrough_api_started:
			passthrough_api_started = xr_interface.start_passthrough()
		enabled = enabled or passthrough_api_started

	get_tree().root.use_xr = true
	get_viewport().use_xr = true
	get_tree().root.transparent_bg = enabled
	get_viewport().transparent_bg = enabled
	if enabled:
		passthrough_unavailable_warned = false
	elif not passthrough_unavailable_warned:
		passthrough_unavailable_warned = true
		push_warning("MR passthrough is unavailable on this OpenXR runtime")
	return enabled


func _stop_passthrough() -> void:
	if not xr_interface:
		return

	# 恢复为不透明VR模式
	var supported_blend_modes: Array = xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in supported_blend_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE

	xr_interface.stop_passthrough()
	passthrough_api_started = false
	passthrough_supported_modes_logged = false
	passthrough_unavailable_warned = false
	get_tree().root.transparent_bg = false
	get_viewport().transparent_bg = false
	print("MR透视: 已关闭")

func _process(_delta: float) -> void:
	_update_preview_container_visibility()

	if runtime_profile.uses_xr():
		if xr_runtime_active:
			_refresh_xr_environment()
		else:
			_ensure_spectator_camera_current()
			if Time.get_ticks_msec() >= xr_retry_after_ms:
				_enter_xr_runtime()
		return

	_ensure_spectator_camera_current()
	if is_test_mode:
		_ensure_test_player()
		_sync_test_player_from_spectator()
	if runtime_profile.is_server():
		_update_preview_camera()

func _update_preview_container_visibility() -> void:
	if preview_container == null:
		return
	preview_container.visible = runtime_profile.uses_desktop_ui() and runtime_profile.is_server()


func _refresh_xr_environment() -> void:
	if xr_interface == null or not xr_interface.is_initialized():
		_fallback_to_spectator("OpenXR runtime became unavailable. Waiting to retry.")
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - passthrough_refresh_ms < PASSTHROUGH_REFRESH_INTERVAL_MS:
		return

	passthrough_refresh_ms = now_ms
	get_tree().root.use_xr = true
	get_viewport().use_xr = true
	if runtime_profile.uses_passthrough() and enable_passthrough:
		_ensure_passthrough_active()
	else:
		_ensure_opaque_environment()

func _ensure_spectator_camera_current() -> void:
	if spectator_camera != null and not spectator_camera.is_current():
		spectator_camera.make_current()


func _fallback_to_spectator(reason: String) -> void:
	xr_runtime_active = false
	xr_retry_after_ms = Time.get_ticks_msec() + XR_RETRY_INTERVAL_MS
	get_tree().root.use_xr = false
	get_viewport().use_xr = false
	get_tree().root.transparent_bg = false
	get_viewport().transparent_bg = false
	_ensure_spectator_camera_current()
	if reason != last_xr_failure_reason:
		last_xr_failure_reason = reason
		push_warning(reason)

func _ensure_test_player() -> void:
	if not is_test_mode or not _should_create_local_test_player():
		return

	var player_name := str(_get_local_player_id())
	if get_node_or_null(player_name) != null:
		return
	var spawner := get_node_or_null("MultiplayerSpawner")
	if spawner != null and spawner.has_method("spawn_player"):
		spawner.call("spawn_player", _get_local_player_id())
		return

	var player := TEST_PLAYER_SCENE.instantiate()
	player.name = player_name
	add_child(player)

func _should_create_local_test_player() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()

func _get_local_player_id() -> int:
	if multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return TEST_PLAYER_DEFAULT_ID

func _sync_test_player_from_spectator() -> void:
	if spectator_camera == null:
		return

	var player := get_node_or_null(str(_get_local_player_id())) as Node3D
	if player == null:
		return

	var xr_camera := player.get_node_or_null("XROrigin3D/XRCamera3D") as Node3D
	if xr_camera == null:
		return

	xr_camera.global_transform = spectator_camera.global_transform
	_sync_test_hand(player, "XROrigin3D/LeftHand", TEST_LEFT_HAND_OFFSET)
	_sync_test_hand(player, "XROrigin3D/RightHand", TEST_RIGHT_HAND_OFFSET)

func _sync_test_hand(player: Node3D, hand_path: NodePath, local_offset: Vector3) -> void:
	var hand := player.get_node_or_null(hand_path) as Node3D
	if hand == null or spectator_camera == null:
		return

	var hand_transform := spectator_camera.global_transform
	hand_transform.origin += spectator_camera.global_transform.basis * local_offset
	hand.global_transform = hand_transform

func _update_preview_camera() -> void:
	if subUI == null:
		return

	var source_node := _get_preview_source_node()
	if source_node != null:
		subUI.global_transform = source_node.global_transform

func _get_preview_source_node() -> Node3D:
	var remote_client_view := _get_remote_client_view_node()
	if remote_client_view != null:
		return remote_client_view

	if is_test_mode:
		var player := get_node_or_null(str(_get_local_player_id()))
		if player != null:
			var test_camera := player.get_node_or_null("XROrigin3D/XRCamera3D") as Camera3D
			if test_camera != null:
				return test_camera
		return spectator_camera

	return find_child("XRCamera3D", true, false) as Camera3D

func _get_remote_client_view_node() -> Node3D:
	if not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return null

	var sky_peer_id := _get_sky_peer_id()
	if sky_peer_id <= 0:
		return null
	var player := get_node_or_null(str(sky_peer_id))
	if player == null:
		return null

	var network_head := player.get_node_or_null("NetworkHead") as Node3D
	if network_head != null and network_head.visible:
		return network_head

	var camera := player.get_node_or_null("XROrigin3D/XRCamera3D") as Camera3D
	if camera != null and camera.visible:
		return camera

	return null

func _get_sky_peer_id() -> int:
	if NetworkHandler != null and NetworkHandler.has_method("get_sky_peer_id"):
		return int(NetworkHandler.call("get_sky_peer_id"))
	return 0
