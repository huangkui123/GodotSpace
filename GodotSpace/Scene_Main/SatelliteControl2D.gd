extends Control

@export_file("*.tscn") var orbital_scene: String = "res://OrbitalSimulation.tscn"
@export var back_button: Button
@export var fade_overlay: ColorRect
@export var camera: Camera3D
@export var focus_target: Node3D

# --- 新增内容 ---
@export var open_close_button: Button # 拖入 OpenCloseText 按钮
# ----------------

const FADE_DURATION = 0.5
var _switching: bool = false
var _labels_visible: bool = true # 记录当前标签显示状态

func _ready() -> void:
	if back_button:
		back_button.pressed.connect(_on_back_pressed)
	
	# --- 新增内容 ---
	if open_close_button:
		open_close_button.pressed.connect(_on_toggle_labels_pressed)
		_update_button_text()
	# ----------------

	if camera and focus_target:
		camera.focus_on(focus_target)
	_fade_in()

# --- 新增功能函数 ---
func _on_toggle_labels_pressed() -> void:
	_labels_visible = !_labels_visible
	
	# 获取场景中所有的 Label3D 节点（无论它们在哪个层级）
	# find_children 的第一个参数 "*" 代表匹配所有名称
	# 第二个参数 "Label3D" 代表只找这个类型的节点
	# 第三个参数 true 代表递归查找所有子孙节点
	var all_labels = get_tree().root.find_children("*", "Label3D", true, false)
	
	for label in all_labels:
		# 1. 修改你之前那个脚本里的变量，防止它在 _process 里又把自己设为 visible
		label.set("label_enabled", _labels_visible)
		
		# 2. 立即修改当前的显示状态
		label.visible = _labels_visible
		
		# 3. 如果 Label3D 挂载了你之前那个脚本，强制调用一次它的逻辑（可选）
		if label.has_method("_process"):
			label.notification(NOTIFICATION_PROCESS)

	_update_button_text()

func _update_button_text() -> void:
	if open_close_button:
		open_close_button.text = "隐藏标签" if _labels_visible else "显示标签"
# -------------------

func _fade_in() -> void:
	if not fade_overlay:
		return
	fade_overlay.visible = true
	fade_overlay.modulate.a = 1.0
	var tween = create_tween()
	tween.tween_property(fade_overlay, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_callback(func(): fade_overlay.visible = false)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_back_pressed()

func _on_back_pressed() -> void:
	if _switching:
		return
	_switching = true
	if back_button:
		back_button.disabled = true

	ResourceLoader.load_threaded_request(orbital_scene)

	if fade_overlay:
		fade_overlay.visible = true
		fade_overlay.modulate.a = 0.0
		var tween = create_tween()
		tween.tween_property(fade_overlay, "modulate:a", 1.0, FADE_DURATION)
		await tween.finished

	await _wait_for_scene_load(orbital_scene)

	await get_tree().process_frame
	await get_tree().process_frame

	var packed = ResourceLoader.load_threaded_get(orbital_scene)
	get_tree().change_scene_to_packed(packed)

func _wait_for_scene_load(target_scene: String) -> void:
	while true:
		var status = ResourceLoader.load_threaded_get_status(target_scene)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		elif status == ResourceLoader.THREAD_LOAD_FAILED:
			push_error("场景加载失败: " + target_scene)
			break
		await get_tree().process_frame
