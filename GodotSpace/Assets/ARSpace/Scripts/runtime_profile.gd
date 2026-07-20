class_name ARSpaceRuntimeProfile
extends RefCounted

## Single source of truth for the network, semantic, presentation, and environment
## roles of the current process. Custom application flags are read from the
## arguments after Godot's `--` separator. Engine XR flags are read from the
## complete argument list.

enum NetworkRole {
	SERVER,
	CLIENT,
}

enum SemanticRole {
	GROUND,
	ASTRONAUT,
}

enum Presentation {
	DESKTOP,
	XR,
	TEST,
}

enum EnvironmentMode {
	OPAQUE,
	PASSTHROUGH,
}

enum Preset {
	PC_GROUND_SERVER,
	VR_GROUND_CLIENT,
	ASTRONAUT_XR_CLIENT,
}


class Profile extends RefCounted:
	var network_role: int = NetworkRole.SERVER
	var semantic_role: int = SemanticRole.GROUND
	var presentation: int = Presentation.DESKTOP
	var environment: int = EnvironmentMode.OPAQUE
	var validation_error: String = ""
	var has_explicit_mode: bool = false
	var selection_locked: bool = false
	var xr_mode_requested: bool = false
	var xr_mode_disabled: bool = false

	func is_valid() -> bool:
		return validation_error.is_empty()

	func is_server() -> bool:
		return network_role == NetworkRole.SERVER

	func is_client() -> bool:
		return network_role == NetworkRole.CLIENT

	func is_ground() -> bool:
		return semantic_role == SemanticRole.GROUND

	func is_astronaut() -> bool:
		return semantic_role == SemanticRole.ASTRONAUT

	func uses_xr() -> bool:
		return presentation == Presentation.XR

	func uses_desktop_ui() -> bool:
		return presentation != Presentation.XR

	func is_test_mode() -> bool:
		return presentation == Presentation.TEST

	func uses_passthrough() -> bool:
		return environment == EnvironmentMode.PASSTHROUGH

	func can_annotate() -> bool:
		return is_ground()

	func get_preset() -> int:
		if is_client():
			return Preset.VR_GROUND_CLIENT if is_ground() else Preset.ASTRONAUT_XR_CLIENT
		return Preset.PC_GROUND_SERVER

	func get_mode_label() -> String:
		if is_test_mode():
			return "ASTRONAUT TEST CLIENT" if is_client() else "GROUND TEST SERVER"
		match get_preset():
			Preset.VR_GROUND_CLIENT:
				return "VR GROUND CLIENT"
			Preset.ASTRONAUT_XR_CLIENT:
				return "ASTRONAUT XR CLIENT"
			_:
				return "PC GROUND SERVER"

const REMOVED_XR_SERVER_ARG := "--ground-vr"
const GROUND_VR_CLIENT_ARG := "--ground-vr-client"
const XR_CLIENT_ARG := "--xr-client"
const TEST_MODE_ARG := "--testmode"
const VOICE_ROLE_ARG := "--voice-role="
const XR_MODE_ARG := "--xr-mode"

static var _session_override = null


static func current():
	if _session_override != null:
		return _session_override
	return from_args(
		OS.get_cmdline_args(),
		OS.get_cmdline_user_args(),
		OS.has_feature("android")
	)


static func from_args(all_args: Array, user_args: Array, is_android: bool = false):
	var profile := Profile.new()
	var app_args: Array = user_args if not user_args.is_empty() else all_args
	var wants_removed_xr_server := _has_arg(app_args, REMOVED_XR_SERVER_ARG)
	var wants_ground_vr_client := _has_arg(app_args, GROUND_VR_CLIENT_ARG)
	var wants_xr_client := _has_arg(app_args, XR_CLIENT_ARG)
	var wants_test_mode := _has_arg(app_args, TEST_MODE_ARG)
	var voice_role := _get_arg_value(app_args, VOICE_ROLE_ARG).to_lower()
	var xr_mode_value := _get_xr_mode_value(all_args)
	var errors: PackedStringArray = []

	profile.xr_mode_requested = xr_mode_value == "on"
	profile.xr_mode_disabled = xr_mode_value == "off"
	var has_explicit_selection := wants_removed_xr_server \
		or wants_ground_vr_client \
		or wants_xr_client \
		or wants_test_mode \
		or not voice_role.is_empty() \
		or profile.xr_mode_disabled \
		or (not xr_mode_value.is_empty() and xr_mode_value not in ["on", "off"])
	# A native Android build still defaults to Astronaut XR, but the shared
	# PICO APK must let the operator choose Ground VR from StartMenu. Only an
	# explicit application role (or an incompatible XR flag) locks the selector.
	profile.has_explicit_mode = is_android or has_explicit_selection
	profile.selection_locked = has_explicit_selection

	if not xr_mode_value.is_empty() and xr_mode_value not in ["on", "off"]:
		errors.append("Unsupported --xr-mode value: %s" % xr_mode_value)
	if not voice_role.is_empty() and voice_role not in ["server", "pc", "client", "vr"]:
		errors.append("Unsupported --voice-role value: %s" % voice_role)

	var role_requests_server := voice_role in ["server", "pc"]
	var role_requests_client := voice_role in ["client", "vr"]

	if wants_removed_xr_server:
		errors.append("--ground-vr is no longer supported; use the PC Ground Server or --ground-vr-client")
	if wants_ground_vr_client and wants_xr_client:
		errors.append("--ground-vr-client cannot be combined with --xr-client")
	if wants_ground_vr_client and not role_requests_client:
		errors.append("--ground-vr-client requires --voice-role=client")
	if wants_xr_client and role_requests_server:
		errors.append("--xr-client requires --voice-role=client")
	if wants_ground_vr_client and wants_test_mode:
		errors.append("--ground-vr-client cannot be combined with --testmode")
	if wants_xr_client and wants_test_mode:
		errors.append("--xr-client cannot be combined with --testmode")
	if profile.xr_mode_requested and wants_test_mode:
		errors.append("--xr-mode on cannot be combined with --testmode")
	if is_android and role_requests_server:
		errors.append("Ground Server is not supported on Android")
	if role_requests_server and profile.xr_mode_requested and not wants_test_mode:
		errors.append("XR Server launch is not supported; use the PC Ground Server")
	var requests_xr_presentation := wants_ground_vr_client \
		or wants_xr_client \
		or (role_requests_client and not wants_test_mode) \
		or (is_android and not wants_test_mode)
	if profile.xr_mode_disabled and requests_xr_presentation:
		errors.append("XR presentation cannot be combined with --xr-mode off")

	var client_role := is_android \
		or wants_ground_vr_client \
		or wants_xr_client \
		or role_requests_client

	profile.network_role = NetworkRole.CLIENT if client_role else NetworkRole.SERVER
	profile.semantic_role = SemanticRole.GROUND \
		if wants_ground_vr_client or not client_role \
		else SemanticRole.ASTRONAUT

	if wants_test_mode:
		profile.presentation = Presentation.TEST
	elif wants_ground_vr_client or client_role:
		profile.presentation = Presentation.XR
	else:
		profile.presentation = Presentation.DESKTOP

	profile.environment = EnvironmentMode.PASSTHROUGH \
		if profile.presentation == Presentation.XR and profile.semantic_role == SemanticRole.ASTRONAUT \
		else EnvironmentMode.OPAQUE
	profile.validation_error = "; ".join(errors)
	return profile


static func select_session_mode(preset: int, is_android: bool = OS.has_feature("android")):
	var profile := Profile.new()
	profile.has_explicit_mode = true
	profile.selection_locked = false
	match preset:
		Preset.VR_GROUND_CLIENT:
			profile.network_role = NetworkRole.CLIENT
			profile.semantic_role = SemanticRole.GROUND
			profile.presentation = Presentation.XR
			profile.environment = EnvironmentMode.OPAQUE
			profile.xr_mode_requested = true
		Preset.ASTRONAUT_XR_CLIENT:
			profile.network_role = NetworkRole.CLIENT
			profile.semantic_role = SemanticRole.ASTRONAUT
			profile.presentation = Presentation.XR
			profile.environment = EnvironmentMode.PASSTHROUGH
			profile.xr_mode_requested = true
		_:
			profile.network_role = NetworkRole.SERVER
			profile.semantic_role = SemanticRole.GROUND
			profile.presentation = Presentation.DESKTOP
			profile.environment = EnvironmentMode.OPAQUE
			if is_android:
				profile.validation_error = "Ground Server is not supported on Android"
	_session_override = profile
	return profile


static func clear_session_override() -> void:
	_session_override = null


static func _has_arg(args: Array, target: String) -> bool:
	for value in args:
		if str(value) == target:
			return true
	return false


static func _get_arg_value(args: Array, prefix: String) -> String:
	for value in args:
		var arg := str(value)
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""


static func _get_xr_mode_value(args: Array) -> String:
	for index in range(args.size()):
		var arg := str(args[index]).to_lower()
		if arg == XR_MODE_ARG and index + 1 < args.size():
			return str(args[index + 1]).to_lower()
		if arg.begins_with(XR_MODE_ARG + "="):
			return arg.get_slice("=", 1).to_lower()
	return ""
