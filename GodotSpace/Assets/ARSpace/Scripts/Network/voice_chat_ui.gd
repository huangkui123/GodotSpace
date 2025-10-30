# voice_chat_ui.gd
# 语音聊天UI控制脚本
extends Control

@onready var voice_button: Button = $VoiceButton
@onready var status_label: Label = $StatusLabel

func _ready():
	# 连接按钮信号
	if voice_button:
		voice_button.pressed.connect(_on_voice_button_pressed)
		_update_ui()
	
	# 监听网络状态
	if NetworkHandler.has_signal("network_ready"):
		print("fuck you")
		NetworkHandler.network_ready.connect(_on_network_ready)
	
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

# 语音按钮点击
func _on_voice_button_pressed():
	VoiceChat.toggle_voice()
	_update_ui()

# 更新UI显示
func _update_ui():
	if voice_button:
		if VoiceChat.voice_enabled:
			voice_button.text = "🎤 语音开启"
			voice_button.modulate = Color.GREEN
		else:
			voice_button.text = "🔇 语音关闭"
			voice_button.modulate = Color.RED
	
	_update_status()

# 更新状态文本
func _update_status():
	if status_label:
		var peer_count = multiplayer.get_peers().size()
		if peer_count > 0:
			status_label.text = "已连接 %d 个玩家" % peer_count
		else:
			status_label.text = "等待连接..."

# 网络就绪
func _on_network_ready():
	_update_status()

# 玩家断开连接
func _on_peer_disconnected(peer_id: int):
	VoiceChat.remove_player(peer_id)
	_update_status()

func _process(delta):
	_update_status()
