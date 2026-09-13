extends SceneTree

var _answer_count := 0
var _run_error := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--multi-e2e-server"):
		await _run_server()
	elif args.has("--multi-e2e-client-1"):
		await _run_client(1)
	elif args.has("--multi-e2e-client-2"):
		await _run_client(2)
	else:
		_fail("Specify a multi-client E2E role.")


func _run_server() -> void:
	var network := root.get_node_or_null("NetworkHandler")
	var agent := root.get_node_or_null("LocalAgentClient")
	var voice_chat := root.get_node_or_null("VoiceChat")
	if network == null or agent == null or voice_chat == null or not network.start_server():
		_fail("Unable to start the multi-client E2E Server.")
		return
	agent.assistant_final_received.connect(func(_request_id: String, _answer: String) -> void:
		_answer_count += 1
	)
	agent.run_error_received.connect(func(_request_id: String, code: String, message: String) -> void:
		_run_error = "%s: %s" % [code, message]
	)

	var deadline := Time.get_ticks_msec() + 15_000
	while (not agent.is_connected_to_gateway() or root.multiplayer.get_peers().size() < 2) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not agent.is_connected_to_gateway() or root.multiplayer.get_peers().size() < 2:
		_fail("Gateway or two target Clients did not connect.")
		return
	var peers := root.multiplayer.get_peers()
	for peer_id in peers:
		_emit_transcript(voice_chat, int(peer_id), "下一步应该做什么")
		if not await _wait_for_answers(_answer_count + 1):
			return
	for peer_id in peers:
		_emit_transcript(voice_chat, int(peer_id), "进入下一步")
		if not await _wait_for_answers(_answer_count + 1):
			return
	await create_timer(1.0).timeout
	print("Multi-client task Agent Server E2E passed.")
	_shutdown_network(network)
	await process_frame
	quit(0)


func _run_client(start_page: int) -> void:
	var network := root.get_node_or_null("NetworkHandler")
	if network == null or not network.start_client("127.0.0.1"):
		_fail("Unable to start multi-client target page %d." % start_page)
		return
	var detail_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn")
	var list_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn")
	var detail_root := detail_scene.instantiate()
	var list_view := list_scene.instantiate()
	root.add_child(detail_root)
	root.add_child(list_view)
	await process_frame
	var opened: Dictionary = list_view.call("open_task_by_id", 1)
	if not bool(opened.get("ok", false)):
		_fail("Client page %d could not open task guide." % start_page)
		return
	var detail_view := detail_root.get_node_or_null("Canvas")
	while int(detail_view.page_index) < start_page:
		detail_view.call("next_click")
	var deadline := Time.get_ticks_msec() + 20_000
	while int(detail_view.page_index) != start_page + 1 and Time.get_ticks_msec() < deadline:
		await process_frame
	if int(detail_view.page_index) != start_page + 1:
		_fail("Client page %d was not independently advanced once." % start_page)
		return
	await create_timer(0.25).timeout
	print("Multi-client target %d -> %d passed." % [start_page, start_page + 1])
	_shutdown_network(network)
	await process_frame
	quit(0)


func _emit_transcript(voice_chat: Node, peer_id: int, text: String) -> void:
	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": peer_id,
		"speaker_name": "远端航天员",
		"text": "助手，%s" % text,
		"is_final": true,
		"source": "asr",
	})


func _wait_for_answers(expected: int) -> bool:
	var deadline := Time.get_ticks_msec() + 8000
	while _answer_count < expected and _run_error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _run_error.is_empty():
		_fail("Gateway returned %s" % _run_error)
		return false
	if _answer_count < expected:
		_fail("Timed out waiting for multi-client answer %d." % expected)
		return false
	return true


func _shutdown_network(network: Node) -> void:
	var peer: Variant = network.get("peer")
	if peer != null and peer.has_method("close"):
		peer.call("close")
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	network.set("peer", null)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
