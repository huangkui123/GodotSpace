class_name OpenAlbumToolAdapter
extends RefCounted

var _target_provider: Callable


func _init(target_provider: Callable = Callable()) -> void:
	_target_provider = target_provider


func execute(arguments: Dictionary) -> Dictionary:
	for key in arguments.keys():
		if String(key) not in ["page", "refresh"]:
			return _error("invalid_arguments", "Unknown open_album argument: %s" % key)

	var page_value: Variant = arguments.get("page", 1)
	var page_is_integer := typeof(page_value) == TYPE_INT
	if typeof(page_value) == TYPE_FLOAT:
		page_is_integer = is_equal_approx(float(page_value), floorf(float(page_value)))
	if not page_is_integer or int(page_value) < 1:
		return _error("invalid_arguments", "page must be an integer greater than zero.")
	var refresh_value: Variant = arguments.get("refresh", true)
	if typeof(refresh_value) != TYPE_BOOL:
		return _error("invalid_arguments", "refresh must be a boolean.")

	var album := _resolve_album()
	if album == null or not is_instance_valid(album) or not album.has_method("open_album"):
		return _error("album_not_ready", "The photo album UI is not ready.")
	var result: Variant = album.call("open_album", int(page_value), bool(refresh_value))
	if typeof(result) != TYPE_DICTIONARY:
		return _error("invalid_album_result", "The photo album returned an invalid result.")
	return result as Dictionary


func _resolve_album() -> Node:
	if _target_provider.is_valid():
		var provided: Variant = _target_provider.call()
		return provided as Node if provided is Node else null
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var global_node := tree.root.get_node_or_null("Global")
	if global_node == null:
		return null
	var target: Variant = global_node.get("picture_canvas")
	return target as Node if target is Node else null


static func _error(code: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"data": {},
		"error": {"code": code, "message": message},
	}
