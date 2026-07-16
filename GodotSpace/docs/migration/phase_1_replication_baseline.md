# 第一阶段复刻基线

本文是 Unity 空间站项目到 GodotSpace 的角色、权限、启动和验收合同。业务名称、测试报告和网络数据均以本文为准；`sky` 只保留给天空盒或环境天空含义。

## 三端角色合同

| Unity 端 | Godot runtime preset | 网络 role | 中文名称 | 启动方式 | 显示与环境 | 主要权限 |
| --- | --- | --- | --- | --- | --- | --- |
| PC | `PC_GROUND_SERVER` | `pc_ground` | PC 地面端 | `godot --path <Project> -- --voice-role=server` | 桌面观察相机、不透明环境 | ENet 权威端；分配角色；校验并广播共享业务状态；地面标注 |
| VR | `VR_GROUND_CLIENT` | `ground_vr` | 地面 VR 端 | `godot --path <Project> --xr-mode on -- --ground-vr-client --voice-role=client --server-ip=<IP>` | OpenXR、不透明环境 | 唯一地面 VR 席位；地面标注；请求业务操作，最终由 Server 校验 |
| AR/XR | `ASTRONAUT_XR_CLIENT` | `astronaut` | 航天端 | `godot --path <Project> --xr-mode on -- --xr-client --voice-role=client --server-ip=<IP>` | OpenXR、MR 透视 | 默认 Client 角色；提交头手位姿、手势和允许的业务请求 |

无头显回归使用航天端测试模式：

```powershell
& $Godot --path $Project -- --testmode --voice-role=client --server-ip=127.0.0.1
```

`--ground-vr` 是已经删除的错误“VR Server”入口，只允许配置解析器返回迁移错误。地面 VR 唯一使用 `--ground-vr-client`。Server peer ID 固定为 `1`，地面 VR 同时只允许一个；其他 Client 在角色请求完成前和请求被拒绝后均按 `astronaut` 安全默认值处理。

## Unity 功能到 Godot 责任和验收对照

| Unity 可观察功能 | Godot 场景/脚本 | 权威/责任角色 | 第一阶段验收用例 |
| --- | --- | --- | --- |
| PC、VR、AR 进入同一会话 | `StartMenu.tscn`、`startmenu_ui.gd`、`runtime_profile.gd`、`network_handler.gd` | PC 地面端创建 ENet 会话并分配角色 | 三种 profile 可解析；第二个地面 VR 被拒绝；不同连接顺序、掉线和重连不产生重复玩家 |
| 头部和双手位姿对其他端可见 | `Player.tscn`、`player.gd`、`multiplayer_spawner.gd` | Client 上报自身位姿，Server 校验发送方并中继 | 两个 Client 与 Server 均看到正确 peer 的头手；旧序号和冒充包被拒绝；远端插值稳定 |
| 航天员全身形象与手势 | 第一阶段目标 `AstronautAvatar.tscn` 及其 IK/手势脚本；当前入口仍在 `Player.tscn` | 航天端产生跟踪和手势状态，Server 校验与中继 | 远端看到同一角色的全身、头手和手势；本地身体不遮挡视野；跟踪丢失、重获和重连无骨骼爆炸 |
| 共享空间与重定中 | `ARSpace.tscn/SharedSpaceOrigin`、`shared_space_alignment.gd`、`SpatialCalibration/*` | Server 保存标定版本；每端只在共享原点边界做局部/世界转换 | 玩家、窗口、标注和柜体使用同一坐标；迟到 Client 收到当前标定；清除/重标定不叠加偏移 |
| 主菜单和三维窗口交互 | `ARSpace.tscn/SharedSpaceOrigin`、`UI/SpatialWindow/SpatialWindow3D.tscn`、`SpatialWindowAdapter` 与 Registry Autoload | PC/Ground VR 发请求，Server 校验角色、稳定窗口 ID、状态、米制尺寸、租约和共享局部变换 | PC 鼠标、XR 近距和 XR 射线语义一致；拖动、缩放、吸附、焦点、关闭可同步且迟到恢复 |
| 无容器样品任务入口 | `WorkListCanvas/WorkListUIView.gd`、`WorkListItem.gd` | 当前仅本地 UI；后续写入协作状态 | 任务 1 可打开 20 步；任务 2—5 明确显示“未配置”且不复制任务 1 步骤；任务 6—8 不出现在 UI |
| 图片、视频、工作清单、语音窗口 | 7 个稳定 ID 的 `SpatialWindowAdapter`；调用入口统一经过 `panel_window_zoom.gd` | 第一阶段窗口外壳状态已统一纳入 Registry；图片/视频等业务内容同步由后续阶段细化 | 主菜单、图片列表/详情、视频列表/详情、工作清单和语音窗口可打开、关闭、变换并迟到恢复 |
| 点式标注 | `VirtualAnnotation/*` | PC 地面端和地面 VR 可请求，Server 分配 ID 和版本 | 非地面角色请求被拒绝；快照、删除、清空、断线清理可重复验证 |
| PICO 图像点选标定 | `SpatialCalibration/*`、Android companion helper | 只在 PC Server 显示标定面板并确认结果 | 帧长度受限；半包/坏包不破坏会话；标定版本可快照、清除和重做 |

## 范围裁决

- 第一阶段实现稳定三端会话、角色、全身角色底座、共享坐标和通用窗口；不把邮件、专家服务、实时作业直播、空间自由线或模型放置包装成已完成。
- LLM、点式虚拟标注、PICO 空间标定和 Depth Pro 是 Godot 增强功能，可保留但不能代替 Unity 的确定性命令、专家流程或空间自由绘制。
- 工作任务只保留 Unity 主线的 1—5：任务 1 已配置；任务 2—5 保留入口并显示“未配置”；Unity 已注释的任务 6—8 不进入复刻基线。
- 打地鼠不在复刻范围。
- 所有共享业务状态必须以 `SharedSpaceOrigin` 局部坐标和 Server 权威版本为合同；RPC 不接收任意资源路径或无上限集合。

## 行为证据优先级

1. 经项目负责人确认的 Unity 最终发布包、演示录屏和验收记录。
2. 可重复运行的 Unity 工程行为。
3. Unity 主线场景、启用组件和代码。
4. 已迁移但未接入主线的 prefab、资源或注释，只作为线索，不作为“已实现”证据。

当前可用证据和缺失项记录在 `asset_migration_ledger.md`。如果后续拿到发布包或录屏，与代码冲突时先更新本文和验收用例，再修改 Godot 行为。
