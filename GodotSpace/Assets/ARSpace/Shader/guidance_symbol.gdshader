shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D symbol_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 symbol_color : source_color = vec4(1.0);
uniform vec3 uv_scale = vec3(1.0);
uniform vec3 uv_offset = vec3(0.0);

void fragment() {
	// Imported arrow art contains a wide translucent glow. Only the solid
	// symbol should guide a user against passthrough. Discard its background
	// from both color and depth, rather than leaving an invisible depth quad.
	ALBEDO = symbol_color.rgb;
	ALPHA = texture(symbol_texture, UV * uv_scale.xy + uv_offset.xy).a;
	ALPHA_SCISSOR_THRESHOLD = 0.9;
}
