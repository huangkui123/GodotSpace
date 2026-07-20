# Godot headless 导入基线

基线日期：2026-07-16

命令：

```powershell
& 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe' `
  --headless --path 'F:\GodotSpace\GodotSpace' --import
```

结果：退出码 `0`；未发现 GDScript 解析失败、第一阶段主场景依赖缺失、Autoload 初始化失败或 GDExtension 动态库加载失败。2026-07-20 使用空 `.godot` 缓存和 `--verbose` 复核后，修正了实际为 PNG、却使用 `.jpg` 扩展名的 `1668416234826` 图片；同时把下述既有非主线源模型问题纳入精确基线，不再笼统声称整个仓库没有缺失资源。

## 已知非第一阶段源资产问题

以下问题均由 fresh import 定位到具体旧源模型；它们不被 `StartMenu.tscn`、`ARSpace.tscn`、航天员 `china_rig.fbx` 或第一阶段自动化场景依赖。验证脚本只允许这些精确路径，出现任何新缺失路径仍会失败：

- `Scene_Main/ori/SM_Tri.obj` 引用缺失的 `SM_Tri.mtl`。
- `Assets/VRIK/Editor/CoreRes/Char/PlayerM/PlayerM.fbx` 引用三个缺失的 `Assets/ChatRes/.../*.tif`。
- Nature Shaders 演示 `Fern.fbx` 引用两个缺失的示例 PNG。
- `Assets/Resource/Model/FBX/Generic/Malamute.fbx` 引用缺失的 `Mala.psd`。
- `Scene_Main/ori/Kepler(B)/Kepler(B).fbx` 的两个内嵌图片 CRC/解码失败；verbose 日志确认该错误发生在 Kepler 导入结束前，随后 `china_rig.fbx` 独立导入成功。

这些资产若在后续阶段进入正式运行路径，必须修复源文件或替换资源，不能继续沿用第一阶段豁免。

## 已知清理阶段噪声

下列输出只在退出码为 `0` 且没有前述关键错误时按已知清理噪声记录：

- progress dialog / task flush / scan thread 在 headless 退出阶段中止。
- `ObjectDB instances leaked at exit`、RID/resource leak 等退出清理报告。
- Godot OpenXR Vendors 4.0.0 在无头、未建立 XR session 的进程退出时报告两次 `p_tracker.is_null()`；只精确忽略该文本，其他 OpenXR 错误仍判失败。

## 待归因基线问题

这些问题在本次导入中已出现，但尚未证明是无害清理噪声；不能加入自动忽略规则：

| 标识 | 当前观察 | 风险/下一步 |
| --- | --- | --- |
| `Unable to open Android 'build-tools' directory` | 本机 Android SDK/build-tools 不完整或路径不可用 | 仅 Android 构建任务修复环境；普通 Godot 导入记录但不顺手改 Android 资源 |
| `SubViewport is not a child of a SubViewportContainer` | 导入/场景初始化期间出现 | 打开相关主菜单/业务窗口确认 Viewport 层级和输入行为；若持续出现则修场景 |
| dummy renderer `Parameter "material" is null` | headless dummy 渲染器遇到空材质 | 在可视编辑器打开受影响场景并定位资源；不能假定真实渲染器无影响 |

## 失败判定

以下任一条件都判定失败：

- 非零退出码。
- `Parse Error`、`Compile Error` 或 `Failed to load script`。
- 缺失/无法打开 `res://` 资源。
- Autoload 无法实例化。
- GDExtension 动态库无法加载。
- 新出现且不在本文中的错误类型。

更新基线时必须附实际日志、原因和验证证据。不能只因为某错误重复出现就把它升级为“已知噪声”。
