extends Control

class_name PictureUIView

var instance: PictureUIView = null
@export var p_info: Node = null
var info_save_list: Array = []
@export var info_: Array[PictureListItem] = []

var page_index: int = 1
var page_count: int = 0
var item_count: int = 0
var page_item_count: int = 9

var is_max: bool = false

var can_max: bool = true

func _ready():
	print("PictureUIView _ready")
	instance = self
	info_save_list = []
#	scale = self.transform.basis.get_scale()
	init_view()

	var picture_list_data_result = PictureListDataResult.new()
	picture_list_data_result.refresh_image_list()
	refresh_data_change_view(picture_list_data_result)

func _enter_tree():
	pass
	# 对应 OnEnable


func init_view():
	print("InitView")
	# 你可以连接信号或绑定数据模型刷新接口

func refresh_data_change_view(result: PictureListDataResult) -> void:
	print("->PictureListDataResult")
	refresh_list(result)

func refresh_list(refresh_list: PictureListDataResult):
	print("->RefreshList:刷新列表")
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
	print("ItemCount = ", item_count, ", PageCount = ", page_count)
	bind_page(page_index)

func bind_page(index: int):
	if page_count == 1:
		for i in range(item_count):
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
				print("BindItem: ", i, " Data = ", info_save_list[i])
				bind_item(info_[i], info_save_list[idx])
				info_[i].visible = true

func bind_item(item: PictureListItem, data: PictureListData):
	print("Title = ", data.title)
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
	if self.visible:
		self.visible = false
