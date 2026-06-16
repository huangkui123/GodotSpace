extends RichTextLabel

const GROUND_COLOR := "#65D8FF"
const ASTRONAUT_COLOR := "#FFD166"
const PARTIAL_CURSOR_COLOR := "#D7DEE8"
const DEMO_DIALOGUE := [
	{
		"speaker": "服务端",
		"final": "神舟飞船，这里是北京航天飞行控制中心，听到请回答",
		"partials": [
			"神舟飞船，这里是北京航天飞控中心",
			"神舟飞船，这里是北京航天飞行控制中心，听到请回",
			"神舟飞船，这里是北京航天飞行控制中心，听到请回答",
		],
	},
	{
		"speaker": "客户端 2",
		"final": "北京，神舟飞船收到，声音清晰，状态良好",
		"partials": [
			"北京，神舟飞船收到",
			"北京，神舟飞船收到，声音清西，状态良",
			"北京，神舟飞船收到，声音清晰，状态良好",
		],
	},
	{
		"speaker": "服务端",
		"final": "收到，当前飞船各系统工作正常，轨道参数符合预期",
		"partials": [
			"收到，当前飞船各系统工作正常",
			"收到，当前飞船各系统工作正常，轨道参数复合预期",
			"收到，当前飞船各系统工作正常，轨道参数符合预期",
		],
	},
	{
		"speaker": "客户端 2",
		"final": "明白，我们正在按计划进行在轨检查，舱内环境舒适",
		"partials": [
			"明白，我们正在按计划进行在轨检",
			"明白，我们正在按计划进行在轨检查，舱内环境舒",
			"明白，我们正在按计划进行在轨检查，舱内环境舒适",
		],
	},
]

var completed_text := ""
var partial_speaker := ""
var partial_text := ""


func _ready() -> void:
	bbcode_enabled = true
	text = ""
	simulate_dialogue()


func add_dialog(speaker: String, message: String) -> void:
	partial_speaker = ""
	partial_text = ""
	if completed_text != "":
		completed_text += "\n"
	completed_text += _format_dialog_line(speaker, message, false)
	_update_text()


func clear_dialog() -> void:
	completed_text = ""
	partial_speaker = ""
	partial_text = ""
	_update_text()


func simulate_dialogue() -> void:
	await get_tree().create_timer(4.0).timeout
	for line in DEMO_DIALOGUE:
		var speaker := str(line.get("speaker", ""))
		var final_text := str(line.get("final", ""))
		var partials: Array = line.get("partials", [])
		for partial in partials:
			partial_speaker = speaker
			partial_text = str(partial)
			_update_text()
			await get_tree().create_timer(_get_partial_delay(partial_text)).timeout

		add_dialog(speaker, final_text)
		await get_tree().create_timer(1.7).timeout


func receive_message(speaker: String, message: String) -> void:
	add_dialog(speaker, message)


func _update_text() -> void:
	var body := completed_text
	if partial_text != "":
		if body != "":
			body += "\n"
		body += _format_dialog_line(partial_speaker, partial_text, true)
	text = body
	scroll_to_line(get_line_count())


func _format_dialog_line(speaker: String, message: String, is_partial: bool) -> String:
	var cursor := "[color=%s]|[/color]" % PARTIAL_CURSOR_COLOR if is_partial else ""
	return "[color=%s]%s：%s%s[/color]" % [_get_speaker_color(speaker), speaker, message, cursor]


func _get_speaker_color(speaker: String) -> String:
	if speaker.begins_with("客户端"):
		return ASTRONAUT_COLOR
	return GROUND_COLOR


func _get_partial_delay(message: String) -> float:
	return clampf(1.2 + float(message.length()) * 0.045, 1.7, 3.2)
