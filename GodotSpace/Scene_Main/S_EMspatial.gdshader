shader_type spatial;
render_mode cull_disabled, unshaded;

uniform vec4 fill_color : source_color = vec4(1.0, 0.8, 0.0, 1.0);
uniform float fill_alpha : hint_range(0.0, 1.0) = 0.15;
uniform float edge_pixels : hint_range(0.0, 20.0) = 2.0;

void fragment() {
	// 用屏幕空间UV变化率计算实际像素宽度，不受缩放影响
	vec2 uv = UV;
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	
	// 每个UV单位对应多少像素
	float px_x = length(vec2(dx.x, dy.x));
	float px_y = length(vec2(dx.y, dy.y));
	
	// 把edge_pixels转换成UV空间的宽度
	float edge_u = px_x * edge_pixels;
	float edge_v = px_y * edge_pixels;
	
	float min_dist_u = min(uv.x, 1.0 - uv.x) / edge_u;
	float min_dist_v = min(uv.y, 1.0 - uv.y) / edge_v;
	float min_dist = min(min_dist_u, min_dist_v);
	
	if (min_dist < 1.0) {
		// 描边：fill_color 不透明
		ALBEDO = fill_color.rgb;
		ALPHA = fill_color.a;
	} else {
		// 填充：fill_color 半透明
		ALBEDO = fill_color.rgb;
		ALPHA = fill_alpha;
	}
}