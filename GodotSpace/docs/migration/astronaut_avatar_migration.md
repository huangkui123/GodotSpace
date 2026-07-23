# 航天员角色迁移与 XR 驱动合同

## 资产来源与导入

源目录是 Unity 工程的 `Assets/ARSpace/Models/09_YuHangYuan 1/`。确认的输入为：

- `china_rig.fbx`：30,644,608 字节，Unity Humanoid importer，`importAnimation=0`。
- 8 个 Unity `.mat`、44 张 PNG/JPG 纹理、`china_rig.prefab` 与 `china_rig_VRIK.prefab`。
- `china_rig_VRIK.prefab` 依赖 RootMotion FinalIK；该 Unity 运行时依赖没有复制。

可复现迁移入口是 `tools/migration/migrate_astronaut_assets.ps1`。脚本复制 FBX，将 44 张源纹理生成最大边 1024 的移动端副本，并生成 4 个 Godot FBX importer 使用的 UDIM 别名。原 FBX 的 `<UDIM>` 文件名在复制件内按等长字节替换，不改变 FBX 二进制字段偏移；Unity 源文件不修改。目标 FBX 使用 `Assets/ARSpace/Characters/Astronaut/.gitattributes` 的 Git LFS 规则，缩放后贴图保持普通 Git 二进制。

目标 `Source/` 当前约 49.1 MiB（源目录约 271.35 MiB）。Godot 4.4 导入得到 8 个网格、33 根骨骼和无业务动画的 `PackedScene`。骨骼主链如下：

- 躯干：`Hips/Spine/Spine1TMP/Spine2TMP/NeckTMP/HeadTMP`。
- 左臂：`LeftShoulder/LeftArm/LeftForeArm/LeftHand`。
- 右臂：`RightShoulder/RightArm/RightForeArm/RightHand`。
- 每只手只有 `HandIndex1`—`HandIndex4` 一条可用手指链，因此第一阶段手势表现是有界握拳/扣机弯曲，不宣称完整五指追踪。

## 统一场景和程序化 IK

`AstronautAvatar.tscn` 把导入模型、角色标签和驱动脚本分开。`Player.tscn` 保留 `NetworkHead/NetworkLeftHand/NetworkRightHand` 作为跟踪目标与网络插值节点，航天员场景只消费这些节点，不拥有网络权威。远端玩家进入树前仍移除完整 XR 本地分支，因此不会重复注册移动或输入功能。

Godot 的 `ImportedModel.scale=10` 与 FBX 内部 `0.01` 单位换算共同得到 Skeleton3D 的 `0.1` 世界缩放；33 根 rest bone 的世界高度为约 `1.798 m`，因此不是 10 倍巨人。自动测试将可接受高度锁在 `1.6–2.1 m`。Unity `china_rig_VRIK.prefab` 中关闭的 `DETAIL/PANT/STRIP` 在 Godot 也永久关闭，只保留 `Basemesh/TORSO/HELMET_GLASS/HELMET/GLOVES`。

五个启用网格使用显式 Godot 材质覆盖，不再依赖 FBX 的不完整内嵌材质。Basemesh 保持 Unity 的白色、不透明、非金属/全粗糙合同；TORSO、HELMET、GLOVES 从 Unity metallic-gloss 贴图的 R/Alpha 分别还原金属度与 `1-smoothness` 粗糙度；HELMET_GLASS 按 Unity 源材质保持不透明、全金属、全光滑并绑定 `A.PNG`，不擅自改成透明面罩。

`astronaut_avatar.gd` 使用自定义程序化双骨解算：

- HMD 驱动头部与上躯干朝向；左右手目标驱动肩、上臂、前臂和手。
- 身高按 1.70 m 参考眼高自动标定到 `0.78`—`1.22`；肩宽按手间距估算并限制在 `0.34`—`0.50 m`。
- 头和双手均有局部偏移；目标使用指数平滑，跟踪丢失在 0.25 秒内过渡到头部附近的放松姿势，重新获得跟踪时平滑恢复。
- 双骨求解限制最大伸展为总臂长的 `98.5%`，极近、极远和共线目标均生成有限结果，防止骨骼爆炸。
- 所有写入 Skeleton3D 的旋转 basis 都先正交化；FBX 单位换算缩放只参与位置换算，不能传播到 `Spine2TMP` 及其头、肩、双臂子树。
- 本地 HMD 视图隐藏头盔、面罩与头部网格；远端保留全身模型和独立角色标签。

## 输入与网络合同

`XRInputRouter` 读取现有 OpenXR `trigger`、`grip`、`ax_button`、`by_button` 和 `primary` action，并保证同一时刻只激活一个交互来源：

- 左手 `A/X`：切换左手主控。
- 右手 `A/X`：切换右手主控。
- 任一手 `B/Y`：切换头部凝视。
- 当前主控手的 trigger、grip 与摇杆 Y 分别提供选择、抓取和滚动；凝视模式使用头部射线，并允许任一仍连接手柄的 trigger 确认。
- 当前手失去追踪时先降级到另一只有效手；双手均无效时降级到头部凝视。路由器分别保存用户请求模式和当前有效模式，PICO 启动阶段或短时失跟踪后会在请求手恢复时自动恢复该手射线。
- 头部凝视使用真正的 `XRToolsFunctionPointer`，而不是仅显示的装饰 Mesh；PICO trigger 读取 float action，以 `0.65/0.45` 迟滞阈值生成一次按下/释放，避免依赖 runtime 自选的 bool 阈值。

30 Hz 位姿 RPC 仍使用 `unreliable`。追加的状态是固定 7 个整数字段：头/左右手追踪位、输入模式、左右 trigger/grip 的 8 位量化值和 6 位手势位图。序列化上限 256 字节；Server 对字段完整性、类型和范围进行校验，非法包不会推进位姿序号。远端位置继续走 100 ms 插值，手势使用相邻样本的离散中点切换。

## 验证与剩余风险

自动回归覆盖 FBX 骨骼合同、左右手不交换、双骨有限解、长度限制、手势量化/越界拒绝、追踪降级，以及真实 ENet 的位姿和手势中继。最终视觉仍必须在两台 PICO/真实 OpenXR Client 上检查：

1. 分别以左手、右手、凝视模式连续点击、抓取和滚动。
2. 遮挡/关闭单个手柄，再关闭两个手柄，确认射线按合同降级且重获时不跳动。
3. 两个航天端同时做大范围交叉手、伸直手臂和快速扣机/抓握动作至少 10 分钟。
4. 观察肩、肘、腕、头盔方向、左右手和重连后的角色数量；若模型朝向或局部偏移有设备差异，只调整导出的 offset，不修改网络坐标。

2026-07-20 预检时开发机没有可用 PICO 连接，因此当时未把真实设备的材质观感、控制器 profile 差异或长时间抖动标为已验证。2026-07-23 已通过 PICO Streaming 收到首轮真机反馈；下述修复完成自动化验证后，视觉观感、射线手感和稳定性仍等待重新真机签字。

2026-07-23 首次 PICO Streaming 检查发现并修复了三个真机阻断：`Spine2TMP` 覆盖携带单位缩放导致上半身骨骼爆炸、启动首帧 tracking 未就绪导致输入永久卡在不可交互凝视模式、以及 Astronaut 射线触发窗口打开/关闭/聚焦时被共享窗口权限拒绝。自动回归现在会驱动真实骨架后检查正交 basis、验证 Unity 网格/材质合同，并用实际 `XRToolsViewport2DIn3D` + `Button` 完成一次 analog trigger 点击；最终完整 `run_phase1_validation.ps1` 输出 `PHASE1_VALIDATION PASS`（60.8 秒）。PICO 视觉和手感仍需重新真机签字。
