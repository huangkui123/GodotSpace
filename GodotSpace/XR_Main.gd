extends Node3D

const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const TEST_PLAYER_SCENE: PackedScene = preload("res://Assets/ARSpace/Scenes/Player.tscn")
const TEST_PLAYER_DEFAULT_ID: int = 1
const TEST_LEFT_HAND_OFFSET: Vector3 = Vector3(-0.28, -0.22, -0.45)
const TEST_RIGHT_HAND_OFFSET: Vector3 = Vector3(0.28, -0.22, -0.45)
const PASSTHROUGH_REFRESH_INTERVAL_MS: int = 1000
const XR_RETRY_INTERVAL_MS: int = 2000
const XR_PRESS_THRESHOLD: float = 0.65
const MAIN_PANEL_TOGGLE_DEBOUNCE_MS: int = 180
const VIRTUAL_ANNOTATION_SETTING: StringName = &"arspace/virtual_annotation_enabled"
const VIRTUAL_ANNOTATION_SCENE_PATH: String = \
	"res://Assets/ARSpace/Scenes/VirtualAnnotationSystem.tscn"
const SKY_OBJECT_OPACITY: float = 0.5
const SKY_PANEL_UI_OPACITY: float = 0.8
const SKY_BOUNDARY_SURFACE_OPACITY: float = 0.25
const SKY_BOUNDARY_SURFACE_NAMES: Array[StringName] = [
	&"DownPlane",
	&"BackDor",
]
const SKY_TRANSPARENCY_STATE_META: StringName = \
	&"_arspace_sky_transparency_state"
const SKY_TRANSPARENCY_EXEMPT_GROUPS: Array[StringName] = [
	&"reconstruction_point_cloud_chunks",
]

var xr_interface: XRInterface
var runtime_profile

@onready var spectator_camera: Camera3D = $SpectatorCamera
@onready var preview_container: SubViewportContainer = $UI/SubViewportContainer
@export var subUI: Camera3D

## 是否启用 MR 透传模式（打开后可同时看到现实世界和虚拟物体）
@export var enable_passthrough: bool = true

var is_test_mode: bool = false
var xr_runtime_active: bool = false
var xr_retry_after_ms: int = 0
var last_xr_failure_reason: String = ""
var passthrough_api_started: bool = false
var passthrough_refresh_ms: int = 0
var passthrough_supported_modes_logged: bool = false
var passthrough_unavailable_warned: bool = false
var _last_right_a_pressed: bool = false
var _last_main_panel_toggle_ms: int = -MAIN_PANEL_TOGGLE_DEBOUNCE_MS
var _sky_geometry_transparency_enabled: bool = false
var _sky_transparent_material_cache: Dictionary = {}


func _enter_tree() -> void:
	runtime_profile = RuntimeProfile.current()
	_configure_virtual_annotation_system()

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
	if not get_tree().node_added.is_connected(_on_scene_node_added):
		get_tree().node_added.connect(_on_scene_node_added)

	_update_preview_container_visibility()
	_apply_runtime_profile()


func _exit_tree() -> void:
	_set_sky_geometry_transparency(false)
	if get_tree().node_added.is_connected(_on_scene_node_added):
		get_tree().node_added.disconnect(_on_scene_node_added)
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
	_configure_virtual_annotation_system()
	_apply_runtime_profile()


func _apply_runtime_profile() -> void:
	_configure_spacebox_rendering()
	_configure_scene_geometry_rendering()
	if runtime_profile.uses_xr():
		_enter_xr_runtime()
	else:
		_enter_desktop_runtime()


func _configure_spacebox_rendering() -> void:
	var spacebox := get_node_or_null("SpaceBox")
	if spacebox != null and spacebox.has_method(
		"configure_for_runtime_profile"
	):
		spacebox.call(
			"configure_for_runtime_profile",
			runtime_profile
		)


func _configure_scene_geometry_rendering() -> void:
	_set_sky_geometry_transparency(
		runtime_profile != null
		and runtime_profile.is_valid()
		and runtime_profile.is_sky()
		and runtime_profile.uses_xr()
	)


func _set_sky_geometry_transparency(enabled: bool) -> void:
	_sky_geometry_transparency_enabled = enabled
	if enabled:
		_apply_sky_transparency_to_subtree(self)
	else:
		_restore_geometry_transparency_in_subtree(self)
		_sky_transparent_material_cache.clear()


func _apply_sky_transparency_to_subtree(root: Node) -> void:
	if not is_instance_valid(root):
		return
	if _is_sky_transparency_exempt(root):
		return
	if root is MeshInstance3D:
		_apply_sky_mesh_transparency(root as MeshInstance3D)
	elif root is Label3D:
		_apply_sky_label_transparency(root as Label3D)
	elif root is SpriteBase3D:
		_apply_sky_sprite_transparency(root as SpriteBase3D)
	for child in root.get_children():
		_apply_sky_transparency_to_subtree(child)


func _is_sky_transparency_exempt(node: Node) -> bool:
	var current := node
	while current != null:
		for group_name in SKY_TRANSPARENCY_EXEMPT_GROUPS:
			if current.is_in_group(group_name):
				return true
		if current == self:
			break
		current = current.get_parent()
	return false


func _restore_geometry_transparency_in_subtree(root: Node) -> void:
	if not is_instance_valid(root):
		return
	if root is MeshInstance3D:
		_restore_sky_mesh_transparency(root as MeshInstance3D)
	elif root is Label3D:
		_restore_sky_label_transparency(root as Label3D)
	elif root is SpriteBase3D:
		_restore_sky_sprite_transparency(root as SpriteBase3D)
	for child in root.get_children():
		_restore_geometry_transparency_in_subtree(child)


func _apply_sky_mesh_transparency(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance.has_meta(SKY_TRANSPARENCY_STATE_META):
		return

	var object_opacity := _get_sky_mesh_opacity(mesh_instance)
	var state := {
		"material_override": mesh_instance.material_override,
		"surface_overrides": [],
	}
	var source_override := mesh_instance.material_override
	if source_override != null:
		var transparent_override := _get_sky_transparent_material(
			source_override,
			object_opacity
		)
		if transparent_override == source_override:
			return
		mesh_instance.set_meta(SKY_TRANSPARENCY_STATE_META, state)
		mesh_instance.material_override = transparent_override
		return

	if mesh_instance.mesh == null:
		return
	var surface_count := mesh_instance.mesh.get_surface_count()
	if surface_count <= 0:
		return
	var original_surface_overrides: Array = state["surface_overrides"]
	var transparent_surfaces: Array[Material] = []
	for surface_index in range(surface_count):
		original_surface_overrides.append(
			mesh_instance.get_surface_override_material(surface_index)
		)
		transparent_surfaces.append(_get_sky_transparent_material(
			mesh_instance.get_active_material(surface_index),
			object_opacity
		))
	mesh_instance.set_meta(SKY_TRANSPARENCY_STATE_META, state)
	for surface_index in range(surface_count):
		mesh_instance.set_surface_override_material(
			surface_index,
			transparent_surfaces[surface_index]
		)


func _get_sky_mesh_opacity(mesh_instance: MeshInstance3D) -> float:
	var current: Node = mesh_instance
	while current != null and current != self:
		if current.name in SKY_BOUNDARY_SURFACE_NAMES:
			return SKY_BOUNDARY_SURFACE_OPACITY
		current = current.get_parent()
	return SKY_OBJECT_OPACITY


func _restore_sky_mesh_transparency(mesh_instance: MeshInstance3D) -> void:
	if not mesh_instance.has_meta(SKY_TRANSPARENCY_STATE_META):
		return
	var state := mesh_instance.get_meta(
		SKY_TRANSPARENCY_STATE_META
	) as Dictionary
	mesh_instance.material_override = state.get("material_override") as Material
	var original_surface_overrides := state.get(
		"surface_overrides",
		[]
	) as Array
	for surface_index in range(original_surface_overrides.size()):
		mesh_instance.set_surface_override_material(
			surface_index,
			original_surface_overrides[surface_index] as Material
		)
	mesh_instance.remove_meta(SKY_TRANSPARENCY_STATE_META)


func _apply_sky_label_transparency(label: Label3D) -> void:
	if label.has_meta(SKY_TRANSPARENCY_STATE_META):
		return
	label.set_meta(SKY_TRANSPARENCY_STATE_META, {
		"modulate": label.modulate,
		"outline_modulate": label.outline_modulate,
	})
	var label_modulate := label.modulate
	label_modulate.a *= SKY_OBJECT_OPACITY
	label.modulate = label_modulate
	var outline_modulate := label.outline_modulate
	outline_modulate.a *= SKY_OBJECT_OPACITY
	label.outline_modulate = outline_modulate


func _restore_sky_label_transparency(label: Label3D) -> void:
	if not label.has_meta(SKY_TRANSPARENCY_STATE_META):
		return
	var state := label.get_meta(SKY_TRANSPARENCY_STATE_META) as Dictionary
	label.modulate = state.get("modulate", Color.WHITE) as Color
	label.outline_modulate = state.get(
		"outline_modulate",
		Color.BLACK
	) as Color
	label.remove_meta(SKY_TRANSPARENCY_STATE_META)


func _apply_sky_sprite_transparency(sprite: SpriteBase3D) -> void:
	if sprite.has_meta(SKY_TRANSPARENCY_STATE_META):
		return
	sprite.set_meta(SKY_TRANSPARENCY_STATE_META, {
		"modulate": sprite.modulate,
	})
	var sprite_modulate := sprite.modulate
	sprite_modulate.a *= SKY_OBJECT_OPACITY
	sprite.modulate = sprite_modulate


func _restore_sky_sprite_transparency(sprite: SpriteBase3D) -> void:
	if not sprite.has_meta(SKY_TRANSPARENCY_STATE_META):
		return
	var state := sprite.get_meta(SKY_TRANSPARENCY_STATE_META) as Dictionary
	sprite.modulate = state.get("modulate", Color.WHITE) as Color
	sprite.remove_meta(SKY_TRANSPARENCY_STATE_META)


func _get_sky_transparent_material(
	source: Material,
	object_opacity: float = SKY_OBJECT_OPACITY
) -> Material:
	var source_id: int = 0 if source == null else source.get_instance_id()
	var cache_key := "%d:%.4f" % [source_id, object_opacity]
	if _sky_transparent_material_cache.has(cache_key):
		return _sky_transparent_material_cache[cache_key] as Material

	var transparent_material: Material
	if source == null:
		var default_material := StandardMaterial3D.new()
		default_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		default_material.albedo_color = Color(
			1.0,
			1.0,
			1.0,
			object_opacity
		)
		transparent_material = default_material
	elif source is BaseMaterial3D:
		var source_base_material := source as BaseMaterial3D
		var source_was_opaque := (
			source_base_material.transparency
			== BaseMaterial3D.TRANSPARENCY_DISABLED
		)
		# Keep live ViewportTexture and other runtime texture references intact.
		# Deep duplication breaks relative viewport paths and renders magenta.
		var base_material := source.duplicate(false) as BaseMaterial3D
		base_material.resource_local_to_scene = true
		base_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var albedo_color := base_material.albedo_color
		var target_opacity := (
			SKY_PANEL_UI_OPACITY
			if source_base_material.albedo_texture is ViewportTexture
			else object_opacity
		)
		# Opaque imported materials can contain arbitrary ignored alpha values.
		# Give those a stable role-specific opacity instead of multiplying stale alpha.
		albedo_color.a = (
			target_opacity
			if source_was_opaque
			else albedo_color.a * target_opacity
		)
		base_material.albedo_color = albedo_color
		transparent_material = base_material
	elif source is ShaderMaterial:
		transparent_material = _make_sky_transparent_shader_material(
			source as ShaderMaterial,
			object_opacity
		)
	else:
		transparent_material = source

	_sky_transparent_material_cache[cache_key] = transparent_material
	return transparent_material


func _make_sky_transparent_shader_material(
	source: ShaderMaterial,
	object_opacity: float
) -> ShaderMaterial:
	var transparent_material := source.duplicate(false) as ShaderMaterial
	transparent_material.resource_local_to_scene = true
	if transparent_material.shader == null:
		return transparent_material
	for uniform_info in transparent_material.shader.get_shader_uniform_list():
		var uniform_name := StringName(uniform_info.get("name", ""))
		var uniform_type := int(uniform_info.get("type", TYPE_NIL))
		var value = transparent_material.get_shader_parameter(uniform_name)
		if uniform_type == TYPE_COLOR and value is Color:
			var color := value as Color
			color.a *= object_opacity
			transparent_material.set_shader_parameter(uniform_name, color)
		elif uniform_type == TYPE_FLOAT \
				and str(uniform_name).to_lower() in [
					"alpha",
					"opacity",
					"arspace_opacity",
				]:
			var opacity_value: float = (
				float(value)
				if value is float or value is int
				else 1.0
			)
			transparent_material.set_shader_parameter(
				uniform_name,
				opacity_value * object_opacity
			)
	return transparent_material


func _on_scene_node_added(node: Node) -> void:
	if node != self and not is_ancestor_of(node):
		return
	call_deferred("_refresh_scene_geometry_subtree", node)


func _refresh_scene_geometry_subtree(root: Node) -> void:
	if not is_instance_valid(root):
		return
	if root != self and not is_ancestor_of(root):
		return
	if _sky_geometry_transparency_enabled:
		_apply_sky_transparency_to_subtree(root)
	else:
		_restore_geometry_transparency_in_subtree(root)


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
	if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in supported_blend_modes \
			and xr_interface.environment_blend_mode != XRInterface.XR_ENV_BLEND_MODE_OPAQUE:
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


## 启动 MR 透传模式
func _start_passthrough() -> bool:
	return _ensure_passthrough_active()


## 确保 MR 透传模式已启用
func _ensure_passthrough_active() -> bool:
	if xr_interface == null:
		push_warning("MR passthrough: OpenXR interface is not ready")
		return false
	if not _ensure_openxr_initialized():
		push_warning("MR passthrough: OpenXR initialization failed")
		return false

	var supported_blend_modes: Array = xr_interface.get_supported_environment_blend_modes()
	var should_log_configuration := not passthrough_supported_modes_logged
	if should_log_configuration:
		passthrough_supported_modes_logged = true
		print("MR passthrough supported blend modes = ", supported_blend_modes)

	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in supported_blend_modes:
		if xr_interface.environment_blend_mode != XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND:
			xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		_configure_passthrough_background(true)
		_set_xr_background_transparent(true)
		passthrough_unavailable_warned = false
		if should_log_configuration:
			print("MR passthrough active: alpha blend")
		return true

	if XRInterface.XR_ENV_BLEND_MODE_ADDITIVE in supported_blend_modes:
		if xr_interface.environment_blend_mode != XRInterface.XR_ENV_BLEND_MODE_ADDITIVE:
			xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ADDITIVE
		_configure_passthrough_background(false)
		_set_xr_background_transparent(false)
		passthrough_unavailable_warned = false
		if should_log_configuration:
			print("MR passthrough active: additive blend")
		return true

	if xr_interface.is_passthrough_supported():
		_configure_passthrough_background(true)
		_set_xr_background_transparent(true)
		if not passthrough_api_started:
			passthrough_api_started = xr_interface.start_passthrough()
		if passthrough_api_started:
			passthrough_unavailable_warned = false
			if should_log_configuration:
				print("MR passthrough active: legacy passthrough API")
			return true

	_set_xr_background_transparent(false)
	if not passthrough_unavailable_warned:
		passthrough_unavailable_warned = true
		push_warning("MR passthrough is unavailable on this OpenXR runtime")
	return false


## 停止 MR 透传模式
func _stop_passthrough() -> void:
	if not xr_interface:
		return

	# 恢复为不透明VR模式
	var supported_blend_modes: Array = xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in supported_blend_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE

	if passthrough_api_started:
		xr_interface.stop_passthrough()
	passthrough_api_started = false
	passthrough_supported_modes_logged = false
	passthrough_unavailable_warned = false
	get_tree().root.transparent_bg = false
	get_viewport().transparent_bg = false
	print("MR 透传: 已关闭")

func _process(_delta: float) -> void:
	_update_preview_container_visibility()

	if runtime_profile.uses_xr():
		if xr_runtime_active:
			_poll_xr_ui_shortcuts()
			_refresh_xr_environment()
		else:
			_last_right_a_pressed = false
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


func request_toggle_main_panel_ui() -> bool:
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_main_panel_toggle_ms < MAIN_PANEL_TOGGLE_DEBOUNCE_MS:
		return false
	var controller := get_node_or_null("MainMenuCanvas/SpatialWindowController")
	if controller == null \
			or not controller.has_method("toggle_local_visibility"):
		push_warning("主面板空间窗口控制器尚未就绪。")
		return false
	_last_main_panel_toggle_ms = now_ms
	return bool(controller.call("toggle_local_visibility"))


func _poll_xr_ui_shortcuts() -> void:
	var right_tracker := XRServer.get_tracker(&"right_hand")
	var right_a_pressed := _tracker_input_pressed(right_tracker, &"ax_button")
	if right_a_pressed and not _last_right_a_pressed:
		request_toggle_main_panel_ui()
	_last_right_a_pressed = right_a_pressed


func _tracker_input_pressed(
	tracker: XRPositionalTracker,
	input_name: StringName
) -> bool:
	if tracker == null:
		return false
	var value = tracker.get_input(input_name)
	if value is bool:
		return value
	if value is float or value is int:
		return float(value) >= XR_PRESS_THRESHOLD
	return false


func _configure_virtual_annotation_system() -> void:
	var shared_origin := get_node_or_null("SharedSpaceOrigin")
	if shared_origin == null:
		return
	var annotation_system := shared_origin.get_node_or_null(
		"VirtualAnnotations"
	)
	var profile = runtime_profile
	if profile == null:
		profile = RuntimeProfile.current()
	var feature_enabled := bool(ProjectSettings.get_setting(
		VIRTUAL_ANNOTATION_SETTING,
		false
	))
	var should_load: bool = false
	if feature_enabled and profile != null:
		should_load = bool(
			profile.is_valid()
			and profile.is_ground()
			and profile.uses_desktop_ui()
		)
	if should_load:
		if annotation_system != null:
			return
		var annotation_scene := load(VIRTUAL_ANNOTATION_SCENE_PATH) as PackedScene
		if annotation_scene == null:
			push_error("无法加载可选空间标注系统。")
			return
		annotation_system = annotation_scene.instantiate()
		annotation_system.name = "VirtualAnnotations"
		shared_origin.add_child(annotation_system)
		return
	if annotation_system == null:
		return
	var parent := annotation_system.get_parent()
	if parent != null:
		parent.remove_child(annotation_system)
	annotation_system.queue_free()


func _configure_passthrough_background(use_alpha: bool) -> void:
	var world_environment := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_environment == null or world_environment.environment == null:
		return
	world_environment.environment.background_mode = Environment.BG_COLOR
	world_environment.environment.background_color = (
		Color(0.0, 0.0, 0.0, 0.0)
		if use_alpha
		else Color.BLACK
	)


func _set_xr_background_transparent(enabled: bool) -> void:
	get_tree().root.use_xr = true
	get_viewport().use_xr = true
	get_tree().root.transparent_bg = enabled
	get_viewport().transparent_bg = enabled

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
