# WorkListInfoData.gd
extends Resource
class_name WorkListInfoData

@export var step: int
@export var type: int
@export var path: String
@export var title: String
@export var info: String

func _init(_step = 1, _type = 1, _path = "", _title = "", _info = ""):
	step = _step
	type = _type
	path = _path
	title = _title
	info = _info