# WorkListInfoDataResult.gd
extends Resource
class_name WorkListInfoDataResult

@export var title: String
@export var list: Array[WorkListInfoData] = []

func _init(_title: String = "", _list: Array[WorkListInfoData] = []):
	title = _title
	list = _list