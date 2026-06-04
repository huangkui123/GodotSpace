# WorkListUIView.gd

extends Control

const DEBUG_LOGS := false

var _info_save_list: Array[WorkListData] = []

@export var info_: Array[WorkListItem] = []

var page_index: int = 1

var page_count: int = 0

var item_count: int = 0

var page_item_count: int = 5

func _ready():
	if DEBUG_LOGS: print(self.name, ": _ready")
	if OS.has_feature("editor"):
		sample_data_init()

func on_refresh_data_change_view(result: WorkListDataResult):
	if DEBUG_LOGS: print(self.name, ": on_refresh_data_change_view -> WorkListDataResult")
	refresh_list(result)

func refresh_list(refresh_list_data: WorkListDataResult):
	if DEBUG_LOGS: print(self.name, "-> refresh_list: 刷新列表")
	_info_save_list.clear()
	for item_data in refresh_list_data.list:
		_info_save_list.append(item_data)

	page_index = 1
	page_count = 0
	item_count = 0
	refresh_info()

func refresh_info():
	item_count = _info_save_list.size()

	page_count = int(ceil(float(_info_save_list.size()) / page_item_count))
	
	bind_page(page_index)

func bind_page(index: int):
	if DEBUG_LOGS: print("page_count = ", page_count, ", page_index = ", index)
	
	for i in range(info_.size()):
		info_[i].visible = false

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

func bind_item(item: WorkListItem, infos: WorkListData):
	if DEBUG_LOGS: print(self.name, ": Title = ", infos.title)
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

func sample_data_init():
	var info_data_result = WorkListInfoDataResult.new()
	info_data_result.title = "无容器样品实验流程"
	info_data_result.list.append(WorkListInfoData.new(1, 1, "step1.png",
		"1.准备应用系统综合包",
		"在TZ3货船D区III象限应用系统综合包03（TZYY001-03）中，取出样品盒（Z03-1）和无容器样品下行包装袋，用胶带固定在无容器柜附近备用。注：综合包03提手处系有浅紫色缎带作为色彩标识"
	))
	info_data_result.list.append(WorkListInfoData.new(2, 1, "step2.png",
		"2.准备工具",
		"准备手套，确认A区Ⅲ象限无容器柜附近工具，包括：棘轮组合工具（棘轮扳手、M5套头、M6套头、150mm加长杆）、内六角拐脖（M3、M5）、斜口钳、力矩扳手1、3M胶带、剪刀；辅助设施（防静电手环、手环转接件）。"
	))
	info_data_result.list.append(WorkListInfoData.new(3, 1, "step3.png",
		"3.操作准备",
		"航天员至A区Ⅲ象限，将手环转接件安装到无容器材料实验柜的接地点上，插入防静电手环，并佩戴。"
	))
	info_data_result.list.append(WorkListInfoData.new(4, 2, "Demo1.mp4",
		"4.天地通话",
		"天地通话，经地面确认无容器断电后，宇航员进行后续操作。注：在测控区执行该项操作。"
	))
	info_data_result.list.append(WorkListInfoData.new(5, 1, "step5.png",
		"5.识别设备",
		"识别无容器材料实验柜上编号为TGTHYY04014 的无容器实验平台，找到科学实验操作盖。"
	))
	info_data_result.list.append(WorkListInfoData.new(6, 1, "step6.png",
		"6.解锁螺钉",
		"用棘轮扳手、150mm长杆和M5套头解锁科学实验操作盖上51-58号8个M5松不脱螺钉。"
	))
	info_data_result.list.append(WorkListInfoData.new(7, 2, "Demo1.mp4",
		"7.拆除操作盖",
		"抓住科学实验操作盖上的把手，拆除科学实验操作盖，使用3M胶带将操作盖临时固定在柜体附近。"
	))
	info_data_result.list.append(WorkListInfoData.new(8, 1, "step8.png",
		"8.拆卸连接器",
		"航天员确保佩戴防静电手环与手套，断开轴心机构上连接器X01和X02。"
	))
	info_data_result.list.append(WorkListInfoData.new(9, 1, "step9.png",
		"9.解锁螺钉",
		"取出M6内六角套头，150mm加长杆和双向棘轮扳手，解锁6颗M6松不脱压紧螺钉（编号1~6）"
	))
	info_data_result.list.append(WorkListInfoData.new(10, 1, "step10.png",
		"10.解锁轴心机构",
		"螺钉解锁后，顺时针旋转锁紧机构齿扣至“开”。"
	))
	info_data_result.list.append(WorkListInfoData.new(11, 2, "Demo1.mp4",
		"11.抽出轴心机构",
		"握住把手，抽出轴心机构。"
	))
	info_data_result.list.append(WorkListInfoData.new(12, 1, "step11.png",
		"12.取出旧样品盒",
		"需要两名航天员配合操作。一名航天员用双手固定轴心机构，另一名航天员一只手按住样品盒两侧的按钮，然后向上提拉，取出样品盒。将取出样品盒放入无容器样品下行包装袋中，临时固定于高微柜附近，固定位置拍照发给地面，后续将随载人船下行。"
	))
	info_data_result.list.append(WorkListInfoData.new(13, 1, "step12.png",
		"13.识别新样品盒安装位置",
		"取下无容器柜体附近临时固定的样品盒备件（代号为Z03-1），剪开包装袋，按住样品盒两侧的按钮，识别样品盒对位标识。"
	))
	info_data_result.list.append(WorkListInfoData.new(14, 2, "Demo1.mp4",
		"14.安装新样品盒",
		"将样品盒插入安装口。"
	))
	info_data_result.list.append(WorkListInfoData.new(15, 2, "Demo1.mp4",
		"15.插入轴心机构",
		"将轴心机构插入到腔体内部"
	))
	info_data_result.list.append(WorkListInfoData.new(16, 1, "step15.png",
		"16.锁紧轴心机构",
		"插入过程中，注意使定位凸耳（银白色）与外腔定位槽（银白色）方向一致。旋动锁紧机构至“关”"
	))
	info_data_result.list.append(WorkListInfoData.new(17, 1, "step16.png",
		"17.固定机构",
		"使用M6内六角套头+150mm加长杆+力矩扳手1（必须使用），使用2.5N·m的力矩锁紧6颗螺钉（依照对角线原则操作）。对6个M6螺钉第二遍逐个打力矩检查。"
	))
	info_data_result.list.append(WorkListInfoData.new(18, 1, "step17.png",
		"18.安装连接器",
		"插上轴心机构连接器X01和X02。"
	))
	info_data_result.list.append(WorkListInfoData.new(19, 1, "step18.png",
		"19.安装科学实验操作盖",
		"使用力矩扳手1、150mm长杆和M5螺钉套头锁紧科学实验操作盖51-58号M5松不脱螺钉，力矩2.5N.m。"
	))
	info_data_result.list.append(WorkListInfoData.new(20, 1, "step19.png",
		"20.撤收工具至舱内工具包",
		"将棘轮组合工具（棘轮扳手、M5套头、M6套头、150mm加长杆）、内六角拐脖（M3、M5）、斜口钳、力矩扳手1、3M胶带、剪刀放回舱内工具包1a/b中，货包放至核心舱后端通道Ⅲ偏Ⅳ象限安装板。防静电手环、手环转接件，视情回收。"
	))

	var da_result = WorkListDataResult.new()
	da_result.list.append(WorkListData.new(1, "Group 155676.png",
		"无容器样品实验流程",
		"共20步",
		"1.准备应用系统综合包。2.准备工具。3.操作准备...",
		info_data_result
	))
	da_result.list.append(WorkListData.new(2, "无容器样品盒更换.png",
		"无容器样品盒更换",
		"共5步",
		"1.步骤。2.步骤。3.步骤...",
		info_data_result
	))
	da_result.list.append(WorkListData.new(3, "高微柜悬浮实验.png",
		"高微柜悬浮实验",
		"共5步",
		"1.步骤。2.步骤。3.步骤...",
		info_data_result
	))
	da_result.list.append(WorkListData.new(4, "水稻剪枝实验.png",
		"水稻剪枝实验",
		"共5步",
		"1.步骤。2.步骤。3.步骤...",
		info_data_result
	))
	da_result.list.append(WorkListData.new(5, "细胞注射实验.png",
		"细胞注射实验",
		"共5步",
		"1.步骤。2.步骤。3.步骤...",
		info_data_result
	))
	da_result.list.append(WorkListData.new(6, "Group 155681.png",
		"实验流程5",
		"共5步",
		"1.步骤。2.步骤。3.步骤...",
		info_data_result
	))
	da_result.list.append(WorkListData.new(7, "Group 155682.png",
		"实验流程6",
		"共6步",
		"1.步骤。2.步骤。3.步骤...",
		info_data_result
	))
	da_result.list.append(WorkListData.new(8, "Group 155683.png",
		"实验流程7",
		"共7步",
		"1.步骤。2.步骤。3.步骤...",
		info_data_result
	))

	on_refresh_data_change_view(da_result)


func _on_back_pressed():
	pre_click()


func _on_next_pressed():
	next_click()
