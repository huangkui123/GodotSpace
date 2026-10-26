# 大实验柜半自动空间标定

> 2026-10-21：产品入口已切换为默认 1:1 的 **CAD 自动视觉识别**，无需人工角点。操作与部署见 [CAD 自动视觉标定](cabinet_visual_runtime.md)。以下四角/手动流程作为历史实现及回归记录保留，不再是默认头显界面。

适用条件：PICO 4 Ultra Enterprise、一个在实物旁的天上端 XR Client、精度要求较宽松。场景中常驻一个长方体柜子，标定时测出实物柜体位姿，确认后整体对齐虚拟世界。提供人工四角定位和手动定位线框；不包含柜体自动识别、训练模型或实测厘米级精度承诺。

## 固定柜体与整体空间对齐

`ARSpace/SharedSpaceOrigin/CalibrationCabinet` 引用 `Prefabs/CalibrationCabinet.tscn`。当前默认宽 0.45 米、高 1.21 米、深 0.80 米（旧版本为 0.40 / 0.56 / 0.50 米），底面在共享地面 `Y=0`，正面距天上端初始位置约 2 米。柜体原点是正面左下角；尺寸可以随实测宽高深调整，柜体在虚拟场景中的位置与朝向保持固定。

计算时，橙色线框表示实物测量位置。点击「确认并对齐整个场景」后，来源头显通过 XR 原点更新整个虚拟世界相对现实的映射：`新 XR 原点 = 固定柜体位姿 × 实测柜体位姿的逆 × 旧 XR 原点`。这是整体场景相对真实跟踪空间的刚体变换；不独立移动柜子，不修改头部的局部跟踪高度，不缩放世界。地板、墙面、家具与柜体的相对关系保持不变。PC 和其他 Client 保持统一的虚拟场景坐标，来源头显的头手位姿按新映射正常同步。

天上端在本机应用成功后立即显示已确认，不向地面 Server 请求确认。应用阶段暂缓取景和头姿跳变检测，避免把主动对齐当成追踪异常。离线模拟与快照回放不会改变 XR 原点。清除标定只清除记录/线框，保留当前空间映射与固定柜体；重新标定以当前坐标为输入，系统重新定位或重启则重新建立初始映射。

## 启动与入口

继续使用当前 Godot 程序直接串流运行，不需要导出主工程。

```powershell
$Project = 'F:\GodotSpace\GodotSpace'
$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'
& $Godot --path $Project -- --voice-role=server
# 在另一进程/串流环境启动天上端：
& $Godot --path $Project --xr-mode on -- --xr-client --voice-role=client --server-ip=<SERVER_IP>
```

在启动菜单进入 ARSpace。佩戴头显，按右手柄 A 打开主面板，切到工作页，点击「柜体标定」卡片。地面 Server 和地面 VR 均无柜体标定控制器、收帧端口或操作入口。

标定面板首次打开位于主面板右侧；射线指向面板并按住侧握键即可拖动，松开后固定。拖动不会选四角或改变空间标定。关闭后再次打开会保留拖动位置；标题栏可放大/还原。重新定位或应用世界对齐后，会把可见面板移回主面板旁，避免面板落在身后。快照操作位于「工具」页签，预览与确认按钮位于底部。显示设置在主面板内容区打开，通过左上角返回工作页。

柜体标定的取图、头姿、四角输入、相机参数解析、求解、微调、确认、清除和重新定位失效处理全部属于天上端本机。没有柜体标定 RPC、Server 状态副本、网络头姿或回执等待。多人会话仍按原有方式连接 Server 进入场景，但标定算法与操作不依赖 Server 的计算或代操作。

Windows 串流模式下，「天上端」指运行 XR Client 的进程，它仍在电脑上运行。PICO Helper 直接向该电脑的 **8789/TCP** 发图；若 Server 与 XR Client 在同一电脑，IP 相同而端口不同。既有地面单点标注/实时重建继续使用 **8787/TCP**，不作为柜体标定的中转。Helper 已支持填写端口，迁移不要求重装 Helper，也没有改变 PSA2/PAA1 二进制协议。

## 现场调整头显显示

佩戴头显，在天上端主面板的工作页点击「显示设置」卡片。如果主面板未显示，先按右手柄 A 键打开。用手柄射线点击滑块或两侧的「− / +」按钮：

- 「物体 / 文字」：调整柜体线框、普通虚拟物体与 3D 文字。默认 50%。
- 「窗口面板」：单独调整其他使用 ViewportTexture 的虚拟窗口。默认 80%。主面板保持清晰，避免调到 0% 后找不到设置入口。
- 「地板 / 后墙」：单独调整虚拟地板和后墙。默认 25%。
- 「清晰模式」：物体和窗口调为 100%，地板和后墙保持 25%；「恢复默认」恢复上述初值。

滑块越高，虚拟内容越实；越低，越容易透过它看现实环境。可先把物体调到 80%～100%、面板调到 100%，再根据现场背景调整。它控制应用虚拟内容的不透明度，保留素材自身的透明区域；不是 PICO 相机曝光或整幅现实画面的亮度开关。在当前 alpha blend 透传链路上生效，最终观感需佩戴头显确认。

透明度只影响本地天上端，不清除标定、不改变尺寸和位姿，不同步给 PC 或其他头显。显示设置在天上端主面板，柜体标定面板不提供这些控件。柜体操作面板始终保持可读，不随虚拟物体或其他窗口的不透明度一起淡出。

调整好后点击「保存为默认」，将透明度保存在本机 `user://sky_view_preferences.cfg`；下次进入天上端自动应用。更新代码后需重启 XR Client，运行中的旧进程不会出现新增控件。

### 低不透明度的遮挡修复

2026-10-15 检查实际主场景，55 个独立基础材质中有 25 个继承了导入资源的 `DEPTH_DRAW_ALWAYS`，包括柜体、地板和后墙。仅改变 alpha 会让这些接近透明的表面继续写入深度，导致后绘制的半透明表面出现缺口；[Godot 深度模式说明](https://docs.godotengine.org/en/4.4/classes/class_basematerial3d.html#enum-basematerial3d-depthdrawmode)明确描述了这种遮挡行为。

`XR_Main.gd` 现在对天上端渐隐材质副本禁用深度写入，保留深度测试；原本不透明的模型在 100% 时恢复实体渲染，避免破坏自身遮挡。原始材质、PC Server 和地面 VR 显示不修改。

实际 Mobile 渲染回归使用柜体原始材质构造前后半透明表面：修复前 0%、1%、5%、10% 均错误遮挡后方，修复后通过，并确认前方实体仍正确遮挡半透明物体。测试命令如下；这是 GPU 渲染回归，需窗口渲染，不能加 `--headless`：

```powershell
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/XR/sky_transparency_render_self_test.gd'
& $Godot --headless --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/runtime_mode_integration_self_test.gd'
```

真机复核：重启 XR Client，分别测试 0%、1%、5%、10% 和 100%，缓慢转头观察柜体边缘、地板和窗口重叠处。预期接近透明时不再因残留深度遮挡产生破碎斑点，100% 模型仍有正常的实体遮挡。头显串流最终观感需与上述离线渲染结果分开确认。

### 低不透明度的渲染精度修复

2026-10-15 佩戴者反馈：上述深度写入修复后，低不透明度仍有闪烁。继续使用同一个指定 Godot 构建、RTX 4060 和同一柜体材质做像素读取，确认另一个独立问题：Mobile 的中间颜色缓冲只有 2 位 alpha。此前的遮挡回归只比较前后表面是否被挡住，没有检查最终 alpha 是否接近输入值，因此不能覆盖这个问题。

| 材质不透明度 | Mobile 最终 alpha | Forward+ 最终 alpha |
| --- | --- | --- |
| 1% | 0% | 0.78% |
| 5% | 0% | 5.10% |
| 10% | 0% | 9.80% |
| 20% | 33.33% | 20.00% |
| 50% | 33.33% | 49.80% |

数值来自透明背景、无光照纯色表面中心像素；最终读回图像为 RGBA8，所以 Forward+ 仍有正常的 8 位量化误差。Mobile 在低 alpha 已归零时 RGB 仍非零，且连续变化跨越阈值时 alpha 会突然跳变，不能正确表示 MR 合成需要的透明度。[Godot 4.4 渲染架构文档](https://docs.godotengine.org/en/4.4/contributing/development/core_and_modules/internal_rendering_architecture.html)说明 Mobile 使用 R10G10B10A2，Forward+ 使用 RGBA16F；[对应源码](https://github.com/godotengine/godot/blob/4.4-stable/servers/rendering/renderer_rd/forward_mobile/render_forward_mobile.cpp)的 `_render_buffers_get_color_format()` 返回 `A2B10G10R10_UNORM_PACK32`。当前定制构建即使打开 `use_hdr_2d`，实测仍丢失 3D 中间 alpha，不能仅开启这个选项解决。

`project.godot` 增加 `renderer/rendering_method.windows="forward_plus"`，Windows 的 PC Server 和串流 XR Client 在启动时选用 Forward+，其他平台保留原来的 Mobile 设置。仍使用原有 Godot 可执行程序，无引擎升级、导出或第三方插件修改。`XR_Main.gd` 首次配置透传时打印 `MR rendering method = forward_plus`，用于排除命令行覆盖渲染器或旧进程未重启的情况。不要给串流启动命令附加 `--rendering-method mobile`。Forward+ 的显存/渲染开销可能较高，实际头显的帧率和延迟需一并观察。

增强后的 `sky_transparency_render_self_test.gd` 检查 0/1/2/5/10/15/20/33/50/80/100% 的绝对 alpha、移动相机后的表面内部 alpha、15%～22% 连续变化以及原有透明遮挡。使用上述默认测试命令通过；加 `--rendering-method mobile` 可复现失败。窗口渲染的显示设置测试和无头运行模式测试也通过；资源导入没有解析、资源缺失、autoload 或 GDExtension 加载错误，保留已知退出阶段日志。

完整 StartMenu → ARSpace 已以 Forward+ 跑过一台 Server 和两个桌面测试 Client，连接成功并切换过低透明度材质；完整场景仍有既有 SubViewport/空材质日志，测试进程关闭时也记录了网络断开/RPC 提示，因此不把它记作无错误的完整网络回归。PICO XR Runtime 1.1.46 的 Forward+ 初始化已成功，交换链格式为 `VK_FORMAT_R8G8B8A8_SRGB`；诊断还记录了 Vulkan layer manifest 查找错误和 OpenXR 退出 RID 提示，未阻止初始化。上述结果能确认 Godot 内部精度缺陷已消除，不能单独证明串流后的粒子闪烁全部消失。

实机对照步骤：重启 Windows XR Client，在启动日志确认 Forward+，进入场景后将「物体/文字」和「地板/后墙」设为 5%，窗口面板保留清晰值；静止观察并缓慢左右转头，再比较 1%、10% 和 100%。分别观察柜体表面、轮廓、相互重叠处以及透传背景，确认闪烁、帧率、射线点击和初始高度。若仍有闪烁，下一步需对比应用眼图与头显录屏，区分透明排序/纹理采样和 PICO 合成/编码问题，不能把剩余现象都归因于 alpha 精度。

### PICO 串流低透明度白光修复

同日真机反馈确认 Forward+ 下闪烁消失，但虚拟物体的位置出现刺眼白光，PICO 截图却显示透明；0% 时白光消失，低百分比时出现。另启动不含场景灯光的双列 A/B 诊断，分别显示 5%、10%、25% 白块：A 使用原有线性空间预乘，B 改为在编码颜色空间预乘。两列 alpha 相同，佩戴者明确确认「B 明显正常，A 仍刺眼」。这是当前 PICO Windows 串流路径的兼容性证据，不把 B 当成所有 OpenXR 运行时应使用的通用公式，也不凭截图断言厂商内部的具体故障环节。

新增 `XR/pico_streaming_alpha_effect.gd`，通过 [Godot CompositorEffect](https://docs.godotengine.org/en/4.4/tutorials/rendering/compositor.html) 在全部透明物体完成混合后，对最终眼图进行转换：解除线性 RGB 的预乘 → 转成 sRGB → 按 alpha 预乘 → 转回线性以抵消随后引擎的一次 sRGB 编码。保留 alpha，0% 的 RGB 清零，100% 的像素不处理。采用一次完整画面转换，避免逐个物体调暗或在多个透明层之间重复转换。

仅当 Windows、Forward+、天上端 MR、运行时名为 `PICO XR Runtime` 且项目设置 `arspace/xr/pico_streaming_encoded_alpha=true` 时，挂到本地 `XRCamera3D.compositor`。其他运行时、PC Server、地面 VR 及 UI 自己的 SubViewport 不挂此效果。相机替换、退出透传、回退桌面和场景退出时恢复原 compositor；已有其他效果通过副本保留。当前场景使用线性 tonemapper、单位曝光；若今后更改曝光、tonemapper 或 PICO 串流版本，应重新检查这个设备适配，可关闭该项目设置进行对照。

像素回归还覆盖白色/彩色在 0/1/5/10/50/100% 下的 RGB 与 alpha、GPU 效果销毁后重建，以及相机 compositor 清理时保留其他所有者的替换。默认渲染测试、运行模式测试均通过。完整 PICO 场景已记录 `PICO encoded-alpha compositor active: views=2`，确认双眼均执行；静止调节完成后采样约 89～91 FPS，滑块改变材质期间曾降到 31～73 FPS，不能把稳定值当作全程最低帧率。完整场景仍有 SubViewport 层级、初始连接 RPC、立体对象拾取日志，未作为本次颜色修复范围。

完整场景实机验收已完成：PICO 4 Ultra Enterprise、系统 5.15.7、Windows PICO XR Runtime 1.1.46、指定 Godot 构建与 RTX 4060。佩戴者操作三个显示滑块后，针对「低不透明度下刺眼白光和闪烁是否都消失、主面板文字和原来视点高度是否正常」明确回复「都正常了」。截图与直视曾存在差异，因此本次最终观感结论以这次佩戴者反馈为准。临时 A/B 图和测试启动器位于开发机临时目录，不加入正式场景，也不保存覆盖用户显示偏好。

## 初始视点高度与真机检查

`project.godot` 的 `xr/openxr/reference_space` 使用 `1`（Stage）。当前指定引擎的枚举顺序是 Local、Stage、Local Floor；`2` 不是 Stage。开发机 PICO XR Runtime 1.1.46 实际提供 View、Local、Stage，原来的 Local Floor 会进入引擎模拟路径。本项目以地面为共享空间基准，因此直接使用设备提供的 Stage；水平位置和朝向仍由角色锚点对齐。Godot 的 [Local Floor 模拟实现](https://github.com/godotengine/godot/blob/4.4-stable/modules/openxr/openxr_api.cpp)也依赖 Stage 与 Local，这次修改去除了该兼容路径，但不能仅据此断言佩戴时高度异常的全部原因。

初始对齐等待高置信度头部跟踪。虚拟视点高度等于角色锚点地面高度加设备测得的头高，不添加固定身高，也不存储手工高度补偿。对齐时输出一条 `[SharedSpaceAlignment]` 日志，包含参考空间、世界缩放、地面、头部局部高度、原点高度与最终视点高度。

真机检查：

1. 连接 PICO 串流，重启 XR Client，按通常坐姿或站姿进入场景。
2. 检查虚拟地面与实际地面的高度关系，缓慢下蹲再恢复；视点应等量移动，头和双手保持相对位置。
3. 检查日志：当前场景应为 `reference_space=1`、`world_scale=1.000`、`floor_y=0.000`、`origin_y=0.000`，`world_head_y` 应与 `tracked_head_y` 一致，而非强制设为某个固定身高。
4. 在天上端主面板打开「显示设置」，调整三个滑块，关闭再打开，保存默认后重启验证。PC Server 的显示不应跟着变淡。

若视点仍然偏高，需要继续对比设备上报高度与实际眼睛离地高度，不能用升降按钮掩盖差值。

2026-10-15 已用实际 PC Server + PICO XR Client 串流运行约一分钟：初始设备头高和最终视点均为约 1.61 米，随后随佩戴者移动等量变化，跟踪原点 Y 始终为 0。佩戴者确认「高度正常了」「现在高度对了」。这是当前设备/会话的验证结果，不把 Local Floor 兼容路径本身判定为所有设备上的故障。

本次还运行了资源导入、`shared_space_alignment_self_test.gd`、`runtime_mode_integration_self_test.gd`、`XR/sky_display_settings_self_test.gd`、柜体窗口/网络测试和 StartMenu → ARSpace 测试；均使用仓库指定 Godot 构建。显示设置窗口经实际渲染检查。导入仍有已知退出阶段日志，完整场景仍有 SubViewport/空材质及定制引擎 Vulkan 缓存、OpenXR 退出 RID 提示；这些未作为本次修复范围。连接尚未完成时收到重定位事件不再发送柜体 RPC。

## 没有实物时

1. 打开头显内柜体面板，切换「模拟柜体（离线）」。示例尺寸为 0.40 × 0.56 × 0.50 米。
2. 点击标有「正面」的白色四边形，顺序为左上、右上、右下、左下。
3. 点击「计算并预览柜体」。检查绿色投影与输入图形重合；尝试撤销、重选、改变尺寸和微调。
4. 点击「保存快照」，然后「打开最近快照」重新求解。快照始终是离线状态，确认按钮禁用，不会改变本地 XR 原点。

模拟只能验证软件、投影、输入映射和求解，不能代表真实相机精度。有头显时建议先用已测量的纸箱或普通柜子验证真实链路。

## 现场方式一：手动放置（最少前提）

1. 先完成头显串流和共享空间初始对齐。保持本次会话中原点不变。
2. 输入实测宽、高、深，单位为米。可以「保存尺寸为默认值」。
3. 在实时模式点击「在头显前方放置」。不需要 Helper 图像或相机标定参数。
4. 线框柜体出现在头显前约 2 米。佩戴者在「微调」页用手柄点击加减按钮，调整左右 X、上下 Y、前后 Z，以及偏航、俯仰、侧倾。
5. 从正面与侧面检查橙色线框及柜体深度，再点击「确认并对齐整个场景」。头显应用后，固定长方体与实物重合，并显示绿色确认轮廓。

偏移沿初始柜体坐标轴，旋转绕正面左下角。输入尺寸后再开始放置；修改尺寸会清除旧结果，需要重新放置或求解。只有本地天上端可以修改或确认标定。尺寸、快照和标定状态均保存在本机，不上传给地面端。

## 现场方式二：透传四角定位

1. 启动 PICO Spatial Anchor Helper，接收目标设为运行天上端 XR Client 的电脑 IP 和端口 `8789`；面板顶部显示可用地址及连接状态。使用已校正的左眼或右眼单眼图像；当前不支持 raw、双眼拼接、交错画面。
2. 输入柜体实际宽高深，尽量让柜体正面完整占据画面。
3. 用手柄点击「3 秒后冻结」，看向柜体正面并静止约 1.5 秒；也可直接点击「冻结 / 重新取景」。系统检查新鲜图像、本地 XRCamera 高置信度跟踪及近期头部稳定性。既不使用桌面观察相机，也不使用网络插值头姿。
4. 按提示点击正面左上、右上、右下、左下。深度向这个正面的背后延伸。
5. 「计算并预览柜体」，再从不同观察位置检查、微调、确认。
6. 保存这次冻结图像和选点快照，供回来后复现问题。

相机内参来自该帧 metadata，必须对应解码图像的实际分辨率。可以输入经过确认的手动内参 `fx/fy/cx/cy`。Helper 当前可能根据配置的 FOV 推导内参，因此返回参数不等于经过实测的精确校准。

默认「PICO 4 Ultra：设备外参」使用该帧对应的左右相机外参，组合冻结时本地 XRCamera 头姿。Helper 根据官方 SDK 的参考系转换生成相机到头部的变换，Godot 再转换相机光学坐标轴；原始 SDK 矩阵不能直接当作 Godot 变换。需要更新头显 Helper 后重新取景。缺少参数、读取失败或图像模式不匹配时明确报错，不会自动退回近似值。

「头部近似（需现场微调）」作为手动选项保留。旧的「相机→头部 / 取逆」选项已移除，对应快照拒绝直接回放，需重新取景。去畸变画面默认 FOV 由猜测的 90° / 73.74° 改为官方 SDK 的 76.35° / 61.05°；它仍是输出投影模型，并非逐设备实测内参。来源、公式、适用范围及真机检查见 [相机参数说明](camera_model.md)。

本版通过静止取景降低 Helper 图像传输延迟误差；时钟最小到达延迟估计不是曝光级同步。移动中标定不属于本版支持范围。显示的 px 误差仅表示四点重投影拟合程度，不能当作实测厘米误差；平面目标仍可能存在位姿歧义。

## 生命周期与快照

- `preview → confirmed` 在天上端本地完成。预览不改变 XR 原点；确认成功只应用一次整体变换，没有远程确认状态或其他头显误用本机空间映射的问题。
- 「清除标定」删除测量线框及标定记录，保留固定长方体和当前 XR 映射。关闭面板保留当前预览/确认状态，重新打开时保留用户拖动后的位置。
- 本地头部跟踪丢失超过 2 秒、明显位置跳变、共享空间重新对齐或 OpenXR `pose_recentered`，会使现场标定失效并隐藏柜体。Helper 断连会使冻结帧过期，但不撤销已成功应用的对齐。退出/重新进入场景会建立新标定会话。
- 若设备重定位没有发出信号，且变化较小，仍可能无法自动发现。佩戴者发现偏差或使用系统重新定位后应主动清除并重标定。不能承诺覆盖所有设备内部失跟状态。
- 重启后仅从 `user://cabinet_calibration.cfg` 恢复尺寸，不恢复世界变换。
- 「保存快照」手动保存单次冻结图像、图像尺寸、原始 metadata、头姿、选点、内参覆盖和结果到本机 `user://cabinet_snapshots/cabinet_<时间>.json`。它不是连续视频录制。文件可能包含现场图像，保存在天上端进程的用户目录，不纳入仓库。
- 回放只用于重新计算与分析，不能将上次会话的世界位姿发布到当前头显。微调后的结果保存在 `result`，重新求解会从原始角点重新开始。

## 实现与验证

- `cabinet_geometry.gd`：矩形平面单应初始化、刚体六参数重投影优化、参数与几何校验；输出模型到 Godot 相机的变换。固定尺寸，不做自由尺度配准。
- `cabinet_calibration.gd`：Sky 独占的收帧器、本地头姿、静止取景、柜体显示、整体空间变换和本地生命周期。
- `cabinet_calibration_window.gd` / `cabinet_image_view.gd`：头显内 Control 面板、离线模拟、快照回放；沿用历史文件名，不再创建桌面 Window。
- `cabinet_panel_surface.gd`：将本地手柄射线映射成 SubViewport 像素输入，无输入 RPC。
- `XR_Main.gd` 仅在 Sky XR / Sky testmode 创建 `CabinetCalibration`；主面板脚本提供入口。地面端只保留原有固定柜体场景资源和与柜体无关的单点标注/重建功能。

```powershell
& $Godot --headless --path $Project --import
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_geometry_self_test.gd'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_calibration_self_test.gd'
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_scene_self_test.gd' -- --voice-role=server
# 已有 Server 时，另测天上端入口：
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_scene_self_test.gd' -- --testmode --voice-role=client --server-ip=127.0.0.1
```

最后一个测试使用真实启动菜单到 ARSpace 的路径，并监听项目常用端口；运行前关闭同端口的测试 Server。测试禁用本地 AI 服务启动。

固定长方体的 UI/网络和场景检查使用实际窗口渲染器。此定制引擎的 headless dummy 渲染器在实例化/更新 BoxMesh 时打印 `mesh_get_surface_count: Parameter m is null`；逻辑断言可通过，但有这些错误的 headless 执行不作为渲染验证通过。窗口运行检查柜体固定、整体变换顺序、重复应用幂等、本地头姿、无 Server 完成标定、真实 TCP 半包/ACK/重连和射线选四角。

现场验收至少包括：纸箱/实柜手动放置；冻结图像四角定位；正面和侧面独立检查点；持续观察；Helper 断开与恢复；头显断线重连；共享空间重新对齐；清除与再次标定。预期是柜体固定在现场位置、生命周期操作一致，失效后明确要求重标定。真实 PICO 的透传、显示、相机内外参和最终误差必须现场确认。

### 2026-10-14 开发机验证记录

指定 Godot 构建上通过了 60 组精确/带噪声位姿测试、窗口点选/快照回放、Server + 两个本机 ENet Client 的同步及生命周期测试、现有共享空间对齐自检、真实 StartMenu → ARSpace → 柜体窗口 → 退出路径。另以工程默认渲染器检查了实际窗口布局。

资源导入仍出现仓库已知的退出阶段 progress dialog / ObjectDB 清理信息。完整 ARSpace 场景还会打印 SubViewport 层级与空材质错误；通过在内存中换回 Git HEAD 的原始 XR_Main 和标定面板脚本做对照，确认这些消息在没有本功能时也出现。独立柜体窗口渲染测试没有这些消息。以上不代替真实头显与实柜验收。


### 2026-10-15 天上端迁移验证

独立本地标定测试实际通过了 VR Surface 射线 → SubViewport → 图像像素四角输入、模拟/快照/设备外参、真实 TCP 半包收帧及 PAA1 ACK、Helper 重连、本地 XRCamera 取姿、没有游戏 Server 时确认整体对齐、重复应用保护和重新定位失效。几何 60 组测试、相机模型、共享接收器协议、共享空间高度和运行模式自检通过。资源导入退出码 0，无解析/资源缺失错误，仍有已知 progress dialog / ObjectDB 退出日志。

实际 StartMenu → ARSpace 的 Sky testmode 入口、独占控制器、面板关闭及清理断言通过。完整场景仍有既有 SubViewport、初始连接/退出期间节点未就绪 RPC 消息；独立 VR 面板也会打印一次复用 SubViewport 的 screen-transform 提示。这些消息单独记录，不作为实际头显操作验收结果。用户已确认迁移后的功能检查没有问题；以下 UI 调整需单独检查真机操作体验。


### 2026-10-15 显示设置与标定 UI 优化

入口移入工作页卡片区，复用原有卡片底图；显示设置在主面板内容区展开。两部分共用 `UI/sky_panel_style.gd` 配色与控件主题。标定窗口使用 `cabinet_panel_window.gd` 复用已有窗口拖动逻辑，保持本地 scope，禁止共享停靠与 Server 状态管理。窗口首次在主面板右侧打开；重新定位后若主面板太远或在身后，则回到本地视点前方。

本轮执行并通过：资源导入、显示设置布局/透明度/持久化/角色隔离回归、标定及模拟 XR 拖动回归、仓库要求的 7 项 LLM 离线自检、`git diff --check`。标定测试覆盖原生 XRControllerTracker 侧握键事件、控制器移动、松手、关闭清理、重开保持位置、放大还原、拖动不选四角且不改变 XR 原点/柜体/标定 epoch。实际渲染截图检查了工作页、显示设置和标定全部四个页签，均位于对应视口范围内。资源导入的既有退出清理日志、独立标定的 SubViewport screen-transform 提示仍单独保留记录。

以下为本轮两个直接相关的验证命令（使用上面的 `$Godot`、`$Project`）：

```powershell
& $Godot --path $Project --xr-mode off --position -32000,-32000 --script 'res://Assets/ARSpace/Scripts/XR/sky_display_settings_self_test.gd' -- --capture-ui
& $Godot --path $Project --xr-mode off --position -32000,-32000 --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_calibration_self_test.gd' -- --capture-ui
```

按用户要求没有启动 PC Server / XR Client。真机验收由用户自行启动：进入主面板工作页，确认两张卡片及显示设置滑块可点击；打开柜体标定应位于主面板右侧，侧握键拖动后松开固定；关闭再打开应保留位置，放大/还原不跳位，拖动不增加角点。随后照原流程完成一次四角预览和确认，检查世界对齐仍正常。真机字体大小、舒适距离和手柄手感尚未由本轮自动化确认。
