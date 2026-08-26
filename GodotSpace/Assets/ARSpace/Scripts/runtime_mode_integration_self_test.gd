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
	if not voice_source.contains("NetworkHandler.peer == null or not multiplayer.has_multiplayer_peer()"):
		failures.append("VoiceChat must wait for a real ENet peer before publishing levels")

	if failures.is_empty():
		print("Runtime mode integration self-test passed")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


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
	primary_geometry.material_override = original_material
	xr_main.add_child(primary_geometry)
	var surface_geometry := MeshInstance3D.new()
	var surface_mesh := BoxMesh.new()
	var surface_material := StandardMaterial3D.new()
	surface_material.albedo_color = Color(0.8, 0.6, 0.4, 0.8)
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
	var point_cloud_root := Node3D.new()
	point_cloud_root.add_to_group(&"reconstruction_point_cloud_chunks")
	xr_main.add_child(point_cloud_root)
	var point_cloud_geometry := MeshInstance3D.new()
	var point_cloud_material := ShaderMaterial.new()
	var point_cloud_shader := Shader.new()
	point_cloud_shader.code = """
shader_type spatial;
void fragment() {
	ALBEDO = COLOR.rgb;
}
"""
	point_cloud_material.shader = point_cloud_shader
	point_cloud_geometry.material_override = point_cloud_material
	point_cloud_root.add_child(point_cloud_geometry)

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
			or surface_material.transparency \
				!= BaseMaterial3D.TRANSPARENCY_DISABLED:
		failures.append("Sky XR must not mutate shared source materials")
	if not is_equal_approx(label.modulate.a, 0.5) \
			or not is_equal_approx(label.outline_modulate.a, 0.4):
		failures.append("Sky XR must make Label3D text and outlines transparent")
	if point_cloud_geometry.material_override != point_cloud_material:
		failures.append("Sky XR must keep reconstruction point clouds opaque")
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
	var late_point_geometry := MeshInstance3D.new()
	late_point_geometry.material_override = point_cloud_material
	point_cloud_root.add_child(late_point_geometry)
	xr_main.call("_apply_sky_transparency_to_subtree", late_point_geometry)
	if late_point_geometry.material_override != point_cloud_material:
		failures.append("Sky XR must keep late-created reconstruction points opaque")

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
