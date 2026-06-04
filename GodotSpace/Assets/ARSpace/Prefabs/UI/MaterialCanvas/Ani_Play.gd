extends Node3D

const DEBUG_LOGS := false

@onready var anim_player: AnimationPlayer = $AnimationPlayer
const MAX_STEP: int = 19

func _ready():
	if DEBUG_LOGS: print("✅ 动画控制器已初始化")
	if DEBUG_LOGS: print("🎞️ 已有动画：", anim_player.get_animation_list())

# 👉 外部调用这个函数，播放 Step1~Step19 中对应编号的动画
func play_step(step_index: int):
	if DEBUG_LOGS: print("🟦 [DEBUG] 请求播放动画 Step", step_index)

	if step_index < 1 or step_index > MAX_STEP:
		if DEBUG_LOGS: print("⚠️ [DEBUG] 无效的步骤编号：", step_index)
		return

	var anim_name = "Step%d" % step_index
	if DEBUG_LOGS: print("🟦 [DEBUG] 检查动画是否存在：", anim_name)

	if not anim_player.has_animation(anim_name):
		if DEBUG_LOGS: print("❌ [DEBUG] 未找到动画：", anim_name)
		if DEBUG_LOGS: print("👉 当前已有动画列表：", anim_player.get_animation_list())
		return

	var length = anim_player.get_animation(anim_name).length
	if DEBUG_LOGS: print("🎬 [DEBUG] 开始播放动画：", anim_name, "（时长：", length, "秒）")
	anim_player.play(anim_name)
