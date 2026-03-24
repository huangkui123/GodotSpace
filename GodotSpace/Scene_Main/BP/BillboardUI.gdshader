shader_type spatial;
render_mode cull_disabled, unshaded, depth_draw_never;

uniform sampler2D ui_texture : source_color;

void fragment() {
	vec4 col = texture(ui_texture, UV);
	ALBEDO = col.rgb;
	ALPHA = col.a;
}