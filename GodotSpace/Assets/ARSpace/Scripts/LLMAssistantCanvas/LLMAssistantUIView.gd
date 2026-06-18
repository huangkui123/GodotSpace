extends Control

class_name LLMAssistantUIView

@onready var status_label: Label = $StatusLabel
@onready var transcript_label: RichTextLabel = $Transcript
@onready var footer_label: Label = $Footer
@onready var page_label: Label = get_node_or_null("PageLabel") as Label
@onready var previous_button: Button = get_node_or_null("PreviousButton") as Button
@onready var next_button: Button = get_node_or_null("NextButton") as Button

var assistant: Node
var _history: Array = []
var _page_index := 0
var _task_catalog_provider: Node


func _ready() -> void:
	visible = false
	assistant = _get_assistant_service()
	_connect_assistant()
	if previous_button != null:
		previous_button.pressed.connect(_on_previous_pressed)
	if next_button != null:
		next_button.pressed.connect(_on_next_pressed)
	_render_empty_state()


func start_assistant() -> void:
	visible = true
	_sync_task_context()
	assistant = _get_assistant_service()
	_connect_assistant()
	_load_history(true)
	_render_history_page()


func stop_assistant() -> void:
	visible = false


func start_demo() -> void:
	start_assistant()


func stop_demo() -> void:
	stop_assistant()


func ask_text(question: String) -> void:
	var clean_question := question.strip_edges()
	if clean_question.is_empty():
		return
	_sync_task_context()
	assistant = _get_assistant_service()
	if assistant != null and assistant.has_method("ask"):
		assistant.call("ask", clean_question)


func refresh_task_context() -> void:
	_sync_task_context()
	if visible:
		_load_history(false)
		_render_history_page()


func set_task_catalog_provider(provider: Node) -> void:
	_task_catalog_provider = provider
	_sync_task_context()


func _get_assistant_service() -> Node:
	return get_node_or_null("/root/LLMAssistantService")


func _connect_assistant() -> void:
	if assistant == null or not assistant.has_signal("qa_history_changed"):
		return
	var callback := Callable(self, "_on_qa_history_changed")
	if not assistant.is_connected("qa_history_changed", callback):
		assistant.connect("qa_history_changed", callback)


func _load_history(follow_latest: bool) -> void:
	_history = []
	if assistant != null and assistant.has_method("get_qa_history"):
		_history = assistant.call("get_qa_history")
	if _history.is_empty():
		_page_index = 0
		return
	if follow_latest:
		_page_index = _history.size() - 1
	else:
		_page_index = clampi(_page_index, 0, _history.size() - 1)


func _render_history_page() -> void:
	if _history.is_empty():
		_render_empty_state()
		return

	var item = _history[_page_index]
	if typeof(item) != TYPE_DICTIONARY:
		_render_empty_state()
		return

	var data := item as Dictionary
	var question := str(data.get("question", "")).strip_edges()
	var answer := str(data.get("answer", "")).strip_edges()
	var success := bool(data.get("success", true))

	if status_label != null:
		status_label.text = "历史问答 %d / %d" % [_page_index + 1, _history.size()]
	if page_label != null:
		page_label.text = "%d / %d" % [_page_index + 1, _history.size()]
	if transcript_label != null:
		transcript_label.clear()
		transcript_label.append_text("[color=#FFD166][b]问题：[/b]%s[/color]" % _escape_bbcode(question if not question.is_empty() else "未记录问题"))
		transcript_label.append_text("\n\n")
		var answer_color := "#65D8FF" if success else "#FF8A8A"
		transcript_label.append_text("[color=%s][b]回答：[/b]%s[/color]" % [
			answer_color,
			_escape_bbcode(answer if not answer.is_empty() else "未记录回答"),
		])
	if footer_label != null:
		footer_label.text = _format_footer(data)
	_update_page_buttons()


func _render_empty_state() -> void:
	if status_label != null:
		status_label.text = "暂无历史问答"
	if page_label != null:
		page_label.text = "0 / 0"
	if transcript_label != null:
		transcript_label.clear()
		transcript_label.append_text("[color=#D7DEE8]暂无历史问答。\n\n语音开启并完成转写后，说出“助手”加问题即可触发回答。[/color]")
	if footer_label != null:
		footer_label.text = "智能助手在后台监听语音转写；此页只用于查看历史问答。"
	_update_page_buttons()


func _format_footer(data: Dictionary) -> String:
	var timestamp := str(data.get("timestamp", "")).strip_edges()
	var sources = data.get("sources", [])
	var labels: Array[String] = []
	if typeof(sources) == TYPE_ARRAY:
		for source in sources:
			if typeof(source) != TYPE_DICTIONARY:
				continue
			var item := source as Dictionary
			labels.append("%s / %s" % [str(item.get("source", "知识库")), str(item.get("title", "未命名条目"))])
	var source_text := "未命中本地知识条目" if labels.is_empty() else "依据：" + "；".join(labels)
	return "%s%s%s" % [
		timestamp,
		" / " if not timestamp.is_empty() else "",
		source_text,
	]


func _update_page_buttons() -> void:
	if previous_button != null:
		previous_button.disabled = _history.is_empty() or _page_index <= 0
	if next_button != null:
		next_button.disabled = _history.is_empty() or _page_index >= _history.size() - 1


func _on_previous_pressed() -> void:
	if _history.is_empty():
		return
	_page_index = max(0, _page_index - 1)
	_render_history_page()


func _on_next_pressed() -> void:
	if _history.is_empty():
		return
	_page_index = min(_history.size() - 1, _page_index + 1)
	_render_history_page()


func _on_qa_history_changed() -> void:
	var was_following_latest := _history.is_empty() or _page_index >= _history.size() - 1
	_load_history(was_following_latest)
	if visible:
		_render_history_page()


func _sync_task_context() -> void:
	assistant = _get_assistant_service()
	if assistant == null or not assistant.has_method("set_runtime_context_entries"):
		return

	var entries: Array[Dictionary] = []
	if _task_catalog_provider != null and is_instance_valid(_task_catalog_provider) \
			and _task_catalog_provider.has_method("get_task_context_entries"):
		_append_context_entries(entries, _task_catalog_provider.call("get_task_context_entries"))

	var global_node := get_node_or_null("/root/Global")
	var current_task = global_node.get("work_list_info_canvas") if global_node != null else null
	if current_task != null and is_instance_valid(current_task) \
			and current_task.has_method("get_current_task_context_entries"):
		_append_context_entries(entries, current_task.call("get_current_task_context_entries"))

	assistant.call("set_runtime_context_entries", entries)


func _append_context_entries(target: Array[Dictionary], source_entries: Variant) -> void:
	if typeof(source_entries) != TYPE_ARRAY:
		return
	for entry in source_entries:
		if typeof(entry) == TYPE_DICTIONARY:
			target.append((entry as Dictionary).duplicate(true))


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "\\[").replace("]", "\\]")
