shader_type canvas_item;
render_mode unshaded;

// Output-to-source radial sampling. Normalize with the video aspect ratio,
// never the panel's aspect, so resizing a window cannot stretch the correction.
// This adjustable division model is for uncalibrated cast video, not the
// separately rectified camera frames used for spatial calibration.
uniform float strength : hint_range(0.0, 0.8) = 0.25;
uniform float video_aspect = 1.7777778;
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec2 aspect = vec2(video_aspect, 1.0);
	vec2 p = (UV - vec2(0.5)) * 2.0 * aspect;
	float r2 = dot(p, p) / dot(aspect, aspect);
	vec2 source_uv = vec2(0.5) + p / (1.0 + strength * r2) / aspect * 0.5;
	COLOR = texture(TEXTURE, source_uv) * tint;
}
