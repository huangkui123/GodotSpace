# SharedSpaceOrigin 坐标合同

## 唯一空间语义

`ARSpace.tscn/SharedSpaceOrigin` 是所有可变网络空间数据的唯一坐标合同。网络负载中的位置、旋转和缩放均为该节点的局部值，标记为：

- `coordinate_space = "shared_local"`
- `coordinate_contract_version = 1`

业务 RPC 不得发送未说明的 world/global transform。Server 只接受有限数值且距共享原点不超过 50 m 的位置。静态机柜由三端加载相同场景，它是标定的物理参照，不通过业务 RPC 移动；`SharedSpaceOrigin.global_transform` 定义共享内容相对于机柜场景的绝对映射。

## 转换边界

| 数据 | 写入网络前 | 网络/权威状态 | 显示时 |
| --- | --- | --- | --- |
| 玩家头和双手 | 本地跟踪 global → shared local | 30 Hz unreliable pose；Server 校验后转发 | shared local 插值 → global |
| 窗口 | 交互命中 global → shared local，拖动期间持续更新 | `window_transforms`/`window_states` 始终保存 shared local | 窗口节点挂在 `SharedSpaceOrigin` 下并直接应用 local transform |
| 笔划 | 每个采样点 global → shared local | `strokes` 保存 shared local 点列 | 在共享原点下重建线条 |
| 共享模型 | 放置结果 global → shared local | `models` 保存白名单资源和 shared local transform | 在共享原点下实例化 |
| 虚拟批注 | 射线命中 global → shared local；若绑定模型还记录目标局部点 | `annotation_drafts`/`confirmed_annotations` 保存 shared local fallback | 优先目标局部坐标，目标失效时使用 shared local |
| 空间标定预览/确认点 | Server 虚拟相机先得到 world 点，再且仅再转换一次 | `SpatialCalibrationState` 保存 shared local 点和可靠快照 | `SpatialCalibrationReplica` 作为共享原点子节点直接应用 local position |

禁止在同一字段中混用 global 和 local，也禁止在接收端再次减去标定偏移。

## 标定状态

标定结果是 `SharedSpaceOrigin` 的**绝对 global transform**，不是增量：

- 每次 `begin`、`commit`、`clear` 都推进 Server revision。
- Client 只应用比本地更新的 revision；重复快照是幂等的，不叠加偏移。
- late join 和重连通过可靠完整快照取得当前绝对原点、预览和确认点。
- clear 会清除原点有效性、预览与确认点；recalibrate 从清洁 revision 开始。
- Server 关闭或会话清理后不得把旧会话标定带入新会话。

## PICO 画面反投影来源

PICO helper 的 metadata 会记录头部位姿、相机内参/外参探测状态及选中相机，用于诊断和离线核对。当前可交付路径中，它不是最终坐标源：

1. Server 的虚拟 `Camera3D` 产生射线原点和方向。
2. Depth Pro 或人工输入只提供沿射线的标量深度。
3. Server 得到 world 点并转换一次为 shared local。
4. 状态服务以 shared local 保存和广播。

同步负载只保留有界的 metadata 审计子集，不传播原始 metadata、矩阵或本机路径。

## 重定中与失跟踪

- 第一次取得有效头部跟踪时自动对齐。
- 标定 revision 变化时自动请求重定中。
- 用户可按 `R`、UI 按钮或控制器菜单键显式重定中。
- 头部跟踪持续丢失 15 s 后显示提示；跟踪恢复后自动重试。

验收目标：位置 RMS ≤ 0.05 m、单点最大误差 ≤ 0.10 m；水平朝向 RMS ≤ 3°、单点最大误差 ≤ 5°。超过任一阈值必须重新标定，不得以手工隐藏偏移的方式通过验收。
