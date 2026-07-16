# Godot headless 导入基线

基线日期：2026-07-16

命令：

```powershell
& 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe' `
  --headless --path 'F:\GodotSpace\GodotSpace' --import
```

结果：退出码 `0`；未发现 GDScript 解析失败、缺失 `res://` 资源、Autoload 初始化失败或 GDExtension 动态库加载失败。

## 已知清理阶段噪声

下列输出只在退出码为 `0` 且没有前述关键错误时按已知清理噪声记录：

- progress dialog / task flush / scan thread 在 headless 退出阶段中止。
- `ObjectDB instances leaked at exit`、RID/resource leak 等退出清理报告。

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
