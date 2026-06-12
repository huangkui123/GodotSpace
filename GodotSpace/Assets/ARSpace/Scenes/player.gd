extends Node3D

const LOCAL_XR_NODE_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D"),
	NodePath("XROrigin3D/XRCamera3D"),
	NodePath("XROrigin3D/LeftHand"),
	NodePath("XROrigin3D/RightHand"),
	NodePath("XROrigin3D/PlayerBody"),
]

const REMOTE_INHERIT_TRANSFORM_PATHS: Array[NodePath] = [
	NodePath("XROrigin3D/LeftHand/LeftHand"),
	NodePath("XROrigin3D/RightHand/RightHand"),
]

@onready var xr_camera = $XROrigin3D/XRCamera3D

func _enter_tree():
	var peer_id := _get_peer_id_from_name()
	set_multiplayer_authority(peer_id, true)
	_configure_local_xr_nodes(_is_local_authority())
	call_deferred("_refresh_authority_configuration")

func _ready():
	var peer_id := _get_peer_id_from_name()
	set_multiplayer_authority(peer_id, true)
	_configure_local_xr_nodes(_is_local_authority())

	if _is_local_authority() and not multiplayer.is_server() and not OS.get_cmdline_args().has("--testmode"):
		xr_camera.make_current()

func _process(delta: float):
	if not _is_local_authority():
		# if multiplayer.is_server():
		# 	print("当前服务器: ", multiplayer.multiplayer_peer.get_packet())
		# 	# 接收数据包
		# 	while multiplayer.get_peers().size() > 0 and multiplayer.multiplayer_peer.get_available_packet_count() > 0:
		# 		var pkt = bytes_to_var(multiplayer.multiplayer_peer.get_packet())
		# 		print("收到数据包: ", pkt)
		return
	
	# 传输数据 - 只监听按键输入并在有按键时传输
	var button_data = {}
	var has_button_pressed = false
	
	# 获取XR控制器按键输入
	var xr_interface = XRServer.primary_interface
	if xr_interface:
		# 左手控制器按键
		var left_controller = XRServer.get_tracker("left_hand")
		if left_controller:
			var left_buttons = {}
			var trigger = left_controller.get_input("trigger")
			var grip = left_controller.get_input("grip")
			var primary = left_controller.get_input("primary")
			var secondary = left_controller.get_input("secondary")

			if trigger != null and trigger > 0:
				left_buttons["trigger"] = trigger
				has_button_pressed = true
			if grip != null and grip > 0:
				left_buttons["grip"] = grip
				has_button_pressed = true
			if primary != null and primary:
				left_buttons["primary"] = primary
				has_button_pressed = true
			if secondary != null and secondary:
				left_buttons["secondary"] = secondary
				has_button_pressed = true
			
			if not left_buttons.is_empty():
				button_data["left_hand"] = left_buttons
		
		# 右手控制器按键
		var right_controller = XRServer.get_tracker("right_hand")
		if right_controller:
			var right_buttons = {}
			var trigger = right_controller.get_input("trigger")
			var grip = right_controller.get_input("grip")
			var primary = right_controller.get_input("primary")
			var secondary = right_controller.get_input("secondary")
			
			if trigger != null and trigger > 0:
				right_buttons["trigger"] = trigger
				rpc_id(1, "trigger_pressed")
				has_button_pressed = true
			if grip != null and grip > 0:
				right_buttons["grip"] = grip
				has_button_pressed = true
			if primary != null and primary:
				right_buttons["primary"] = primary
				has_button_pressed = true
			if secondary != null and secondary:
				right_buttons["secondary"] = secondary
				has_button_pressed = true
			
			if not right_buttons.is_empty():
				button_data["right_hand"] = right_buttons
	
	# 只在有按键被按下时传输数据包
	if has_button_pressed and multiplayer.multiplayer_peer:
		# print("发送按键数据包: ", button_data)
		var pkt = var_to_bytes(button_data)
		multiplayer.multiplayer_peer.put_packet(pkt)

func _physics_process(delta: float):
	if not _is_local_authority():
		return

func _get_peer_id_from_name() -> int:
	var peer_id := name.to_int()
	if peer_id <= 0:
		return 1
	return peer_id

func _is_local_authority() -> bool:
	if multiplayer.has_multiplayer_peer():
		return is_multiplayer_authority()
	return _get_peer_id_from_name() == 1

func _configure_local_xr_nodes(is_local_authority: bool) -> void:
	var xr_origin := get_node_or_null("XROrigin3D") as XROrigin3D
	var camera := get_node_or_null("XROrigin3D/XRCamera3D") as Camera3D
	var player_body := get_node_or_null("XROrigin3D/PlayerBody")

	if xr_origin != null:
		xr_origin.current = is_local_authority

	if camera != null:
		camera.current = is_local_authority

	var process_mode_for_nodes := Node.PROCESS_MODE_INHERIT if is_local_authority else Node.PROCESS_MODE_DISABLED
	for node_path in LOCAL_XR_NODE_PATHS:
		var local_node := get_node_or_null(node_path)
		if local_node != null:
			local_node.process_mode = process_mode_for_nodes

	for node_path in REMOTE_INHERIT_TRANSFORM_PATHS:
		var remote_visual := get_node_or_null(node_path) as Node3D
		if remote_visual != null:
			remote_visual.top_level = is_local_authority

	if player_body != null:
		player_body.set("enabled", is_local_authority)
		if player_body is CollisionObject3D:
			var collision_body := player_body as CollisionObject3D
			collision_body.collision_layer = 524288 if is_local_authority else 0
			collision_body.collision_mask = 1023 if is_local_authority else 0

func _refresh_authority_configuration() -> void:
	var peer_id := _get_peer_id_from_name()
	set_multiplayer_authority(peer_id, true)
	_configure_local_xr_nodes(_is_local_authority())
