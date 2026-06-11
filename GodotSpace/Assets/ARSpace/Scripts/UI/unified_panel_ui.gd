extends Control

const PANEL_MODEL := "model"
const PANEL_VOICE := "voice"
const PANEL_CALIBRATION := "calibration"

@onready var content_panel: PanelContainer = $PanelRoot/ContentPanel
@onready var model_button: Button = $PanelRoot/Sidebar/SidebarMargin/SidebarButtons/ModelButton
@onready var voice_button: Button = $PanelRoot/Sidebar/SidebarMargin/SidebarButtons/VoiceButton
@onready var calibration_button: Button = $PanelRoot/Sidebar/SidebarMargin/SidebarButtons/CalibrationButton
@onready var collapse_button: Button = $PanelRoot/Sidebar/SidebarMargin/SidebarButtons/CollapseButton
@onready var model_section: Control = $PanelRoot/ContentPanel/ContentMargin/Sections/ModelSection
@onready var voice_section: Control = $PanelRoot/ContentPanel/ContentMargin/Sections/VoiceSection
@onready var calibration_section: Control = $PanelRoot/ContentPanel/ContentMargin/Sections/CalibrationSection

var active_panel := PANEL_VOICE
var content_expanded := true


func _ready() -> void:
	_configure_mouse_passthrough(self)

	model_button.toggle_mode = true
	voice_button.toggle_mode = true
	calibration_button.toggle_mode = true

	model_button.pressed.connect(func(): _open_panel(PANEL_MODEL))
	voice_button.pressed.connect(func(): _open_panel(PANEL_VOICE))
	calibration_button.pressed.connect(func(): _open_panel(PANEL_CALIBRATION))
	collapse_button.pressed.connect(_toggle_content)

	if NetworkHandler.has_signal("network_role_selected"):
		NetworkHandler.network_role_selected.connect(_on_network_role_selected)
	if NetworkHandler.has_signal("network_ready"):
		NetworkHandler.network_ready.connect(_on_network_changed)

	multiplayer.peer_connected.connect(_on_peer_changed)
	multiplayer.peer_disconnected.connect(_on_peer_changed)

	active_panel = PANEL_MODEL if _server_panels_available() else PANEL_VOICE
	_refresh_visibility()


func _on_network_role_selected(_is_server: bool) -> void:
	if _server_panels_available():
		active_panel = PANEL_MODEL
	else:
		active_panel = PANEL_VOICE
	content_expanded = true
	_refresh_visibility()


func _on_network_changed() -> void:
	_refresh_visibility()


func _on_peer_changed(_peer_id: int) -> void:
	_refresh_visibility()


func _open_panel(panel_name: String) -> void:
	if panel_name != PANEL_VOICE and not _server_panels_available():
		panel_name = PANEL_VOICE

	if panel_name == active_panel:
		content_expanded = not content_expanded
		_refresh_visibility()
		return

	active_panel = panel_name
	content_expanded = true
	_refresh_visibility()


func _toggle_content() -> void:
	content_expanded = not content_expanded
	_refresh_visibility()


func _refresh_visibility() -> void:
	var server_panels_available := _server_panels_available()
	model_button.visible = server_panels_available
	calibration_button.visible = server_panels_available

	if not server_panels_available and active_panel != PANEL_VOICE:
		active_panel = PANEL_VOICE

	content_panel.visible = content_expanded
	collapse_button.text = "收起" if content_expanded else "展开"

	model_section.visible = content_expanded and active_panel == PANEL_MODEL and server_panels_available
	voice_section.visible = content_expanded and active_panel == PANEL_VOICE
	calibration_section.visible = content_expanded and active_panel == PANEL_CALIBRATION and server_panels_available

	model_button.button_pressed = content_expanded and active_panel == PANEL_MODEL
	voice_button.button_pressed = content_expanded and active_panel == PANEL_VOICE
	calibration_button.button_pressed = content_expanded and active_panel == PANEL_CALIBRATION


func _server_panels_available() -> bool:
	if VoiceChat.voice_endpoint_selected:
		return not VoiceChat.is_vr_mode
	return multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func _configure_mouse_passthrough(node: Node) -> void:
	if node is Control:
		var control := node as Control
		control.mouse_filter = Control.MOUSE_FILTER_STOP if _is_interactive_control(control) else Control.MOUSE_FILTER_IGNORE

	for child in node.get_children():
		_configure_mouse_passthrough(child)


func _is_interactive_control(control: Control) -> bool:
	return control is Button \
		or control is Tree \
		or control is LineEdit \
		or control is SpinBox \
		or control.name == "PreviewTexture"
