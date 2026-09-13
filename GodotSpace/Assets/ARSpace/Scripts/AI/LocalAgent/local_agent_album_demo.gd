extends SceneTree

var _picture_canvas: Control


func _init() -> void:
	call_deferred("_run")


func _process(_delta: float) -> bool:
	if Input.is_key_pressed(KEY_ESCAPE):
		quit(0)
	return false


func _run() -> void:
	root.title = "GodotSpace - Local Agent 打开相册演示（Esc 退出）"
	root.size = Vector2i(900, 650)
	var background := ColorRect.new()
	background.color = Color("18243a")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)

	var picture_scene: PackedScene = load("res://Assets/ARSpace/Prefabs/UI/PictureCanvas.tscn")
	if picture_scene == null:
		push_error("PictureCanvas scene did not load.")
		quit(1)
		return
	var picture_root := picture_scene.instantiate()
	root.add_child(picture_root)
	await process_frame
	_picture_canvas = picture_root.get_node_or_null("Canvas")
	if _picture_canvas == null:
		push_error("PictureCanvas/Canvas is missing.")
		quit(1)
		return
	_picture_canvas.position = Vector2(160, 70)

	var client := root.get_node_or_null("LocalAgentClient")
	if client != null:
		client.assistant_final_received.connect(func(_request_id: String, answer: String) -> void:
			print("Local Agent demo answer: %s" % answer)
			call_deferred("_capture_demo")
		)
	print("Album demo ready; waiting for open_album over WebSocket.")


func _capture_demo() -> void:
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	var output_path := "C:/Users/94580/Desktop/cxy/Model/generated/album_demo.png"
	var error := image.save_png(output_path)
	if error == OK:
		print("Album demo screenshot saved: %s" % output_path)
	else:
		push_error("Unable to save album demo screenshot: %s" % error_string(error))
