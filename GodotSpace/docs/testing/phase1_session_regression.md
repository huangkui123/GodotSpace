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

## 真实 XR 补充

- 地面 VR 使用 `--xr-mode on -- --ground-vr-client --voice-role=client --server-ip=<IP>`；第二个地面 VR 请求必须被拒绝并降级为 `astronaut`，不能获得地面权限。
- 航天端使用 `--xr-mode on -- --xr-client --voice-role=client --server-ip=<IP>`；预期使用 MR 透视并隐藏本地远端代理模型。
- 三端测试记录连接顺序、peer ID、角色、返回菜单次数、重连次数和所有 RPC 错误。真实设备验收结果写入任务 1.7，不用桌面 testmode 冒充。
