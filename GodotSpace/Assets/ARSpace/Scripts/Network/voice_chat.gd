# voice_chat.gd - 使用 two-voip 插件重写
extends Node

# 语音设置
var voice_enabled: bool = true

# 音频播放器字典 {peer_id: AudioStreamPlayer}
var voice_players: Dictionary = {}

# 麦克风相关
var mic_capture: AudioEffectOpusChunked
var recording_player: AudioStreamPlayer

# 统计信息
var packets_received: int = 0
var packets_sent: int = 0

func _ready():
	# 连接多人游戏信号
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
	# 等待网络就绪
	if NetworkHandler.has_signal("network_ready"):
		NetworkHandler.network_ready.connect(_on_network_ready)
	
	# 设置音频捕获
	_setup_audio_capture()
	
	print("🎤 语音聊天系统已初始化 (使用 two-voip)")

# 设置音频捕获
func _setup_audio_capture():
	# 获取或创建 Mic 音频总线
	var bus_index = AudioServer.get_bus_index("Mic")
	if bus_index == -1:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, "Mic")
		print("✅ 创建了新的 Mic 音频总线，索引: %d" % bus_index)
	else:
		print("✅ 使用现有的 Mic 音频总线，索引: %d" % bus_index)
	
	# 确保总线上有 OpusChunked 效果
	var has_opus_effect = false
	for i in range(AudioServer.get_bus_effect_count(bus_index)):
		var effect = AudioServer.get_bus_effect(bus_index, i)
		if effect is AudioEffectOpusChunked:
			mic_capture = effect
			has_opus_effect = true
			print("✅ 找到现有的 OpusChunked 效果")
			break
	
	# 如果没有，添加新的 OpusChunked 效果
	if not has_opus_effect:
		mic_capture = AudioEffectOpusChunked.new()
		AudioServer.add_bus_effect(bus_index, mic_capture)
		AudioServer.set_bus_effect_enabled(bus_index, AudioServer.get_bus_effect_count(bus_index) - 1, true)
		print("✅ 添加了新的 OpusChunked 效果")
	
	# 设置总线为静音（避免回声）
	AudioServer.set_bus_mute(bus_index, true)
	
	# 创建麦克风录音播放器
	recording_player = AudioStreamPlayer.new()
	recording_player.stream = AudioStreamMicrophone.new()
	recording_player.bus = "Mic"
	recording_player.autoplay = true
	recording_player.mix_target = AudioStreamPlayer.MIX_TARGET_STEREO  # 确保音频输出到VR头显
	add_child(recording_player)
	
	print("✅ 音频捕获已设置，麦克风已启动")
	print("📊 可用音频输入设备: %s" % str(AudioServer.get_input_device_list()))

# 网络准备就绪
func _on_network_ready():
	print("🌐 网络已就绪，语音聊天可用")

# 多人游戏信号处理
func _on_peer_connected(id: int):
	print("🔗 玩家 %d 已连接" % id)
	# 为新连接的玩家创建音频播放器
	_get_or_create_player(id)

func _on_peer_disconnected(id: int):
	print("❌ 玩家 %d 已断开连接" % id)
	remove_player(id)

func _on_connected_to_server():
	print("✅ 已连接到服务器")

func _on_connection_failed():
	print("❌ 连接服务器失败")

func _on_server_disconnected():
	print("❌ 服务器已断开连接")

# 切换语音开关
func toggle_voice():
	voice_enabled = not voice_enabled
	if voice_enabled:
		start_voice_chat()
	else:
		stop_voice_chat()
	print("🔊 语音" + ("开启" if voice_enabled else "关闭"))

# 开始语音聊天
func start_voice_chat():
	if not voice_enabled:
		voice_enabled = true
	
	var bus_index = AudioServer.get_bus_index("Mic")
	if bus_index != -1:
		AudioServer.set_bus_effect_enabled(bus_index, 0, true)
		set_process(true)
		print("🎙️ 开始录音...")

# 停止语音聊天
func stop_voice_chat():
	voice_enabled = false
	
	var bus_index = AudioServer.get_bus_index("Mic")
	if bus_index != -1:
		AudioServer.set_bus_effect_enabled(bus_index, 0, false)
		set_process(false)
		print("🛑 停止录音")

# 处理音频数据
func _process(_delta):
	if not voice_enabled or not multiplayer.has_multiplayer_peer():
		return
	
	if not mic_capture:
		return
	
	# 检查是否有可用的 Opus 数据块
	while mic_capture.chunk_available():
		# 读取 Opus 数据包
		var packet = mic_capture.read_opus_packet(PackedByteArray())
		mic_capture.drop_chunk()
		
		# 发送给其他玩家
		if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_voice_packet_received.rpc(packet)
			packets_sent += 1
			
			# 每100个包打印一次统计信息
			# if (packets_sent % 100) == 0:
			# 	print("📤 已发送数据包: %d (来自 ID %d)" % [packets_sent, multiplayer.get_unique_id()])

# 接收语音数据包
@rpc("any_peer", "unreliable")
func _voice_packet_received(packet: PackedByteArray):
	packets_received += 1
	
	# 每100个包打印一次统计信息
	# if (packets_received % 100) == 0:
	# 	print("📥 已接收数据包: %d (来自 ID %d)" % [packets_received, multiplayer.get_unique_id()])
	
	var sender_id = multiplayer.get_remote_sender_id()
	
	# 不播放自己的声音
	if sender_id == multiplayer.get_unique_id():
		return
	
	# 获取或创建对应玩家的音频播放器
	var player = _get_or_create_player(sender_id)
	
	# 推送 Opus 数据包到播放流
	if player and player.stream is AudioStreamOpusChunked:
		player.stream.push_opus_packet(packet, 0, 0)

# 获取或创建音频播放器
func _get_or_create_player(peer_id: int) -> AudioStreamPlayer:
	if not voice_players.has(peer_id):
		var player = AudioStreamPlayer.new()
		var stream = AudioStreamOpusChunked.new()
		player.stream = stream
		player.autoplay = true
		player.mix_target = AudioStreamPlayer.MIX_TARGET_STEREO  # 确保音频输出到VR头显
		add_child(player)
		voice_players[peer_id] = player
		print("🔊 为玩家 %d 创建 Opus 音频播放器" % peer_id)
	return voice_players[peer_id]

# 清理断开连接的玩家
func remove_player(peer_id: int):
	if voice_players.has(peer_id):
		var player = voice_players[peer_id]
		player.queue_free()
		voice_players.erase(peer_id)
		print("🗑️ 移除玩家 %d 的音频播放器" % peer_id)
