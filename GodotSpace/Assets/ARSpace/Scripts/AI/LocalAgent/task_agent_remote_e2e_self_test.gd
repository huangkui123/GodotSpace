extends SceneTree

var _answer_count := 0
var _run_error := ""
const LOCAL_AGENT_ENDPOINT_SETTING := "arspace/local_agent/endpoint_url"


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
	var router := root.get_node_or_null("AssistantCommandRouter")
	if network == null or agent == null or voice_chat == null or router == null:
		_fail("Server autoloads are missing.")
		return
	if not network.start_server():
		_fail("Unable to start the remote E2E Server.")
		return
	var mock_gateway_port := _mock_gateway_port()
	if mock_gateway_port > 0:
		ProjectSettings.set_setting(
			LOCAL_AGENT_ENDPOINT_SETTING,
			"ws://127.0.0.1:%d/ws/godot" % mock_gateway_port
		)
		agent.call("_disable_connection")
		agent.call("_try_connect")
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
	var wake_deadline := Time.get_ticks_msec() + 5000
	while not (router.get("_wake_sessions") as Dictionary).has(target_peer_id) and Time.get_ticks_msec() < wake_deadline:
		await process_frame
	if not (router.get("_wake_sessions") as Dictionary).has(target_peer_id):
		_fail("Remote Client manual wake request did not reach the Server router.")
		return

	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": target_peer_id,
		"speaker_name": "远端航天员",
		"text": "打开相册",
		"is_final": true,
		"utterance_id": 1,
		"source": "asr",
	})
	if not await _wait_for_answers(1):
		return
	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": target_peer_id,
		"speaker_name": "远端航天员",
		"text": "助手，打开无容器样品实验指导书",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(2):
		return
	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": target_peer_id,
		"speaker_name": "远端航天员",
		"text": "助手，下一步应该做什么",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(3):
		return
	voice_chat.voice_transcript_received.emit({
		"speaker_peer_id": target_peer_id,
		"speaker_name": "远端航天员",
		"text": "助手，进入下一步",
		"is_final": true,
		"source": "asr",
	})
	if not await _wait_for_answers(4):
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
	var voice_chat := root.get_node_or_null("VoiceChat")
	if network == null or voice_chat == null or not network.start_client("127.0.0.1"):
		_fail("Unable to start the remote E2E Client.")
		return
	var connection_deadline := Time.get_ticks_msec() + 5000
	while (
		root.multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED
		and Time.get_ticks_msec() < connection_deadline
	):
		await process_frame
	if not bool(voice_chat.call("request_assistant_wake")):
		_fail("Remote Client could not send the manual assistant wake request.")
		return
	var detail_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn")
	var list_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn")
	var album_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/PictureCanvas.tscn")
	var detail_root := detail_scene.instantiate()
	var list_view := list_scene.instantiate()
	var album_root := album_scene.instantiate()
	root.add_child(detail_root)
	root.add_child(list_view)
	root.add_child(album_root)
	await process_frame
	var detail_view := detail_root.get_node_or_null("Canvas")
	var album_view := album_root.get_node_or_null("Canvas")
	# Four routed commands each observe the production 5-second silence window.
	var deadline := Time.get_ticks_msec() + 35_000
	while (int(detail_view.page_index) != 2 or not album_view.visible) and Time.get_ticks_msec() < deadline:
		await process_frame
	if int(detail_view.page_index) != 2:
		_fail("Remote Client task page did not advance exactly once.")
		return
	if not album_view.visible:
		_fail("Remote Client album did not open.")
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


func _mock_gateway_port() -> int:
	const PREFIX := "--mock-gateway-port="
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(PREFIX):
			var value := argument.trim_prefix(PREFIX)
			return value.to_int() if value.is_valid_int() else 0
	return 0


func _fail(message: String) -> void:
	push_error(message)
	quit(1)


func _shutdown_network(network: Node) -> void:
	var peer: Variant = network.get("peer")
	if peer != null and peer.has_method("close"):
		peer.call("close")
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	network.set("peer", null)
