extends CompositorEffect

## Compatibility for the PICO Windows streaming path, validated on runtime
## 1.1.46. Its headset display needs RGB premultiplied in encoded color space.
## This is NOT the normal OpenXR linear-premultiplied representation. Attach
## only to the local PICO MR camera, after all transparent surfaces are mixed.
## Requires Forward+ and the scene's linear tonemapper / unit exposure.
const COMPUTE_SOURCE := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(push_constant, std430) uniform Params { vec2 size; vec2 reserved; } params;

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055,
		12.92 * c, lessThanEqual(c, vec3(0.0031308)));
}
vec3 to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)),
		c / 12.92, lessThanEqual(c, vec3(0.04045)));
}
void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, ivec2(params.size)))) { return; }
	vec4 color = imageLoad(color_image, pixel);
	if (color.a <= 0.0) {
		color.rgb = vec3(0.0);
	} else if (color.a < 1.0) {
		// Undo linear premultiplication, encode the straight color, then
		// premultiply in encoded space. Invert the engine's upcoming sRGB
		// conversion here so it writes that result exactly once. Alpha stays
		// unchanged, and opaque pixels (including the main UI) are untouched.
		vec3 straight = clamp(color.rgb / color.a, vec3(0.0), vec3(1.0));
		color.rgb = to_linear(to_srgb(straight) * color.a);
	}
	imageStore(color_image, pixel, color);
}
"""

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _attempted_compile := false
var _reported_views := false


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	_rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null and _shader.is_valid():
		# The pipeline/uniform sets depend on this shader and are freed with it.
		_rd.free_rid(_shader)


func _prepare_pipeline() -> bool:
	if _rd == null:
		return false
	if _attempted_compile:
		return _pipeline.is_valid()
	_attempted_compile = true
	var source := RDShaderSource.new()
	source.source_compute = COMPUTE_SOURCE
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("PICO alpha compositor: " + spirv.compile_error_compute)
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or not _prepare_pipeline():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var constants := PackedFloat32Array([size.x, size.y, 0, 0]).to_byte_array()
	for view in range(buffers.get_view_count()):
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = 0
		uniform.add_id(buffers.get_color_layer(view))
		var uniforms := UniformSetCacheRD.get_cache(_shader, 0, [uniform])
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniforms, 0)
		_rd.compute_list_set_push_constant(compute_list, constants, constants.size())
		_rd.compute_list_dispatch(compute_list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		_rd.compute_list_end()
	if not _reported_views:
		_reported_views = true
		print("PICO encoded-alpha compositor active: views=", buffers.get_view_count())
