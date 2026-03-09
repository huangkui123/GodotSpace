@tool
extends EditorPlugin

func _enter_tree():
	print("✅ Remote Annotation System 插件已加载")

func _exit_tree():
	print("❌ Remote Annotation System 插件已卸载")
