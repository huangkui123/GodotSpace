extends SceneTree

const PanelScene := preload(
	"res://Assets/ARSpace/Scenes/SpatialDrawing/SpatialDrawingPanel.tscn"
)
const OUTPUT_PATH := "user://spatial_drawing_panel_preview.png"
const CAPTURE_SIZE := Vector2i(800, 380)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = CAPTURE_SIZE
	var background := ColorRect.new()
	background.color = Color(0.72, 0.75, 0.79, 1.0)
	background.size = Vector2(CAPTURE_SIZE)
	root.add_child(background)

	var panel := PanelScene.instantiate() as Control
	if panel == null:
		push_error("SPATIAL_DRAWING_PANEL_RENDER_SELF_TEST: panel failed to instantiate")
		quit(1)
		return
	panel.position = Vector2(20.0, 20.0)
	root.add_child(panel)

	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("SPATIAL_DRAWING_PANEL_RENDER_SELF_TEST: viewport capture is empty")
		quit(1)
		return
	var save_error := image.save_png(OUTPUT_PATH)
	if save_error != OK:
		push_error(
			"SPATIAL_DRAWING_PANEL_RENDER_SELF_TEST: PNG save failed with %s" % save_error
		)
		quit(1)
		return
	print(
		"SPATIAL_DRAWING_PANEL_RENDER_SELF_TEST PASS %s"
		% ProjectSettings.globalize_path(OUTPUT_PATH)
	)
	quit(0)
