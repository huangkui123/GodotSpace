extends SceneTree

const RuntimeProfile := preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const RESOURCE_PATHS := [
	"res://Assets/ARSpace/Scripts/runtime_profile.gd",
	"res://Assets/ARSpace/Scripts/shared_space_alignment.gd",
	"res://Assets/ARSpace/Scenes/startmenu_ui.gd",
	"res://Assets/ARSpace/Scenes/StartMenu.tscn",
	"res://Assets/ARSpace/Scripts/Network/network_handler.gd",
	"res://Assets/ARSpace/Scripts/Network/voice_chat_ui.gd",
	"res://Assets/ARSpace/Scripts/UI/unified_panel_ui.gd",
	"res://Assets/ARSpace/Scenes/SpaceBox.gd",
	"res://XR_Main.gd",
]


func _initialize() -> void:
	var failures: PackedStringArray = []
	for path in RESOURCE_PATHS:
		var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if resource == null:
			failures.append("Failed to load %s" % path)

	var xr_main_source := FileAccess.get_file_as_string("res://XR_Main.gd")
	var exit_tree_index := xr_main_source.find("func _exit_tree() -> void:")
	var exit_tree_block := xr_main_source.substr(exit_tree_index, 320) if exit_tree_index >= 0 else ""
	if not exit_tree_block.contains("_shutdown_openxr()"):
		failures.append("XR_Main must shut OpenXR down when leaving ARSpace")
	if not xr_main_source.contains("OpenXR runtime became unavailable"):
		failures.append("XR_Main must handle an OpenXR runtime loss")
	if not xr_main_source.contains("XR_RETRY_INTERVAL_MS"):
		failures.append("XR_Main must retry a delayed OpenXR runtime without a busy loop")
	if not xr_main_source.contains("XR_ENV_BLEND_MODE_ADDITIVE"):
		failures.append("Sky XR must support additive passthrough when alpha blend is unavailable")
	if not xr_main_source.contains("_configure_passthrough_background"):
		failures.append("Sky XR must configure a compositor-compatible transparent background")
	if not xr_main_source.contains("request_toggle_main_panel_ui") \
			or not xr_main_source.contains("toggle_local_visibility"):
		failures.append("XR_Main must expose the local right-A main panel toggle")
	if not xr_main_source.contains("VIRTUAL_ANNOTATION_SETTING"):
		failures.append("XR_Main must gate the disabled virtual annotation system")
	if not xr_main_source.contains("_configure_spacebox_rendering") \
			or not xr_main_source.contains("configure_for_runtime_profile"):
		failures.append("XR_Main must apply role-specific cabin rendering")
	if not xr_main_source.contains("SKY_OBJECT_OPACITY") \
			or not xr_main_source.contains(
				"_apply_sky_transparency_to_subtree"
			):
		failures.append("Sky XR must apply scene-wide geometry transparency")
	if not xr_main_source.contains("get_tree().node_added"):
		failures.append("Sky XR must include geometry created after scene startup")
	var spacebox_source := FileAccess.get_file_as_string(
		"res://Assets/ARSpace/Scenes/SpaceBox.gd"
	)
	if not spacebox_source.contains("NodePath(\"SpaceBox/DownPlane\")") \
			or not spacebox_source.contains("NodePath(\"SpaceBox/BackDor\")"):
		failures.append("Sky XR must explicitly show DownPlane and BackDor")
	_test_role_specific_scene_transparency(failures)
	_test_pico_compositor_cleanup(failures)

	var network_source := FileAccess.get_file_as_string("res://Assets/ARSpace/Scripts/Network/network_handler.gd")
	if not network_source.contains("return _handle_start_failure("):
		failures.append("NetworkHandler startup failures must use the shared recovery path")
	if not network_source.contains("OfflineMultiplayerPeer.new()"):
		failures.append("NetworkHandler must restore an OfflineMultiplayerPeer after closing ENet")
	var menu_source := FileAccess.get_file_as_string("res://Assets/ARSpace/Scenes/startmenu_ui.gd")
	if not menu_source.contains("NetworkHandler.get_last_start_error()"):
		failures.append("StartMenu must display synchronous network startup failures")
	if not menu_source.contains("RuntimeProfile.Preset.VR_GROUND_CLIENT"):
		failures.append("StartMenu must expose the VR Ground Client mode")
	var voice_source := FileAccess.get_file_as_string("res://Assets/ARSpace/Scripts/Network/voice_chat.gd")
	if not voice_source.contains("NetworkHandler.peer == null or not multiplayer.has_multiplayer_peer()") \
			and not voice_source.contains('network_handler.get("peer") == null or not multiplayer.has_multiplayer_peer()'):
		failures.append("VoiceChat must wait for a real ENet peer before publishing levels")

	if failures.is_empty():
		print("Runtime mode integration self-test passed")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_pico_compositor_cleanup(failures: PackedStringArray) -> void:
	var host := load("res://XR_Main.gd").new() as Node3D
	var camera := XRCamera3D.new()
	host.add_child(camera)
	var original := Compositor.new()
	var installed := Compositor.new()
	camera.compositor = installed
	host.set("_pico_alpha_camera", camera)
	host.set("_pico_alpha_original_compositor", original)
	host.set("_pico_alpha_compositor", installed)
	host.call("_remove_pico_alpha_compositor")
	if camera.compositor != original or host.get("_pico_alpha_compositor") != null:
		failures.append("leaving PICO MR must restore the camera's authored compositor")
	# Another owner may replace the compositor before XR teardown. Do not
	# overwrite its newer resource when detaching our own effect.
	var replacement := Compositor.new()
	camera.compositor = replacement
	host.set("_pico_alpha_camera", camera)
	host.set("_pico_alpha_original_compositor", original)
	host.set("_pico_alpha_compositor", installed)
	host.call("_remove_pico_alpha_compositor")
	if camera.compositor != replacement:
		failures.append("PICO cleanup must preserve a compositor installed by another owner")
	host.call("_remove_pico_alpha_compositor")
	host.free()


func _test_role_specific_scene_transparency(
	failures: PackedStringArray
) -> void:
	var xr_main_script := ResourceLoader.load(
		"res://XR_Main.gd",
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as Script
	if xr_main_script == null:
		failures.append("XR_Main must load for scene transparency test")
		return
	var xr_main := xr_main_script.new() as Node3D
	var primary_geometry := MeshInstance3D.new()
	var original_material := StandardMaterial3D.new()
	original_material.albedo_color = Color.WHITE
	original_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	primary_geometry.material_override = original_material
	xr_main.add_child(primary_geometry)
	var surface_geometry := MeshInstance3D.new()
	var surface_mesh := BoxMesh.new()
	var surface_material := StandardMaterial3D.new()
	surface_material.albedo_color = Color(0.8, 0.6, 0.4, 0.8)
	surface_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	surface_mesh.material = surface_material
	surface_geometry.mesh = surface_mesh
	xr_main.add_child(surface_geometry)
	var ui_geometry := MeshInstance3D.new()
	var ui_material := StandardMaterial3D.new()
	ui_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var viewport_texture := ViewportTexture.new()
	viewport_texture.viewport_path = NodePath("Viewport")
	ui_material.albedo_texture = viewport_texture
	ui_geometry.material_override = ui_material
	xr_main.add_child(ui_geometry)
	var sky_down_plane := Node3D.new()
	sky_down_plane.name = "DownPlane"
	xr_main.add_child(sky_down_plane)
	var sky_down_geometry := MeshInstance3D.new()
	sky_down_geometry.material_override = original_material
	sky_down_plane.add_child(sky_down_geometry)
	var sky_back_door := Node3D.new()
	sky_back_door.name = "BackDor"
	xr_main.add_child(sky_back_door)
	var sky_back_geometry := MeshInstance3D.new()
	sky_back_geometry.material_override = original_material
	sky_back_door.add_child(sky_back_geometry)
	var label := Label3D.new()
	label.modulate = Color(0.6, 0.7, 0.8, 1.0)
	label.outline_modulate = Color(0.1, 0.2, 0.3, 0.8)
	xr_main.add_child(label)

	var sky_profile = RuntimeProfile.select_session_mode(
		RuntimeProfile.Preset.SKY_XR_CLIENT,
		false
	)
	xr_main.set("runtime_profile", sky_profile)
	xr_main.call("_configure_scene_geometry_rendering")
	var sky_primary_material := (
		primary_geometry.material_override as StandardMaterial3D
	)
	if sky_primary_material == null \
			or sky_primary_material == original_material \
			or sky_primary_material.transparency \
				!= BaseMaterial3D.TRANSPARENCY_ALPHA \
			or not is_equal_approx(
				sky_primary_material.albedo_color.a,
				0.5
			):
		failures.append("Sky XR must use a half-alpha local material override")
	var sky_surface_material := surface_geometry.get_surface_override_material(
		0
	) as StandardMaterial3D
	if sky_surface_material == null \
			or sky_surface_material == surface_material \
			or sky_surface_material.transparency \
				!= BaseMaterial3D.TRANSPARENCY_ALPHA \
			or not is_equal_approx(
				sky_surface_material.albedo_color.a,
				0.5
			):
		failures.append("Sky XR must make authored mesh surfaces transparent")
	var sky_ui_material := ui_geometry.material_override as StandardMaterial3D
	if sky_ui_material == null \
			or sky_ui_material == ui_material \
			or sky_ui_material.albedo_texture != viewport_texture \
			or not is_equal_approx(sky_ui_material.albedo_color.a, 0.8):
		failures.append("Sky XR must preserve live ViewportTexture references")
	for faded in [sky_primary_material, sky_surface_material, sky_ui_material]:
		if faded.depth_draw_mode != BaseMaterial3D.DEPTH_DRAW_DISABLED \
				or faded.no_depth_test:
			failures.append("faded Sky materials must stop writing depth while preserving depth testing")
	var sky_down_material := (
		sky_down_geometry.material_override as StandardMaterial3D
	)
	var sky_back_material := (
		sky_back_geometry.material_override as StandardMaterial3D
	)
	if sky_down_material == null \
			or sky_back_material == null \
			or not is_equal_approx(sky_down_material.albedo_color.a, 0.25) \
			or not is_equal_approx(sky_back_material.albedo_color.a, 0.25):
		failures.append(
			"Sky XR must make DownPlane and BackDor more transparent"
		)
	if original_material.transparency \
			!= BaseMaterial3D.TRANSPARENCY_DISABLED \
			or original_material.depth_draw_mode != BaseMaterial3D.DEPTH_DRAW_ALWAYS \
			or surface_material.depth_draw_mode != BaseMaterial3D.DEPTH_DRAW_ALWAYS \
			or surface_material.transparency \
				!= BaseMaterial3D.TRANSPARENCY_DISABLED:
		failures.append("Sky XR must not mutate shared source materials")
	if not is_equal_approx(label.modulate.a, 0.5) \
			or not is_equal_approx(label.outline_modulate.a, 0.4):
		failures.append("Sky XR must make Label3D text and outlines transparent")
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
uniform float arspace_opacity = 1.0;
void fragment() {
	ALPHA = arspace_opacity;
}
"""
	var shader_material := ShaderMaterial.new()
	shader_material.shader = shader
	var sky_shader_material := xr_main.call(
		"_get_sky_transparent_material",
		shader_material
	) as ShaderMaterial
	if sky_shader_material == null \
			or not is_equal_approx(
				float(sky_shader_material.get_shader_parameter(
					"arspace_opacity"
				)),
				0.5
			):
		failures.append("Sky XR must adjust supported shader opacity uniforms")

	var late_branch := Node3D.new()
	xr_main.add_child(late_branch)
	var late_geometry := MeshInstance3D.new()
	var late_material := StandardMaterial3D.new()
	late_material.albedo_color = Color(0.2, 0.4, 0.6, 0.6)
	late_geometry.material_override = late_material
	late_branch.add_child(late_geometry)
	xr_main.call("_apply_sky_transparency_to_subtree", late_branch)
	var sky_late_material := (
		late_geometry.material_override as StandardMaterial3D
	)
	if sky_late_material == null \
			or not is_equal_approx(sky_late_material.albedo_color.a, 0.5):
		failures.append("Sky XR must make late-created geometry half transparent")

	# Adjust repeatedly, including after late creation, and verify authored alpha
	# and live viewport references survive every rebuild.
	var sprite := Sprite3D.new()
	sprite.modulate.a = 0.7
	xr_main.add_child(sprite)
	for opacity in [Vector3(0.9, 0.95, 0.1), Vector3(0.2, 0.3, 0), Vector3.ONE]:
		if not bool(xr_main.call("set_sky_opacity", opacity)):
			failures.append("valid live opacity adjustment rejected")
		var adjusted := primary_geometry.material_override as StandardMaterial3D
		var adjusted_ui := ui_geometry.material_override as StandardMaterial3D
		var adjusted_boundary := sky_down_geometry.material_override as StandardMaterial3D
		var adjusted_late := late_geometry.material_override as StandardMaterial3D
		if is_equal_approx(opacity.x, 1.0) and (
				adjusted.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
				or adjusted.depth_draw_mode != BaseMaterial3D.DEPTH_DRAW_ALWAYS):
			failures.append("100% opacity must restore solid self-occlusion for authored opaque meshes")
		if not is_equal_approx(adjusted.albedo_color.a, opacity.x) \
				or not is_equal_approx(adjusted_late.albedo_color.a, opacity.x) \
				or not is_equal_approx(label.modulate.a, opacity.x) \
				or not is_equal_approx(label.outline_modulate.a, 0.8 * opacity.x) \
				or not is_equal_approx(sprite.modulate.a, 0.7 * opacity.x):
			failures.append("live opacity must rebuild meshes, text and sprites without cumulative fading")
		if adjusted_ui.albedo_texture != viewport_texture \
				or not is_equal_approx(adjusted_ui.albedo_color.a, opacity.y) \
				or not is_equal_approx(adjusted_boundary.albedo_color.a, opacity.z):
			failures.append("panel and boundary opacity must be independently adjustable")
	if bool(xr_main.call("set_sky_opacity", Vector3(NAN, 1, 1))) \
			or bool(xr_main.call("set_sky_opacity", Vector3(-1, 1, 1))):
		failures.append("invalid opacity must be rejected")
	if original_material.albedo_color != Color.WHITE or not is_equal_approx(ui_material.albedo_color.a, 1.0):
		failures.append("live opacity must leave shared authored resources unchanged")
	var main_menu := Node3D.new()
	main_menu.name = "MainMenuCanvas"
	xr_main.add_child(main_menu)
	var menu_screen := MeshInstance3D.new()
	menu_screen.material_override = ui_material
	main_menu.add_child(menu_screen)
	xr_main.call("set_sky_opacity", Vector3.ZERO)
	if menu_screen.material_override != ui_material \
			or not is_equal_approx((ui_geometry.material_override as StandardMaterial3D).albedo_color.a, 0):
		failures.append("local display controls must remain readable when other panels are transparent")

	var ground_profile = RuntimeProfile.select_session_mode(
		RuntimeProfile.Preset.VR_GROUND_CLIENT,
		false
	)
	xr_main.set("runtime_profile", ground_profile)
	xr_main.call("_configure_scene_geometry_rendering")
	if primary_geometry.material_override != original_material \
			or surface_geometry.get_surface_override_material(0) != null \
			or ui_geometry.material_override != ui_material \
			or sky_down_geometry.material_override != original_material \
			or sky_back_geometry.material_override != original_material \
			or late_geometry.material_override != late_material:
		failures.append("Ground VR must restore every original material assignment")
	if not label.modulate.is_equal_approx(
			Color(0.6, 0.7, 0.8, 1.0)
		) or not label.outline_modulate.is_equal_approx(
			Color(0.1, 0.2, 0.3, 0.8)
		):
		failures.append("Ground VR must restore original Label3D colors")
	xr_main.call("set_sky_opacity", Vector3(0.1, 0.2, 0.3))
	if primary_geometry.material_override != original_material \
			or not is_equal_approx(sprite.modulate.a, 0.7):
		failures.append("opacity control must not fade Ground VR or desktop roles")
	xr_main.free()

	var spacebox_script := ResourceLoader.load(
		"res://Assets/ARSpace/Scenes/SpaceBox.gd",
		"",
		ResourceLoader.CACHE_MODE_IGNORE
	) as Script
	if spacebox_script == null:
		failures.append("SpaceBox controller must load for cabin rendering test")
		return
	var spacebox := spacebox_script.new() as Node3D

	var shell_root := Node3D.new()
	shell_root.name = "SpaceBox"
	spacebox.add_child(shell_root)
	var down_plane := Node3D.new()
	down_plane.name = "DownPlane"
	down_plane.visible = false
	shell_root.add_child(down_plane)
	var back_door := Node3D.new()
	back_door.name = "BackDor"
	back_door.visible = false
	shell_root.add_child(back_door)
	spacebox.call("configure_for_runtime_profile", sky_profile)
	if not down_plane.visible or not back_door.visible:
		failures.append("Sky XR must show DownPlane and BackDor")
	spacebox.call("configure_for_runtime_profile", ground_profile)
	if down_plane.visible or back_door.visible:
		failures.append(
			"Ground VR must restore authored DownPlane and BackDor visibility"
		)

	RuntimeProfile.clear_session_override()
	spacebox.free()
