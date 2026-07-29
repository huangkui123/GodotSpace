extends SceneTree

const SharedMainMenuState := preload(
	"res://Assets/ARSpace/Scripts/UI/shared_main_menu_state.gd"
)
const SwitchWorkLife := preload(
	"res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/SwitchWorkLife.gd"
)
const MODE_LIFE: int = 0
const MODE_WORK: int = 1

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shared_state := SharedMainMenuState.new()
	shared_state.name = "SharedMainMenuState"
	root.add_child(shared_state)

	var mode_layout := SwitchWorkLife.new() as VBoxContainer
	mode_layout.name = "ModeLayout"
	var life_tab := Button.new()
	life_tab.name = "LifeModeTab"
	var work_tab := Button.new()
	work_tab.name = "WorkModeTab"
	var life_view := Control.new()
	life_view.name = "LifeView"
	var work_view := Control.new()
	work_view.name = "WorkView"
	mode_layout.add_child(life_tab)
	mode_layout.add_child(work_tab)
	mode_layout.add_child(life_view)
	mode_layout.add_child(work_view)
	mode_layout.set("life_tab", life_tab)
	mode_layout.set("work_tab", work_tab)
	mode_layout.set("life_view", life_view)
	mode_layout.set("work_view", work_view)
	root.add_child(mode_layout)

	_expect(
		int(shared_state.call("get_active_mode")) == MODE_LIFE,
		"shared MainMenu state must default to LIFE"
	)
	_expect(
		life_view.visible and not work_view.visible,
		"ModeLayout must apply the initial LIFE view"
	)
	_expect(
		life_tab.button_pressed and not work_tab.button_pressed,
		"ModeLayout must apply the initial LIFE button state"
	)

	work_tab.emit_signal("pressed")
	_expect(
		int(shared_state.call("get_active_mode")) == MODE_WORK,
		"WorkModeTab must submit WORK to the shared state"
	)
	_expect(
		not life_view.visible and work_view.visible,
		"WORK authority must switch both views"
	)
	_expect(
		not life_tab.button_pressed and work_tab.button_pressed,
		"WORK authority must reconcile both button states"
	)

	var work_revision := int(shared_state.call("get_state_revision"))
	_expect(
		not bool(shared_state.call("request_active_mode", 99)),
		"invalid MainMenu modes must be rejected"
	)
	_expect(
		int(shared_state.call("get_state_revision")) == work_revision,
		"invalid modes must not advance the authoritative revision"
	)

	_expect(
		bool(shared_state.call("request_active_mode", MODE_LIFE)),
		"offline LIFE mode request must succeed"
	)
	_expect(
		int(mode_layout.call("get_active_mode")) == MODE_LIFE,
		"ModeLayout must consume authoritative LIFE updates"
	)
	_expect(
		life_view.visible and not work_view.visible,
		"LIFE authority must restore both views"
	)

	var canvas_text := _read_text(
		"res://Assets/ARSpace/Prefabs/UI/MainMenuCanvas/canvas.gd"
	)
	_expect(
		canvas_text.contains("PanelWindowZoom.set_window_visible(canvas, is_visible, self)"),
		"MainMenu child-window buttons must pass their explicit spatial parent"
	)

	mode_layout.queue_free()
	shared_state.queue_free()
	await process_frame
	if _failures.is_empty():
		print("SHARED_MAIN_MENU_STATE_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("SHARED_MAIN_MENU_STATE_SELF_TEST: %s" % failure)
	quit(1)


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
