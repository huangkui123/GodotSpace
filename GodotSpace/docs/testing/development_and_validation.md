# 开发环境与验证入口

## 固定环境

- 仓库：`F:\GodotSpace`
- Godot 工程：`F:\GodotSpace\GodotSpace`
- 控制台程序：`D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe`
- 已验证版本：`4.4.dev.custom_build.76dfa79fb`

不要用其他 Godot 大版本保存场景或资源。新开发机先确保 Git LFS 对象已取回；工作树里只有 LFS 指针的 MP4 不能用于视频验收。

## 第一阶段统一验证

在仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\GodotSpace\tools\tests\run_phase1_validation.ps1
```

脚本依次执行：

1. `--headless --import`，并对脚本解析、资源、Autoload 和 GDExtension 关键错误做失败判定；完整日志写到系统临时目录的 `GodotSpace-headless-import.log`。
2. runtime profile、共享对齐、网络启动恢复、角色、玩家、VirtualAnnotation 和三进程协作测试。
3. 工作任务 1—5 复刻基线测试。
4. 7 个不需要在线 key 的 LLM 离线测试。
5. PC Server + 无头显 testmode Client 的实际 ENet 启动烟雾，以及 XR Client 配置解析烟雾。

可在定位单一问题时使用 `-SkipImport`、`-SkipRuntimeSmoke` 或 `-SkipLlm`，但任务验收必须运行无跳过的完整命令。脚本不会运行 DeepSeek 在线测试，也不会读取或打印 API key。

## 分项命令

```powershell
# 资源导入
& $Godot --headless --path $Project --import

# 协作网络和玩家测试
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\GodotSpace\tools\tests\run_collaboration_self_tests.ps1

# 三种启动烟雾
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\GodotSpace\tools\tests\run_runtime_startup_smoke_tests.ps1
```

## 手工/半自动回归

StartMenu → ARSpace、连接失败返回、Server 断开返回和重连步骤见 `phase1_session_regression.md`。这些步骤需要真实窗口或多个进程，自动测试通过不能替代对 UI 状态和真实 XR 设备的观察。

headless 导入的已知输出分类和待归因问题见 `headless_import_baseline.md`。新的错误文本不得因退出码仍为 0 就自动归为噪声。
