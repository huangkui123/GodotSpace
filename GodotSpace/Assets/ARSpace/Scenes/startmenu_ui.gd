# start_menu_ui.gd
extends Control

const GAME_SCENE_PATH = "res://Assets/ARSpace/Scenes/ARSpace.tscn"
const SERVER_IP_ARG = "--server-ip="
const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")

@onready var mode_label: Label = $VBoxContainer/ModeLabel
@onready var mode_selector: OptionButton = $VBoxContainer/RuntimeMode
@onready var network_controls: Control = $VBoxContainer/Network
@onready var server_ip_label: Label = $VBoxContainer/Network/ServerIPLabel
@onready var client_ip_label: Label = $VBoxContainer/Network/ClientIPLabel
@onready var server_ip_input: LineEdit = $VBoxContainer/Network/ServerIPInput
@onready var audio_controls: Control = $VBoxContainer/Audio
@onready var input_device: OptionButton = $VBoxContainer/Audio/InputDevice
@onready var output_device: OptionButton = $VBoxContainer/Audio/OutputDevice
@onready var status_label: Label = $VBoxContainer/Status
@onready var start_button: Button = $VBoxContainer/Start

var _changing_scene: bool = false
var _setting_runtime_mode: bool = false

func _ready():
	_reset_presentation_viewport()
	NetworkHandler.network_ready.connect(_on_network_ready)
	_setup_runtime_mode_selector()
	_update_runtime_ui()
	_setup_network_controls()
	_setup_audio_controls()

func _on_start_pressed():
	var profile = RuntimeProfile.current()
	if not profile.is_valid():
		_set_status(profile.validation_error, true)
		return

	_apply_audio_selection()
	if not _prepare_presentation(profile):
		return

	if profile.is_server():
		if NetworkHandler.start_server():
			_go_to_game_scene()
		else:
			_set_status(NetworkHandler.get_last_start_error(), true)
		return

	if profile.is_client():
		_set_status("Connecting to %s:%d..." % [_get_selected_server_ip(), NetworkHandler.PORT])
		if NetworkHandler.start_client(_get_selected_server_ip()):
			# Load the replicated scene before ENet finishes its asynchronous
			# handshake so MultiplayerSpawner is ready for the initial snapshot.
			_go_to_game_scene()
		else:
			_set_status(NetworkHandler.get_last_start_error(), true)

func _setup_runtime_mode_selector() -> void:
	if mode_selector == null:
		return

	_setting_runtime_mode = true
	mode_selector.clear()
	mode_selector.add_item("PC 地面端 Server", RuntimeProfile.Preset.PC_GROUND_SERVER)
	mode_selector.add_item("VR 地面端 Client", RuntimeProfile.Preset.VR_GROUND_CLIENT)
	mode_selector.add_item("航天端 XR Client", RuntimeProfile.Preset.ASTRONAUT_XR_CLIENT)

	var profile = RuntimeProfile.current()
	_select_runtime_preset(profile.get_preset())
	mode_selector.disabled = profile.selection_locked
	if not profile.has_explicit_mode:
		profile = RuntimeProfile.select_session_mode(RuntimeProfile.Preset.PC_GROUND_SERVER)
	if not mode_selector.item_selected.is_connected(_on_runtime_mode_selected):
		mode_selector.item_selected.connect(_on_runtime_mode_selected)
	_setting_runtime_mode = false


func _select_runtime_preset(preset: int) -> void:
	for index in range(mode_selector.item_count):
		if mode_selector.get_item_id(index) == preset:
			mode_selector.select(index)
			return


func _on_runtime_mode_selected(index: int) -> void:
	if _setting_runtime_mode:
		return
	var preset := mode_selector.get_item_id(index)
	RuntimeProfile.select_session_mode(preset)
	_update_runtime_ui()
	_setup_network_controls()
	_setup_audio_controls()


func _update_runtime_ui() -> void:
	var profile = RuntimeProfile.current()
	if mode_label != null:
		mode_label.text = "MODE: %s" % profile.get_mode_label()
	if start_button != null:
		start_button.disabled = not profile.is_valid()
	if profile.is_valid():
		_set_status("")
	else:
		_set_status(profile.validation_error, true)

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

func _setup_network_controls() -> void:
	if network_controls == null:
		return

	var is_client: bool = RuntimeProfile.current().is_client()
	network_controls.visible = true

	if server_ip_label != null:
		server_ip_label.visible = not is_client
		server_ip_label.text = "SERVER IP: %s" % _get_local_server_ip()

	if client_ip_label != null:
		client_ip_label.visible = is_client

	if server_ip_input != null:
		server_ip_input.visible = is_client
		server_ip_input.placeholder_text = NetworkHandler.IP_ADDRESS
		server_ip_input.text = _get_default_server_ip()

func _get_selected_server_ip() -> String:
	if server_ip_input != null:
		var value := server_ip_input.text.strip_edges()
		if value != "":
			return value
	return _get_default_server_ip()

func _get_default_server_ip() -> String:
	var arg_ip := _get_arg_value(SERVER_IP_ARG)
	if arg_ip != "":
		return arg_ip
	return NetworkHandler.IP_ADDRESS

func _get_local_server_ip() -> String:
	var addresses := IP.get_local_addresses()
	for address in addresses:
		var ip := str(address)
		if _is_preferred_lan_ipv4(ip):
			return ip

	for address in addresses:
		var ip := str(address)
		if _is_usable_ipv4(ip):
			return ip

	return NetworkHandler.IP_ADDRESS

func _is_preferred_lan_ipv4(ip: String) -> bool:
	if not _is_usable_ipv4(ip):
		return false
	if ip.begins_with("10.") or ip.begins_with("192.168."):
		return true
	if ip.begins_with("172."):
		var parts := ip.split(".")
		var second_octet := int(parts[1])
		return second_octet >= 16 and second_octet <= 31
	return false

func _is_usable_ipv4(ip: String) -> bool:
	if ip == "" or ip == "0.0.0.0":
		return false
	if ip.begins_with("127.") or ip.begins_with("169.254."):
		return false
	var parts := ip.split(".")
	if parts.size() != 4:
		return false
	for part in parts:
		if not part.is_valid_int():
			return false
		var octet := int(part)
		if octet < 0 or octet > 255:
			return false
	return true

func _get_arg_value(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	for arg in OS.get_cmdline_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""

func _prepare_presentation(profile) -> bool:
	_reset_presentation_viewport()
	if profile.uses_xr() and XRServer.find_interface("OpenXR") == null:
		_set_status("OpenXR interface was not found. Launch XR modes with --xr-mode on.", true)
		return false
	return true


func _reset_presentation_viewport() -> void:
	get_tree().root.use_xr = false
	get_viewport().use_xr = false
	get_tree().root.transparent_bg = false
	get_viewport().transparent_bg = false


func _set_status(message: String, is_error: bool = false) -> void:
	if status_label == null:
		return
	status_label.text = message
	status_label.visible = not message.is_empty()
	status_label.modulate = Color(1.0, 0.35, 0.35) if is_error else Color(0.85, 0.9, 1.0)

func _on_network_ready():
	_go_to_game_scene()

func _go_to_game_scene() -> void:
	if _changing_scene:
		return

	_changing_scene = true
	if NetworkHandler.network_ready.is_connected(_on_network_ready):
		NetworkHandler.network_ready.disconnect(_on_network_ready)
	get_tree().change_scene_to_file(GAME_SCENE_PATH)
