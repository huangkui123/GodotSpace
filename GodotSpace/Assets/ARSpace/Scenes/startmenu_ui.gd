# start_menu_ui.gd
extends Control

const GAME_SCENE_PATH = "res://Assets/ARSpace/Scenes/ARSpace.tscn"
const SERVER_IP_ARG = "--server-ip="
const RuntimeProfile = preload("res://Assets/ARSpace/Scripts/runtime_profile.gd")
const LaunchConfig = preload("res://Assets/ARSpace/Scripts/Startup/launch_config.gd")

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
var _starting := false
var _compute_selector: OptionButton
var _agent_toggle: CheckBox
var _launcher := false
var _saved: Dictionary = {}
var _voice_toggle: CheckBox
var _capture_toggle: CheckBox
var _cast_toggle: CheckBox
var _adb_input: LineEdit
var _serial_input: LineEdit
var _streaming_input: LineEdit
var _server_choices: OptionButton
var _discovery_button: Button
var _startup_controls: VBoxContainer

func _ready():
	_reset_presentation_viewport()
	NetworkHandler.network_ready.connect(_on_network_ready)
	_setup_runtime_mode_selector()
	_update_runtime_ui()
	_setup_network_controls()
	_setup_audio_controls()
	_setup_agent_controls()
	if _launcher:
		_setup_launch_controls()
	SessionRuntime.status_changed.connect(_on_session_status)
	if SessionRuntime.is_child:
		_agent_toggle.button_pressed = bool(SessionRuntime.options.get("assistant", false))
		call_deferred("_on_start_pressed")
	var previous_error := NetworkHandler.get_last_start_error()
	if not previous_error.is_empty():
		_set_status(previous_error, true)

func _on_start_pressed():
	if _starting:
		return
	if _launcher:
		var selected := _collect_launch_options()
		if SessionRuntime.start_session(selected):
			start_button.disabled = true
			_set_status("正在准备协作…")
		return
	var profile = RuntimeProfile.current()
	if not profile.is_valid():
		_set_status(profile.validation_error, true)
		return
	_starting = true
	start_button.disabled = true
	mode_selector.disabled = true
	_compute_selector.disabled = true
	_agent_toggle.disabled = true
	LocalAgentRuntime.enabled = _agent_toggle.button_pressed
	ProjectSettings.set_setting("arspace/local_agent/enabled", LocalAgentRuntime.enabled)
	# Optional model startup must not gate ENet or XR. The runtime publishes its
	# own progress and remains disabled by default, including managed children.
	if LocalAgentRuntime.enabled:
		LocalAgentRuntime.ensure_services(profile)
	_starting = false
	start_button.disabled = false
	mode_selector.disabled = profile.selection_locked
	_compute_selector.disabled = false
	_agent_toggle.disabled = false
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
	if SessionRuntime.is_child and bool(SessionRuntime.options.get("voice", false)):
		VoiceChat.set_voice_enabled(true)

func _setup_runtime_mode_selector() -> void:
	if mode_selector == null:
		return

	_setting_runtime_mode = true
	mode_selector.clear()
	var initial_profile = RuntimeProfile.current()
	_launcher = not initial_profile.has_explicit_mode and not SessionRuntime.is_child
	if _launcher:
		_saved = LaunchConfig.preferences()
		mode_selector.add_item("本机调试天上端（Server + SKY XR）", 100)
		mode_selector.add_item("本机调试地面端（Server + Ground VR）", 101)
		mode_selector.add_item("天上端加入协作（连接另一台电脑）", 102)
		mode_selector.select(LaunchConfig.PRESETS.find(_saved.preset))
		mode_selector.item_selected.connect(_on_runtime_mode_selected)
		_setting_runtime_mode = false
		return
	mode_selector.add_item("PC 协作 Server（可部署在天上端）", RuntimeProfile.Preset.PC_GROUND_SERVER)
	mode_selector.add_item("VR 地面端 Client", RuntimeProfile.Preset.VR_GROUND_CLIENT)
	mode_selector.add_item("天上端 XR Client", RuntimeProfile.Preset.SKY_XR_CLIENT)
	mode_selector.add_item("VR 地面端 Server", RuntimeProfile.Preset.VR_GROUND_SERVER)

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
	if _launcher:
		_saved.preset = LaunchConfig.PRESETS[index]
		_update_runtime_ui()
		_setup_network_controls()
		return
	var preset := mode_selector.get_item_id(index)
	RuntimeProfile.select_session_mode(preset)
	_update_runtime_ui()
	_setup_network_controls()
	_setup_audio_controls()
	if _compute_selector != null:
		_compute_selector.visible = RuntimeProfile.current().is_server()


func _setup_agent_controls() -> void:
	_agent_toggle = CheckBox.new()
	_agent_toggle.text = "启动智能助手服务"
	_agent_toggle.button_pressed = bool(_saved.get("assistant", ProjectSettings.get_setting("arspace/local_agent/enabled", false)))
	$VBoxContainer.add_child(_agent_toggle)
	$VBoxContainer.move_child(_agent_toggle, status_label.get_index())
	_compute_selector = OptionButton.new()
	_compute_selector.add_item("模型算力：本机（8B）")
	_compute_selector.add_item("模型算力：远端（已配置 SSH）")
	_compute_selector.select(1 if LocalAgentRuntime.compute_mode == "remote" else 0)
	_compute_selector.visible = RuntimeProfile.current().is_server()
	_compute_selector.item_selected.connect(func(index: int): LocalAgentRuntime.select_compute("local" if index == 0 else "remote"))
	$VBoxContainer.add_child(_compute_selector)
	$VBoxContainer.move_child(_compute_selector, status_label.get_index())
	LocalAgentRuntime.status_changed.connect(func(next: String, detail: String): _set_status(detail, next == "failed"))


func _update_runtime_ui() -> void:
	if _launcher:
		mode_label.text = "GodotSpace 协作启动台"
		start_button.text = "开始协作"
		return
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
	if SessionRuntime.is_child:
		selected_input = str(SessionRuntime.options.get("input_device", selected_input))
		selected_output = str(SessionRuntime.options.get("output_device", selected_output))
	VoiceChat.set_audio_devices(selected_input, selected_output)

func _get_selected_option_text(option: OptionButton) -> String:
	var selected := option.selected
	if selected < 0:
		return "Default"
	return option.get_item_text(selected)

func _setup_network_controls() -> void:
	if network_controls == null:
		return

	var is_client: bool = _saved.get("preset") == "join_sky" if _launcher else RuntimeProfile.current().is_client()
	network_controls.visible = true

	if server_ip_label != null:
		server_ip_label.visible = not is_client
		server_ip_label.text = "本机 Server · XR 自动连接" if _launcher else "SERVER IP: %s" % _get_local_server_ip()

	if client_ip_label != null:
		client_ip_label.visible = is_client

	if server_ip_input != null:
		server_ip_input.visible = is_client
		server_ip_input.placeholder_text = NetworkHandler.IP_ADDRESS
		server_ip_input.text = _get_default_server_ip()
	if _server_choices != null:
		_server_choices.visible = is_client
		_discovery_button.visible = is_client
		if is_client:
			SessionRuntime.call_deferred("discover_servers")

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
	if _launcher:
		return str(_saved.get("server_ip", ""))
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
	if _launcher:
		return
	_go_to_game_scene()


func _on_session_status(detail: String) -> void:
	_set_status(detail)


func _setup_launch_controls() -> void:
	# Keep the existing node paths and legacy single-role entry points intact.
	var column := $VBoxContainer as VBoxContainer
	column.custom_minimum_size.x = 560
	column.add_theme_constant_override("separation", 8)
	mode_label.add_theme_font_size_override("font_size", 24)
	start_button.custom_minimum_size.y = 44
	_voice_toggle = CheckBox.new()
	_voice_toggle.text = "开启语音通话"
	_voice_toggle.button_pressed = bool(_saved.voice)
	column.add_child(_voice_toggle)
	column.move_child(_voice_toggle, status_label.get_index())
	_capture_toggle = CheckBox.new()
	_capture_toggle.text = "自动开启天上端透传采集（USB）"
	_capture_toggle.button_pressed = bool(_saved.capture)
	column.add_child(_capture_toggle)
	column.move_child(_capture_toggle, status_label.get_index())
	_cast_toggle = CheckBox.new()
	_cast_toggle.text = "自动开启天上画面投屏（USB）"
	_cast_toggle.button_pressed = bool(_saved.cast)
	column.add_child(_cast_toggle)
	column.move_child(_cast_toggle, status_label.get_index())
	_server_choices = OptionButton.new()
	_server_choices.add_item("发现局域网 Server…")
	network_controls.add_child(_server_choices)
	_discovery_button = Button.new()
	_discovery_button.text = "搜索局域网 Server"
	network_controls.add_child(_discovery_button)
	_discovery_button.pressed.connect(SessionRuntime.discover_servers)
	_server_choices.item_selected.connect(func(index: int):
		if index > 0:
			server_ip_input.text = str(_server_choices.get_item_metadata(index)))
	SessionRuntime.servers_changed.connect(_on_servers_changed)
	var advanced := CheckButton.new()
	advanced.text = "设备与音频设置（首次配置后自动记住）"
	column.add_child(advanced)
	column.move_child(advanced, status_label.get_index())
	_startup_controls = VBoxContainer.new()
	column.add_child(_startup_controls)
	column.move_child(_startup_controls, status_label.get_index())
	_adb_input = _add_launch_field("ADB 路径（留空自动查找 Android SDK）", str(_saved.adb_path))
	_serial_input = _add_launch_field("PICO USB 序列号（单设备可留空）", str(_saved.device_serial))
	_streaming_input = _add_launch_field("Business Streaming 程序路径（可选，自动查找）", str(_saved.streaming_path))
	_startup_controls.visible = false
	audio_controls.visible = false
	_compute_selector.visible = false
	advanced.toggled.connect(func(value: bool):
		_startup_controls.visible = value
		audio_controls.visible = value
		_compute_selector.visible = value)
	_populate_device_option(input_device, AudioServer.get_input_device_list(), str(_saved.input_device))
	_populate_device_option(output_device, AudioServer.get_output_device_list(), str(_saved.output_device))
	_setup_network_controls()
	# Fit smaller desktop windows while retaining the legacy scene layout.
	network_controls.get_node("Title").text = "协作网络"
	if _saved.preset != "join_sky":
		server_ip_label.text = "本机 Server · XR 自动连接"
	var scroll := ScrollContainer.new()
	add_child(scroll)
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	scroll.add_child(margin)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 24)
	column.reparent(margin)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# StartMenu's parent is Node2D, so full-rect anchors have no Control parent
	# size. Size the root explicitly and keep it synchronized with the viewport.
	get_viewport().size_changed.connect(_resize_launcher)
	_resize_launcher()


func _resize_launcher() -> void:
	size = get_viewport_rect().size


func _add_launch_field(placeholder: String, value: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.tooltip_text = placeholder
	field.text = value
	_startup_controls.add_child(field)
	return field


func _collect_launch_options() -> Dictionary:
	var result := LaunchConfig.defaults()
	result.preset = LaunchConfig.PRESETS[mode_selector.selected]
	result.server_ip = server_ip_input.text.strip_edges()
	result.assistant = _agent_toggle.button_pressed
	result.voice = _voice_toggle.button_pressed
	result.capture = _capture_toggle.button_pressed
	result.cast = _cast_toggle.button_pressed
	result.adb_path = _adb_input.text.strip_edges()
	result.device_serial = _serial_input.text.strip_edges()
	result.streaming_path = _streaming_input.text.strip_edges()
	result.input_device = _get_selected_option_text(input_device)
	result.output_device = _get_selected_option_text(output_device)
	return result


func _on_servers_changed(servers: Dictionary) -> void:
	_server_choices.clear()
	_server_choices.add_item("选择 Server（%d 台）" % servers.size())
	for address in servers:
		_server_choices.add_item("%s · %s" % [servers[address], address])
		_server_choices.set_item_metadata(_server_choices.item_count - 1, address)

func _go_to_game_scene() -> void:
	if _changing_scene:
		return

	_changing_scene = true
	if NetworkHandler.network_ready.is_connected(_on_network_ready):
		NetworkHandler.network_ready.disconnect(_on_network_ready)
	get_tree().change_scene_to_file(GAME_SCENE_PATH)
