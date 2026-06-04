extends Resource
class_name MovieListDataResult

const DEBUG_LOGS := false

@export var list: Array[MovieListData] = []

func refresh_video_list():
	list.clear()
	var video_files = get_video_file_names()
	for file_name in video_files:
		var data = MovieListData.new()
		data.index = list.size() + 1
		data.banner_path = "res://Assets/StreamingAssets/Videos/" + file_name
		data.title = file_name.get_basename()
		list.append(data)

	if DEBUG_LOGS: print("MovieListDataResult initialized with %d items." % list.size())
	for item in list:
		if DEBUG_LOGS: print("Item: %s" % [item.title])

func get_video_file_names():
	var dir_path = "res://Assets/StreamingAssets/Videos"
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
			if file_name.ends_with(".mp4"):
				file_names.append(file_name)
		dir.list_dir_end()
	else:
		push_error("Failed to open directory: %s" % dir_path)

	return file_names
