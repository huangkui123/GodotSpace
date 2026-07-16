# WorkListData.gd
extends Resource
class_name WorkListData

@export var id: int
@export var icon_path: String
@export var title: String
@export var step_count_text: String
@export var brief_description: String
@export var info_data_result: WorkListInfoDataResult
@export var is_configured: bool = true

func _init(
	_id: int = 0,
	_icon_path: String = "",
	_title: String = "",
	_step_count_text: String = "",
	_brief_description: String = "",
	_info_data_result: WorkListInfoDataResult = null,
	_is_configured: bool = true
):
	id = _id
	icon_path = _icon_path
	title = _title
	step_count_text = _step_count_text
	brief_description = _brief_description
	info_data_result = _info_data_result
	is_configured = _is_configured
