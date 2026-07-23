# 第一阶段集成验收记录（2026-07-16）

## 结论

第一阶段的软件实现与自动化准入门槛已通过；真实 PICO/OpenXR 三端联机、视觉手感和 30 分钟稳定性尚未执行，因此任务 1.7 仍为“待真机签字”，不能标记为最终验收完成。另经源资产复核，Unity 航天员没有可导入的业务动画 clip/Controller；程序化 IK/手势替代已实现，但任务 1.4 的合并资产项必须等负责人接受该替代方案或补充动画资产后才能勾选。

本次验证基于分支 `codex/unity-to-godot`，任务 1.1–1.6 的独立提交为：

- `307c760`、`08f2539`：三端角色与 Unity 复刻基线。
- `acaf5cd`：第一阶段可重复验证入口。
- `b889f94`：Server 权威协作状态。
- `353cda6`：航天员角色、IK、手势与 XR 输入。
- `6112156`：共享空间与标定闭环。
- `36029bf`：Server 权威通用三维窗口框架。
- `7ae7ecd`：收紧角色文案、WorkList 运行时和资产复制前置证据。
- `218f244`：补齐角色变更临时网络状态清理与消费者重建回归。
- `4e6d9d2`：如实纠正 Unity 航天员动画资产状态。

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

### 2026-07-17 增强回归

同一完整命令再次执行通过，退出码为 `0`，用时 89.2 秒。增强后的 `run_collaboration_multiprocess_self_test.ps1` 不再依赖固定 sleep，而是为每个场景分配独立 `432xx` 端口和临时阶段标记，并同时校验三个进程的退出码、精确 PASS token 与非预期 Godot 错误。现覆盖：

- Server→Ground VR→Astronaut，含 Ground 断线、重连、迟到快照与最终 Server 关闭。
- Server→Astronaut→Ground VR，确认 Ground 席位不依赖连接先后。
- 两个独立 Ground Client 竞争唯一席位，确认第二个被降级为 Astronaut、本地与伪造标注请求均被拒绝。
- Server 在两个 Client 完成断言后统一关闭，两个 Client 均确认 ENet transport 已断开。

`collaboration_state_network_self_test.gd` 同时使用真实 loopback ENet 扩充窗口集成覆盖：Ground 拖动预览中断线后 lease 自动释放且预览不写入持久状态；离线期间 Server 新增窗口后，Ground 重连取得与 Server 完全相同的两窗口快照；第二个 Ground 请求者被真实角色注册表降级后，窗口 lease 请求返回 `role_not_allowed`；Server 关闭后 Ground/Astronaut 两端 registry revision 归零且窗口集合为空。完整回归末尾仍出现两条精确的 headless dummy renderer `Parameter "m" is null` 空 Mesh 噪声，未出现脚本解析、资源缺失、RPC path、autoload 或 GDExtension 新错误。

`run_runtime_startup_smoke_tests.ps1` 还新增正式关闭恢复双进程用例：Server/桌面 Test Client 通过真实 `NetworkHandler.start_server/start_client` 进入 `ARSpace.tscn`；Server 先创建非零 CollaborationState 菜单状态、SpatialCalibrationState 确认点和 SpatialWindowRegistryService 窗口，Client 验证完整快照后才触发 Server 关闭；随后 Client 必须同时观察 `server_connection_lost` 与 `session_closed`，恢复 `OfflineMultiplayerPeer`，清空角色表、Ground 席位和三类状态，并由正式路径返回 `StartMenu.tscn`。runner 使用 READY 日志屏障、原生退出码、唯一 PASS token 与精确错误白名单，已独立复跑 12.9 秒通过。

### 2026-07-17 本地闭环复核

最新完整命令再次得到 `PHASE1_VALIDATION PASS`，退出码 `0`，用时 94.4 秒。除前述已归类的定制 headless/progress dialog、SubViewport 和 dummy renderer 空材质/空 Mesh 噪声外，没有脚本解析、资源缺失、RPC path、Autoload 或 GDExtension 新错误。新增证据包括：

- WorkList 测试真实实例化 `WorkListView.tscn`，验证非 editor 运行时恰好创建任务 1—5、任务 1 的 20 个连续步骤、任务 2—5 的未配置显示/点击拒绝、任务 6—8 缺席和重复初始化幂等。
- 同一已连接 Ground VR 被 Server 降级为 Astronaut 后，窗口 lease、请求序号、结果缓存、快照节流和 preview 序列均清理；已确认的共享 `focus_order` 按合同保留，后续 Ground-only 操作由 Server 以 `role_not_allowed` 拒绝且 revision 不变。
- 在 ENet 连接保持期间销毁并重建 Astronaut 端 `CollaborationState` 和窗口 Registry，重复即时快照请求只应用一次，完整状态与 Server 精确相等，每个窗口只注册/变更一次。
- StartMenu 三个中文标签已锁定为“PC 地面端 Server”“地面 VR 端 Client”“航天端 XR Client”；旧倒序“VR 地面端 Client”由测试禁止恢复。
- 航天员迁移脚本复制前会硬性检查仓库边界、LFS filter、Git LFS 可用性和对象体积，并在修改复制件前执行 SHA-256 一致性校验。当前源 FBX/目标补丁件和 44+4 张纹理的尺寸、哈希与 LFS 状态已记录在资产台账。

硬件就绪审计发现本机有 PICO Connect 自带 ADB 和 PICO Streaming OpenXR runtime，但 `adb devices -l` 返回空设备列表，系统也没有物理 PICO/Android PnP 设备。当前无法执行两台 PICO + PC 的真实三端、Unity 三 Tag 对照和 30 分钟稳定性验收；这属于外部设备前置条件，不以桌面模拟替代。

### 2026-07-20 PICO 验收前收口

针对真机前置再次从空 `.godot` 缓存审计，修复了三项会影响同一 PICO APK 验收的阻断：Android 不再拒绝 Ground VR Client，原生默认仍为 Astronaut 但 StartMenu 角色选择保持解锁；恢复 Godot OpenXR Vendors 4.0.0 的 PICO debug/release AAR、Android arm64 库和编辑器库，并补齐 hand-tracking 项目设置；`Android PICO` 预设固定为 arm64、Gradle、PICO vendor、Internet/录音权限和包名 `com.yaoling.godotspace`。新增 `run_pico_hardware_preflight.ps1`，现已并入总验证入口。

仓库中的 EIRTeam FFmpeg 扩展没有 Android 二进制。为避免 APK 引用不存在的 `.so`，Android 声明已移除，视频详情/工作清单改为显式不可用降级；Windows/Linux 保持原扩展。一个内容实际为 PNG、扩展名却为 `.jpg` 的图片也已改正。fresh import 退出码为 `0`，用时 104.2 秒，并精确定位、记录了七个旧非主线源模型缺失路径和 Kepler FBX 的内嵌图片错误；航天员 `china_rig.fbx` 随后独立导入成功。最终完整 `run_phase1_validation.ps1` 退出码为 `0`，用时 58.2 秒，最终输出 `PHASE1_VALIDATION PASS`。

2026-07-20 预检时复核机没有 `ANDROID_HOME`/`ANDROID_SDK_ROOT`、项目 Android Gradle build template、Godot Android export templates 或可用 `adb`，因此没有伪造 APK 构建/安装结论。2026-07-23 已可通过 PICO Connect 的 ADB 看到头显，但设备上没有本项目 Godot APK，首轮反馈来自 PC PICO Streaming/OpenXR。原生 APK 生成/安装仍须先按 `pico_hardware_preflight.md` 配置打包环境；六项真机复选框继续保持未勾选。

### 2026-07-23 首次 PICO 反馈修复

首次 PICO Streaming 运行暴露出航天员上半身严重畸变和射线完全不可用。运行时量化确认 `Spine2TMP` 骨骼 basis 因 FBX 单位换算被放大到约 `7.7`；修复后各轴长度和 determinant 恢复为约 `1`。当时按 Unity 半身 VRIK prefab 关闭 `DETAIL/PANT/STRIP`，并先为其余五个网格绑定显式 Unity 对齐材质，保留约 `1.798 m` 的 rest bone 世界高度；后续 PC 视角真机反馈证明该半身显隐合同不适用于远端完整人物，现已由下述 8 网格合同取代。

射线侧将“用户请求模式”和“当前 tracking 回退模式”分离，避免 PICO 首帧无 tracking 后永久停在 gaze；原装饰性 HeadGazeLaser 已替换为相机锚定的真实 FunctionPointer，并以 `trigger` float 的 `0.65/0.45` 迟滞阈值驱动点击。`PlayerPresenceSelfTest` 现会实际射中 `XRToolsViewport2DIn3D` 并精确触发一次 SubViewport Button。Astronaut 允许请求窗口打开、关闭、聚焦、显隐和最大化，但仍不能取得租约或修改空间 transform/尺寸/吸附。

同次日志还记录到旧脚本持续发送已移除的 `trigger_pressed` RPC；当前分支没有该调用，说明切分支后复用了旧 Godot 运行进程。后续每次真机复测前必须完全退出 PC Server/Client 游戏进程并重新启动当前分支；日志不得再出现 `trigger_pressed` RPC 配置错误。上述修复通过自动化后仍需重新执行本页真机复选框。

修复后的最终完整 `run_phase1_validation.ps1` 于 2026-07-23 输出 `PHASE1_VALIDATION PASS`（60.8 秒），覆盖资源导入、PICO 包预检、协作/玩家/角色/空间窗口、多人重连、工作清单、LLM 和三种启动冒烟测试。

### 2026-07-23 第二次 PICO 航天员反馈修复

第二轮截图中航天员白/黑/红表面形成贯穿场景的长三角。其外观容易被判断为材质错误，但探针确认材质和 Unity prefab 可见性合同不变，真正根因是髋/脊柱停在舞台原点、头/手骨骼使用 HMD 世界位姿，导致同一蒙皮被相距数米的骨骼撕裂。HMD 水平偏移约 3 m 时，旧版 TORSO 世界深度由约 `0.51 m` 扩张到 `3.51 m`；让 Avatar 根节点跟随 HMD 地面投影后恢复到约 `0.51 m`。

本次让完整身体根节点随 HMD 的共享地面投影和水平朝向移动，并对超过 `0.5 m` 的重定中位移首帧跟随；导入模型增加 Unity `+Z` 到 Godot `-Z` 的 180° Y 轴转换，头/手/躯干旋转保留 FBX rest basis，双臂改为世界空间求解后再转换回骨架。自动门禁新增命名左右骨骼身体侧、左右手目标不交叉、逐骨正交、数米房间尺度移动、重定中首帧人体边界与五个精确材质资源路径检查。定制版和 Godot 4.4 stable 的 `PlayerPresenceSelfTest` 均通过，稳定版离屏渲染无长三角；完整 `run_phase1_validation.ps1` 再次输出 `PHASE1_VALIDATION PASS`（60.9 秒）。PICO 复选框继续保持未勾选，等待当前提交重启进程后的真机复测。

地面 VR 随后还确认 PC Server 的观察相机被错误显示为航天员。现将 PC Ground 固定为无形观察/操作端：网络仍复制它的相机位姿，但客户端永远隐藏该 peer 的四个网络代理根节点和 `AstronautAvatar`；Ground VR 与 Astronaut 仍显示 XR 人物。`PlayerPresenceSelfTest` 覆盖三角色可见性，`PlayerNetworkSelfTest` 通过真实 ENet 断言 Client 收到 PC 位姿但不渲染人物。

PC 观察地面 VR 的下一张截图显示模型已不再爆炸，但缺少裤装、双腿和外部细节。源资产复核确认完整 `china_rig.prefab` 启用全部 8 个网格，而半身 `china_rig_VRIK.prefab` 才关闭 `PANT/DETAIL/STRIP`。为满足第一阶段“远端完整航天员”合同，Godot 现启用全部 8 个网格，并为恢复的三项分别绑定源底色、metallic-gloss 和法线贴图。自动测试要求远端三项可见并核对 8 个精确材质路径；Godot 4.4 stable 离屏渲染已得到带裤装、双腿和细节的完整人体。角色测试、真实 ENet、三种多进程连接顺序/重连均通过，最终完整 `run_phase1_validation.ps1` 输出 `PHASE1_VALIDATION PASS`（62.0 秒）。

后续真机观察仍认为航天服整体复刻与手部姿态不可接受，因此当前验收基线已回退为虚拟头/手/躯干代理。两个 XR 角色的远端代理必须显示头球、朝向标记、双手球、胶囊躯干和标签；PC Ground 仍不可见；导入航天服必须隐藏且停止处理。该回退保留网络头手位姿与射线交互，但不再把全身 IK、身高/手臂适配和可见手势动画记作完成，第一阶段对应真机项仍待后续重做与签字。定向玩家测试通过；随后运行 `run_phase1_validation.ps1 -SkipRuntimeSmoke`，54.2 秒输出 `PHASE1_VALIDATION PASS`。启动冒烟本轮未重复执行，因为用户正在运行的手工 PC Server 占用正式 UDP 42069；没有为测试终止该进程。

## 任务 1.7 证据矩阵

| 验收项 | 自动化证据 | 当前判定 | 真机仍需确认 |
| --- | --- | --- | --- |
| PC Ground Server + Ground VR + Astronaut XR | `run_collaboration_multiprocess_self_test.ps1` 在三个独立 Godot 进程中运行三角色；`run_runtime_startup_smoke_tests.ps1` 检查正式参数入口 | 部分覆盖 | 两台真实 PICO 同时接入正式 `ARSpace.tscn` |
| 连接顺序、第二 Ground VR、掉线/重连、角色变更、Server 关闭 | 三套独立进程场景覆盖两种连接顺序、Ground 重连和第二 Ground 降级/拒权；同连接角色降级验证临时状态清理，消费者重建验证快照去重；正式运行时双进程用例覆盖非零业务状态下 ARSpace→StartMenu 的 Server 关闭与全量清理 | 部分覆盖 | 真实无线网络、头显休眠/唤醒和头显内界面提示 |
| XR 角色虚拟头/手/躯干代理、名称、本地/远端隐藏 | `PlayerPresenceSelfTest.tscn`、`PlayerNetworkSelfTest.tscn`、`avatar_pose_state` 边界检查 | 回退代理已覆盖；全身 IK 未完成 | 真实跟踪姿态、代理观感与长时稳定性；后续重新验收全身模型 |
| 共享原点、重定中、标定快照、迟到 Client | `shared_space_alignment_self_test.gd`、`shared_space_contract_self_test.gd`、`spatial_calibration_state_network_self_test.gd` | 部分覆盖 | PICO 实景三 Tag 对照、重定中后的实体对齐误差 |
| 主菜单和至少四类业务窗口 | 5 项 SpatialWindow 自测；真实 ENet 覆盖预览、lease 断线释放、降级拒权、重连完整快照与 Server 关闭清理 | 部分覆盖 | PC 鼠标、PICO 近抓/远射线/摇杆、震动和两端视觉一致性 |
| 真实设备运行至少 30 分钟 | 无 | 未执行 | 帧率、跟踪、内存、RPC 错误、残留节点和断线恢复 |

## 真机签字流程

### 1. 固定环境

记录以下信息后再开始：Git commit、Godot 完整版本、两台 PICO 的设备编号与系统版本、PC/PICO IP、目标刷新率、开始时间、语音输入输出设备。三端必须位于同一局域网；PC 防火墙允许 UDP `42069`。若启用 Ground VR 配对保护，在 PC Server 与 Ground VR 的本地环境中配置相同的非空 `GODOTSPACE_GROUND_VR_TOKEN`，不得把令牌写入日志或仓库。

```powershell
# PC Ground Server
& $Godot --path $Project -- --voice-role=server

# Ground VR Client（桌面/OpenXR 调试参数；原生 PICO 可在 StartMenu 直接选择）
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
- [ ] 操作时另一个 Ground 端竞争同一窗口，租约拒绝并发写；Astronaut 可打开/关闭/聚焦/最大化窗口，但租约、拖动、缩放和吸附请求仍被拒绝。
- [ ] 迟到 Client 与两台在线端看到相同 transform、尺寸、模式、焦点和显隐。

### 5. 30 分钟稳定性

每 5 分钟记录一次三端帧率、PC 进程内存、跟踪状态、当前 peer、RPC 错误数和残留节点观察结果。期间至少执行一次 Client 断线重连、一次重定中、一次窗口拖动/缩放/吸附循环和一次 Server 关闭后的完整恢复。

- [ ] 无崩溃、卡死或无法恢复的网络状态。
- [ ] 帧率与设备目标刷新率的偏差、掉帧时段和操作场景已记录。
- [ ] 内存没有持续无界增长，关闭窗口/断开 Client 后相关节点和媒体资源被释放。
- [ ] 无持续 RPC 权限错误、重复玩家、残留射线、残留语音或旧窗口租约。
- [ ] 附上日志、时间点和必要截图，并由执行人填写姓名与日期。

执行人：__________　日期：__________　结论：通过 / 不通过 / 有条件通过
