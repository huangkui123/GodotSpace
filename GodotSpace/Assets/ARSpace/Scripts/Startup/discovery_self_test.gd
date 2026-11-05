extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var server := PacketPeerUDP.new()
	if server.bind(42070, "127.0.0.1") != OK:
		push_error("Discovery test requires loopback UDP 42070 to be free")
		quit(1)
		return
	var runtime := root.get_node("SessionRuntime")
	var expected_lan := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--expect-lan="):
			expected_lan = argument.trim_prefix("--expect-lan=")
	runtime.call("discover_servers")
	var received := 0
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		while server.get_available_packet_count() > 0:
			var packet := server.get_packet()
			var address := server.get_packet_ip()
			var port := server.get_packet_port()
			if packet.get_string_from_utf8() != "GODOTSPACE_DISCOVER_1":
				continue
			received += 1
			# Drop the first request to verify discovery retries.
			if received > 1:
				server.set_dest_address(address, port)
				server.put_packet(JSON.stringify({"type": "godotspace_server", "version": 1,
					"name": "Discovery test", "port": 42069}).to_utf8_buffer())
		var found: Dictionary = runtime.get("discovered_servers")
		if found.get("127.0.0.1") == "Discovery test" and (expected_lan.is_empty() or found.has(expected_lan)):
			print("Discovery self-test passed: reply received after dropped request; targets=", runtime.get("_discovery_targets"))
			print("Discovered servers: ", found)
			server.close()
			quit(0)
			return
		await create_timer(0.05).timeout
	server.close()
	push_error("Discovery retries did not recover the dropped request")
	quit(1)
