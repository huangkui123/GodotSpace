extends Node3D

@onready var anim_player: AnimationPlayer = $AnimationPlayer
var current_step: int = 1
const MAX_STEP: int = 19
var is_playing: bool = false

func _ready():
	print("✅ 动画控制器已初始化，等待外部触发")
	print("已有动画：", anim_player.get_animation_list())
	anim_player.animation_finished.connect(_on_animation_finished)

# 从 Step1 开始播放顺序动画（由外部触发）
func play_from_ui():
	if is_playing:
		print("⚠️ 动画已在播放中，忽略重复触发")
		return

	current_step = 1
	is_playing = true
	print("🟦 接收到 UI 触发，开始从 Step1 播放动画")
	play_next_step()

func play_next_step():
	if current_step > MAX_STEP:
		print("✅ 所有动画播放完毕")
		is_playing = false
		return

	var anim_name = "Step%d" % current_step
	if not anim_player.has_animation(anim_name):
		print("❌ 未找到动画：", anim_name)
		is_playing = false
		return

	var length = anim_player.get_animation(anim_name).length
	print("🎬 播放动画：", anim_name, "（时长：", length, "秒）")
	anim_player.play(anim_name)

func _on_animation_finished(anim_name: String):
	print("🔚 动画播放结束：", anim_name)
	if anim_name.begins_with("Step") and is_playing:
		current_step += 1
		play_next_step()
