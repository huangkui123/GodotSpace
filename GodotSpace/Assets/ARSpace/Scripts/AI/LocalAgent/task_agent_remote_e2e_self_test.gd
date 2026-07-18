extends SceneTree

var _answer_count := 0
var _run_error := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--remote-e2e-server"):
		await _run_server()
	elif args.has("--remote-e2e-client"):
		await _run_client()
	else:
		_fail("Specify --remote-e2e-server or --remote-e2e-client.")


func _run_server() -> void:
	var network := root.get_node_or_null("NetworkHandler")
	var agent := root.get_node_or_null("LocalAgentClient")
	var voice_chat := root.get_node_or_null("VoiceChat")
	if network == null or agent == null or voice_chat == null:
		_fail("Server autoloads are missing.")
		return
	if not network.start_server():
		_fail("Unable to start the remote E2E Server.")
		return
	agent.assistant_final_received.connect(func(_request_id: String, _answer: String) -> void:
		_answer_count += 1
	)
	agent.run_error_received.connect(func(_request_id: String, code: String, message: String) -> void:
		_run_error = "%s: %s" % [code, message]
	)

	var deadline := Time.get_ticks_msec() + 12_000
	while (not agent.is_connected_to_gateway() or root.multiplayer.get_peers().is_empty()) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not agent.is_connected_to_gateway():
		_fail("Server did not connect to the mock Gateway.")
		return
	if root.multiplayer.get_peers().is_empty():
		_fail("Remote E2E Client did not connect.")
		return
	var target_peer_id := int(root.multiplayer.get_peers()[0])

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": target_peer_id,
		"speaker_name": "远端航天员",
		"text": "下一步应该做什么",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(1):
		return
	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": target_peer_id,
		"speaker_name": "远端航天员",
		"text": "进入下一步",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(2):
		return
	# Let the Client observe completion and close its ENet peer first.
	await create_timer(1.0).timeout
	print("Remote task Agent Server E2E passed.")
	_shutdown_network(network)
	await process_frame
	await process_frame
	quit(0)


func _run_client() -> void:
	var network := root.get_node_or_null("NetworkHandler")
	if network == null or not network.start_client("127.0.0.1"):
		_fail("Unable to start the remote E2E Client.")
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
		_fail("Remote Client task guide did not open.")
		return
	var detail_view := detail_root.get_node_or_null("Canvas")
	var deadline := Time.get_ticks_msec() + 15_000
	while int(detail_view.page_index) != 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	if int(detail_view.page_index) != 2:
		_fail("Remote Client task page did not advance exactly once.")
		return
	# Keep the peer alive long enough for the reliable tool_result RPC to flush.
	await create_timer(0.25).timeout
	print("Remote task Agent Client E2E passed.")
	_shutdown_network(network)
	await process_frame
	await process_frame
	quit(0)


func _wait_for_answers(expected: int) -> bool:
	var deadline := Time.get_ticks_msec() + 8000
	while _answer_count < expected and _run_error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _run_error.is_empty():
		_fail("Gateway returned %s" % _run_error)
		return false
	if _answer_count < expected:
		_fail("Timed out waiting for remote Agent answer %d." % expected)
		return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)


func _shutdown_network(network: Node) -> void:
	var peer: Variant = network.get("peer")
	if peer != null and peer.has_method("close"):
		peer.call("close")
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	network.set("peer", null)
