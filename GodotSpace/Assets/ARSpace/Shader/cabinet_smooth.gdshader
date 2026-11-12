shader_type spatial;
render_mode depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float cabinet_opacity = 1.0;
uniform bool depth_ready = false;
uniform sampler2D cabinet_depth_left : filter_nearest, repeat_disable;
uniform sampler2D cabinet_depth_right : filter_nearest, repeat_disable;
uniform mat4 capture_view_left;
uniform mat4 capture_view_right;
uniform mat4 capture_projection_left;
uniform mat4 capture_projection_right;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_map : source_color, filter_linear_mipmap_anisotropic;
uniform bool has_albedo_map = false;
uniform bool vertex_albedo = false;
uniform bool unshaded = false;
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);
uniform float metallic_value = 0.0;
uniform float specular_value = 0.5;
uniform float roughness_value = 1.0;
uniform sampler2D metallic_map : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D roughness_map : hint_default_white, filter_linear_mipmap_anisotropic;
uniform vec4 metallic_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 roughness_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform bool normal_enabled = false;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic;
uniform float normal_scale = 1.0;

void fragment() {
	if (cabinet_opacity <= 0.0) { discard; }
	if (depth_ready && cabinet_opacity < 1.0) {
		vec4 world = INV_VIEW_MATRIX * vec4(VERTEX, 1.0);
		vec4 captured = (VIEW_INDEX == 0 ? capture_view_left : capture_view_right) * world;
		vec4 projected = (VIEW_INDEX == 0 ? capture_projection_left : capture_projection_right) * captured;
		vec2 uv = projected.xy / projected.w * 0.5 + 0.5;
		uv.y = 1.0 - uv.y;
		vec3 packed_depth = VIEW_INDEX == 0 ? texture(cabinet_depth_left, uv).rgb : texture(cabinet_depth_right, uv).rgb;
		vec3 bytes = floor(packed_depth * 255.0 + 0.5);
		float nearest = dot(bytes, vec3(65536.0, 256.0, 1.0)) / 16777215.0 * 1024.0;
		float distance_to_camera = -captured.z;
		float tolerance = max(0.0002, fwidth(distance_to_camera) * 1.5);
		if (distance_to_camera > nearest + tolerance) { discard; }
	}
	vec2 mapped_uv = UV * uv_scale.xy + uv_offset.xy;
	vec3 color = albedo_color.rgb;
	if (has_albedo_map) { color *= texture(albedo_map, mapped_uv).rgb; }
	if (vertex_albedo) { color *= COLOR.rgb; }
	ALBEDO = unshaded ? vec3(0.0) : color;
	EMISSION = unshaded ? color : vec3(0.0);
	METALLIC = metallic_value * dot(texture(metallic_map, mapped_uv), metallic_channel);
	ROUGHNESS = roughness_value * dot(texture(roughness_map, mapped_uv), roughness_channel);
	SPECULAR = unshaded ? 0.0 : specular_value;
	if (normal_enabled) {
		NORMAL_MAP = texture(normal_map, mapped_uv).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}
	ALPHA = cabinet_opacity;
}
