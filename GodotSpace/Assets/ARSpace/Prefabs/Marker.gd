# Marker.gd
extends Node3D

# 呼吸灯效果参数
var min_scale: float = 0.8  # 最小缩放
var max_scale: float = 1.3  # 最大缩放
var pulse_duration: float = 0.3  # 每次呼吸周期时长（秒）
var lifetime: float = 2.0  # 标记存在时间（秒）
var tween: Tween

# 设置 SharedSpaceOrigin 局部位置。网络入口由 Server 权威的 NetworkHandler 提供。
func setup(shared_position: Vector3) -> void:
	position = shared_position
	start_pulse_effect()
	
	# 设置延迟销毁
	var timer = get_tree().create_timer(lifetime)
	timer.timeout.connect(_on_lifetime_end)

# 生命周期结束处理
func _on_lifetime_end():
	# 停止动画
	stop_pulse_effect()
	# 销毁自身
	queue_free()

# 开始呼吸灯效果
func start_pulse_effect():
	# 如果已有tween，先停止
	if tween:
		tween.kill()
	
	# 创建新的tween动画
	tween = create_tween()
	tween.set_loops()  # 无限循环
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	
	# 呼吸灯动画：从小变大再变小
	tween.tween_property(self, "scale", Vector3(max_scale, max_scale, max_scale), pulse_duration/2).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "scale", Vector3(min_scale, min_scale, min_scale), pulse_duration/2).set_ease(Tween.EASE_IN_OUT)

# 停止呼吸灯效果
func stop_pulse_effect():
	if tween:
		tween.kill()
		tween = null
	scale = Vector3.ONE

# 清理资源
func _exit_tree():
	stop_pulse_effect()
