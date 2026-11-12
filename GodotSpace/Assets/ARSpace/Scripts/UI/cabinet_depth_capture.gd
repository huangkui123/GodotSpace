extends Node

## A private depth world. It never writes depth into the main scene, so faded
## shells cannot punch invisible holes in UI or the surrounding environment.
const DepthShader := preload("res://Assets/ARSpace/Shader/cabinet_depth.gdshader")
var sources: Array[MeshInstance3D] = []
var materials: Array[ShaderMaterial] = []
var opacity: float = 1.0
var _views: Array[SubViewport] = []
var _cameras: Array[Camera3D] = []
var _copies: Array[MeshInstance3D] = []


func _enter_tree() -> void:
	if not RenderingServer.frame_pre_draw.is_connected(_update_views):
		RenderingServer.frame_pre_draw.connect(_update_views)


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var world := World3D.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.WHITE
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = environment
	for eye in 2:
		var viewport := SubViewport.new()
		viewport.name = "CabinetDepth%d" % eye
		viewport.world_3d = world
		viewport.size = Vector2i(16, 16)
		# Packed depth is data: antialiasing or temporal blending corrupts bytes.
		viewport.msaa_3d = Viewport.MSAA_DISABLED
		viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		viewport.use_taa = false
		viewport.use_debanding = false
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(viewport)
		_views.append(viewport)
		var camera := Camera3D.new()
		viewport.add_child(camera)
		camera.make_current()
		_cameras.append(camera)
	for source in sources:
		var copy := MeshInstance3D.new()
		copy.mesh = source.mesh
		for surface in source.mesh.get_surface_count():
			var depth := ShaderMaterial.new()
			var shader := Shader.new()
			var original := source.get_active_material(surface) as ShaderMaterial
			var cull := "cull_back"
			if original != null and original.shader.code.contains("cull_disabled"):
				cull = "cull_disabled"
			elif original != null and original.shader.code.contains("cull_front"):
				cull = "cull_front"
			shader.code = DepthShader.code.replace("cull_disabled", cull)
			depth.shader = shader
			copy.set_surface_override_material(surface, depth)
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_views[0].add_child(copy)
		_copies.append(copy)
	# Main materials reference ViewportTextures, establishing render ordering.
	for material in materials:
		material.set_shader_parameter("cabinet_depth_left", _views[0].get_texture())
		material.set_shader_parameter("cabinet_depth_right", _views[1].get_texture())


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_update_views):
		RenderingServer.frame_pre_draw.disconnect(_update_views)


func _update_views() -> void:
	if _views.is_empty():
		return
	var main := get_viewport()
	var camera := main.get_camera_3d()
	var active := camera != null and opacity > 0.0 and opacity < 1.0
	var xr := XRServer.primary_interface
	var stereo := main.use_xr and xr != null and xr.is_initialized()
	for eye in 2:
		_views[eye].render_target_update_mode = SubViewport.UPDATE_ALWAYS if active and (eye == 0 or stereo) else SubViewport.UPDATE_DISABLED
	if not active:
		return
	for i in sources.size():
		_copies[i].transform = sources[i].global_transform
		_copies[i].force_update_transform()
		_copies[i].visible = sources[i].is_visible_in_tree()
	var size := Vector2i(xr.get_render_target_size()) if stereo else Vector2i(main.get_visible_rect().size)
	for eye in (2 if stereo else 1):
		var target := _cameras[eye]
		if stereo:
			var projection := xr.get_projection_for_view(eye, float(size.x) / size.y, camera.near, camera.far)
			_configure_xr_view(eye, projection, xr.get_transform_for_view(eye, XRServer.world_origin), size.y, camera.near, camera.far)
		else:
			_views[eye].size = size.max(Vector2i.ONE)
			target.keep_aspect = camera.keep_aspect
			target.projection = camera.projection
			target.fov = camera.fov
			target.size = camera.size
			target.frustum_offset = camera.frustum_offset
			target.near = camera.near
			target.far = camera.far
			target.transform = camera.get_camera_transform()
		# frame_pre_draw runs after the normal deferred transform flush. Submit
		# this camera pose now, before publishing the matching shader matrices;
		# otherwise the depth texture is rendered with the previous frame pose.
		target.force_update_transform()
		for material in materials:
			material.set_shader_parameter("capture_view_left" if eye == 0 else "capture_view_right", target.global_transform.affine_inverse())
			material.set_shader_parameter("capture_projection_left" if eye == 0 else "capture_projection_right", target.get_camera_projection())
			material.set_shader_parameter("depth_ready", true)


func _configure_xr_view(eye: int, projection: Projection, pose: Transform3D, height_pixels: int, near: float, far: float) -> void:
	# Match the optical frustum, including each eye's asymmetry. The capture
	# aspect can differ from the headset's packed render size. The material
	# reprojects world positions into this exact capture, not screen UVs.
	var target := _cameras[eye]
	var aspect := projection.y.y / projection.x.x
	_views[eye].size = Vector2i(maxi(1, roundi(height_pixels * aspect)), maxi(1, height_pixels))
	target.keep_aspect = Camera3D.KEEP_HEIGHT
	var height := 2.0 * near / projection.y.y
	var offset := Vector2(projection.z.x * height * aspect, projection.z.y * height) * 0.5
	target.set_frustum(height, offset, near, far)
	target.transform = pose
