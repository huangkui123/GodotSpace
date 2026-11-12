extends Node3D

const StepAnimations := preload("res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_animations.gd")
const MAX_STEP: int = 20

@onready var anim_player: AnimationPlayer = $AnimationPlayer
var active_step: int = 0


func _ready() -> void:
	# The imported blend tree must not compete with explicit task playback.
	var tree := get_node_or_null("AnimationTree") as AnimationTree
	if tree != null:
		tree.active = false
	anim_player.stop()
	var library := StepAnimations.build(self, anim_player.get_animation_library(""))
	anim_player.remove_animation_library("")
	anim_player.add_animation_library("", library)
	anim_player.playback_auto_capture = false
	clear_step()


func play_step(step_index: int) -> void:
	if step_index < 1 or step_index > MAX_STEP:
		return
	var anim_name := "Step%d" % step_index
	if not anim_player.has_animation(anim_name):
		push_error("Missing cabinet task animation: %s" % anim_name)
		return
	active_step = step_index
	anim_player.stop()
	anim_player.clear_queue()
	anim_player.play(anim_name, 0.0)
	# Apply the complete target pose now, even for several page changes per frame.
	anim_player.seek(0.0, true)


func clear_step() -> void:
	active_step = 0
	anim_player.stop()
	anim_player.clear_queue()
	anim_player.play("Idle", 0.0)
	anim_player.seek(0.0, true)
	anim_player.pause()


func get_active_step() -> int:
	return active_step
