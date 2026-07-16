# CollaborationState 网络合同

`CollaborationState` 是主菜单、窗口、工作步骤、媒体、空间自由线和可放置模型的 Server 权威会话状态。它只保存可序列化业务数据，不直接创建 UI、模型或线条节点；场景消费者通过信号把快照映射到本地节点。

## 权威与生命周期

- PC 地面端 peer `1` 是唯一写入权威。Client 只能发送有序请求，不能直接广播最终状态。
- Server 为每个 domain 维护独立 revision，同时维护全局 session revision。一次有效变更只增加一次对应 revision。
- 新 Client 连接后收到完整可靠快照，不依赖加入前的一次性 RPC。
- Client 的 `(peer_id, request_sequence)` 是幂等键。完全相同的重试返回缓存结果，不再次创建窗口、线条或模型；同序号不同 payload 被拒绝。
- Client 掉线或角色更换时清除该 peer 的请求缓存和临时操作租约，已确认的会话状态保留供重连快照恢复。
- Server 关闭、开始新会话或 Client 失去 Server 时清空本地会话副本。场景切换只重建消费者节点，不重复变更权威状态。

## Domain、限额与角色

| Domain | 数据合同 | 上限 | 允许发起角色 |
| --- | --- | --- | --- |
| `menu` | `mode=life/work`、活动页签和子页 ID | 单例；文本 ID 最长 64 | `pc_ground`、`ground_vr` |
| `active_windows` | 稳定 `window_id` 集合、窗口类型、可见/关闭状态 | 16 个；ID 最长 64 | `pc_ground`、`ground_vr` |
| `task` | `task_id`、`step`、步骤事件版本和播放状态 | 单例；任务 1—5，步骤 0—20 | `pc_ground`、`ground_vr` |
| `media` | 稳定媒体 ID、图片/视频类型、播放状态、毫秒位置 | 8 个活动媒体；不接受任意文件路径 | `pc_ground`、`ground_vr` |
| `window_transforms` | `window_id`、SharedSpaceOrigin 局部变换、尺寸、状态、吸附槽、焦点顺序 | 16 个；位置在共享原点 50 m 内，缩放/尺寸有限且非 NaN | `pc_ground`、`ground_vr` |
| `strokes` | Server 分配 ID、颜色、粗细、SharedSpaceOrigin 局部点列、确认状态 | 128 笔、每笔 2048 点；单请求受字节上限 | `pc_ground`、`ground_vr`、`astronaut` |
| `models` | Server 分配 instance ID、模型白名单 ID、共享局部变换 | 64 个；位置/缩放有限且非 NaN | `pc_ground`、`ground_vr`、`astronaut` |

单请求序列化大小上限为 64 KiB；完整快照上限为 2 MiB。所有集合在规范化前检查类型和数量，所有字符串去除首尾空白并限制长度。Transform/Vector/数值必须有限，窗口和模型位置必须明确为 `SharedSpaceOrigin` 局部坐标。

## 请求与结果

通用请求包含：

- `request_sequence`：每个 Client 严格递增的正整数。
- `domain`：上表固定值之一。
- `operation`：该 domain 白名单中的 `set/upsert/remove/clear` 等操作。
- `payload`：通过 schema 规范化后的业务数据。

结果包含 `accepted`、`request_sequence`、`domain`、`operation`、`revision`、`entity_id` 和安全错误码/说明。结果可重复发送，但一次请求最多产生一次权威变更。Client 应以快照或 revision 更新信号为最终事实，不能只凭本地按钮状态创建节点。

## 安全边界

- 发送方角色只从 Server 的 `NetworkHandler` 注册表读取，payload 中的 role/owner 字段不授予权限。
- 媒体和模型只接受受控 ID；Client 不能传 `res://`、绝对路径、URL 或脚本资源。
- 不接受 Object、Callable、RID 或任意 Resource；快照只含 Godot 网络可序列化的基础 Variant。
- 无效 domain、operation、越界数值、过大 payload、旧序号、伪造 owner 和未连接 peer 均返回拒绝，不修改 revision。
- 高频拖动/绘制的预览传输可在对应功能任务中另走受限不可靠通道；本服务保存的最终状态与快照使用可靠 RPC。
