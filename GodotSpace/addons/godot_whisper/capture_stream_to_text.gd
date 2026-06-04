## Node that does transcribing of real time audio. It requires a bus with a [AudioEffectCapture] and a [WhisperResource] language model.
class_name CaptureStreamToText
extends SpeechToText

const DEBUG_LOGS := false

signal transcribed_msg(is_partial, new_text)

# For Traditional Chinese "以下是普通話的句子。"
# For Simplified Chinese "以下是普通话的句子。"
@export var initial_prompt: String = "以下是普通话的句子。"

func _get_configuration_warnings():
	if language_model == null:
		return ["You need a language model."]
	else:
		return []
		
@export var recording := false:
	set(value):
		recording = value
		if recording:
			if is_inside_tree():
				_ready()
		else:
			_should_capture = false
			if thread && thread.is_alive():
				thread.wait_to_finish()
	get:
		return recording
## The interval at which transcribing is done. Use a value bigger than the time it takes to transcribe (eg. depends on model).
@export var transcribe_interval := 0.3
## Using dynamic audio context speeds up transcribing but may result in mistakes.
@export var use_dynamic_audio_context := true
## How much time has to pass in seconds until we can consider a sentence.
@export var minimum_sentence_time := 3
## Maximum time a sentence can have in seconds.
@export var maximum_sentence_time := 15
## How many tokens it's allowed to halucinate. Can provide useful info as it talks, but too much can provide useless text.
@export var halucinating_count := 1
## The record bus has to have a AudioEffectCapture at index specified by [member audio_effect_capture_index]
@export var record_bus := "Mic"
## The index where the [AudioEffectCapture] is located at in the [member record_bus]
@export var audio_effect_capture_index := 1

## Character to consider when ending a sentence.
@export var punctuation_characters := ".!?;。；？！"

@onready var _idx = AudioServer.get_bus_index(record_bus)
@onready var _effect_capture := AudioServer.get_bus_effect(_idx, audio_effect_capture_index) as AudioEffectCapture

var thread : Thread

# 调试：保存音频到文件
@export var save_audio_debug := false  # 是否保存调试音频
var audio_save_counter := 0  # 保存文件计数器

func _ready():
	if Engine.is_editor_hint():
		return
	if !recording:
		return
	if thread && thread.is_alive():
		_should_capture = false
		thread.wait_to_finish()
	thread = Thread.new()
	if _effect_capture:
		_effect_capture.clear_buffer()
	thread.start(transcribe_thread)

var _accumulated_frames: PackedVector2Array
var _capture_mutex: Mutex
var _should_capture := false

func _process(_delta):
	if !recording || !_should_capture:
		return
	
	# 持续捕获音频，不要等待转录完成
	if _effect_capture:
		var available_frames = _effect_capture.get_frames_available()
		if available_frames > 0:
			_capture_mutex.lock()
			_accumulated_frames.append_array(_effect_capture.get_buffer(available_frames))
			_capture_mutex.unlock()

func transcribe_thread():
	var last_token_count := 0
	_capture_mutex = Mutex.new()
	_should_capture = true
	
	while recording:
		var start_time = Time.get_ticks_msec()
		
		# 等待积累足够的音频数据
		OS.delay_msec(transcribe_interval * 1000)
		
		# 复制当前累积的帧进行处理
		_capture_mutex.lock()
		var frames_to_process = _accumulated_frames.duplicate()
		_capture_mutex.unlock()
		
		if frames_to_process.size() <= 0:
			continue
		
		# 调试：保存原始音频帧到文件
		# if save_audio_debug && frames_to_process.size() > 0:
		# 	_save_audio_stereo_to_file(frames_to_process, "raw_audio")
		
		var resampled = resample(frames_to_process, SpeechToText.SRC_SINC_FASTEST)
		if resampled.size() <= 0:
			OS.delay_msec(transcribe_interval * 1000)
			continue
		
		# 调试：保存重采样后的音频
		# if save_audio_debug && resampled.size() > 0:
		# 	_save_audio_mono_to_file(resampled, "resampled_audio")
		var no_activity := voice_activity_detection(resampled)
		#if no_activity:
			#print("no activity")
			#continue
		var total_time : float= (resampled.size() as float) / SpeechToText.SPEECH_SETTING_SAMPLE_RATE
		var audio_ctx : int = total_time * 1500 / 30 + 128
		if !use_dynamic_audio_context:
			audio_ctx = 0
		var tokens := transcribe(resampled, initial_prompt, audio_ctx)
		if tokens.is_empty():
			push_warning("No tokens generated")
			return
		var full_text : String = tokens.pop_front()
		var mix_rate : int = ProjectSettings.get_setting("audio/driver/mix_rate")
		var finish_sentence = false
		if total_time > maximum_sentence_time:
			finish_sentence = true
		var text : String
		for token in tokens:
			text += token["text"]
		text = _remove_special_characters(text)
		if _has_terminating_characters(text, punctuation_characters) || no_activity:
			finish_sentence = true
		if total_time < minimum_sentence_time || abs(tokens.size() - last_token_count) > halucinating_count:
			finish_sentence = false
		var time_processing = (Time.get_ticks_msec() - start_time)
		
		# 根据句子是否结束，清理已处理的音频
		if finish_sentence:
			_capture_mutex.lock()
			# 保留最后 0.2 秒作为上下文
			var keep_frames = int(0.2 * mix_rate)
			if _accumulated_frames.size() > keep_frames:
				_accumulated_frames = _accumulated_frames.slice(_accumulated_frames.size() - keep_frames)
			_capture_mutex.unlock()
		
		if !no_activity:
			call_deferred("emit_signal", "transcribed_msg", finish_sentence, full_text)
			if DEBUG_LOGS: print(full_text)
			if DEBUG_LOGS: print("Transcribe " + str(time_processing/ 1000.0) + " s")
		
		last_token_count = tokens.size()

func _has_terminating_characters(message: String, characters: String):
	for character in characters:
		if message.contains(character):
			return true
	return false

func _remove_special_characters(message: String):
	var special_characters = [ \
		{ "start": "[", "end": "]" }, \
		{ "start": "<", "end": ">" }, \
		{ "start": "♪", "end": "♪" }]
	for special_character in special_characters:
		while(message.find(special_character["start"]) != -1):
			var begin_character := message.find(special_character["start"])
			var end_character := message.find(special_character["end"])
			if end_character != -1:
				message = message.substr(0, begin_character) + message.substr(end_character + 1)

	var hallucinatory_character = [". you."]
	for special_character in hallucinatory_character:
		while(message.find(special_character) != -1):
			var begin_character := message.find(special_character)
			var end_character = begin_character + len(special_character)
			message = message.substr(0, begin_character) + message.substr(end_character + 1)
	return message

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		recording = false
		_should_capture = false
		if thread && thread.is_alive():
			thread.wait_to_finish()

# 保存立体声音频数据到WAV文件用于调试
func _save_audio_stereo_to_file(audio_data: PackedVector2Array, prefix: String):
	if audio_data.size() == 0:
		return
	
	# 创建保存目录
	var save_dir = "user://debug_audio"
	if !DirAccess.dir_exists_absolute(save_dir):
		DirAccess.make_dir_absolute(save_dir)
	
	# 生成文件名
	var timestamp = Time.get_ticks_msec()
	var filename = "%s/%s_%d_%d.wav" % [save_dir, prefix, audio_save_counter, timestamp]
	audio_save_counter += 1
	
	# 创建WAV文件
	var file = FileAccess.open(filename, FileAccess.WRITE)
	if file == null:
		push_error("无法创建音频文件: " + filename)
		return
	
	# 确定采样率
	var sample_rate = ProjectSettings.get_setting("audio/driver/mix_rate")
	
	var num_channels = 2  # 立体声
	var bits_per_sample = 16
	var byte_rate = sample_rate * num_channels * bits_per_sample / 8
	var block_align = num_channels * bits_per_sample / 8
	var data_size = audio_data.size() * num_channels * bits_per_sample / 8
	
	# 写入WAV头
	file.store_buffer("RIFF".to_ascii_buffer())
	file.store_32(36 + data_size)  # 文件大小 - 8
	file.store_buffer("WAVE".to_ascii_buffer())
	
	# fmt 子块
	file.store_buffer("fmt ".to_ascii_buffer())
	file.store_32(16)  # fmt 块大小
	file.store_16(1)   # 音频格式 (1 = PCM)
	file.store_16(num_channels)
	file.store_32(sample_rate)
	file.store_32(byte_rate)
	file.store_16(block_align)
	file.store_16(bits_per_sample)
	
	# data 子块
	file.store_buffer("data".to_ascii_buffer())
	file.store_32(data_size)
	
	# 写入音频数据
	for frame in audio_data:
		# 转换为16位整数
		var left = int(clamp(frame.x, -1.0, 1.0) * 32767.0)
		var right = int(clamp(frame.y, -1.0, 1.0) * 32767.0)
		file.store_16(left)
		file.store_16(right)
	
	file.close()
	if DEBUG_LOGS: print("✅ 保存调试音频(立体声): %s (采样率: %d Hz, 帧数: %d)" % [filename, sample_rate, audio_data.size()])

# 保存单声道音频数据到WAV文件用于调试
func _save_audio_mono_to_file(audio_data: PackedFloat32Array, prefix: String):
	if audio_data.size() == 0:
		return
	
	# 创建保存目录
	var save_dir = "user://debug_audio"
	if !DirAccess.dir_exists_absolute(save_dir):
		DirAccess.make_dir_absolute(save_dir)
	
	# 生成文件名
	var timestamp = Time.get_ticks_msec()
	var filename = "%s/%s_%d_%d.wav" % [save_dir, prefix, audio_save_counter, timestamp]
	audio_save_counter += 1
	
	# 创建WAV文件
	var file = FileAccess.open(filename, FileAccess.WRITE)
	if file == null:
		push_error("无法创建音频文件: " + filename)
		return
	
	# 使用Whisper的采样率
	var sample_rate = SpeechToText.SPEECH_SETTING_SAMPLE_RATE
	
	var num_channels = 1  # 单声道
	var bits_per_sample = 16
	var byte_rate = sample_rate * num_channels * bits_per_sample / 8
	var block_align = num_channels * bits_per_sample / 8
	var data_size = audio_data.size() * num_channels * bits_per_sample / 8
	
	# 写入WAV头
	file.store_buffer("RIFF".to_ascii_buffer())
	file.store_32(36 + data_size)  # 文件大小 - 8
	file.store_buffer("WAVE".to_ascii_buffer())
	
	# fmt 子块
	file.store_buffer("fmt ".to_ascii_buffer())
	file.store_32(16)  # fmt 块大小
	file.store_16(1)   # 音频格式 (1 = PCM)
	file.store_16(num_channels)
	file.store_32(sample_rate)
	file.store_32(byte_rate)
	file.store_16(block_align)
	file.store_16(bits_per_sample)
	
	# data 子块
	file.store_buffer("data".to_ascii_buffer())
	file.store_32(data_size)
	
	# 写入音频数据
	for sample in audio_data:
		# 转换为16位整数
		var value = int(clamp(sample, -1.0, 1.0) * 32767.0)
		file.store_16(value)
	
	file.close()
	if DEBUG_LOGS: print("✅ 保存调试音频(单声道): %s (采样率: %d Hz, 采样数: %d)" % [filename, sample_rate, audio_data.size()])
