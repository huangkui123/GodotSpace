extends Control

class_name WorkListInfoUIView

const DEBUG_LOGS := false

@export var to_sound: Button
@export var to_video: Button
@export var to_animation: Button

@onready var title_label: Label = $TopMenuBox/Title

var _info_save_list: Array[WorkListInfoData] = []
@export var info_: Array[WorkListInfoItem] = []

var page_index: int = 1
var page_count: int = 0
var item_count: int = 0
var page_item_count: int = 1

func _ready():
	Global.work_list_info_canvas = self
	self.visible = false

	if DEBUG_LOGS: print(self.name, ": _ready")
	init_view()

func _enter_tree():
	if DEBUG_LOGS: print(self.name, ": _enter_tree")

func init_view():
	if DEBUG_LOGS: print(self.name, ": init_view")

func on_refresh_data_change_view(result: WorkListInfoDataResult):
	if DEBUG_LOGS: print(self.name, ": on_refresh_data_change_view -> WorkListInfoDataResult")
	if title_label:
		title_label.text = result.title
	refresh_list(result)

func refresh_list(refresh_list_data: WorkListInfoDataResult):
	if DEBUG_LOGS: print("refresh_list refresh_list_data.list.size() = ", refresh_list_data.list.size())
	
	_info_save_list.clear()
	for i in range(refresh_list_data.list.size()):
		if DEBUG_LOGS: print(refresh_list_data.list[i].step, refresh_list_data.list[i].title)
		_info_save_list.append(refresh_list_data.list[i])
	
	page_index = 1
	page_count = 0
	item_count = 0
	refresh_info()

func refresh_info():
	item_count = _info_save_list.size()
	page_count = int(ceil(float(_info_save_list.size()) / page_item_count))
	bind_page(page_index)

func bind_page(index: int):
	if _info_save_list.size() <= 0:
		if DEBUG_LOGS: print("_info_save_list.size() = ", _info_save_list.size())
		return
	
	for item in info_:
		item.visible = false

	if page_count == 1:
		for i in range(item_count):
			if i < info_.size():
				bind_item(info_[i], _info_save_list[i])
				info_[i].visible = true
	elif page_count > 1:
		if index == page_count:
			var start_index = (index - 1) * page_item_count
			var current_page_items = item_count - start_index
			for i in range(current_page_items):
				if i < info_.size():
					bind_item(info_[i], _info_save_list[start_index + i])
					info_[i].visible = true
		else:
			var start_index = (index - 1) * page_item_count
			for i in range(page_item_count):
				if i < info_.size():
					bind_item(info_[i], _info_save_list[start_index + i])
					info_[i].visible = true

func bind_item(item: WorkListInfoItem, infos: WorkListInfoData):
	if DEBUG_LOGS: print(self.name, ": WorkListInfoStep = ", infos.step)
	if DEBUG_LOGS: print("🟦 [DEBUG] 尝试播放动画 Step", infos.step)

	if Global.spacebox_controller:
		Global.spacebox_controller.play_step(infos.step)
		Global.spacebox_controller.show_only_work_info(infos.step)
	else:
		if DEBUG_LOGS: print("❌ [DEBUG] Global.spacebox_controller 为空")

	item.refresh_info(infos)

func pre_click():
	if page_count <= 0:
		return
	if page_index <= 1:
		return
	page_index -= 1
	if page_index < 1:
		page_index = 1
	bind_page(page_index)

func first_page():
	page_index = 1
	bind_page(page_index)

func last_page():
	page_index = page_count
	bind_page(page_index)

func next_click():
	if page_count <= 0:
		return
	if page_index >= page_count:
		return
	page_index += 1
	if page_index > page_count:
		page_index = page_count
	bind_page(page_index)

func to_animation_on_value_changed(arg0: bool):
	pass

func _on_back_pressed():
	pre_click()

func _on_next_pressed():
	next_click()


func _on_close_button_pressed():
	self.visible = false
