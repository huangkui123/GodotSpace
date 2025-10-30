# 快速添加语音聊天到现有场景的示例
# 将此脚本附加到你的主场景节点
extends Node3D

# 可选：添加快捷键控制
func _ready():
	# 语音聊天会自动在网络就绪后启动
	print("✅ 场景已准备就绪，语音聊天功能可用")

# 可选：使用快捷键控制语音
func _input(event):
	# 按 V 键切换语音开关
	if event.is_action_pressed("toggle_voice"):
		VoiceChat.toggle_voice()
		print("按下 V 键 - 语音已" + ("开启" if VoiceChat.voice_enabled else "关闭"))
	
	# 按 M 键临时静音（按住说话模式）
	if event.is_action_pressed("push_to_talk"):
		VoiceChat.start_voice_chat()
		print("按住 M 键 - 开始说话")
	elif event.is_action_released("push_to_talk"):
		VoiceChat.stop_voice_chat()
		print("释放 M 键 - 停止说话")

# 网络按钮回调
func _on_server_button_pressed():
	NetworkHandler.start_server()
	print("🖥️ 服务器已启动")

func _on_client_button_pressed():
	NetworkHandler.start_client()
	print("🔌 正在连接服务器...")
