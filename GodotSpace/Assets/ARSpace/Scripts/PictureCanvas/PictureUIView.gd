extends Control

class_name PictureUIView

const PanelWindowZoom = preload("res://Assets/ARSpace/Scripts/UI/panel_window_zoom.gd")
const DEBUG_LOGS := false

var info_save_list: Array = []
@export var info_: Array[PictureListItem] = []

var page_index: int = 1
var page_count: int = 0
var item_count: int = 0
var page_item_count: int = 9

var is_max: bool = false

var can_max: bool = true

func _ready():
	if DEBUG_LOGS: print("PictureUIView _ready")
	self.visible = false
	var global_node := get_node_or_null("/root/Global")
	if global_node != null:
		global_node.set("picture_canvas", self)
	PanelWindowZoom.bind_max_button(self)
	info_save_list = []
#	scale = self.transform.basis.get_scale()
	init_view()
	_refresh_picture_data()

func _enter_tree():
	pass
	# 对应 OnEnable


func init_view():
	if DEBUG_LOGS: print("InitView")
	# 你可以连接信号或绑定数据模型刷新接口

func refresh_data_change_view(result: PictureListDataResult):
	if DEBUG_LOGS: print("->PictureListDataResult")
	refresh_list(result)


func open_album(requested_page: int = 1, refresh: bool = true) -> Dictionary:
	if requested_page < 1:
		return _tool_error("invalid_page", "Album page must be greater than zero.")
	if refresh:
		_refresh_picture_data()
	if page_count > 0 and requested_page > page_count:
		return _tool_error(
			"invalid_page",
			"Album page %d exceeds the available page count %d." % [requested_page, page_count]
		)
	page_index = requested_page
	if page_count > 0:
		bind_page(page_index)
	else:
		for item in info_:
			if item != null:
				item.visible = false
	visible = true
	return {
		"ok": true,
		"data": {
			"visible": visible,
			"page": page_index,
			"page_count": page_count,
			"picture_count": item_count,
			"refreshed": refresh,
		},
		"error": null,
	}


func get_album_snapshot() -> Dictionary:
	return {
		"visible": visible,
		"page": page_index,
		"page_count": page_count,
		"picture_count": item_count,
		"can_previous": visible and page_count > 0 and page_index > 1,
		"can_next": visible and page_count > 0 and page_index < page_count,
	}


func close_album() -> Dictionary:
	if not visible:
		return _tool_error("album_not_open", "The photo album is not currently open.")
	visible = false
	return {"ok": true, "data": get_album_snapshot(), "error": null}


func next_album_page() -> Dictionary:
	if not visible:
		return _tool_error("album_not_open", "The photo album is not currently open.")
	if page_index >= page_count:
		return _tool_error("already_last_page", "The photo album is already at its last page.")
	next_click()
	return {"ok": true, "data": get_album_snapshot(), "error": null}


func previous_album_page() -> Dictionary:
	if not visible:
		return _tool_error("album_not_open", "The photo album is not currently open.")
	if page_index <= 1:
		return _tool_error("already_first_page", "The photo album is already at its first page.")
	pre_click()
	return {"ok": true, "data": get_album_snapshot(), "error": null}


func go_to_album_page(requested_page: int) -> Dictionary:
	if not visible:
		return _tool_error("album_not_open", "The photo album is not currently open.")
	if requested_page < 1 or requested_page > page_count:
		return _tool_error("invalid_page", "The requested photo album page is unavailable.")
	page_index = requested_page
	bind_page(page_index)
	return {"ok": true, "data": get_album_snapshot(), "error": null}


func _refresh_picture_data() -> void:
	var picture_list_data_result = PictureListDataResult.new()
	picture_list_data_result.refresh_image_list()
	refresh_data_change_view(picture_list_data_result)


func _tool_error(code: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"data": {},
		"error": {"code": code, "message": message},
	}

func refresh_list(refresh_list: PictureListDataResult):
	if DEBUG_LOGS: print("->RefreshList:刷新列表")
	info_save_list.clear()
	for item in refresh_list.list:
		info_save_list.append(item)

	page_index = 1
	page_count = 0
	item_count = 0
	refresh_info()

func refresh_info():
	item_count = info_save_list.size()
	page_count = int(item_count / page_item_count) if item_count % page_item_count == 0 else int(item_count / page_item_count) + 1
	if DEBUG_LOGS: print("ItemCount = ", item_count, ", PageCount = ", page_count)
	bind_page(page_index)

func bind_page(index: int):
	if page_count == 1:
		for i in range(page_item_count):
			if i < item_count:
				bind_item(info_[i], info_save_list[i])
				info_[i].visible = true
			else:
				info_[i].visible = false
	elif page_count > 1:
		if index == page_count:
			for i in range(page_item_count):
				if i < item_count - page_item_count * (index - 1):
					var idx = page_item_count * (index - 1) + i
					bind_item(info_[i], info_save_list[idx])
					info_[i].visible = true
				else:
					info_[i].visible = false
		else:
			for i in range(page_item_count):
				var idx = page_item_count * (index - 1) + i
				if DEBUG_LOGS: print("BindItem: ", i, " Data = ", info_save_list[i])
				bind_item(info_[i], info_save_list[idx])
				info_[i].visible = true

func bind_item(item: PictureListItem, data: PictureListData):
	if DEBUG_LOGS: print("Title = ", data.title)
	item.refresh_info(data)

func pre_click():
	if page_count <= 0 or page_index <= 1:
		return
	page_index -= 1
	page_index = max(page_index, 1)
	bind_page(page_index)

func first_page():
	page_index = 1
	bind_page(page_index)

func last_page():
	page_index = page_count
	bind_page(page_index)

func next_click():
	if page_count <= 0 or page_index >= page_count:
		return
	page_index += 1
	page_index = min(page_index, page_count)
	bind_page(page_index)

#func set_scale():
#	if can_max:
#		is_max = not is_max
#		var target_scale = scale * 2 if is_max else scale
#		self.scale = target_scale


func _on_back_pressed():
	pre_click()


func _on_next_pressed():
	next_click()


func _on_close_button_pressed():
	self.visible = false
