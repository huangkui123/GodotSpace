# 第一阶段会话回归步骤

## 准备

```powershell
$Project = 'F:\GodotSpace\GodotSpace'
$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'
```

先运行 `run_phase1_validation.ps1`。手工测试时关闭占用 UDP `42069` 的旧进程；PC 与 XR 设备在同一局域网。

## StartMenu → ARSpace

1. 执行 `& $Godot --editor --path $Project`，运行主场景。
2. 依次选择 PC 地面端、地面 VR 端和航天端 profile，确认模式文案、IP 输入和音频设备控件符合角色。
3. PC 地面端点击开始；预期进入 `ARSpace.tscn`，观察相机可用，XR viewport 关闭，Server 监听 `42069`。
4. 地面 VR 与航天端分别输入 Server IP 并开始；预期连接后进入 ARSpace，角色分别为 `ground_vr` 和 `astronaut`。

## Client 连接失败返回

1. 确保没有 Server，使用无头显模式启动：`& $Godot --path $Project -- --testmode --voice-role=client --server-ip=127.0.0.1`。
2. 在 StartMenu 点击开始。
3. 预期 Client 可短暂进入 ARSpace 等待握手；连接失败后释放 ENet peer 并返回 StartMenu。
4. 预期状态区说明无法连接地面 Server；再次点击开始不会出现重复玩家、残留窗口或空 peer 错误。

## Server 断开返回与重连

1. 启动 PC Server，再启动一个 testmode Client 并确认双方玩家只出现一次。
2. 关闭 Server 进程。
3. 预期 Client 收到 `server_disconnected`，释放旧 peer 并返回 StartMenu；语音、标注和旧玩家节点不残留。
4. 重新启动 Server，在 Client 的 StartMenu 再次连接。
5. 预期获得新的有效 peer ID、当前角色快照和当前业务快照；旧 peer ID 不恢复，玩家与窗口均不重复。

## 通用三维窗口

1. PC Server 依次打开主菜单、图片列表/详情、视频列表/详情、工作清单和语音窗口；确认同类唯一窗口不会重复创建，关闭后内容和碰撞体均不可交互，再打开时使用原稳定 ID。
2. PC 鼠标分别执行标题栏拖动、四边/四角缩放、放大/恢复、吸附预览、取消、确认和拖离；预期尺寸渐进变化且始终在 0.2–3.0 m，保持宽高比时内容不变形，窗口不突然跳到世界原点。
3. Ground VR 用近距离标题栏抓取和远距离射线重复操作，远距时用摇杆改变深度；预期近/远状态互斥，窗口保持选定朝向约束，开始抓取、越过缩放刻度和确认吸附有对应手柄震动。
4. Astronaut 端可本地选中查看，但共享拖动、缩放、焦点或关闭请求必须被 Server 拒绝；PC 与 Ground VR 的合法操作应在两个 Client 显示相同 transform、尺寸、模式和显隐。
5. 操作期间让另一个 Ground Client 竞争同一窗口；预期租约阻止并发写入。拖动后新接入 Client；预期只应用最终可靠快照，不依赖曾错过的不可靠预览。
6. 拖动中断开操作者、重连并再次打开窗口；预期旧租约释放，无残留焦点、重复窗口、二次 scale、跳变或穿透。

## 真实 XR 补充

- 地面 VR 使用 `--xr-mode on -- --ground-vr-client --voice-role=client --server-ip=<IP>`；第二个地面 VR 请求必须被拒绝并降级为 `astronaut`，不能获得地面权限。
- 航天端使用 `--xr-mode on -- --xr-client --voice-role=client --server-ip=<IP>`；预期使用 MR 透视并隐藏本地远端代理模型。
- 三端测试记录连接顺序、peer ID、角色、返回菜单次数、重连次数和所有 RPC 错误。真实设备验收结果写入任务 1.7，不用桌面 testmode 冒充。
