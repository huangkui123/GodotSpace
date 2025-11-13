# voice_chat.gd
extends Node

# 语音设置
const SAMPLE_RATE = 48000  # 采样率 (Hz) - 改为标准采样率以匹配麦克风
const BUFFER_SIZE = 512   # 缓冲区大小

# 语音状态
var is_recording: bool = false
var voice_enabled: bool = true

# 音频播放器字典 {peer_id: AudioStreamPlayer}
var voice_players: Dictionary = {}

# 录音相关
var audio_effect_capture: AudioEffectCapture
var playback: AudioStreamGeneratorPlayback
var recording_player: AudioStreamPlayer  # 用于录音的播放器

func _ready():
	# 等待网络就绪
	if NetworkHandler.has_signal("network_ready"):
		NetworkHandler.network_ready.connect(_on_network_ready)
	
	# 设置音频捕获
	_setup_audio_capture()
	
	print("🎤 语音聊天系统已初始化")

# 设置音频捕获
func _setup_audio_capture():
	# 获取或创建音频总线
	var bus_index = AudioServer.get_bus_index("Record")
	if bus_index == -1:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, "Record")
		print("✅ 创建了新的 Record 音频总线，索引: %d" % bus_index)
	else:
		print("✅ 使用现有的 Record 音频总线，索引: %d" % bus_index)
	
	# 添加捕获效果
	audio_effect_capture = AudioEffectCapture.new()
	audio_effect_capture.buffer_length = 0.1  # 100ms缓冲
	AudioServer.add_bus_effect(bus_index, audio_effect_capture)
	AudioServer.set_bus_mute(bus_index, true)  # 静音以避免回声
	
	# 创建麦克风录音播放器
	recording_player = AudioStreamPlayer.new()
	recording_player.stream = AudioStreamMicrophone.new()
	recording_player.bus = "Record"
	add_child(recording_player)
	recording_player.play()
	
	print("✅ 音频捕获已设置，麦克风已启动")
	print("📊 可用音频输入设备: %s" % str(AudioServer.get_input_device_list()))

# 网络准备就绪
func _on_network_ready():
	print("🌐 网络已就绪，语音聊天可用")
	if voice_enabled:
		start_voice_chat()

# 开始语音聊天
func start_voice_chat():
	if is_recording:
		return
	
	is_recording = true
	audio_effect_capture.clear_buffer()
	print("🎙️ 开始录音...")

# 停止语音聊天
func stop_voice_chat():
	if not is_recording:
		return
	
	is_recording = false
	print("🛑 停止录音")

# 切换语音开关
func toggle_voice():
	voice_enabled = not voice_enabled
	if voice_enabled:
		start_voice_chat()
	else:
		stop_voice_chat()
	print("🔊 语音" + ("开启" if voice_enabled else "关闭"))

# 处理音频数据
func _process(_delta):
	if not is_recording or not multiplayer.has_multiplayer_peer():
		return
	
	# 获取可用的帧数
	var frames_available = audio_effect_capture.get_frames_available()
	
	if frames_available > BUFFER_SIZE:
		# 捕获音频数据
		var audio_data = audio_effect_capture.get_buffer(BUFFER_SIZE)
		
		# 检查音频数据是否有效
		if audio_data.size() == 0:
			return
		
		# 将音频数据转换为字节数组以便传输
		var byte_data = _audio_to_bytes(audio_data)
		
		# 调试：检测音频信号强度
		var max_amplitude = 0.0
		for frame in audio_data:
			max_amplitude = max(max_amplitude, abs(frame.x))

		# print("max_amplitude: %.3f" % max_amplitude)
		
		# 只有当有声音时才发送（简单的噪音门限）
		if max_amplitude > 0.01:  # 噪音门限
			# 发送给其他客户端
			_send_voice_data.rpc(byte_data, multiplayer.get_unique_id())
			# 每隔一段时间输出调试信息
			# if Engine.get_process_frames() % 60 == 0:
			# 	print("📡 发送语音数据，振幅: %.3f, 大小: %d 字节" % [max_amplitude, byte_data.size()])

# 将音频帧转换为字节数组
func _audio_to_bytes(audio_frames: PackedVector2Array):
	var byte_array = PackedByteArray()
	for frame in audio_frames:
		# 只传输左声道并压缩数据
		var sample = int(clamp(frame.x * 32767.0, -32768.0, 32767.0))
		byte_array.append(sample & 0xFF)
		byte_array.append((sample >> 8) & 0xFF)
	return byte_array

# 将字节数组转换回音频帧
func _bytes_to_audio(byte_data: PackedByteArray) -> PackedVector2Array:
	var audio_frames = PackedVector2Array()
	for i in range(0, byte_data.size(), 2):
		if i + 1 < byte_data.size():
			var sample = (byte_data[i] | (byte_data[i + 1] << 8))
			# 处理有符号整数
			if sample > 32767:
				sample -= 65536
			var value = sample / 32767.0
			audio_frames.append(Vector2(value, value))
	return audio_frames

# 接收并播放语音数据
@rpc("any_peer", "unreliable")
func _send_voice_data(byte_data: PackedByteArray, sender_id: int):
	# 不播放自己的声音
	if sender_id == multiplayer.get_unique_id():
		return
	
	# print("🔊 接收到来自玩家 %d 的语音数据，大小: %d 字节" % [sender_id, byte_data.size()])
	
	# 获取或创建对应玩家的音频播放器
	var player = _get_or_create_player(sender_id)
	
	# 转换字节数据回音频
	var audio_frames = _bytes_to_audio(byte_data)
	
	# 播放音频
	_play_audio(player, audio_frames)

# 获取或创建音频播放器
func _get_or_create_player(peer_id: int):
	# print("🔊 获取或创建玩家 %d 的音频播放器" % peer_id)
	if not voice_players.has(peer_id):
		var player = AudioStreamPlayer.new()
		var stream = AudioStreamGenerator.new()
		stream.mix_rate = SAMPLE_RATE
		stream.buffer_length = 0.1  # 100ms缓冲
		player.stream = stream
		player.autoplay = true
		add_child(player)
		voice_players[peer_id] = player
		player.play()
		print("🔊 为玩家 %d 创建音频播放器" % peer_id)
	return voice_players[peer_id]

# 播放音频数据
func _play_audio(player: AudioStreamPlayer, audio_frames: PackedVector2Array):
	if not player.playing:
		player.play()
		print("▶️ 开始播放音频流")
	
	var playback_stream = player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback_stream:
		# 检查可用帧空间
		var frames_available = playback_stream.get_frames_available()
		if frames_available < audio_frames.size():
			print("⚠️ 播放缓冲区已满，可用: %d, 需要: %d" % [frames_available, audio_frames.size()])
		
		# 推送音频帧到播放器
		var pushed_count = 0
		for frame in audio_frames:
			if playback_stream.can_push_buffer(1):
				playback_stream.push_frame(frame)
				pushed_count += 1
		
		# if pushed_count > 0 and Engine.get_process_frames() % 60 == 0:
		# 	print("✅ 推送了 %d 帧音频到播放器" % pushed_count)
	else:
		print("❌ 无法获取播放流")

# 清理断开连接的玩家
func remove_player(peer_id: int):
	if voice_players.has(peer_id):
		var player = voice_players[peer_id]
		player.queue_free()
		voice_players.erase(peer_id)
		print("🗑️ 移除玩家 %d 的音频播放器" % peer_id)

# 当玩家断开连接时调用
func _on_player_disconnected(peer_id: int):
	remove_player(peer_id)
