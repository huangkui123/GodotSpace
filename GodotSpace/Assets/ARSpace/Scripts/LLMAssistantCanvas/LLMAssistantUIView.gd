extends Control

class_name LLMAssistantUIView

@onready var status_label: Label = $StatusLabel
@onready var transcript_label: RichTextLabel = $Transcript

const LLM_QUESTION := "氧气分压缓慢下降时，优先检查什么"
const LLM_ANSWER := "优先复核传感器读数，确认氧气供给阀门状态，并检查舱门密封圈和设备接口。若趋势持续，按环境异常流程上报。"
const DEFAULT_STATUS := "知识库：航天员手册 / 舱内环境控制 / 专家任务指导"
const QUESTION_TRANSCRIPT_STEPS := [
	"氧气分压",
	"氧气分压缓慢降",
	"氧气分压缓慢下降时，优先检查",
	LLM_QUESTION
]
const QUESTION_TRANSCRIPT_DELAYS := [1.25, 1.5, 1.65, 1.9]

var _demo_run_id := 0
var _transcript_lines: Array[String] = []

func _ready() -> void:
	self.visible = false
	_reset_demo_text()

func start_demo() -> void:
	_start_llm_demo()

func stop_demo() -> void:
	_demo_run_id += 1

func _start_llm_demo() -> void:
	_demo_run_id += 1
	var run_id := _demo_run_id
	_reset_demo_text()
	_run_llm_demo(run_id)

func _reset_demo_text() -> void:
	if status_label:
		status_label.text = DEFAULT_STATUS
	if transcript_label:
		transcript_label.clear()
	_transcript_lines.clear()

func _run_llm_demo(run_id: int) -> void:
	await get_tree().create_timer(3.0).timeout
	if not _is_demo_current(run_id):
		return

	status_label.text = "正在识别航天员语音..."
	await _play_question_transcription(run_id)
	if not _is_demo_current(run_id):
		return

	await get_tree().create_timer(2.8).timeout
	if not _is_demo_current(run_id):
		return

	status_label.text = "正在检索航天员手册和专家知识库..."
	_append_line("LLM助手", "正在检索相关手册条目...", "#65D8FF")
	await get_tree().create_timer(4.0).timeout
	if not _is_demo_current(run_id):
		return

	status_label.text = "已命中：环境控制系统异常趋势处置流程"
	_append_line("LLM助手", LLM_ANSWER, "#65D8FF")

func _play_question_transcription(run_id: int) -> void:
	for index in range(QUESTION_TRANSCRIPT_STEPS.size()):
		if not _is_demo_current(run_id):
			return

		_replace_last_line("航天员", QUESTION_TRANSCRIPT_STEPS[index], "#FFD166")
		await get_tree().create_timer(QUESTION_TRANSCRIPT_DELAYS[index]).timeout

func _append_line(speaker: String, message: String, color: String) -> void:
	_transcript_lines.append(_format_line(speaker, message, color))
	_render_transcript()

func _replace_last_line(speaker: String, message: String, color: String) -> void:
	var line := _format_line(speaker, message, color)
	if _transcript_lines.is_empty():
		_transcript_lines.append(line)
	else:
		_transcript_lines[_transcript_lines.size() - 1] = line
	_render_transcript()

func _format_line(speaker: String, message: String, color: String) -> String:
	return "[color=%s][b]%s：[/b]%s[/color]" % [color, speaker, message]

func _render_transcript() -> void:
	if transcript_label == null:
		return

	transcript_label.clear()
	for index in range(_transcript_lines.size()):
		if index > 0:
			transcript_label.append_text("\n\n")
		transcript_label.append_text(_transcript_lines[index])

func _is_demo_current(run_id: int) -> bool:
	return run_id == _demo_run_id and self.visible
