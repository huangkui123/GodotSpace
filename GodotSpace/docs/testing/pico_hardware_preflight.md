# PICO 真机验收前置与打包说明

## 当前结论

第一阶段仓库侧前置由 `tools/tests/run_pico_hardware_preflight.ps1` 固化。它检查 Android PICO 导出预设、PICO OpenXR vendor AAR/arm64 库、PICO 4 action map、Ground/Astronaut 双角色入口、网络与录音权限，以及 Android 缺少 FFmpeg 二进制时的安全降级。

同一份 `Android PICO` APK 可安装到两台 PICO：默认角色为“航天端 XR Client”，角色下拉框保持可选；另一台在 StartMenu 选择“地面 VR 端 Client”。两台 Client 均在 StartMenu 输入 PC Ground Server 显示的局域网 IPv4 地址后启动。

## PC 侧前置检查

```powershell
$Repo = 'F:\GodotSpace'
$Project = Join-Path $Repo 'GodotSpace'
$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'

powershell -NoProfile -ExecutionPolicy Bypass -File `
  (Join-Path $Project 'tools\tests\run_pico_hardware_preflight.ps1') `
  -Project $Project

powershell -NoProfile -ExecutionPolicy Bypass -File `
  (Join-Path $Project 'tools\tests\run_phase1_validation.ps1') `
  -Godot $Godot -Project $Project
```

预期分别出现 `PICO_HARDWARE_PREFLIGHT PASS` 和 `PHASE1_VALIDATION PASS`。

## Android 构建环境

打包机还需要：

- JDK 17、Android SDK 与 Godot 要求的 build-tools/platform-tools。
- 与当前 Godot 版本一致的 Android export templates。
- 项目已安装 Android Gradle build template。
- PICO 开发者模式和 USB 调试；`adb devices -l` 能看到目标头显。

本次代码复核机没有配置 `ANDROID_HOME`/`ANDROID_SDK_ROOT`，也没有 Godot Android export templates 和在线 PICO，因此无法在此机生成并安装 APK；这部分按约定由真机执行人完成。

构建命令：

```powershell
& $Godot --headless --path $Project `
  --export-debug 'Android PICO' `
  (Join-Path $Project 'Dabao\GodotSpace-PICO.apk')
```

安装前记录 `git rev-parse HEAD`。打包成功后，使用 `adb install -r` 分别安装到两台 PICO，并确认包名为 `com.yaoling.godotspace`。

## 三端启动

切换 Git 分支或更新脚本后，先完全退出旧的 PC Server/Client 游戏进程，再从当前分支重新启动三端。Godot 编辑器可保留，但不能复用切分支前已经运行的游戏实例；日志若出现已移除的 `trigger_pressed` RPC，说明混用了旧脚本，当前轮结果无效。

1. PC 运行 Windows 版，选择“PC 地面端 Server”，记录界面显示的 LAN IPv4；防火墙允许 UDP `42069`。
2. 第一台 PICO 选择“地面 VR 端 Client”，输入 PC IPv4 后启动；该角色使用不透明 XR，并拥有地面交互权限。
3. 第二台 PICO 保持“航天端 XR Client”，输入同一 PC IPv4 后启动；该角色请求 passthrough，可用射线操作菜单内容以及窗口打开、关闭、聚焦和最大化，但窗口空间拖动、缩放与吸附仍由 PC/Ground VR 控制。
4. 继续执行 `phase1_acceptance_2026-07-16.md` 的三端、重连、标定、窗口和 30 分钟检查表。

## 已知平台限制

仓库内 EIRTeam FFmpeg 扩展只带 Windows/Linux 二进制，没有 Android `.so`。Android 导出不再声明不存在的库；视频详情或工作清单视频在 PICO 上会停止播放器并显示/记录“当前平台不支持播放”，不会影响主菜单、三端联网、共享空间、标定和三维窗口壳体验证。Android MP4 播放属于后续补齐原生库或改用受支持媒体格式的独立任务，不能在本轮真机记录中误判为已支持。
