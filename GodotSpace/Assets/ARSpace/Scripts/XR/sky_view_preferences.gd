extends RefCounted

const CONFIG_PATH := "user://sky_view_preferences.cfg"
const DEFAULT_OPACITY := Vector3(0.5, 0.8, 0.25)


static func valid_opacity(value: Vector3) -> bool:
	return value.is_finite() and value.x >= 0 and value.x <= 1 \
		and value.y >= 0 and value.y <= 1 and value.z >= 0 and value.z <= 1


static func load_values(path: String = CONFIG_PATH) -> Dictionary:
	var result := {"opacity": DEFAULT_OPACITY}
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return result
	var opacity: Variant = config.get_value("sky", "opacity", DEFAULT_OPACITY)
	if opacity is Vector3 and valid_opacity(opacity):
		result.opacity = opacity
	return result


static func save_values(opacity: Vector3, path: String = CONFIG_PATH) -> Error:
	if not valid_opacity(opacity):
		return ERR_INVALID_PARAMETER
	var config := ConfigFile.new()
	config.set_value("sky", "opacity", opacity)
	return config.save(path)
