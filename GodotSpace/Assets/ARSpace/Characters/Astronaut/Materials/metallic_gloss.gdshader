shader_type spatial;
render_mode specular_schlick_ggx;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D metallic_gloss_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_normal_map = true;

void fragment() {
	vec4 base_color = texture(albedo_texture, UV);
	vec4 metallic_gloss = texture(metallic_gloss_texture, UV);
	ALBEDO = base_color.rgb;
	METALLIC = metallic_gloss.r;
	ROUGHNESS = 1.0 - metallic_gloss.a;
	if (use_normal_map) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = 1.0;
	}
}
