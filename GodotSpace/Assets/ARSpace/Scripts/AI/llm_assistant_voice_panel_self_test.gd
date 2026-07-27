extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load("res://Assets/ARSpace/Scenes/voice_chat_ui.tscn")
	if scene == null:
		_fail("Unable to load voice_chat_ui scene.")
		return

	var ui := scene.instantiate()
	root.add_child(ui)
	await process_frame

	var assistant := root.get_node_or_null("LLMAssistantService")
	if assistant == null:
		_fail("LLMAssistantService autoload is unavailable.")
		return
	var voice_chat := root.get_node_or_null("VoiceChat")
	if voice_chat == null or not voice_chat.has_method("publish_assistant_transcript"):
		_fail("VoiceChat autoload cannot publish assistant transcripts.")
		return

	var transcript_label := ui.get_node_or_null("PanelContainer/MarginContainer/Layout/TranscribeSection/TranscriptBox/TranscriptLabel") as RichTextLabel
	if transcript_label == null:
		_fail("VoiceChatUI missing transcript label.")
		return
	var interaction_panel := ui.get_node_or_null("PanelContainer/MarginContainer/Layout/TranscribeSection/AssistantInteraction") as Control
	var interaction_label := ui.get_node_or_null("PanelContainer/MarginContainer/Layout/TranscribeSection/AssistantInteraction/Label") as Label
	if interaction_panel == null or interaction_label == null:
		_fail("VoiceChatUI missing assistant interaction panel.")
		return
	voice_chat.call("publish_assistant_interaction_state", 1, "listening", "我在，请说。")
	await process_frame
	if not interaction_panel.visible or interaction_label.text != "我在，请说。":
		_fail("VoiceChatUI did not show the targeted assistant wake state.")
		return
	voice_chat.call("publish_assistant_interaction_state", 1, "idle")
	await process_frame
	if interaction_panel.visible:
		_fail("VoiceChatUI did not clear the assistant wake state.")
		return

	assistant.answer_started.emit("当前步骤需要做什么")
	await process_frame
	if transcript_label.text.find("正在分析问题") == -1:
		_fail("VoiceChatUI did not show assistant pending state.")
		return

	assistant.answer_completed.emit("当前步骤需要做什么", "保持防静电接地，并按目标力矩操作。", [])
	voice_chat.call("publish_assistant_transcript", "保持防静电接地，并按目标力矩操作。", "智能助手")
	await process_frame
	if transcript_label.text.find("正在分析问题") != -1:
		_fail("VoiceChatUI did not clear assistant pending state.")
		return
	if transcript_label.text.find("智能助手") == -1 or transcript_label.text.find("保持防静电接地") == -1:
		_fail("VoiceChatUI did not show assistant reply in transcript box.")
		return

	print("LLM assistant voice panel self test passed.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
