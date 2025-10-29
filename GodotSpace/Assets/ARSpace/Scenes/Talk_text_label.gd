extends RichTextLabel

# 初始化函数
func _ready():
	# 启用BBCode以便可以使用颜色等格式
	self.bbcode_enabled = true
	# 清空初始文本
	self.text = ""
	
	# 模拟对话
	simulate_dialogue()

# 添加对话的函数
func add_dialog(speaker: String, message: String):
	# 根据说话者选择颜色
	var color = "#FFFFFF"  # 默认白色
	
	match speaker:
		"地面":
			color = "#FFFFFF"  # 绿色
		"航天员":
			color = "#00BFFF"  # 深天蓝色
	
	# 格式化对话文本
	var formatted_text = "[color={color}]{speaker}：{message}[/color]".format({
		"color": color,
		"speaker": speaker,
		"message": message
	})
	
	# 如果已有文本，先添加换行
	if self.text != "":
		self.text += "\n"
	
	# 添加新对话
	self.text += formatted_text
	
	# 自动滚动到底部显示最新消息
	self.scroll_to_line(self.get_line_count())

# 清空所有对话
func clear_dialog():
	self.text = ""

# 模拟对话函数
func simulate_dialogue():
	# 使用await替代yield
	await get_tree().create_timer(0.5).timeout
	add_dialog("地面", "神舟飞船，这里是北京航天飞行控制中心，听到请回答")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "北京，神舟飞船收到，声音清晰，状态良好")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "收到，当前飞船各系统工作正常，轨道参数符合预期")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "明白，我们正在按计划进行在轨检查，舱内环境舒适")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "很好，下一阶段将进行交会对接演练，请做好准备")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "收到，已开始准备交会对接程序，设备检查中")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "注意监控燃料余量和姿态控制系统，保持通信畅通")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "明白，燃料充足，姿态稳定，我们将持续报告状态")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "预计一小时后进行下一次轨道修正，请关注指令")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "收到，已设置提醒，等待下一步指令")
	
	await get_tree().create_timer(0.5).timeout
	add_dialog("地面", "神舟飞船，这里是北京航天飞行控制中心，听到请回答")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "北京，神舟飞船收到，声音清晰，状态良好")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "收到，当前飞船各系统工作正常，轨道参数符合预期")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "明白，我们正在按计划进行在轨检查，舱内环境舒适")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "很好，下一阶段将进行交会对接演练，请做好准备")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "收到，已开始准备交会对接程序，设备检查中")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "注意监控燃料余量和姿态控制系统，保持通信畅通")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "明白，燃料充足，姿态稳定，我们将持续报告状态")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("地面", "预计一小时后进行下一次轨道修正，请关注指令")
	
	await get_tree().create_timer(1.0).timeout
	add_dialog("航天员", "收到，已设置提醒，等待下一步指令")

# 外部调用接口 - 用于实际接收消息
func receive_message(speaker: String, message: String):
	add_dialog(speaker, message)
