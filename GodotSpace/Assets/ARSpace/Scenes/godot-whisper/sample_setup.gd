extends VBoxContainer

@onready var mic_player: AudioStreamPlayer = $MicPlayer
@onready var audio_to_text: CaptureStreamToText = $CaptureStreamToText
@onready var transcribe_label: RichTextLabel = $Panel/Label
# Called when the node enters the scene tree for the first time.
func _init():
	pass

func _ready():
	# var args = OS.get_cmdline_args()

	# if "--testmode" in args:
	# 	return

	mic_player.bus = "Record"
	audio_to_text.transcribed_msg.connect(transcribe_label._on_capture_stream_to_text_transcribed_msg)
