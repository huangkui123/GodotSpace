extends SceneTree

# Opt-in live check. Only a fixed instruction, synthetic UI context and a
# boolean tool result leave this process; no album filenames or task evidence.
var _album: Node
var _opened := false
var _finished := false
var _error := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not OS.get_cmdline_user_args().has("--local-agent-album-smoke"):
		push_error("Live album smoke requires --local-agent-album-smoke.")
		quit(1)
		return
	_watchdog()
	var scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/PictureCanvas.tscn")
	var panel := scene.instantiate()
	root.add_child(panel)
	await process_frame
	_album = panel.get_node("Canvas")
	_album.call("close_album")
	var agent := root.get_node("LocalAgentClient")
	agent.replace_tool("open_album", _open_album)
	agent.assistant_final_received.connect(func(_id: String, _answer: String) -> void: _finished = true)
	agent.run_error_received.connect(func(_id: String, code: String, _message: String) -> void: _error = code)
	# Exercise recovery from collaboration-only startup and the real WS handshake.
	ProjectSettings.set_setting("arspace/local_agent/enabled", false)
	agent.call("_disable_connection")
	if not await root.get_node("LocalAgentRuntime").ensure_gateway():
		push_error("Gateway recovery failed.")
		quit(1)
		return
	if not agent.submit_user_message("album-smoke", "打开相册", {"album": {"visible": false}},
			PackedStringArray(["open_album"]), "synthetic-album-smoke"):
		push_error("Could not submit the synthetic album instruction.")
		quit(1)
		return
	while not _finished and _error.is_empty():
		await process_frame
	if not _error.is_empty() or not _opened:
		push_error("Album smoke failed: tool was not completed. " + _error)
		quit(1)
		return
	print("Live album smoke passed: Gateway recovery, WebSocket handshake, real model, actual album UI opened.")
	panel.queue_free()
	quit(0)


func _open_album(arguments: Dictionary, _context: Dictionary) -> Dictionary:
	var adapter := OpenAlbumToolAdapter.new(func() -> Node: return _album)
	var result := adapter.execute(arguments)
	_opened = bool(result.get("ok", false)) and bool(_album.call("get_album_snapshot").get("visible", false))
	# Deliberately discard local filenames and all other real album metadata.
	return {"ok": _opened, "data": {"visible": _opened}, "error": null}


func _watchdog() -> void:
	await create_timer(90.0).timeout
	push_error("Live album smoke timed out.")
	quit(1)
