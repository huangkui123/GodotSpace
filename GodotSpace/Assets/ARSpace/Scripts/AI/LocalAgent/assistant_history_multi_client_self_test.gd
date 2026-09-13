extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--history-server"):
		await _run_server()
	elif args.has("--history-client-1"):
		await _run_client(0.25)
	elif args.has("--history-client-2"):
		await _run_client(0.75)
	else:
		_fail("Specify a history multi-client role.")


func _run_server() -> void:
	var network := root.get_node_or_null("NetworkHandler")
	var router := root.get_node_or_null("AssistantCommandRouter")
	var assistant := root.get_node_or_null("LLMAssistantService")
	if network == null or router == null or assistant == null or not network.start_server():
		_fail("Unable to start assistant history Server.")
		return
	var deadline := Time.get_ticks_msec() + 10_000
	while root.multiplayer.get_peers().size() < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	if root.multiplayer.get_peers().size() != 2:
		_fail("Two history target Clients did not connect.")
		return
	for peer_id_value in root.multiplayer.get_peers():
		var peer_id := int(peer_id_value)
		router.rpc_id(
			peer_id,
			"_client_record_assistant_history",
			"history-%d" % peer_id,
			"客户端专属问题",
			"客户端专属回答",
			true,
			{"provider": "local_qwen_agent", "route": "tool", "tool_name": "open_album"}
		)
	await create_timer(0.5).timeout
	if not (assistant.call("get_qa_history") as Array).is_empty():
		_fail("Targeted Client history was also written into the Server history.")
		return
	var disconnect_deadline := Time.get_ticks_msec() + 3000
	while not root.multiplayer.get_peers().is_empty() and Time.get_ticks_msec() < disconnect_deadline:
		await process_frame
	print("Assistant history targeting Server self test passed.")
	quit(0)


func _run_client(disconnect_delay_seconds: float) -> void:
	var network := root.get_node_or_null("NetworkHandler")
	var assistant := root.get_node_or_null("LLMAssistantService")
	if network == null or assistant == null or not network.start_client("127.0.0.1"):
		_fail("Unable to start assistant history Client.")
		return
	var deadline := Time.get_ticks_msec() + 10_000
	while (assistant.call("get_qa_history") as Array).is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	var history := assistant.call("get_qa_history") as Array
	if history.size() != 1:
		_fail("Target Client received %d history entries instead of exactly one." % history.size())
		return
	var item := history[0] as Dictionary
	var metadata := item.get("metadata", {}) as Dictionary
	if str(item.get("question", "")) != "客户端专属问题" \
			or str(item.get("answer", "")) != "客户端专属回答" \
			or str(metadata.get("provider", "")) != "local_qwen_agent" \
			or metadata.has("speaker_peer_id"):
		_fail("Target Client history content or metadata is invalid.")
		return
	print("Assistant history target Client self test passed.")
	await create_timer(disconnect_delay_seconds).timeout
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
