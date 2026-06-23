extends Node3D

const TEST_MODE_ARG: String = "--testmode"
const XR_CLIENT_ARG: String = "--xr-client"
const VOICE_ROLE_ARG: String = "--voice-role="
const XR_MODE_ARG: String = "--xr-mode"
const TEST_PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const TEST_PLAYER_DEFAULT_ID: int = 1
const TEST_LEFT_HAND_OFFSET: Vector3 = Vector3(-0.28, -0.22, -0.45)
const TEST_RIGHT_HAND_OFFSET: Vector3 = Vector3(0.28, -0.22, -0.45)
const PASSTHROUGH_REFRESH_INTERVAL_MS: int = 1000

var xr_interface: XRInterface

@onready var spectator_camera: Camera3D = $SpectatorCamera
@onready var preview_container: SubViewportContainer = $UI/SubViewportContainer
@export var subUI: Camera3D

## 是否启用MR透视模式（打开后可同时看到现实世界和虚拟物体）
@export var enable_passthrough: bool = true

var is_test_mode: bool = false
var passthrough_api_started: bool = false
var passthrough_refresh_ms: int = 0

func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")

	if _has_launch_arg(TEST_MODE_ARG):
		print("Starting in test mode (no XR)")
		is_test_mode = true

	if NetworkHandler.has_signal("network_role_selected") and not NetworkHandler.network_role_selected.is_connected(_on_network_role_selected):
		NetworkHandler.network_role_selected.connect(_on_network_role_selected)

	_update_preview_container_visibility()

	if _is_server_runtime_instance() or is_test_mode:
		_enter_server_runtime()
	else:
		_enter_vr_client_runtime()

func _on_network_role_selected(is_server_role: bool) -> void:
	if is_server_role:
		_enter_server_runtime()
	else:
		_enter_vr_client_runtime()


func _enter_server_runtime() -> void:
	if not _is_vr_client_runtime_instance():
		NetworkHandler.shutdown_xr_for_server()
		passthrough_api_started = false
	_ensure_spectator_camera_current()
	if is_test_mode:
		call_deferred("_ensure_test_player")


func _enter_vr_client_runtime() -> void:
	if spectator_camera != null:
		spectator_camera.current = false

	if xr_interface == null:
		xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface == null:
		push_warning("OpenXR interface not found for VR client.")
		return
	if not _ensure_openxr_initialized():
		push_warning("OpenXR not initialized, please check if your headset is connected.")
		return

	print("OpenXR initialized successfully")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_tree().root.use_xr = true
	get_viewport().use_xr = true

	if enable_passthrough:
		_ensure_passthrough_active()


func _ensure_openxr_initialized() -> bool:
	if xr_interface == null:
		return false
	if xr_interface.is_initialized():
		return true

	return xr_interface.initialize()


## 启动MR透视模式
func _start_passthrough() -> bool:
	return _ensure_passthrough_active()
	if not xr_interface:
		push_warning("MR透视: XR接口未初始化")
		return false

	# 方式1: 尝试使用 environment_blend_mode (Godot 4.3+ 推荐方式)
	# XR_ENV_BLEND_MODE_ALPHA_BLEND = 2，适用于MR透视
	var supported_blend_modes = xr_interface.get_supported_environment_blend_modes()
	print("MR透视: 支持的混合模式 = ", supported_blend_modes)

	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in supported_blend_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		get_viewport().transparent_bg = true
		print("MR透视: 已通过 environment_blend_mode (ALPHA_BLEND) 启用")
		return true

	# 方式2: 回退到 passthrough API
	if xr_interface.is_passthrough_supported():
		if xr_interface.start_passthrough():
			get_viewport().transparent_bg = true
			print("MR透视: 已通过 passthrough API 启用")
			return true
		else:
			push_warning("MR透视: start_passthrough() 失败")
	else:
		push_warning("MR透视: 设备不支持透视功能")

	return false


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
	if not enabled:
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
	get_tree().root.transparent_bg = false
	get_viewport().transparent_bg = false
	print("MR透视: 已关闭")

func _process(_delta: float) -> void:
	_update_preview_container_visibility()

	if _is_vr_client_runtime_instance():
		_refresh_vr_client_passthrough()
		return

	if _is_server_runtime_instance() or is_test_mode:
		_ensure_spectator_camera_current()
		if is_test_mode:
			_ensure_test_player()
			_sync_test_player_from_spectator()
		_update_preview_camera()

func _has_launch_arg(target: String) -> bool:
	var args := []
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args.has(target)

func _get_launch_arg_value(prefix: String) -> String:
	for arg in _get_all_launch_args():
		var value := str(arg)
		if value.begins_with(prefix):
			return value.substr(prefix.length()).strip_edges()
	return ""

func _get_all_launch_args() -> Array:
	var args := []
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())
	return args

func _update_preview_container_visibility() -> void:
	if preview_container == null:
		return
	preview_container.visible = not _is_testmode_client_instance()

func _is_testmode_client_instance() -> bool:
	if not is_test_mode:
		return false
	if _is_client_launch_mode():
		return true
	return multiplayer.has_multiplayer_peer() and not multiplayer.is_server()


func _is_vr_client_runtime_instance() -> bool:
	if is_test_mode:
		return _is_testmode_client_instance()
	if _is_client_launch_mode():
		return true
	return multiplayer.has_multiplayer_peer() and not multiplayer.is_server()


func _is_server_runtime_instance() -> bool:
	if is_test_mode:
		return not _is_testmode_client_instance()
	if _is_client_launch_mode():
		return false
	if multiplayer.has_multiplayer_peer():
		return multiplayer.is_server()
	return true


func _refresh_vr_client_passthrough() -> void:
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - passthrough_refresh_ms < PASSTHROUGH_REFRESH_INTERVAL_MS:
		return

	passthrough_refresh_ms = now_ms
	get_tree().root.use_xr = true
	get_viewport().use_xr = true
	if enable_passthrough:
		_ensure_passthrough_active()

func _is_client_launch_mode() -> bool:
	var role := _get_launch_arg_value(VOICE_ROLE_ARG).to_lower()
	if role == "client" or role == "vr":
		return true
	if role == "server" or role == "pc":
		return false
	if _has_launch_arg(XR_CLIENT_ARG):
		return true
	return _has_xr_mode_on_arg()

func _has_xr_mode_on_arg() -> bool:
	var args := _get_all_launch_args()
	for i in range(args.size()):
		var arg := str(args[i]).to_lower()
		if arg == XR_MODE_ARG and i + 1 < args.size():
			return str(args[i + 1]).to_lower() == "on"
		if arg.begins_with(XR_MODE_ARG + "="):
			return arg.get_slice("=", 1).to_lower() == "on"
	return false

func _ensure_spectator_camera_current() -> void:
	if spectator_camera != null and not spectator_camera.is_current():
		spectator_camera.make_current()

func _ensure_test_player() -> void:
	if not is_test_mode or not _should_create_local_test_player():
		return

	var player_name := str(_get_local_player_id())
	if get_node_or_null(player_name) != null:
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

	for peer_id in _get_remote_client_peer_ids():
		var player := get_node_or_null(str(peer_id))
		if player == null:
			continue

		var network_head := player.get_node_or_null("NetworkHead") as Node3D
		if network_head != null and network_head.visible:
			return network_head

		var camera := player.get_node_or_null("XROrigin3D/XRCamera3D") as Camera3D
		if camera != null and camera.visible:
			return camera

	return null

func _get_remote_client_peer_ids() -> Array:
	var ids := []
	for peer_id in multiplayer.get_peers():
		var id := int(peer_id)
		if id != _get_local_player_id():
			ids.append(id)
	ids.sort()
	return ids
