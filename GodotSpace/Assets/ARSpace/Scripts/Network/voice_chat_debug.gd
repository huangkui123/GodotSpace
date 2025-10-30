# voice_chat_debug.gd
# 语音聊天调试工具
extends Node

var test_player: AudioStreamPlayer

func _ready():
	print("\n=== 🔍 语音聊天调试工具 ===")
	_check_audio_devices()
	_check_audio_server()
	# _test_microphone()

# 检查音频设备
func _check_audio_devices():
	print("\n📱 音频设备检查:")
	var input_devices = AudioServer.get_input_device_list()
	print("  输入设备数量: %d" % input_devices.size())
	for i in range(input_devices.size()):
		print("  - [%d] %s" % [i, input_devices[i]])
	
	var output_devices = AudioServer.get_output_device_list()
	print("  输出设备数量: %d" % output_devices.size())
	for i in range(output_devices.size()):
		print("  - [%d] %s" % [i, output_devices[i]])
	
	print("  当前输入设备: %s" % AudioServer.get_input_device())
	print("  当前输出设备: %s" % AudioServer.get_output_device())

# 检查音频服务器
func _check_audio_server():
	print("\n🔊 音频服务器检查:")
	print("  总线数量: %d" % AudioServer.bus_count)
	for i in range(AudioServer.bus_count):
		var bus_name = AudioServer.get_bus_name(i)
		var is_mute = AudioServer.is_bus_mute(i)
		var volume = AudioServer.get_bus_volume_db(i)
		print("  - 总线 [%d] '%s': 静音=%s, 音量=%.1fdB" % [i, bus_name, is_mute, volume])
		
		# 检查效果
		var effect_count = AudioServer.get_bus_effect_count(i)
		if effect_count > 0:
			print("    效果数量: %d" % effect_count)
			for j in range(effect_count):
				var effect = AudioServer.get_bus_effect(i, j)
				print("      - [%d] %s (启用: %s)" % [j, effect.get_class(), AudioServer.is_bus_effect_enabled(i, j)])

# 测试麦克风
func _test_microphone():
	print("\n🎤 麦克风测试:")
	print("  创建测试音频播放器...")
	
	test_player = AudioStreamPlayer.new()
	test_player.stream = AudioStreamMicrophone.new()
	test_player.bus = "Master"  # 直接输出到主总线用于测试
	add_child(test_player)
	test_player.play()
	
	print("  ✅ 麦克风测试播放器已创建")
	print("  💡 如果能听到自己的声音（回声），说明麦克风工作正常")
	print("  💡 按 T 键切换测试播放器（听到自己的声音）")

func _input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_T:
		if test_player:
			if test_player.stream_paused:
				test_player.stream_paused = false
				print("🔊 麦克风测试: 开启 (应该能听到自己的声音)")
			else:
				test_player.stream_paused = true
				print("🔇 麦克风测试: 关闭")

func _process(_delta):
	# 监控音频捕获状态
	if Engine.get_process_frames() % 120 == 0:  # 每2秒
		_monitor_voice_chat()

func _monitor_voice_chat():
	if not VoiceChat:
		return
	
	# print("\n📊 语音聊天状态:")
	# print("  录音中: %s" % VoiceChat.is_recording)
	# print("  语音启用: %s" % VoiceChat.voice_enabled)
	# print("  网络连接: %s" % multiplayer.has_multiplayer_peer())
	
	# if multiplayer.has_multiplayer_peer():
	# 	print("  本地ID: %d" % multiplayer.get_unique_id())
	# 	print("  连接的玩家: %s" % str(multiplayer.get_peers()))
	
	# print("  活跃的语音播放器: %d" % VoiceChat.voice_players.size())
	# for peer_id in VoiceChat.voice_players:
	# 	var player = VoiceChat.voice_players[peer_id]
	# 	print("    - 玩家 %d: 播放中=%s" % [peer_id, player.playing])
	
	# # 检查音频捕获
	# if VoiceChat.audio_effect_capture:
	# 	var frames = VoiceChat.audio_effect_capture.get_frames_available()
	# 	print("  音频捕获可用帧: %d" % frames)
