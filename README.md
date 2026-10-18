# GodotSpace

GodotSpace is a monorepo for the Godot XR/MR application and its local AI
services.

## Layout

- `GodotSpace/`: the Godot 4.4 project, including multiplayer, XR, voice, task
  UI, and realtime reconstruction features.
- `Model/`: the Qwen Agent Gateway, knowledge/tool-call harnesses, local FunASR
  service, model launch scripts, benchmarks, and service tests.
- `docs/`: repository-level documentation.

The `Model/` directory was imported with its original Git history by using a
non-squashed subtree merge. It is now maintained in this repository; do not
initialize another Git repository inside it.

## Common entry points

日常串流运行：双击仓库根目录的 **`Start-GodotSpace.cmd`**，选择预设后点击“开始协作”。

| 使用场景 | 选择的预设 | 自动启动 |
| --- | --- | --- |
| 单机调试天上端 | 本机调试天上端 | 当前窗口作为 PC Server，另开 SKY XR |
| 单机调试地面端 | 本机调试地面端 | 当前窗口作为 PC Server，另开 Ground VR |
| 双机协作，电脑 1 | 本机调试地面端 | PC Server + Ground VR |
| 双机协作，电脑 2 | 天上端加入协作 | 选择发现的 Server，另开 SKY XR |

默认关闭语音和智能助手，开启天上端透传采集、投屏，**两者均走 USB**。头显通过数据线连接运行 SKY 的电脑，Business Streaming 也选择 USB 串流；头显 Wi-Fi 可以关闭。地面端不会启动本机相机，等待天上端加入。设置保存在 Godot 的 `user://startup/preferences.json`。主工程直接由指定 Godot 运行，不需要导出。

首次使用 PICO 4 Ultra Enterprise / Business Streaming 2.2.0：

1. 安装并绑定 Business Streaming，在其设置中开启自动连接/串流；确保当前 OpenXR Runtime 指向实际使用的 PICO 串流链路。
2. 开启头显 USB 调试并完成授权。单 USB 设备自动识别；多设备时在“设备与音频设置”中填写 PICO USB 序列号。ADB 默认从 Android SDK 自动查找；旧设置中的无线 ADB 地址会清空，不会静默改走 Wi-Fi。
3. 构建一次仓库内的 companion app：在 `GodotSpace/companion_app/pico_spatial_anchor_helper` 执行 `gradlew.bat test assembleDebug`。启动器发现旧 helper 缺少自动启动入口时，会用本地 Debug APK 执行 `adb install -r` 更新。签名不兼容时会报错，不会卸载现有应用。
4. 首次相机和通知权限仍须在头显授权。以后启动器自动传配置、启动 helper 并退出其短暂显示的启动界面；helper 继续作为头显侧后台采集组件运行。USB 投屏不启用 helper 的 Wi-Fi Cast 服务，也不申请其录音权限。
5. USB 投屏使用固定版本 scrcpy 5.0.1 server，首次缺少组件时自动从官方 GitHub 下载并校验 SHA-256，随后可离线运行；不需要安装或手动打开 scrcpy 窗口。当前开发电脑已备好该组件。离线部署可复制官方 `scrcpy-server` 到 `GodotSpace/tools/startup/.runtime/scrcpy-server-5.0.1`，或用 `GODOTSPACE_SCRCPY_SERVER` 指定文件；其 SHA-256 必须为 `764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536`。组件缓存不提交仓库。
6. 单机不需要头显与 PC 之间的 IP 网络。双机仅要求两台电脑网络互通，可使用有线局域网；Windows 防火墙需允许 Godot 的协作/收帧端口，以及 SKY 电脑上 Windows PowerShell 的专用网络入站视频连接。启动器不自动修改防火墙。

自动流程：Server 就绪 → 启动本机串流程序/头显串流入口 → XR Client 自动连接并获得角色 → 仅 SKY 启动 USB 采集和投屏。相机通过 ADB reverse 分别送到 SKY `8789` 和 Server `8787`；双机时由 SKY 电脑转发到 Server，PSA2/PAA1 数据和 ACK 不变，两个发送队列独立。投屏通过 USB 读取头显完整合成画面，按当前 PICO 双目尺寸裁切左眼，默认最大 1280 像素、30 fps、6 Mbps，再由现有 FFmpeg 扩展解码；PC 只封装视频，不重复编码。实际帧率受头显唤醒状态及负载影响。

USB 投屏地址通过 Server 的 `8788` 接收，并同步给已注册的 Client，支持地面端晚加入和重连。单机视频服务只监听 loopback，双机在 SKY 电脑动态 TCP 端口提供带随机会话凭据的 HTTP/MPEG-TS；媒体凭据与控制凭据分离。慢观看端会断开重连，不阻塞头显编码器或其他观看端；不把视频文件持久保存到磁盘。

采集启动会等待 OpenXR 就绪、SKY 接收端监听成功，并给 XR 留出 2 秒稳定时间。启动命令成功不等于收帧成功：最近 5 秒的相机帧及收到实际 USB 视频帧后上报的投屏地址才计为就绪。缺少画面时按 20 / 40 / 80 秒间隔最多自动重试 3 次；持续正常 10 秒后恢复重试额度。安装 APK 和准备 USB 组件时另留最多 240 秒。权限或配置错误会显示具体提示并暂停重试；状态文件暂时读不到不会反复弹出 helper。

协作状态卡片位于右上角，可收起；窄窗口默认收起，长诊断文本在卡片内部滚动。ADB 输出按 UTF-8 解码，避免 Windows 中文系统将头显消息转成乱码。

“结束协作”会请求本次 XR 退出，并停止对应 helper 会话、USB 编码器和 PC 转发服务，只移除本会话建立且仍归本会话所有的 ADB 转发。已有同目标转发可借用但不会被删除，冲突转发会明确报错。启动台异常退出后，XR 心跳超时会自行结束，helper 看守进程随后清理。不关闭已有 Business Streaming、ADB 服务或其他程序。双机模式的天上电脑还会保留一个轻量启动台窗口，用于状态、重试和结束。

重建按需启用：进入天上端“实时重建”工作区后才连接 Lab 隧道，准备完成后开始新重建；相机采集可独立用于柜体标定。**远端 LingBot 服务、SSH 隧道和 Depth Pro 仍按模块部署文档配置，本次启动台不管理远端 GPU 进程。** 助手被勾选时沿用 `Model` 的部署配置，启动失败会显示状态，不阻塞协作连接。

排查入口：启动台提供“重试 XR”“重试采集 / 投屏”；控制台日志在 `%LOCALAPPDATA%/GodotSpace/startup`，会话配置、子进程日志和状态在 `user://startup/sessions/<会话编号>`。局域网发现使用 UDP `42070`，会话仍使用 UDP `42069`；本机启动台互斥使用 loopback TCP `42071`。更换 Godot 路径可设置 `GODOTSPACE_GODOT` 或执行 `Start-GodotSpace.ps1 -Godot <path>`。

会话内的 `helper-lifecycle.jsonl` 记录等待 XR、启动、等待画面、自动重试与恢复状态，不记录投屏 token 或 URL。`helper-status.json` 带启动代次，避免上一次的成功状态掩盖本次启动等待。

### 启动功能验证

指定 Godot 的 `--path` 指向本仓库的 `GodotSpace` 子目录，以下脚本可用 `--headless --script res://Assets/ARSpace/Scripts/Startup/<脚本>.gd` 运行：

- `startup_self_test.gd`：三个预设、默认开关、菜单布局；有窗口时可加 `-- --preview=<PNG绝对路径>` 保存截图。
- `helper_health_self_test.gd`：模拟首帧超时、断流、分级重试、权限等待和安装超时，不连接头显。
- `session_status_overlay_self_test.gd`：实际 ARSpace 场景中的状态卡片位置、缩放、折叠、长文本和按钮；有窗口时可加 `-- --preview=<PNG绝对路径>` 保存截图。
- `startup_integration_self_test.gd`：启动真实 Server / SKY / Ground 测试进程，检查自动连接、角色、投屏地址晚加入/重开、Server 重启重连、关闭清理和重建按需连接。无需头显，不启动 ADB 或在线模型；默认占用项目端口，请先结束其他项目会话。

Windows PowerShell 离线验证：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File GodotSpace/tools/startup/pico_helper_self_test.ps1`，覆盖原生进程中文输出、状态代次和模拟设备的轮询/关闭行为，不调用真实 ADB。

另外运行 `GodotSpace/tools/startup/usb_launcher_self_test.ps1` 和 `GodotSpace/tools/startup/usb_transport_self_test.ps1`（同样使用 Windows PowerShell），分别验证 USB 设备选择、相机 loopback 配置、转发所有权清理，以及相机/ACK 转发、scrcpy 分包、MPEG-TS 校验和时间戳、HTTP 鉴权、晚加入和断开。`res://Assets/ARSpace/Scripts/AstronautView/pico_cast_control_self_test.gd` 验证 USB/RTMP 控制消息及 URL 限制。

真机验收：关闭头显 Wi-Fi，接好 USB 数据线并保持唤醒，选择单机 SKY；确认 OpenXR、头手位姿、柜体标定相机首帧及 Server `8787` 收帧，状态显示“采集 / 投屏：USB”。再按表格双机启动，确认地面端投屏为单眼真实环境与虚拟物体的叠加画面。重开地面端应自动恢复投屏；拔插 USB 后应自动恢复（超过重试次数时点击重试），结束协作后相机、编码器和本次转发应停止。新 USB 默认链路的真机并行采集、单眼裁切、USB 拔插及双物理机防火墙可达性仍须现场验收，离线测试不能替代。

Open the Godot editor from PowerShell:

```powershell
& 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe' `
  --editor --path .\GodotSpace
```

Run the local service tests from WSL:

```bash
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate
python -m unittest discover -s agent_service/tests -v
python -m unittest discover -s asr_service/tests -v
```

See `GodotSpace/Assets/ARSpace/Scripts/RealtimeReconstruction/README.md` and
`Model/README.md` for subsystem-specific setup and validation.

Local Agent 的部署步骤和功能清单见
[`docs/LOCAL_AGENT_DEPLOYMENT.md`](docs/LOCAL_AGENT_DEPLOYMENT.md)。
