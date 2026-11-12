extends SceneTree

const SharedWorkStepState := preload(
	"res://Assets/ARSpace/Scripts/WorkListCanvas/shared_work_step_state.gd"
)
const SpaceBoxController := preload(
	"res://Assets/ARSpace/Scenes/SpaceBox.gd"
)

var _failures: PackedStringArray = []


class MockAnimationController extends Node3D:
	var played_steps: Array[int] = []
	var active_step: int = 0

	func play_step(step_index: int) -> void:
		played_steps.append(step_index)
		active_step = step_index
	func clear_step() -> void:
		active_step = 0
	func get_active_step() -> int:
		return active_step


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shared_state := SharedWorkStepState.new()
	shared_state.name = "SharedWorkStepState"
	root.add_child(shared_state)

	_expect(
		not bool(shared_state.call("get_current_state").get("is_visible", true)),
		"shared work-step state must default to hidden"
	)
	var initial_controller := _make_spacebox_controller()
	root.add_child(initial_controller)
	await process_frame
	initial_controller.call("request_worklist_visibility", true)
	var initial_guidance := initial_controller.get_node("SpaceBox/WorkEffect/WorkList1") as Node3D
	_expect(not initial_guidance.visible, "opening without a selected step must keep guidance hidden")
	for branch: Node3D in initial_guidance.get_children():
		_expect(not branch.visible, "unselected step branches must start hidden")
	_expect(initial_controller.get_node("SpaceBox/dashiyangui").active_step == 0,
		"opening without a step must not start an animation")
	initial_controller.free()
	_expect(
		bool(shared_state.call("request_work_step", 4)),
		"an authoritative step must be storable before the controller is ready"
	)

	var controller := _make_spacebox_controller()
	root.add_child(controller)
	await process_frame
	await process_frame
	var animation_controller := controller.get_node(
		"SpaceBox/dashiyangui"
	) as MockAnimationController
	_expect(
		_has_only_visible_step(controller, 4),
		"a late-bound controller must restore the active WorkInfo"
	)
	_expect(
		animation_controller.played_steps == [4],
		"a late-bound controller must replay the authoritative animation"
	)

	_expect(
		bool(controller.call("request_worklist_visibility", true)),
		"opening the work list must submit shared visibility"
	)
	_expect(
		bool(controller.call("request_work_step", 6)),
		"selecting a valid step must submit shared state"
	)
	_expect(
		int(shared_state.call("get_current_state").get("active_step", 0)) == 6,
		"shared state must store the selected step"
	)
	_expect(_has_only_visible_step(controller, 6), "only WorkInfo6 must be visible")
	_expect(
		animation_controller.played_steps == [4, 6],
		"authoritative step application must play Step6"
	)

	var first_revision := int(shared_state.call("get_state_revision"))
	_expect(
		bool(controller.call("request_work_step", 6)),
		"replaying the current step must be accepted"
	)
	_expect(
		int(shared_state.call("get_state_revision")) == first_revision + 1,
		"replaying the same step must advance the event revision"
	)
	_expect(
		animation_controller.played_steps == [4, 6, 6],
		"replaying the current step must restart the animation"
	)

	var replay_revision := int(shared_state.call("get_state_revision"))
	_expect(
		not bool(controller.call("request_work_step", 0)),
		"step zero must be rejected as an animation request"
	)
	_expect(
		not bool(controller.call("request_work_step", 21)),
		"steps above the supported range must be rejected"
	)
	_expect(
		int(shared_state.call("get_state_revision")) == replay_revision,
		"invalid steps must not change authoritative state"
	)

	_expect(
		bool(controller.call("request_worklist_visibility", false)),
		"closing the work list must submit shared visibility"
	)
	_expect(
		not controller.get_node("SpaceBox/WorkEffect/WorkList1").visible,
		"authoritative close must hide WorkList1"
	)
	_expect(animation_controller.active_step == 0, "closing clears animated parts")
	controller.call("request_worklist_visibility", true)
	_expect(animation_controller.active_step == 6, "reopening restores the current step even without replay flag")
	var legacy_count := animation_controller.played_steps.size()
	controller.call("play_dashiyangui_animation")
	_expect(animation_controller.played_steps.size() == legacy_count + 1 and animation_controller.active_step == 6,
		"legacy main menu replays the selected step through shared state")

	controller.queue_free()
	shared_state.queue_free()
	await process_frame
	if _failures.is_empty():
		print("SHARED_WORK_STEP_STATE_SELF_TEST PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("SHARED_WORK_STEP_STATE_SELF_TEST: %s" % failure)
	quit(1)


func _make_spacebox_controller() -> Node3D:
	var controller := SpaceBoxController.new() as Node3D
	controller.name = "SpaceBoxController"
	var spacebox := Node3D.new()
	spacebox.name = "SpaceBox"
	controller.add_child(spacebox)

	for surface_name in ["DownPlane", "BackDor"]:
		var surface := Node3D.new()
		surface.name = surface_name
		spacebox.add_child(surface)

	var environment := Node3D.new()
	environment.name = "Environment_Life"
	spacebox.add_child(environment)
	var animation_controller := MockAnimationController.new()
	animation_controller.name = "dashiyangui"
	spacebox.add_child(animation_controller)
	var work_effect := Node3D.new()
	work_effect.name = "WorkEffect"
	spacebox.add_child(work_effect)
	var work_list := Node3D.new()
	work_list.name = "WorkList1"
	work_effect.add_child(work_list)
	for step_index in range(1, 21):
		var work_info := Node3D.new()
		work_info.name = "WorkInfo%d" % step_index
		work_list.add_child(work_info)
	return controller


func _has_only_visible_step(controller: Node, expected_step: int) -> bool:
	var work_list := controller.get_node("SpaceBox/WorkEffect/WorkList1")
	if not work_list.visible:
		return false
	for step_index in range(1, 21):
		var work_info := work_list.get_node("WorkInfo%d" % step_index) as Node3D
		if work_info.visible != (step_index == expected_step):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
