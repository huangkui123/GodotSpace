extends Resource
class_name PictureListDataResult

const DEBUG_LOGS := false

@export var list: Array[PictureListData] = []

func refresh_image_list():
	list.clear()
	var image_files = get_image_file_names()
	for file_name in image_files:
		# 这里可以给 PictureListData 填充默认值，比如索引和路径
		var data = PictureListData.new()
		data.index = list.size() + 1
		data.banner_path = "res://Assets/StreamingAssets/Images/" + file_name
		data.title = file_name.get_basename()
		list.append(data)

	if DEBUG_LOGS: print("PictureListDataResult initialized with %d items." % list.size())
	for item in list:
		if DEBUG_LOGS: print("Item: %s" % [item.title])

func get_image_file_names():
	var dir_path = "res://Assets/StreamingAssets/Images"
	var file_names := []

	var dir = DirAccess.open(dir_path)
	if dir:
		dir.list_dir_begin()
		while true:
			var file_name = dir.get_next()
			if file_name == "":
				break
			if dir.current_is_dir():
				continue
			if file_name.ends_with(".png") or file_name.ends_with(".jpg") or file_name.ends_with(".jpeg"):
				file_names.append(file_name)
		dir.list_dir_end()
	else:
		push_error("Failed to open directory: %s" % dir_path)

	return file_names
