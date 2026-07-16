# 第一阶段集成验收记录（2026-07-16）

## 结论

第一阶段的软件实现与自动化准入门槛已通过；真实 PICO/OpenXR 三端联机、视觉手感和 30 分钟稳定性尚未执行，因此任务 1.7 仍为“待真机签字”，不能标记为最终验收完成。

本次验证基于分支 `codex/unity-to-godot`，任务 1.1–1.6 的独立提交为：

- `307c760`、`08f2539`：三端角色与 Unity 复刻基线。
- `acaf5cd`：第一阶段可重复验证入口。
- `b889f94`：Server 权威协作状态。
- `353cda6`：航天员角色、IK、手势与 XR 输入。
- `6112156`：共享空间与标定闭环。
- `36029bf`：Server 权威通用三维窗口框架。

## 自动化执行结果

执行环境：Windows、Godot `4.4.dev.custom_build.76dfa79fb`，无已连接的 PICO/OpenXR 设备。未运行任何需要真实云凭据或会产生费用的在线 LLM 测试。

```powershell
& 'F:\GodotSpace\GodotSpace\tools\tests\run_phase1_validation.ps1' `
    -Godot 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe' `
    -Project 'F:\GodotSpace\GodotSpace'
```

最终结果：`PHASE1_VALIDATION PASS`，退出码 `0`。覆盖内容包括：

- headless 资源导入，无脚本解析、资源缺失、autoload 或 GDExtension 关键错误。
- 19 项协作、角色、共享空间、标定、窗口与标注脚本测试。
- `PlayerPresenceSelfTest.tscn` 与 `PlayerNetworkSelfTest.tscn`。
- 一台测试 Server、Ground Client、Astronaut Client 的真实 ENet 多进程会话与重连。
- 工作清单基线、7 项 LLM 离线测试。
- PC Server、桌面测试 Client 和 XR 参数配置启动冒烟。
- 5 项 SpatialWindow 专项测试；窗口 ENet 预览/提交专项另连续运行 3 次通过。

第一次 headless 导入在定制引擎清理阶段出现一次 signal 11；清理进程后同命令退出码为 `0`，随后整套验证通过。最终导入仍输出项目已记录的 progress dialog、SubViewport、dummy renderer material 和 ObjectDB 清理噪声，未出现新的关键错误类型。

## 任务 1.7 证据矩阵

| 验收项 | 自动化证据 | 当前判定 | 真机仍需确认 |
| --- | --- | --- | --- |
| PC Ground Server + Ground VR + Astronaut XR | `run_collaboration_multiprocess_self_test.ps1` 同时运行三角色；`run_runtime_startup_smoke_tests.ps1` 检查正式参数入口 | 部分覆盖 | 两台真实 PICO 同时接入正式 `ARSpace.tscn` |
| 连接顺序、第二 Ground VR、掉线/重连、Server 关闭 | `peer_role_network_self_test.gd`、`collaboration_state_network_self_test.gd`、多进程重连测试 | 部分覆盖 | Astronaut 先连接等顺序、真实无线网络、头显休眠/唤醒、StartMenu 回退和界面提示 |
| 航天员全身 IK、头手、手势、名称、本地/远端隐藏 | `PlayerPresenceSelfTest.tscn`、`PlayerNetworkSelfTest.tscn`、`avatar_pose_state` 边界检查 | 部分覆盖 | 真实跟踪姿态、遮挡、手臂观感和长时骨骼稳定性 |
| 共享原点、重定中、标定快照、迟到 Client | `shared_space_alignment_self_test.gd`、`shared_space_contract_self_test.gd`、`spatial_calibration_state_network_self_test.gd` | 部分覆盖 | PICO 实景三 Tag 对照、重定中后的实体对齐误差 |
| 主菜单和至少四类业务窗口 | 5 项 SpatialWindow 自测与真实 ENet 快照/租约测试 | 部分覆盖 | PC 鼠标、PICO 近抓/远射线/摇杆、震动和两端视觉一致性 |
| 真实设备运行至少 30 分钟 | 无 | 未执行 | 帧率、跟踪、内存、RPC 错误、残留节点和断线恢复 |

## 真机签字流程

### 1. 固定环境

记录以下信息后再开始：Git commit、Godot 完整版本、两台 PICO 的设备编号与系统版本、PC/PICO IP、目标刷新率、开始时间、语音输入输出设备。三端必须位于同一局域网；PC 防火墙允许 UDP `42069`。若启用 Ground VR 配对保护，在 PC Server 与 Ground VR 的本地环境中配置相同的非空 `GODOTSPACE_GROUND_VR_TOKEN`，不得把令牌写入日志或仓库。

```powershell
# PC Ground Server
& $Godot --path $Project -- --voice-role=server

# Ground VR Client
& $Godot --path $Project --xr-mode on -- --ground-vr-client --voice-role=client --server-ip=<SERVER_IP>

# Astronaut XR Client
& $Godot --path $Project --xr-mode on -- --xr-client --voice-role=client --server-ip=<SERVER_IP>
```

### 2. 会话与恢复

- [ ] 按 Server → Ground VR → Astronaut 顺序连接，三端角色、名称和人数正确。
- [ ] 按 Server → Astronaut → Ground VR 顺序重做，最终角色不受连接顺序影响。
- [ ] 接入第二个 Ground VR，请求被拒绝或降级，且不能取得地面权限。
- [ ] 分别让两个 Client 断开、重连；无重复玩家、旧 peer、旧租约或残留窗口。
- [ ] 关闭并重启 Server；Client 返回可恢复状态，重新连接后只应用新会话快照。

### 3. 角色与共享空间

- [ ] 航天员本地身体不遮挡视野；其他两端看到全身、头、双手、名称和手势。
- [ ] 左手、右手和头部凝视输入切换正确；跟踪丢失与恢复无骨骼爆炸或射线残留。
- [ ] 完成共享原点标定，柜体、玩家、标注和窗口均落在同一实体参照。
- [ ] 重定中、清除后重标定、迟到 Client 各执行一次；不出现二次偏移。
- [ ] 按 `task_1_5_pico_tagtracking_validation.md` 记录 Unity 三 Tag 对照误差。

### 4. 三维窗口

- [ ] 主菜单、图片、视频、工作清单和语音窗口各打开/关闭一次，稳定 ID 不重复。
- [ ] PC 鼠标与 PICO 近抓、远射线分别完成标题拖动、四边/四角缩放和摇杆深度移动。
- [ ] 验证最大化/恢复保留此前尺寸，吸附预览可确认、取消和拖离。
- [ ] 验证选中、抓取、缩放刻度和吸附确认的震动；不发生误触、穿透或窗口跳变。
- [ ] 操作时另一个 Ground 端竞争同一窗口，租约拒绝并发写；Astronaut 共享变更被拒绝。
- [ ] 迟到 Client 与两台在线端看到相同 transform、尺寸、模式、焦点和显隐。

### 5. 30 分钟稳定性

每 5 分钟记录一次三端帧率、PC 进程内存、跟踪状态、当前 peer、RPC 错误数和残留节点观察结果。期间至少执行一次 Client 断线重连、一次重定中、一次窗口拖动/缩放/吸附循环和一次 Server 关闭后的完整恢复。

- [ ] 无崩溃、卡死或无法恢复的网络状态。
- [ ] 帧率与设备目标刷新率的偏差、掉帧时段和操作场景已记录。
- [ ] 内存没有持续无界增长，关闭窗口/断开 Client 后相关节点和媒体资源被释放。
- [ ] 无持续 RPC 权限错误、重复玩家、残留射线、残留语音或旧窗口租约。
- [ ] 附上日志、时间点和必要截图，并由执行人填写姓名与日期。

执行人：__________　日期：__________　结论：通过 / 不通过 / 有条件通过
