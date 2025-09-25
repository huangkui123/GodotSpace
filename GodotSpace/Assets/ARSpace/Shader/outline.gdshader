shader_type spatial;
render_mode cull_disabled; // 不剔除背面，这样描边能显示

uniform vec4 outline_color : source_color = vec4(0.5, 0.8, 1.0, 1.0);
uniform float outline_width = 0.03;

void vertex() {
    VERTEX += NORMAL * outline_width; // 顶点外扩
}

void fragment() {
    ALBEDO = outline_color.rgb;
    ALPHA  = outline_color.a;
}