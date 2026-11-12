# 实验柜显示与第一视角视频

## 2026-11-12：与原 Unity 的完整步骤对照

本次参考只读原工程 `F:/spaceproject-V2.0.2_NewPlayerModel/SpaceProject`，检查了 `Assets/ARSpace/Scripts/WorkListCanvas/WorkListManager.cs`、`WorkListUIView.cs`、`Containerless/Containerless.cs`、`dashiyangui.controller`、`Models/WorkEffect.prefab`、柜体 prefab 和 `Scenes/ARSpace.unity`。15 张步骤图片逐张查看，且 SHA256 与当前 Godot 中的同名文件全部相同。没有修改 Unity 工程、源图片或二进制动画资源。

根因和修改：

- Godot 复制的是 Unity 编辑器示例 `WorkListUIView` 的错误图片表，而运行时 `WorkListManager` 的对应表正确。修正第 12、13、16、17、18、19、20 步；原 `step11.png`、`step15.png` 不存在。第 16 步本来就要求定位凸耳对齐，第 18 步本来就要求接回 X01/X02，不能把高亮迁到错图所在的下一步。
- `WorkListInfoItem.refresh_info()` 原先加载失败时保留旧纹理，导致画面依赖翻页历史。现在先清理图像和视频，再绑定新内容；缺失时明确显示提示，隐藏窗口时停止视频。
- 第 4、7、11、14、15 步共用的 `Demo1.mp4` 实际是 47.72 秒的无关演示视频。第 4 步改为通话文字提示，7/11/14/15 明确引导观看对应柜体三维动画。通用视频分支保留，并修正 FFmpeg 无法直接打开 `res://` 的路径问题。
- 原 `WorkEffect` 有 34 个启用的 UI 图形在迁移后只剩空节点，涉及步骤 6/9/12/13/16/17/19。`cabinet_step_guidance.gd` 根据原 RectTransform 的 anchored position、图形尺寸、颜色、已有旋转/缩放补回，包含同名节点被转换成 `Canvas (1)2` 的情况；恢复步骤 6/19 的 51–58 编号，共 16 个数字。原 Unity 在 M6 步骤中关闭的错误 51–56 编号保持关闭。
- Unity 柜体 prefab 和 ARSpace 实例都在 Y=0.18，当前 Godot 柜体根节点为 Y=0，指引仍在旧坐标，导致标记整体偏高 18cm。以柜体实际变换校正步骤 3–19 的指引，不移动现有柜体；准备/撤收路线 1/2/20 保持舱内位置。重复安装不会累积偏移。
- 第 12 步“按压解锁”标签缺少正确字号比例和朝向，原来几乎不可见，已修正。步骤指引文字允许覆盖柜边，以免“定位凸耳”等说明被柜沿截断；普通窗口 UI 的遮挡规则不变。

| 步骤 | 配图或呈现 | 操作与场景指引（对应同号 Step / WorkInfo） |
| --- | --- | --- |
| 1 | step1.png | 应用系统综合包、位置路线 |
| 2 | step2.png | 准备工具、位置路线 |
| 3 | step3.png | 防静电接地点，4 个圆圈 |
| 4 | 通话文字 | 天地通话，无部件运动 |
| 5 | step5.png | 识别闭合操作盖 |
| 6 | step6.png | 松开操作盖螺钉，8 个圆圈、51–58 |
| 7 | 柜体三维演示 | 拆下操作盖 |
| 8 | step8.png | 断开 X01/X02，两处连接器标记 |
| 9 | step9.png | 松开六颗 M6 螺钉，6 个圆圈 |
| 10 | step10.png | 齿扣旋至“开”的方向箭头；原资源为静态指引 |
| 11 | 柜体三维演示 | 抽出轴心机构 |
| 12 | step12.png | 按压解锁、取出旧样品盒 |
| 13 | step13.png | 识别新盒与安装位置、按压提示 |
| 14 | 柜体三维演示 | 插入新样品盒 |
| 15 | 柜体三维演示 | 插回轴心机构 |
| 16 | step16.png | 定位凸耳/定位槽对齐、锁至“关”；原资源为静态指引 |
| 17 | step17.png | 固定六颗 M6 螺钉，6 个圆圈 |
| 18 | step18.png | 接回 X01/X02，两处连接器标记 |
| 19 | step19.png | 装回操作盖再紧固，8 个圆圈、51–58 |
| 20 | step20.png | 撤收工具路线，隐藏操作部件 |

新增内容检查使用真实任务数据、UI、柜体和 SpaceBox 控制器，逐步验证正/倒序 20 页的文字、实际纹理像素、动画编号、唯一可见 WorkInfo，以及每步与 Unity 对照的提示文字和图形数量；另验证缺图/缺视频不残留、关闭重开、重复安装。GPU 截图包含 6/8/9/12/13/16/17/18/19/20，位于 `%TEMP%/cabinet-content-XX.png` 和 `cabinet-page-XX.png`，已人工查看。

```powershell
$Godot = 'D:/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe'
$Project = 'F:/GodotSpace/GodotSpace'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_content_self_test.gd' -- --capture-content
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_content_self_test.gd' -- --check-video
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_animation_self_test.gd'
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/shared_work_step_state_self_test.gd'
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_network_self_test.gd'
```

本轮结果：上列检查均退出 0；视频检查包括暂停/恢复、循环 120 秒、隐藏停止、重开和切回图片。全部 7 项 LLM 离线自检、柜体显示与材质 GPU 回归通过，未调用在线模型。最终 `--headless --path F:/GodotSpace/GodotSpace --import` 退出 0，无脚本解析、autoload、缺失资源或 GDExtension 加载错误；仍有已知 progress-dialog/tasks/ObjectDB 清理提示。新脚本 UID 由指定引擎生成，`git diff --check` 通过。

完整场景另运行一台 Server、两台 `--testmode` Client（下文 `cabinet_scene_self_test.gd` 命令），三者 StartMenu → ARSpace 断言和退出码均通过。但第二台 Client 再现已有 `RootNode3D/1` 缺失、peer 1 节点缓存和 Invalid packet 日志，所以完整多人日志检查未全通过；步骤 ENet 专项通过。GPU 内容截图保留原资源的空 material、SubViewport 提示，显示回归有既有 RID/resource 清理日志，不能宣称所有日志无错误。

真机验收：重启所有串流端，依次查看 12→13 和 16→17→18→19→20，再倒序返回；每页图文与上表一致，第 16 页定位凸耳、第 17 页六螺钉、第 18 页 X01/X02、第 19 页八螺钉，上一页的圆圈/文字不残留。分别在柜体 100% 和 0% 下检查圆圈位置和指引文字，并在第 15 步动画未完成时进入 16，确认轴心已经插回。桌面渲染与测试不能替代 PICO 双眼、手柄点击和最终串流验收。

## 使用

- 天上端 MR 现隐藏舱体的天花板 `UpPlane`、地板 `DownPlane`、后背板 `BackDor`，供现场对比真实透传，避免白色半透明舱面造成亮度对比。仅该角色隐藏这三个节点的绘制；其他角色恢复场景原始显隐。柜体、侧墙、操作指导和 UI 不受此修改影响，碰撞不变。「地板 / 后墙」透明度滑条不会重新显示已隐藏的舱面。此改动源于用户对黑区的最新判断，实际视觉效果待重新进入 MR 验证。
- 大实验柜**正面右下角**有「柜体显示」滑条，0% 隐藏、100% 完全显示。通过 XR 射线按住扳机拖动；隐藏后滑条仍可操作。
- 调节仅作用于当前观看端，不发送 RPC，不改变另一端的透明度。场景重新进入时恢复 100%。
- 仅固定大柜壳体 `dashiyangui` 和小柜固定框架 `xiaoshiyangui/xiaoshiyangui_a` 参与淡化。拆装挡板、螺丝、核心、样品盒、工具、步骤提示、高亮、虚拟标注与操作指导不随此滑条淡化；部件显隐仍由步骤动画控制。不关闭父节点，也不改动画、标注锚点或碰撞体。
- 地面端第一视角窗口新增「反畸变」开关和强度滑条。关闭可对照原图；设置保存在本机 `user://cast_correction.cfg`。
- 当前按单幅 PICO 投屏处理，默认强度 25%，可调 0–80%。这是可调径向模型，**不是设备标定结果**；校正会损失部分边缘视野。以柜体直边、圆形操作口为参照微调，避免过度校正。双眼拼接或偏心镜头需要另行确定视口和参数。
- 仅 `source_type=pico_cast` 的未校正视频启用效果。虚拟相机或显式带 `rectified=true` 的源直接显示原图；不复用空间标定相机的内参。

## 实现与问题定位

最新现场结果：用户确认空画面期间黑区消失；随后确认「隐藏柜体组」黑区仍在、「仅柜体组」黑区消失。最新日志记录前者隐藏 18 个几何对象，后者隐藏 185 个几何对象及 92 个 CanvasItem。柜体组按 `independent_cabinet_visuals` 标识，包含柜壳、拆装部件和柜上滑条。当前证据支持优先排查柜体组之外的绘制，不能据此认定柜壳透明度或远处默认背景是原因，也不能只凭这两项锁定具体舱壁、UI 或特效。

已检查周边舱壁原始材质：多为不透明、Always 深度写入，但运行时 Sky 适配会转为 Alpha 混合且关闭深度写入，因此原始材质标志本身不是黑区根因证据。下一项现场对照为：保持柜体正常显示，临时把「物体 / 文字」「窗口面板」「地板 / 后墙」均调至 0%，记录黑区是否消失，随后恢复原值且不保存为默认。用户表示稍后再测，尚无结果。该对照能区分常规全局淡化内容与独立保留内容；后者仍包括指导、标注及部分特殊绘制，不能直接等同于操作箭头。本轮未更改柜体透明度算法，也未凭推测隐藏舱壁或指导内容。

接近 0% 的突变尚未在本机复现。`cabinet_material_render_self_test.gd` 新增连续 96 帧 0–16% 往返、反复从 0 启动并移动相机的 GPU 检查，连接实际 PICO encoded-alpha compositor；Alpha 与 RGB 最大误差均为 0.002157，连续运动测试仍为 0/90 异常帧。它只覆盖本机单眼渲染和颜色修正，不包含串流编码、真实双眼和头显最终合成。本轮没有加入低透明度截断、抖动或修改已正常的透明度公式。

本轮运行指定引擎 `--headless --import`（退出 0，仅既有 progress-dialog/tasks/ObjectDB 清理日志），并用 `--xr-mode off --script` 运行材质渲染、透视检查、显示设置三项自检，均退出 0 且无脚本错误。选择性检查覆盖缺少柜体时拒绝执行、动态加入部件、独立深度视口不受影响、恢复原图层/显隐；设置 UI 已截图检查，在原 446×348 区域内完整显示。

本轮运行角色集成自检通过；另启动一台 Server 和两台 `--testmode` Client，StartMenu → ARSpace 断言与退出码均通过。仍有 SubViewport/dummy renderer 基线日志，且一台 Client 在 `_client_receive_pose`（`player.gd:492`）出现 `is_server` 空引用，因此多人日志检查不算全通过；本轮未修改位姿接收。指定命令见下文，真机分项对照及接近 0% 的串流效果尚未验证。

`cabinet_opacity.gd` 作为 prefab 的 `CabinetOpacity` 子节点挂载，保留主场景原有 `Ani_Play.gd` 和步骤动画接口。当前使用连续 Alpha 混合，已移除现场出现密集颗粒的 Alpha Hash。`cabinet_depth_capture.gd` 在独立 World3D 中为柜壳生成最近表面深度，`cabinet_smooth.gdshader` 只对最近柜壳表面进行一次透明混合，避免合并 CAD 内部前后面相互覆盖或反复叠加。该深度不写入主场景，因此不会留下遮挡 UI/环境的隐形柜体。0% 丢弃全部柜壳片元，100% 使用不透明着色和正常深度写入；两端均停止辅助深度渲染。保留颜色、法线、金属度、粗糙度贴图和 UV，材质实例隔离，源资源不变。高亮临时替换的材质不被覆盖，取消高亮会恢复当前滑条值。模型实际正面为局部 +X，右方为 -Z，位置来自真实网格 AABB。

深度采集使用两个独立相机（桌面只更新一眼），依照 OpenXR 每眼光学投影、`XRServer.world_origin` 和视图位姿设置非对称视锥。主着色器将世界坐标重投影到对应眼深度图，不假定左右眼共用屏幕 UV。深度按 RGB24 存储，禁用该数据视口的抗锯齿、TAA 和色带抖动。场景树重入时重新连接 `frame_pre_draw`，退出时断开并随父节点释放资源。半透明期间增加柜壳专用深度绘制，PICO 实际帧率及双眼边缘必须真机复测；桌面测试不能代替这项验收。

连续移动时局部变黑/透明度跳动：已复现是 `frame_pre_draw` 内修改相机变换但未立即提交，深度纹理仍按上一帧相机位置渲染，而材质矩阵已用新位置。此前等待 5 帧稳定后取图的测试漏掉此问题。新增逐帧持续移动测试，修正前 90 帧中有 49 帧不满足 Alpha/前景细节检查；在发布矩阵前对深度相机、网格副本调用 `force_update_transform()` 后为 0/90。测试随后同时移动相机和柜体，仍为 0/90。没有增大深度容差掩盖误差。参见 [Godot Node3D 变换刷新](https://docs.godotengine.org/en/4.4/classes/class_node3d.html#class-node3d-method-force-update-transform)。真实串流头显仍需复核。

本次同步修复的验证结果：材质连续运动渲染、MR 空画面对照（GPU）、显示设置入口/布局、运行角色集成自检均退出 0，无 ERROR。导入退出 0，仅有已知 progress-dialog/tasks/ObjectDB 清理日志。一台 Server 和两台 `--testmode` Client 的 StartMenu → ARSpace 断言与退出码均通过，本次未见 RPC/脚本错误，但三端仍有 dummy renderer 材质空指针和 SubViewport 坐标提示，因此不宣称场景日志完全干净。`git diff --check` 通过；未进行真实 PICO 运动与黑区验收。

`WorkEffect` 的 `GuidanceMaterials` 子节点只适配本实例材质。`M_Arrow` 与 `M_Arrow_L` 使用的 PNG 本身包含大片半透明青色发光背景；隐藏柜体后光晕露出，并被材质染成绿/红色。`guidance_symbol.gdshader` 按 Alpha 0.9 裁剪这些背景，保留箭头轮廓和标记圆环，使用原材质提示色，不受光照或雾影响。透明背景从颜色与深度中同时丢弃；其余半透明工作特效保留原外观但关闭深度写入。共享 `.material`、贴图和动画文件不变。

技术依据：[Godot 4.4 材质透明模式](https://docs.godotengine.org/en/4.4/tutorials/3d/standard_material_3d.html#transparency)。普通 Alpha 混合的排序限制不能靠修改节点层级解决；上一版采用 Alpha Hash 虽解决排序，但其覆盖噪声不符合平滑淡化要求，已替换。

`XR_Main.gd` 将独立柜体、工作提示/特效、工作指导窗口以及标注组排除在旧的全场景淡化之外，避免旧设置覆盖独立透明度或淡化指导信息。

UI 变黑的可复现材质因素：业务窗口继承的 XR Tools 表面默认 `unshaded=false`，会被场景光照和阴影调暗。业务适配器 `spatial_viewport_2d_in_3d.gd` 在创建/刷新表面时设为 unshaded、关闭雾和投影，禁止透明 UI 写深度；**保持深度测试和正常遮挡**，没有通过强制穿透或更改渲染层解决。测试分别检查暗处原色、旧材质变暗、前方实体遮挡以及后方实体不影响窗口颜色。真实设备的特定遮挡/交叉排序现象尚需现场复核，不能据此宣称所有黑屏原因都已排除。

`cast_undistort.gdshader` 在解码后显示阶段进行输出到源图像的径向采样，使用原视频宽高比，保留 TextureRect 等比显示。没有修改 FFmpeg、传输协议、原始帧或标定数据。`astronaut_view_panel.gd` 管理开关、参数与本机保存；`pico_cast_view_source.gd` 传递已校正标志。

## 自动验证

### 任务步骤与部件动画

用户确认隐藏舱面后显示问题已解决。本轮检查当前无容器任务的全部 20 步及 `dashiyangui.library.res` 的所有动画轨道，发现并修复：

- `ARSpace.tscn` 保存的操作盖、盖螺钉和轴心螺钉是拆卸/预览位置；空 `RESET` 和前 4 个空步骤无法恢复初始装配状态。
- 多个步骤仅有部分轨道，直接 `play()` 会继承之前未完成的姿态；第 15 步插入到一半时进入第 16 步，后者没有轴心位置轨道，导致停在半途。
- 大量原始可见性轨道反复显示已拆除操作盖、工具和旧样品盒；第 16 步还把新样品盒移至 `(10,-10,-10)`。
- 控制器上限为 19，导致第 20 步无法清理前一步模型；主菜单旧入口调用了不存在的 `play_from_ui()`；关闭任务面板没有关闭部件指导。

`cabinet_step_animations.gd` 从原始动作构建本实例私有动画库。按顺序计算各步完成后的姿态，为每一步补齐所有受控部件的位置、旋转、缩放及第 0 秒状态。延迟开始的轨道补齐起始保持值。移除不符合步骤范围的可见性轨道及新样品盒错误停放轨道，保留原动作插值、时长和相关工具/提示的定时显隐。`Ani_Play.gd` 停止旧动画、清队列，以零混合切换并立即 `seek(0, true)`；任意跳步、回退、重播不依赖播放历史。导入的 AnimationTree 停用，防止两个控制器同时写姿态。原始二进制动画、材质、节点层级不改。参考 [Godot AnimationPlayer 的立即更新与 seek](https://docs.godotengine.org/en/4.4/classes/class_animationplayer.html)。

显示范围（相关部件仍完整显示，不受柜壳透明度影响）：

| 部件 | 显示步骤 |
| --- | --- |
| 操作盖 / 挡板 | 5、6、7、19 |
| 操作盖螺钉 | 6、7、19 |
| 轴心主体 / 核心 | 8–18 |
| 轴心螺钉 | 9、10、11、16、17、18 |
| 旧样品盒 | 8–12；第 13 步起不再显示 |
| 新样品盒 | 13–18；第 14 步安装后保持在安装位置 |
| 工具 | 2、6、9、17、19；保留第 6、19 步定时出现/撤回 |
| 部件文字提示 | 抽芯提示 11、旧盒提示 12、新盒提示 13–14 |

未开始任务、关闭指导及第 20 步结束整理时，活动部件隐藏；固定柜壳仍由原滑条控制。初始隐藏部件的内部姿态仍为装配状态，第 5 步显示盖板时处于闭合位置。关闭/重开走既有共享步骤状态，不增加 RPC；主菜单旧入口也通过共享状态重播当前步骤。没有补造原资产中不存在的运动：准备、识别和部分锁紧/连接器步骤仍使用静态姿态与原指导特效。

新增验证命令（同下文指定 `$Godot`、`$Project`）：

```powershell
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_animation_self_test.gd'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_animation_self_test.gd' -- --capture-steps
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/shared_work_step_state_self_test.gd'
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/WorkListCanvas/cabinet_step_network_self_test.gd'
```

以上断言与退出码通过：实际主场景覆盖初始爆炸图偏移、全部 20 步、400 组中途切换（含回退和同一步重播）、完成态、关闭与重开；ENet 一台 Server / 两台 Client 验证中断插入、回退、重播、晚加入、断开重连和结束清理。GPU 截图在 `%TEMP%/cabinet-step-05.png` 等文件中，已查看闭盖、抽芯、插回及装盖画面。柜体显示回归及全部 7 项 LLM 离线自检也通过，未调用在线模型。部分真实模型加载/退出仍有既有 SubViewport、空 mesh/material、RID/resource 清理日志，不宣称所有日志无错误。

最终资源导入有一次在退出阶段发生 signal 11（退出码 -1073740940），该次计为失败；结束独立测试进程后用相同 `--headless --path F:/GodotSpace/GodotSpace --import` 重跑，退出 0，无脚本解析/缺失资源错误，仍有 progress-dialog/tasks/ObjectDB 清理提示。完整主场景另启动一台 Server 和两台 `--testmode` Client，三者 StartMenu → ARSpace 及中断插芯断言、退出码均通过；其中一台 Client 再现已有 `RootNode3D/1`、`RootNode3D/ReconstructionPipeline` 的 RPC 路径缓存错误，故完整多人日志检查未全通过，区别于本次通过的步骤 ENet 专项。原始 `.res`/`.anim` 文件无改动，新增 UID 由指定引擎生成，`git diff --check` 通过。

真机复测：重启后先确认未选步骤时无悬空操作盖或核心；第 5 步闭盖，第 7 步动画拆下；第 11 步抽芯未结束时跳至 12，应直接在完全抽出位置；第 14 步未结束跳至 15，应已装好新盒；第 15 步未结束跳至 16，应已插回核心且新盒不消失；回到 6/12/14 和连续重播应恢复各自起点；第 19 步装盖，第 20 步隐藏活动指导部件。关闭再打开、柜壳 0% 下的部件指导和双端同步仍需真实串流验收。该流程检查针对目前实际提供的无容器 20 步资源；其他任务卡复用这套示例数据，不代表已有独立动画流程。

隐藏舱面调整：指定引擎执行 `--headless --path F:/GodotSpace/GodotSpace --import`、`--script res://Assets/ARSpace/Scripts/runtime_mode_integration_self_test.gd` 及 `--script res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_scene_self_test.gd -- --voice-role=server`，全部退出 0。角色自检确认 Sky XR 隐藏三面、切回 Ground 恢复原始显隐；场景自检通过 StartMenu → ARSpace。导入保留已知清理日志，场景检查保留 SubViewport/dummy renderer 基线提示。`git diff --check` 通过；真实 MR 视觉效果需要用户重启天上端、重新进入场景后对照。

使用仓库指定引擎、真实工程目录（当前工作区为 `F:/GodotSpace/GodotSpace`）：

```powershell
$Godot = 'D:/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe'
$Project = 'F:/GodotSpace/GodotSpace'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/UI/cabinet_display_self_test.gd'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/UI/cabinet_material_render_self_test.gd'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/XR/sky_transparency_render_self_test.gd'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/XR/mr_passthrough_probe_self_test.gd'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/XR/sky_display_settings_self_test.gd' -- --capture-ui
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/runtime_mode_integration_self_test.gd'
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/SpatialWindows/spatial_window_network_self_test.gd'
& $Godot --headless --path $Project --import
```

显示自检覆盖 0/25/100% 往返、共享材质隔离、指导内容、高亮/取消、隐藏后滑条输入、暗处 UI、遮挡、视频源旁路、GPU 径向采样与零强度恒等映射。合成桶形网格恢复直线，误差从 9279.6 降至 1905.2（约 79%）；这不代表真实投屏精度。截图位于 `%TEMP%/cabinet-opacity-solid.png`、`cabinet-opacity-faded.png`、`cast-correction-grid.png`，不加入仓库。

2026-11-11 补充：柜体预览改用独立透明 SubViewport，加入实模型像素 Alpha 检查，柜外背景和 0% 隐藏后的柜体中心 Alpha 均为 0，100% 柜体中心为不透明；增加 `%TEMP%/cabinet-opacity-hidden.png`。此前预览采用普通桌面背景，其灰黑底不能用作 MR 验收依据。执行 `--path F:/GodotSpace/GodotSpace --xr-mode off --script res://Assets/ARSpace/Scripts/UI/cabinet_display_self_test.gd` 退出 0，新增断言通过，仍有上述 SubViewport/退出清理日志。

11 月 12 日截图及现场反馈更新：天上端柜体调至 0% 后肉眼黑区仍存在，但 PICO 内部截图没有记录该黑区；别处能看到现实。此前日志确认 `local_sky`、PICO XR Runtime 1.1.46、Forward+、alpha blend 与双眼 encoded-alpha compositor 已启用。日志中的“MR 透传: 已关闭”发生在退出清理阶段，不据此判断运行期间透视失败。**黑区根因仍未确认，内部截图及桌面 GPU Alpha 测试不能代替头显最终合成验收**。此次修复有证据的柜体排序、动画部件范围及箭头光晕/透明平面深度问题，没有凭推测改写整个 PICO 合成公式。复测仍黑时，在「显示设置」中将「物体 / 文字」和「地板 / 后墙」也调至 0% 作对照（记录原值，测试后恢复，不保存为默认），记录黑区是否变化；如能用手机透过镜片拍摄，才可记录截图未包含的最终显示层。

新增材质渲染回归构造“同一网格前方红色小零件、后方白面板”并验证旧 Alpha 混合会覆盖前方零件；修正后的红色细节像素在 100/99/71/0% 分别为 5184/5124/3704/0。原始两种箭头在 GPU 上的光晕像素分别为 12865、15967，适配后均为 0，箭头实体轮廓保留。测试使用实际 WorkEffect prefab 与原始贴图；图片输出到 `%TEMP%/M_Arrow.material-clean.png`、`M_Arrow_L.material-clean.png`。

上述 5184/5124/3704/0 为已撤销的抖动版本结果。平滑版本增加逐像素 Alpha 验证：100/99/71/25/0% 时内部像素分别接近 1/0.99/0.71/0.25/0，前方红色细节像素为 5184/5184/5184/5184/0，不再以随机丢弃像素淡化。验证还覆盖前后透明 UI、不透明前景、移动透视相机、窗口尺寸改变、双眼非对称投影及右眼着色路径。实柜 100% 与原始材质的 RGB 平均差为 0.003295；实柜 71% 预览在 `%TEMP%/cabinet-opacity-71.png`，15% 预览在 `cabinet-opacity-faded.png`，0% 柜外和柜体中心 Alpha 均为 0。实际头显黑区仍单独追踪，不据此宣称已解决。

平滑版本本轮验证：显示自检、材质渲染自检、Sky 透明度渲染自检、资源导入均退出 0；材质与 Sky 渲染测试无 ERROR，显示测试及导入保留既有清理日志。重新启动一台 Server 和两台 `--testmode` Client，三者退出 0、StartMenu → ARSpace 断言通过；其中一台 Client 再次出现 `RootNode3D/1`、`RootNode3D/ReconstructionPipeline` 缺失和 RPC 缓存报错，因此多人日志检查未通过，不能将断言通过当成完整联机验收。未扩展修改网络模块。新增脚本、着色器的 UID 由指定 Godot 导入生成，`git diff --check` 通过。

本轮执行上述显示自检、新材质渲染自检、Sky 透明度渲染自检与 `--headless --import` 均返回 0；新材质及 Sky 渲染测试无 ERROR。显示自检仍有既有 SubViewport/退出清理日志，导入仍有已知 progress-dialog/tasks/ObjectDB 清理日志，无脚本解析、资源缺失或 GDExtension 加载错误。另按下述命令启动一台 Server 与两台 `--testmode` Client，三个进程均返回 0，StartMenu → ARSpace 断言通过；本轮未见 RPC 路径错误，但 Server 出现 `voice_chat_ui.gd:526` 的 `has_multiplayer_peer` 空引用，三端有 headless dummy renderer/SubViewport 日志，不能声称整场景日志无错误。未修改这段语音 UI；真实头显、手柄和黑区仍需设备复测。`git diff --check` 通过。

2026-11-09：显示自检、Sky 透明度渲染自检、`runtime_mode_integration_self_test.gd`、`spatial_window_self_test.gd`、`astronaut_view_source_self_test.gd`、`pico_cast_control_self_test.gd` 均退出 0，断言通过。资源导入退出 0，无脚本解析、资源缺失、autoload 或 GDExtension 加载错误；仍有 progress-dialog/tasks、RID/ObjectDB/resource/PagedAllocator 清理日志。显示自检也有既有 SubViewport 坐标提示和退出资源清理日志，不能宣称日志完全无错误。

全部 7 项 LLM 离线自检均获得通过结果：其中语音面板测试首次使用窗口模式发生 ASR 就绪断言失败，按 AGENTS.md 改用 `--headless` 后退出 0 并通过。该模式差异已记录，不视为真实语音设备验收。其余 6 项在窗口模式通过。不执行在线模型请求或主工程导出。

主场景回归使用 `cabinet_scene_self_test.gd`：Server 附加 `--voice-role=server --hold-server`，两个 Client 分别附加 `--testmode --voice-role=client --server-ip=127.0.0.1 --no-cabinet-receiver --hold-client`。已检查 StartMenu → ARSpace、原步骤动画接口、滑条接入、柜体隐藏及退出。三进程断言及退出码均通过；日志仍有已有 SubViewport/dummy renderer 提示，其中一台 Client 出现 `RootNode3D/1` 缺失导致的 RPC 缓存错误，**完整多人日志检查未通过**，需另行复核玩家生命周期。独立空间窗口 ENet 回归通过。

## 真机验收（尚未执行）

最新用户确认：局部变黑截图来自电脑镜像，头显转头看别处仍能看到现实。电脑镜像不包含头显端合成的真实房间，截图的空白黑底不能用来判断头显 Alpha；MR 空白处应透视，不需要在远处补一层模型。最新会话日志仍显示 alpha blend、Forward+、PICO 双眼 Alpha 处理已启用，但这不能证明每个局部像素都正确。

「显示设置 → 透视检查」现在打开三个对照选项：「空画面」「隐藏柜体组」「仅柜体组」。各持续 5 秒，自动恢复原图层及显隐；跟踪、网络、碰撞、动画继续运行，不修改材质、透明度偏好或磁盘配置。退出或删除检查节点时也恢复，独立辅助视口不受影响。空画面已由用户确认黑区消失，下一次请保持头部朝向和滑条值一致，分别观察后两项，记录黑区是否存在。仅柜体组期间菜单也临时隐藏，等待 5 秒即可恢复。若隐藏柜体组后黑区消失且仅柜体组时出现，优先检查柜体组绘制及对应合成；若结果相反，转查周围场景；若两项均无黑区，需查两组叠加，不能直接归因于单个模型。

1. 按 AGENTS.md 的串流拓扑启动 PC Server、天上端 MR 和地面端 VR。分别从主菜单进入协作空间，确认柜体右下角滑条在柜体正面、射线可点击。
2. 天上端依次拖至 100%、99%、71%、50%、0%、100%，复查表面连续平滑变淡、无密集颗粒，小零件没有在 99% 突然被后方柜板盖掉。0% 固定柜壳消失，拆装挡板、核心与当前步骤需要显示的部件仍不透明，滑条始终可操作；另一端柜体不受影响。隐藏时播放/切换拆装动画、添加标注、开启/取消部件高亮，指导内容应保持显示。分别观察绿色直箭头和红色弯箭头在柜壳显示与隐藏时均无宽大半透明光圈；圆形定位标记保留。切换旧全场景透明度时，独立柜体和指导内容不应变化。黑区按上文镜片画面单独验收。
3. 将图片、视频、工作指导窗口分别拖到柜前、阴影区、侧面、与柜体相交及柜后。柜前应保持颜色亮度；柜后允许正常遮挡，不能用其判断“变黑”。观察双眼一致性、射线点击、拖动与滚动。
4. 播放实际第一视角投屏，对照开关并调强度，使柜体边线和圆形部件更自然；确认视频比例不随窗口缩放改变。连续播放 2–3 分钟，关闭重开、断开重连，检查帧率、边缘视野、参数恢复和异常黑屏。
5. 反复退出/重连两端，检查玩家重复/残留与 RPC 日志。当前自动化观察到的玩家路径错误需要一起复核；不能把无头测试替代真实头手位姿、MR 透视及输入验收。
