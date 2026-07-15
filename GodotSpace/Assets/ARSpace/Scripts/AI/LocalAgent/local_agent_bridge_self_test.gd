extends SceneTree

const ClientScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_client.gd")
const RegistryScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_tool_registry.gd")
const OpenAlbumAdapterScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/open_album_tool_adapter.gd")

class FakeAlbum:
	extends Node
	var call_count := 0
	var visible := false

	func open_album(page: int, refresh: bool) -> Dictionary:
		call_count += 1
		visible = true
		return {
			"ok": true,
			"data": {"visible": visible, "page": page, "refreshed": refresh},
			"error": null,
		}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var picture_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/PictureCanvas.tscn")
	_assert(picture_scene != null, "PictureCanvas scene did not load")
	var picture_root := picture_scene.instantiate()
	root.add_child(picture_root)
	await process_frame
	var real_adapter := OpenAlbumAdapterScript.new()
	var real_opened: Dictionary = real_adapter.execute({"page": 1, "refresh": false})
	_assert(bool(real_opened.get("ok", false)), "production adapter did not open PictureCanvas")
	var real_canvas := picture_root.get_node_or_null("Canvas")
	_assert(real_canvas != null and real_canvas.visible, "PictureCanvas was not made visible")
	picture_root.queue_free()
	await process_frame

	var album := FakeAlbum.new()
	root.add_child(album)
	var adapter := OpenAlbumAdapterScript.new(func() -> Node: return album)
	var registry := RegistryScript.new()
	_assert(registry.register_tool("open_album", Callable(adapter, "execute")), "open_album registration failed")
	_assert(not registry.register_tool("open_album", Callable(adapter, "execute")), "duplicate registration was accepted")

	var opened := registry.dispatch("open_album", {"page": 2, "refresh": false})
	_assert(bool(opened.get("ok", false)), "open_album did not succeed")
	_assert(int((opened.get("data", {}) as Dictionary).get("page", 0)) == 2, "page was not forwarded")
	_assert(album.visible, "album was not made visible")

	var invalid := registry.dispatch("open_album", {"node_path": "/root/Global"})
	_assert(_error_code(invalid) == "invalid_arguments", "unknown arguments were not rejected")
	var fractional_page := registry.dispatch("open_album", {"page": 1.5})
	_assert(_error_code(fractional_page) == "invalid_arguments", "fractional page was accepted")
	var unknown := registry.dispatch("call_method", {"method": "queue_free"})
	_assert(_error_code(unknown) == "unknown_tool", "unregistered method call was accepted")

	var missing_adapter := OpenAlbumAdapterScript.new(func() -> Node: return null)
	var missing := missing_adapter.execute({})
	_assert(_error_code(missing) == "album_not_ready", "missing album did not return album_not_ready")

	var client := ClientScript.new()
	client.set_tool_registry_for_test(registry)
	var first := client.execute_tool_call_for_test("tool-1", "open_album", {"page": 1})
	var duplicate := client.execute_tool_call_for_test("tool-1", "open_album", {"page": 9})
	_assert(first == duplicate, "duplicate tool_call_id did not replay its original result")
	_assert(album.call_count == 2, "duplicate tool call executed more than once")

	client.free()
	album.free()
	print("Local Agent bridge self test passed.")
	quit(0)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	quit(1)


func _error_code(result: Dictionary) -> String:
	var error_value: Variant = result.get("error", {})
	return str((error_value as Dictionary).get("code", "")) if typeof(error_value) == TYPE_DICTIONARY else ""
