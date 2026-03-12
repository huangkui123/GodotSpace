shader_type spatial;

// 渲染模式：不受光照影响，纯自发光
render_mode unshaded, cull_back, depth_draw_opaque;

// ── 基础颜色 ──
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_offset = vec2(0.0, 0.0);

// ── 自发光 ──
uniform vec4 emission_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float emission_energy : hint_range(0.0, 16.0, 0.01) = 1.0;
uniform sampler2D emission_texture : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;

// ── 透明度 ──
uniform float alpha : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform sampler2D alpha_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0, 0.01) = 0.1;

void fragment() {
	vec2 uv = UV * uv_scale + uv_offset;

	// 基础颜色采样
	vec4 base_color = albedo * texture(albedo_texture, uv);

	// 自发光采样
	vec3 emission = emission_color.rgb * texture(emission_texture, uv).rgb * emission_energy;

	// 透明度
	float final_alpha = base_color.a * alpha * texture(alpha_texture, uv).r;

	// Alpha 裁剪（避免半透明排序问题，可按需关闭）
	if (final_alpha < alpha_scissor_threshold) {
		discard;
	}

	// 输出：albedo 用于基础显示，emission 叠加发光
	ALBEDO = base_color.rgb + emission;
	ALPHA = final_alpha;
}