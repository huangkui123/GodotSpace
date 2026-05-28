extends Control

@onready var voice_button: Button = $VoiceButton
@onready var status_label: Label = $StatusLabel

func _ready() -> void:
	if voice_button != null:
		voice_button.pressed.connect(_on_voice_button_pressed)

	if VoiceChat.has_signal("voice_enabled_changed"):
		VoiceChat.voice_enabled_changed.connect(_on_voice_enabled_changed)

	if NetworkHandler.has_signal("network_ready"):
		NetworkHandler.network_ready.connect(_on_network_ready)

	multiplayer.peer_connected.connect(_on_peer_changed)
	multiplayer.peer_disconnected.connect(_on_peer_changed)
	_update_ui()

func _on_voice_button_pressed() -> void:
	VoiceChat.toggle_voice()

func _on_voice_enabled_changed(_enabled: bool) -> void:
	_update_ui()

func _on_network_ready() -> void:
	_update_ui()

func _on_peer_changed(_peer_id: int) -> void:
	_update_ui()

func _process(_delta: float) -> void:
	_update_status()

func _update_ui() -> void:
	if voice_button != null:
		if VoiceChat.voice_enabled:
			voice_button.text = "Voice ON"
			voice_button.modulate = Color.GREEN
		else:
			voice_button.text = "Voice OFF"
			voice_button.modulate = Color.RED

	_update_status()

func _update_status() -> void:
	if status_label == null:
		return

	var peer_count := multiplayer.get_peers().size() if multiplayer.has_multiplayer_peer() else 0
	var role := "Server" if multiplayer.is_server() else "Client"
	if peer_count > 0:
		status_label.text = "%s connected: %d" % [role, peer_count]
	elif multiplayer.has_multiplayer_peer():
		status_label.text = "%s waiting..." % role
	else:
		status_label.text = "Network offline"
