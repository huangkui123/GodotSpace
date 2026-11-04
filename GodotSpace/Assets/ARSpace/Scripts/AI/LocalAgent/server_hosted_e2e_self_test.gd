extends SceneTree

var failed := false
var answers := 0
var routed := 0
var ordinary := 0
var states: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	ProjectSettings.set_setting("arspace/local_agent/enabled", true)
	var server := OS.get_cmdline_user_args().has("--endpoint-test-server")
	var expected_clients := 1 if OS.get_cmdline_user_args().has("--sky-only") else 2
	var api := root.multiplayer
	var network := root.get_node("NetworkHandler")
	# Isolate scene replication; keep real Server role registration checks.
	for pair in [[api.connected_to_server, "_on_connected_to_server"], [api.peer_connected, "_on_peer_connected"], [api.server_disconnected, "_on_server_disconnected"]]:
		var callback := Callable(network, pair[1])
		if (pair[0] as Signal).is_connected(callback):
			(pair[0] as Signal).disconnect(callback)
	if server:
		api.peer_connected.connect(func(id: int): network._set_peer_role(id, "sky" if api.get_peers().size() == 1 else "ground_vr"))
	var voice := root.get_node("VoiceChat")
	voice.set_process(false)
	voice.voice_transcript_received.connect(func(data: Dictionary):
		if data.get("source", "") == "llm_assistant":
			answers += 1
		elif str(data.get("text", "")) == "普通交流":
			ordinary += 1
	)
	voice.assistant_interaction_state_changed.connect(func(data: Dictionary): states.append(str(data.get("state", ""))))
	var router := root.get_node("AssistantCommandRouter")
	router.command_routed.connect(func(_id, _intent, _peer): routed += 1)
	var agent := root.get_node("LocalAgentClient")
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(42869, 2, 4) if server else peer.create_client("127.0.0.1", 42869, 4)
	_check(error == OK, "ENet start failed")
	api.multiplayer_peer = peer
	agent._on_network_role_selected(server)
	var deadline := Time.get_ticks_msec() + (130000 if OS.get_cmdline_user_args().has("--live-model") else 23000)
	if server:
		while (routed < expected_clients * 2 or ordinary < expected_clients or not router._requests.is_empty()) and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(routed == expected_clients * 2 and ordinary == expected_clients, "Server did not exclusively route the expected commands / ordinary texts")
		_check(api.get_peers().size() == expected_clients, "Unexpected peer count; Sky-only test must not contain a Ground Client")
		_check(answers == 0, "Private Client answers leaked to Server display")
		await create_timer(1.5).timeout
		peer.close()
		_finish("server")
		return
	while peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(0.5).timeout
	_check(not agent._is_enabled() and not agent.is_connected_to_gateway(), "Client connected to Gateway")
	var detail: Node = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn").instantiate()
	var list_view: Node = load("res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn").instantiate()
	root.add_child(detail)
	root.add_child(list_view)
	await process_frame
	voice.transport.send_capture_phase(2, "preparing")
	while not states.has("connecting") and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(states.has("connecting") and not states.has("listening"), "Countdown started before recognizer ready")
	voice.transport.send_endpoint_transcript({"text": "智能助手打开相册", "is_final": true, "utterance_id": 1, "recognition_epoch": 1})
	voice.transport.send_capture_phase(2, "ready")
	voice.transport.send_endpoint_transcript({"text": "打开工作清单", "is_final": true, "utterance_id": 2, "recognition_epoch": 2})
	while answers < 1 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(answers == 1 and detail.get_node("Canvas").visible, "Target Client open tool failed")
	voice.transport.send_endpoint_transcript({"text": "智能助手翻到第二页", "is_final": true, "utterance_id": 3, "recognition_epoch": 2})
	while answers < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(answers == 2 and int(detail.get_node("Canvas").page_index) == 2, "Target Client page tool failed")
	voice.transport.send_endpoint_transcript({"text": "普通交流", "is_final": true, "utterance_id": 4, "recognition_epoch": 2, "speaker_peer_id": 1, "source": "llm_assistant"})
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(routed == 0 and answers == 2, "Client routed locally or received other Client answers")
	_check(not voice.request_assistant_wake(), "Assistant remained available after Server disconnect")
	_check(int(voice.transport.transcription_pcm_packets_sent) == 0, "Client uploaded ASR PCM")
	_finish("client")


func _check(value: bool, detail: String) -> void:
	if not value:
		failed = true
		push_error(detail)


func _finish(role: String) -> void:
	print("Server hosted E2E %s %s." % [role, "FAILED" if failed else "passed"])
	quit(1 if failed else 0)
