# WorkListDataResult.gd
extends Resource
class_name WorkListDataResult

@export var list: Array[WorkListData] = []

func _init(_list: Array[WorkListData] = []):
	list = _list