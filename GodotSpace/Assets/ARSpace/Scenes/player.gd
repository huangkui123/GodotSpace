extends Node3D

@onready var xr_camera = $XROrigin3D/XRCamera3D

func _enter_tree():
	set_multiplayer_authority(name.to_int())

func _ready():
	if not multiplayer.is_server() and not OS.get_cmdline_args().has("--testmode"):
		xr_camera.make_current()

func _process(delta: float):
	if not is_multiplayer_authority():
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
	if not is_multiplayer_authority():
		return
		
