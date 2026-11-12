shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;

vec3 decode_srgb(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThanEqual(c, vec3(0.04045)));
}

void fragment() {
	// Store cabinet-only linear depth in RGB24. Undo the output sRGB transfer
	// so the viewport's 8-bit color texture contains exact data bytes.
	float value = floor(clamp(-VERTEX.z / 1024.0, 0.0, 1.0) * 16777215.0);
	vec3 bytes = vec3(floor(value / 65536.0), mod(floor(value / 256.0), 256.0), mod(value, 256.0));
	ALBEDO = decode_srgb(bytes / 255.0);
}
