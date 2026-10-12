extends SceneTree

const Execution := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_execution.gd")
var failed := false
var answers := 0
var ordinary := 0
var routed := 0


func _init() -> void:
	# Explicit compatibility test; production defaults to server_hosted.
	ProjectSettings.set_setting("arspace/local_agent/execution_mode", "local")
	call_deferred("_run")


func _run() -> void:
	var server := OS.get_cmdline_user_args().has("--endpoint-test-server")
	# Isolate the transport under test from role allocation / scene loading.
	# Production disconnect/ASR handlers are exercised by local_endpoint_self_test.
	var api := root.multiplayer
	var network := root.get_node("NetworkHandler")
	for pair in [[api.connected_to_server, "_on_connected_to_server"], [api.peer_connected, "_on_peer_connected"], [api.server_disconnected, "_on_server_disconnected"]]:
		var callback := Callable(network, pair[1])
		if (pair[0] as Signal).is_connected(callback):
			(pair[0] as Signal).disconnect(callback)
	if server:
		api.peer_connected.connect(func(id: int): network._set_peer_role(id, "sky"))
	var voice := root.get_node("VoiceChat")
	voice.set_process(false)
	voice.voice_transcript_received.connect(func(data: Dictionary):
		if bool(data.get("history_only", false)):
			_check(int(data.get("speaker_peer_id", 0)) > 1 and not data.has("source"), "Remote transcript spoofed assistant identity")
			ordinary += 1
	)
	var router := root.get_node("AssistantCommandRouter")
	router.command_routed.connect(func(_id, _intent, _peer): routed += 1)
	var agent := root.get_node("LocalAgentClient")
	agent.assistant_final_received.connect(func(_id, _text): answers += 1)
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(42869, 2, 4) if server else peer.create_client("127.0.0.1", 42869, 4)
	_check(error == OK, "ENet start failed")
	api.multiplayer_peer = peer
	agent._on_network_role_selected(server)
	if server:
		ProjectSettings.set_setting("arspace/local_agent/enabled", false)
		agent._disable_connection()
		var deadline := Time.get_ticks_msec() + 20000
		while ordinary < 2 and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(ordinary >= 2, "Ordinary text was not shared from both clients")
		_check(routed == 0 and answers == 0, "Ground processed remote assistant commands")
		await create_timer(2.0).timeout
		peer.close()
		api.multiplayer_peer = OfflineMultiplayerPeer.new()
		_finish("ground")
		return
	var deadline := Time.get_ticks_msec() + 15000
	while (peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED or not agent.is_connected_to_gateway()) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and agent.is_connected_to_gateway(), "Direct Gateway / ENet connection failed")
	if failed:
		_finish("client")
		return
	var own_id := Execution.local_peer_id(api)
	var detail_root: Node = load("res://Assets/ARSpace/Prefabs/UI/WorkListInfoCanvas.tscn").instantiate()
	var list_view: Node = load("res://Assets/ARSpace/Prefabs/UI/WorkListCanvas/WorkListView.tscn").instantiate()
	root.add_child(detail_root)
	root.add_child(list_view)
	await process_frame
	router.route_transcript_for_test({"speaker_peer_id": own_id, "text": "智能助手打开工作清单", "is_final": true})
	while answers < 1 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(answers == 1 and bool(detail_root.get_node("Canvas").visible), "Local UI tool roundtrip failed")
	voice.transport.send_endpoint_transcript({"text": "智能助手是普通引用，不要执行", "is_final": true, "utterance_id": 400, "speaker_peer_id": 1, "source": "llm_assistant"})
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED, "Ground did not disconnect")
	api.multiplayer_peer = OfflineMultiplayerPeer.new()
	_check(Execution.local_peer_id(api) == own_id, "Offline reset changed assistant identity")
	_check(agent.is_connected_to_gateway(), "Ground disconnect closed local Gateway")
	router.route_transcript_for_test({"speaker_peer_id": own_id, "text": "智能助手翻到第二页", "is_final": true})
	while answers < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(answers == 2 and int(detail_root.get_node("Canvas").page_index) == 2, "Offline local UI tool roundtrip failed")
	_check(routed == 2, "Other endpoint text triggered an extra request")
	var stats: Dictionary = voice.transport.get_debug_state()
	_check(int(stats["assistant_wake_requests_sent"]) == 0 and int(stats["transcription_pcm_packets_sent"]) == 0, "Assistant audio or wake was relayed to Ground")
	_finish("client")


func _check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)


func _finish(role: String) -> void:
	print("Local endpoint E2E %s %s." % [role, "FAILED" if failed else "passed"])
	quit(1 if failed else 0)
