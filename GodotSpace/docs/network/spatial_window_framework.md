# SpatialWindow3D 通用窗口合同

任务 1.6 将窗口的业务状态从 XR Tools 渲染节点中分离。`SpatialWindow3D.tscn` 是新窗口壳，`SpatialWindowAdapter` 让第一批既有 SubViewport 窗口接入同一合同；XR Tools 继续负责 2D 内容渲染与指针映射，不再同步已迁移窗口的世界变换。

## 稳定标识与权威状态

`SpatialWindowRegistryService` 是 Autoload。窗口记录包含稳定 `window_id`、`window_type`、`content_key`、唯一/多开策略、`SharedSpaceOrigin` 局部刚体变换、米制尺寸、`normal/maximized/snapped/closed` 模式、可见性、焦点顺序、吸附槽和交互租约。

- PC Server 与 Ground VR 可以请求全部窗口变更。Astronaut 可通过射线请求打开、关闭、聚焦、显隐和最大化，从而操作窗口内业务 UI；空间拖动、缩放、吸附、预览和租约仍只允许 PC Server/Ground VR。
- Server 校验角色、窗口 ID、50 m 共享空间边界、0.2–3.0 m 尺寸、请求大小、单调请求序号和租约令牌。
- Client 请求租约后进入 pending；只有收到权威令牌才应用本地拖动/缩放，拒绝时恢复 Registry 当前绝对状态。
- 拖动预览走 channel 1 的不可靠有序 RPC，不增加持久 revision；放手时 transform 与尺寸原子可靠提交，模式、吸附、打开和关闭也走可靠提交。
- 交互租约最长 10 秒；超时或 peer 断开时清理。迟到 Client 收到包含所有窗口的可靠绝对快照。
- 每个窗口状态都是绝对值；重连和重复快照不会累加 transform 或 scale。

## 统一交互入口

`SpatialWindowInteractor` 不绑定具体输入设备。PC 鼠标、PICO 手柄近距碰撞和远距射线都调用同一组方法：

- `begin_near_title_drag` / `update_near_title_drag`
- `begin_far_ray_drag` / `update_far_ray_drag`，摇杆轴改变射线深度
- `begin_resize` / `update_resize`，支持四边、四角、宽高比和渐进缩放
- `preview_snap` / `confirm_snap` / `cancel_snap`
- `focus_window` / `clear_focus` / `end_interaction`

朝向策略可选自由、始终面向用户、保持水平和俯仰/横滚限制。选中、开始拖动、跨越米制缩放刻度和确认吸附会发出可配置 `haptic_requested`；有 OpenXR 接口时同时进入 `XRToolsRumbleManager` 的对应左右手队列。

## 第一批迁移

ARSpace 中以下窗口均位于 `SharedSpaceOrigin` 下，并通过 `PanelWindowZoom` 兼容门面调用状态机：

| 窗口 | 稳定 ID | 策略 |
| --- | --- | --- |
| 主菜单 | `main_menu` | 同类唯一 |
| 图片列表 | `picture_browser` | 同类唯一 |
| 图片详情 | `picture_detail` | 同类唯一 |
| 视频列表 | `movie_browser` | 同类唯一 |
| 视频详情 | `movie_detail` | 同类唯一 |
| 工作清单 | `work_list` | 同类唯一 |
| 语音通话 | `voice_call` | 同类唯一 |

旧的 1.6 倍本地 scale 切换已删除。兼容适配器直接接管既有 XR Tools 指针事件和 PC 鼠标射线，将近/远拖动、缩放与共享局部 transform 交给统一交互器和 Registry；已适配实例的旧 `any_peer` 指针/世界变换 RPC 被明确短路，避免伪造输入和双重同步。

## 自动与真机验收

`spatial_window_state_self_test.gd` 覆盖数据边界，`spatial_window_self_test.gd` 覆盖场景节点、近/远拖动、朝向、八向缩放、渐进缩放、吸附和震动语义，`spatial_window_adapter_self_test.gd` 覆盖嵌套共享坐标、米制尺寸和开关清理，`spatial_window_registry_network_self_test.gd` 使用真实 ENet 覆盖权限、租约、预览/提交、迟到快照、断线清理与唯一/多开策略，`spatial_window_migration_self_test.gd` 固化首批场景接线和旧 RPC 边界。

真实设备仍需按 `docs/testing/phase1_session_regression.md` 检查 PC 鼠标与 PICO 近/远交互不冲突，两台 Client 观察结果一致，拖动/缩放/吸附无跳变、穿透或残留。自动测试通过不能替代这一视觉和手感验收。
