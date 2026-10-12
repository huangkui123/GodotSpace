extends SceneTree


func _init() -> void:
	# UI-only fixture; networked capture readiness has a separate ENet test.
	ProjectSettings.set_setting("arspace/local_agent/execution_mode", "local")
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
	var wake_button := ui.get_node_or_null("PanelContainer/MarginContainer/Layout/TranscribeSection/AssistantWakeButton") as Button
	var interaction_label := ui.get_node_or_null("PanelContainer/MarginContainer/Layout/TranscribeSection/AssistantInteraction/Content/StatusLabel") as Label
	var command_label := ui.get_node_or_null("PanelContainer/MarginContainer/Layout/TranscribeSection/AssistantInteraction/Content/CommandBox/CommandText") as Label
	var countdown_bar := ui.get_node_or_null("PanelContainer/MarginContainer/Layout/TranscribeSection/AssistantInteraction/Content/CountdownBar") as ProgressBar
	if wake_button == null or interaction_panel == null or interaction_label == null or command_label == null or countdown_bar == null:
		_fail("VoiceChatUI missing assistant interaction panel.")
		return
	if (
		countdown_bar.custom_minimum_size.y < 10.0
		or not (countdown_bar.get_theme_stylebox("background") is StyleBoxFlat)
		or not (countdown_bar.get_theme_stylebox("fill") is StyleBoxFlat)
	):
		_fail("VoiceChatUI countdown bar does not have a visible track and fill style.")
		return
	var xr_scene: PackedScene = load("res://Assets/ARSpace/Scenes/voice_chat_ui_3d.tscn")
	var xr_ui := xr_scene.instantiate() if xr_scene != null else null
	var xr_transcript_box := xr_ui.get_node_or_null("Canvas/PanelContainer/MarginContainer/Layout/TranscribeSection/TranscriptBox") as Control if xr_ui != null else null
	var xr_countdown_bar := xr_ui.get_node_or_null("Canvas/PanelContainer/MarginContainer/Layout/TranscribeSection/AssistantInteraction/Content/CountdownBar") as ProgressBar if xr_ui != null else null
	if (
		xr_transcript_box == null
		or xr_countdown_bar == null
		or xr_transcript_box.custom_minimum_size.y > 150.0
		or xr_countdown_bar.custom_minimum_size.y < 10.0
		or not (xr_countdown_bar.get_theme_stylebox("fill") is StyleBoxFlat)
	):
		_fail("VoiceChatUI3D countdown bar can be clipped or lacks a visible fill style.")
		return
	xr_ui.free()
	var router := root.get_node_or_null("AssistantCommandRouter")
	if router == null:
		_fail("AssistantCommandRouter autoload is unavailable.")
		return
	# Headless has no microphone; fake only readiness and ASR ready notification.
	voice_chat.capture.is_setup = true
	wake_button.pressed.emit()
	if str(ui.get("assistant_interaction_state")) != "connecting" or countdown_bar.visible:
		_fail("Manual wake must wait for ASR readiness before counting down.")
		return
	voice_chat.set("_manual_wake_pending", false)
	voice_chat.call("_stop_peer_transcription", 1)
	voice_chat.assistant_capture_ready.emit(1)
	await process_frame
	if not interaction_panel.visible or interaction_label.text != "我在，请说。" or wake_button.text != "重新听写":
		_fail("Manual wake button did not enter the shared assistant listening state.")
		return
	router.call("_handle_wake_transcript", {"speaker_peer_id": 1, "utterance_id": 1, "text": "取消", "is_final": true})
	await process_frame
	var history_size_before := (voice_chat.call("get_transcript_history") as Array).size()
	voice_chat.call("publish_assistant_interaction_state", 1, "listening", "我在，请说。", {
		"command_text": "打开工作清单",
		"countdown_seconds": 5.0,
	})
	await process_frame
	if (
		not interaction_panel.visible
		or interaction_label.text != "我在，请说。"
		or command_label.text != "打开工作清单"
		or not countdown_bar.visible
		or countdown_bar.value <= 0.0
	):
		_fail("VoiceChatUI did not show the targeted assistant wake state.")
		return
	voice_chat.call("_on_transport_transcript_received", {
		"speaker_peer_id": 1,
		"speaker_name": "服务端",
		"text": "打开工作清单",
		"is_final": true,
		"utterance_id": 42,
	})
	await process_frame
	if transcript_label.text.find("打开工作清单") >= 0:
		_fail("Assistant command leaked into the main transcript box.")
		return
	if (voice_chat.call("get_transcript_history") as Array).size() != history_size_before:
		_fail("Assistant command leaked into transcript history.")
		return
	voice_chat.call("publish_assistant_interaction_state", 1, "idle")
	await process_frame
	if interaction_panel.visible:
		_fail("VoiceChatUI did not clear the assistant wake state.")
		return

	voice_chat.call("_on_transport_transcript_received", {
		"speaker_peer_id": 1,
		"speaker_name": "服务端",
		"text": "普通转写第一句",
		"is_final": false,
		"utterance_id": 1001,
		"timestamp_msec": 1001,
	})
	voice_chat.call("_on_transport_transcript_received", {
		"speaker_peer_id": 1,
		"speaker_name": "服务端",
		"text": "普通转写第二句",
		"is_final": false,
		"utterance_id": 1002,
		"timestamp_msec": 1002,
	})
	await process_frame
	if transcript_label.text.find("普通转写第一句") == -1 or transcript_label.text.find("普通转写第二句") == -1:
		_fail("Separate ordinary utterances must not overwrite each other's partial transcript rows.")
		return
	for utterance in [
		{"text": "普通转写第一句", "utterance_id": 1001},
		{"text": "普通转写第二句", "utterance_id": 1002},
	]:
		voice_chat.call("_on_transport_transcript_received", {
			"speaker_peer_id": 1,
			"speaker_name": "服务端",
			"text": utterance["text"],
			"is_final": true,
			"utterance_id": utterance["utterance_id"],
		})
	await process_frame
	if transcript_label.text.find("普通转写第一句") == -1 or transcript_label.text.find("普通转写第二句") == -1:
		_fail("Final ordinary utterances must remain as separate transcript rows.")
		return
	voice_chat.call("_on_transport_transcript_received", {
		"speaker_peer_id": 1,
		"speaker_name": "服务端",
		"text": "普通转写仍在识别",
		"is_final": false,
		"utterance_id": 1003,
		"timestamp_msec": 1003,
	})
	await process_frame

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
	if transcript_label.text.find("保持防静电接地") < transcript_label.text.find("普通转写仍在识别"):
		_fail("A newer assistant reply must render below an older partial transcript.")
		return
	voice_chat.call("_on_transport_transcript_received", {
		"speaker_peer_id": 1,
		"speaker_name": "服务端",
		"text": "普通转写仍在识别完成",
		"is_final": true,
		"utterance_id": 1003,
		"timestamp_msec": 1004,
	})
	await process_frame
	if transcript_label.text.find("保持防静电接地") < transcript_label.text.find("普通转写仍在识别完成"):
		_fail("Finalizing an older partial must not move it below a newer assistant reply.")
		return

	print("LLM assistant voice panel self test passed.")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
