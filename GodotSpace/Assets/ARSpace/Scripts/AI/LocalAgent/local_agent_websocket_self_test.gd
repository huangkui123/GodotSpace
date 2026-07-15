extends SceneTree

class FakeAlbum:
	extends Node
	var call_count := 0

	func open_album(page: int, refresh: bool) -> Dictionary:
		call_count += 1
		return {
			"ok": true,
			"data": {"visible": true, "page": page, "refreshed": refresh},
			"error": null,
		}

var _completed := false
var _failed_message := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var global_node := root.get_node_or_null("Global")
	var client := root.get_node_or_null("LocalAgentClient")
	if global_node == null or client == null:
		_fail("Required Global or LocalAgentClient autoload is missing.")
		return

	var album := FakeAlbum.new()
	root.add_child(album)
	global_node.set("picture_canvas", album)
	client.assistant_final_received.connect(func(_request_id: String, answer: String) -> void:
		if answer == "rpc-test-passed":
			_completed = true
	)
	client.run_error_received.connect(func(_request_id: String, code: String, message: String) -> void:
		_failed_message = "%s: %s" % [code, message]
	)

	var deadline := Time.get_ticks_msec() + 8000
	while not _completed and _failed_message.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame

	if not _failed_message.is_empty():
		_fail("Gateway returned %s" % _failed_message)
		return
	if not _completed:
		_fail("Timed out waiting for the mock Gateway RPC result.")
		return
	if album.call_count != 1:
		_fail("Duplicate tool_call_id executed %d times instead of once." % album.call_count)
		return

	print("Local Agent websocket RPC self test passed.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
