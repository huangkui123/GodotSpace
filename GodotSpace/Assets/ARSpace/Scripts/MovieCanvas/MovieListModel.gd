extends Node
class_name MovieListModel

# # 信号：当列表发生变化时触发
# signal picture_lists_changed(new_result: PictureListDataResult)
# 
# # 当前的图片列表数据
# var _picture_lists_result: PictureListDataResult = null
# 
# # Getter
# func get_picture_lists_result() -> PictureListDataResult:
#     return _picture_lists_result
# 
# # Setter（触发信号）
# func set_picture_lists_result(value: PictureListDataResult) -> void:
#     _picture_lists_result = value
#     emit_signal("picture_lists_changed", _picture_lists_result)
# 
# # 属性语法：支持 picture_lists_result = ... 语法
# var picture_lists_result:
#     get: get_picture_lists_result
#     set: set_picture_lists_result