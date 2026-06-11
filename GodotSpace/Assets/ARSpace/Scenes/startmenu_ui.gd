# start_menu_ui.gd
extends Control

const GAME_SCENE_PATH = "res://Assets/ARSpace/Scenes/ARSpace.scn"
const XR_CLIENT_ARG = "--xr-client"
const XR_MODE_ARG = "--xr-mode"
const VOICE_ROLE_ARG = "--voice-role="

@onready var mode_label: Label = $VBoxContainer/ModeLabel
@onready var audio_controls: Control = $VBoxContainer/Audio
@onready var input_device: OptionButton = $VBoxContainer/Audio/InputDevice
@onready var output_device: OptionButton = $VBoxContainer/Audio/OutputDevice

var _changing_scene: bool = false

func _ready():
	NetworkHandler.network_ready.connect(_on_network_ready)
	_update_startup_mode_label()
	_setup_audio_controls()

func _on_start_pressed():
	_apply_audio_selection()

	if _is_vr_client_mode():
		_start_vr_client()
		return

	if NetworkHandler.start_server():
		_go_to_game_scene()
		return

	if _can_fallback_to_vr_client():
		_start_vr_client()

func _update_startup_mode_label() -> void:
	if mode_label == null:
		return

	mode_label.text = "MODE: VR CLIENT" if _is_vr_client_mode() else "MODE: PC SERVER"

func _setup_audio_controls() -> void:
	if audio_controls == null:
		return

	audio_controls.visible = true
	_populate_device_option(input_device, AudioServer.get_input_device_list(), VoiceChat.get_preferred_input_device())
	_populate_device_option(output_device, AudioServer.get_output_device_list(), VoiceChat.get_preferred_output_device())

func _populate_device_option(option: OptionButton, devices: PackedStringArray, preferred_device: String) -> void:
	if option == null:
		return

	option.clear()
	var selected_index := 0
	if devices.size() == 0:
		option.add_item("Default")
		option.select(0)
		return

	for i in range(devices.size()):
		var device_name := str(devices[i])
		option.add_item(device_name)
		if device_name == preferred_device:
			selected_index = i

	option.select(selected_index)

func _apply_audio_selection() -> void:
	if input_device == null or output_device == null:
		return

	var selected_input := _get_selected_option_text(input_device)
	var selected_output := _get_selected_option_text(output_device)
	VoiceChat.set_audio_devices(selected_input, selected_output)

func _get_selected_option_text(option: OptionButton) -> String:
	var selected := option.selected
	if selected < 0:
		return "Default"
	return option.get_item_text(selected)

func _is_vr_client_mode() -> bool:
	if OS.has_feature("android"):
		return true

	var role := _get_arg_value(VOICE_ROLE_ARG).to_lower()
	if role == "client" or role == "vr":
		return true
	if role == "server" or role == "pc":
		return false
	return OS.get_cmdline_args().has(XR_CLIENT_ARG) or _has_xr_mode_on_arg()

func _get_arg_value(prefix: String) -> String:
	for arg in OS.get_cmdline_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""

func _has_xr_mode_on_arg() -> bool:
	var args := OS.get_cmdline_args()
	for i in range(args.size()):
		var arg := str(args[i]).to_lower()
		if arg == XR_MODE_ARG and i + 1 < args.size():
			return str(args[i + 1]).to_lower() == "on"
		if arg.begins_with(XR_MODE_ARG + "="):
			return arg.get_slice("=", 1).to_lower() == "on"
	return false

func _can_fallback_to_vr_client() -> bool:
	return XRServer.find_interface("OpenXR") != null

func _start_vr_client() -> void:
	if mode_label != null:
		mode_label.text = "MODE: VR CLIENT"

	_start_openxr_for_client()
	if NetworkHandler.start_client():
		_go_to_game_scene()

func _start_openxr_for_client() -> void:
	var openxr_interface := XRServer.find_interface("OpenXR")
	if openxr_interface == null:
		push_warning("OpenXR interface not found for VR client. Start the VR instance with Godot engine args: --xr-mode on --xr-client")
		return

	if not openxr_interface.is_initialized() and not openxr_interface.initialize():
		push_warning("Failed to initialize OpenXR for VR client. If this instance was started with only --xr-client, restart it with --xr-mode on --xr-client")
		return

	get_tree().root.use_xr = true

func _on_network_ready():
	_go_to_game_scene()

func _go_to_game_scene() -> void:
	if _changing_scene:
		return

	_changing_scene = true
	if NetworkHandler.network_ready.is_connected(_on_network_ready):
		NetworkHandler.network_ready.disconnect(_on_network_ready)
	get_tree().change_scene_to_file(GAME_SCENE_PATH)
