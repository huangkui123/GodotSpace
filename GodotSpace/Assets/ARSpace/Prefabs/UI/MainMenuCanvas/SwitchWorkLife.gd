extends VBoxContainer

# 按钮引用
@export_category("按钮引用")
@export var life_tab: Button
@export var work_tab: Button

# 视图引用
@export_category("视图引用")
@export var life_view: Control
@export var work_view: Control

func _ready():
	# 确保按钮为切换模式
	if life_tab:
		life_tab.toggle_mode = true
	if work_tab:
		work_tab.toggle_mode = true

	# 连接按钮信号
	if life_tab:
		life_tab.pressed.connect(_on_life_tab_pressed)
	if work_tab:
		work_tab.pressed.connect(_on_work_tab_pressed)

	# 默认激活生活模式
	if life_tab and work_tab:
		_on_life_tab_pressed()

# 通过全局单例控制SpaceBox环境可见性
func _set_environment_visible(show: bool) -> void:
	if Global.spacebox_controller and Global.spacebox_controller.has_method("set_environment_visible"):
		Global.spacebox_controller.set_environment_visible(show)
	else:
		printerr("❌ Global.spacebox_controller 无效或缺少方法")

func _on_life_tab_pressed() -> void:
	if life_view:
		life_view.visible = true
	if work_view:
		work_view.visible = false

	if life_tab:
		life_tab.button_pressed = true
	if work_tab:
		work_tab.button_pressed = false

	_set_environment_visible(true)  # 生活视图时显示3D环境

func _on_work_tab_pressed() -> void:
	if life_view:
		life_view.visible = false
	if work_view:
		work_view.visible = true

	if life_tab:
		life_tab.button_pressed = false
	if work_tab:
		work_tab.button_pressed = true

	_set_environment_visible(false)  # 工作视图时隐藏3D环境
