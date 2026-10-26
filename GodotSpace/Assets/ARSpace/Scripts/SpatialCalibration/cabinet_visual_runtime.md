# CAD / 自定义柜体自动视觉标定

头显「工作页 → 柜体标定」提供 **真实 CAD 模型**和**自定义长方体柜体**两种自动视觉模式。前者使用 `.magics` 装配模型的合成特征与 RGB SIFT/PnP；后者自动提取可见柜面及长边，把不同视角投影到同一个世界空间，联合拟合输入尺寸的长方体；完整轮廓仅作为一种初始线索。两种模式都不要求人工角点、检测框、标签或深度。**识别器仍为实验性基线，未完成实柜识别覆盖率及精度验收。** 多帧一致不等于物理精度已验证，成功后仍需检查预览并点击「应用对齐」。

## 操作

1. 使用仓库 `Start-GodotSpace.cmd` 进入天上端；USB Helper 继续把单眼相机图像送到本机 `8789`，无须改变串流流程。
2. 右手柄 A → 工作页 → 柜体标定。在顶部选择柜体类型。真实 CAD 默认 **1:1 原尺寸**，可切换 1:3；自定义柜体以 **厘米**设置宽、高、深，默认 **宽 45、高 121、深 80 cm**，可用射线点击加减按钮或编辑数值。自定义尺寸已经是实际物理尺寸，不再叠加 CAD 缩比。修改尺寸或切换类型会取消正在运行的任务并清除旧预览；旧四角流程保存的尺寸不参与初始化。
3. 看向实柜，点击「开始多视角扫描」。3 秒准备后采集 **12 秒**，每 0.75 秒尝试一个关键帧，最多 16 个。保持柜体不动，自己缓慢向侧面移动，始终让柜体在画面中；**不再要求停稳 1.5 秒**。相机位置变化不足 4 cm 的重复视点跳过，原地转头不能代替平移视角。面板显示剩余时间、视角数和跳过原因。
4. 先通过背景图像特征核对图像与头姿的对应关系，再进行识别。自定义柜体使用多视角联合拟合：柜面四边形或横边与两条竖边只生成候选，不能单独授权对齐；画面外的边属于未知，不计为错误，各视角可以互补。每个支持视角需观察到至少四条不同的模型边，其中至少两条竖边、两条横边；联合证据需覆盖一个面的四边和另一个面的至少三边，每条边至少获两个视角支持。完整面的四条边还需各自在两个视角达到 85% 可见采样覆盖，且匹配边方向一致，避免将柜门横缝误当顶边、地砖线误当底边。有效视角需跨越 1 秒、相机基线至少 12 cm、观察方向差至少 8°。多个可行位置仍拒绝。真实 CAD 保留 SIFT/PnP 世界位姿一致性检验，也先检查图像与头姿。
5. 从正面、斜前方与侧面检查，再点击「应用对齐」。真实 CAD 使用实际实验柜 `SpaceBox/SpaceBox/dashiyangui/dashiyangui/MeshRenderer` 锚点；自定义模式使用 `SharedSpaceOrigin/CalibrationCabinet` 正面左下角锚点，并按宽高深调整实体长方体。模式切换只改变当前客户端对应柜体的显示，应用时以刚体变换对齐本地 XR 原点，不缩放跟踪空间。

没有实物时，选择任一柜体类型，再切换「合成演练（无实物）」并开始。程序真实渲染相应模型后调用同一个图像识别器，显示识别投影；不会应用到 XR 原点。自定义模式无需 CAD 文件或模板库，可用于具有清晰棱边的真实长方体；真实 CAD 模式仍只匹配对应实验柜。

### 自定义柜体取景要求

柜体应直立，缓慢移动时尽量让正面与侧面可见。柜顶有杂物、一个底角被桌面遮挡时，不再强制每帧都有闭合的六边形轮廓；程序从实际直线段自动生成可见面的候选，再检查多个相机视角下的三维一致性。可以有部分裁切，但整次扫描仍需多个视角提供柜顶、底边和两面边线证据，不能始终只拍柜体中部。候选提取仍可能把门板、桌面或柜体内嵌面当作矩形，因此不可仅根据一张图里的框就宣称定位成功。严重遮挡、仅一个平面、缺少边线、错误尺寸或多目标歧义仍会拒绝。尺寸范围为每轴 5–2000 cm。

无标记长方体在几何上无法区分前后，约定朝相机的宽面为正面；宽深相等时采用较朝向相机的面。跨越对称方向时可能需要重新取景，不能据此识别柜门的语义朝向。画面不能验证输入的绝对尺寸是否真实，必须输入实测值；同比例填错尺寸也会得到错误距离。短时多帧用于一致性检查和姿态融合，不替代物理精度验证。若所有帧都因遮挡、背景混杂或不可见棱边而失败，延长采集也不能保证识别成功。单视角合成演练仅检查基础模型与显示链路；带遮挡的移动多视角由独立回归覆盖。

## 模型与比例

源文件为 `Merge_of_储存版-白色哑光_w2.magics`。使用已解码、配准到 Godot 固定框架坐标的 `artifacts/assembly/printed_assembly.ply`，并核验它、装配报告及特征库的 SHA-256 一致。

旧特征库按 1/3 建立，但这只是离线原型假设，没有实测确认。运行时按 `目标比例 / 模板比例` 同时换算模型三维点及估计平移，旋转和图像投影保持不变；默认目标比例现为用户指定的 1:1。本机模型的 1:1 包围范围约为 X 0.898 m、Y 1.827 m、Z 1.338 m，含装配中的突出/独立部件，不等同于柜体外壳尺寸。原始 Magics 单位解释和候选模型配准仍需实物核验。

确认时只将场景柜体内容调整到指定比例，并保持固定框架锚点位置，再以刚体变换更新本地 XR 原点。不会缩放 XR 世界、玩家移动或头手跟踪。1:1 场景模型保持原尺寸。缩比仅影响当前天上端柜体内容，尚不将尺寸变更同步给其他客户端；多端联合使用请先统一模型尺寸。

## 本机环境

识别按需创建独立 Python 子进程，没有常驻 HTTP 服务，没有远程上传。两种模式都需按 `tools/cabinet_calibration/README.md` 安装 Python 依赖。只有真实 CAD 模式还需要解码模型、执行装配配准及构建模板；自定义模式直接由尺寸生成模型，不检查 CAD artifacts。模型与模板不随 Git 提交。

默认 Python：`%LOCALAPPDATA%/GodotSpace/cabinet-calibration-venv/Scripts/python.exe`。

可在启动 Godot 前设置：

```powershell
$env:GODOTSPACE_CABINET_PYTHON = '<独立环境的 python.exe>'
$env:GODOTSPACE_CABINET_ARTIFACTS = '<含 assembly 和 templates 的 artifacts 目录>'
```

请求和结果临时写入本机 `user://cabinet_visual_jobs/job_<进程>_<时间>/`；完成、取消、超时、退出时清理本次文件。异常断电可能留下临时图像。缓存上限为 16 帧、24 MiB 原始 JPEG（编码后请求上限 36 MiB），逐帧解码避免同时保留全部高分辨率图像。进程最多运行 120 秒，关闭面板会取消正在进行的识别；已完成预览可保留。不会打印相机图像或上传现场数据。

为避免现场失败后失去证据，实时扫描保留到 `user://cabinet_visual_diagnostics/last_scan.json`，并在同级 `last_scan_history/` 中保留最近 **5 次不同请求**，包含原始 JPEG、内参、头姿历史、模式/尺寸和识别结果。Python 在开始分析及返回结果时原子写入，同一请求更新同一历史文件，超时仍可重放 `processing` 输入。历史文件名由请求 ID 哈希生成；超过 5 次时只清理本工具拥有的旧历史 JSON，保留独立的最新记录。首次升级会归档尚存的上一段扫描。合成演练与离线重放不覆盖或增加历史，不上传数据。可用 `GODOTSPACE_CABINET_DIAGNOSTIC_PATH` 指定保存文件，对应历史目录为 `<文件名不含扩展名>_history/`；自动化测试必须使用临时目录，避免覆盖现场记录。日志记录请求 ID、拒绝原因和保存位置，不打印图像内容。

离线重放不需要重新戴头显，也不改变场景：

```powershell
& $Python -B "$Project/tools/cabinet_calibration/visual_pose_worker.py" `
    --replay "$env:APPDATA/Godot/app_userdata/GodotSpace/cabinet_visual_diagnostics/last_scan.json" `
    --output "$env:TEMP/cabinet-replay-result.json" `
    --artifacts "$Project/tools/cabinet_calibration/artifacts"
```

联合拟合的 `multiview_fit.diagnostics` 记录候选数量、每次优化的位姿、各视角边线可见率/覆盖率、局部竖边端点覆盖、支持视角及各面的重复边线数/已观测端点数；这些被拒绝的位姿只是排障数据，不能用于对齐。诊断视角编号按 `input_frame_indices` 映射回原始请求。

旧四角实现仍保留用于回归测试，但产品默认入口不显示人工选点控件。旧尺寸、四角快照不会参与 CAD 识别。

## 失效处理与边界

- 取帧按映射的图像时间在本地头姿历史中插值，不能用收到结果时或最新的头姿代替。超出历史、跟踪间断超过 100 ms、速度超过 0.4 m/s 或 45°/s 的帧拒绝；只跳过该帧，不要求整段静止。旧四角流程继续使用原有冻结接口。
- `cuboid_faces.py` 生成部分柜面候选；`cuboid_multiview.py` 在已知尺寸和相机位置下联合优化同一世界平移与竖直偏航，逐视角验证边线和观察角度。`cabinet_visual_geometry.gd` 另外核验结果单位、刚体矩阵、支持帧身份/时间、相机基线和角差。CAD 模式仍采用稳定组位置/四元数融合。
- 断连、recenter、追踪丢失或场景切换后拒绝旧识别结果。Helper 断连不会撤销已经应用的空间映射。
- 已应用结果不能重复确认；清除只清理结果与预览，保留已应用映射。退出重进或系统重新定位后重新识别。
- 图像时间先用最小到达延迟映射，并为每帧保存此前 **0～400 ms、间隔 10 ms** 的本地相机位姿。`camera_timing.py` 从静态图像匹配中选择一个整批共用的延迟；支持组内每对视角都需有足够特征、几何误差中位数不超过 3 px、90 分位不超过 6 px。它不独立挪动相机来迎合柜体，也不外推历史；Godot 根据返回的延迟在本地历史中选择同一组相机位置。无历史的旧记录只能检查，不能补偿非零延迟。这个软件检查不能替代曝光级硬件同步或内外参标定；延迟超范围、时变错位、特征不足或相机参数错误仍可能拒绝，不能承诺运动中厘米级精度。
- 设备内参仍由官方去畸变 FOV 构建，未经过逐设备实测；多帧一致性不能排除系统性偏差。
- 当前 SIFT 合成模板对无纹理白色、遮挡、反光和对称结构覆盖有限。此前三个独立合成视角只接受一个。不能把本次接入称作已验收的实柜自动识别。
- 纯视觉网络、连续跟踪与失跟自动重定位不在此实现内。后续替换识别器时需保留单位、模型哈希、同帧头姿、歧义拒绝及生命周期校验。

## 验证

```powershell
$Project = 'F:\GodotSpace\GodotSpace'
$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'
$Python = Join-Path $env:LOCALAPPDATA 'GodotSpace/cabinet-calibration-venv/Scripts/python.exe'
& $Python -B -m unittest discover -s "$Project/tools/cabinet_calibration" -p 'test_*.py' -v
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_runtime_self_test.gd' -- --cad-worker --capture-ui
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_self_test.gd'
& $Godot --headless --path $Project --import
```

`--cad-worker` 使用真实 Python 环境验证两种模型，真实 CAD 部分需要本机模型数据；`--cuboid-worker` 只额外运行自定义柜体子进程，可在没有 CAD 数据的机器上验证。不带这两个参数可运行坐标、尺寸/模式切换、尺度、生命周期及 UI 入口测试。`--capture-ui` 在窗口渲染模式下将合成识别面板截图保存到系统临时目录（`cabinet-visual-ui.png` / `cabinet-cuboid-ui.png`）。无头运行不作为渲染验收。

真机验收：先用合成演练确认入口与自动进程，再对同尺寸实柜从多个视角识别、检查拒绝错误目标、独立量测贴合偏差；应用后走动/下蹲，确认目标不随头移动；断连重连、系统重新定位及关闭重开后确认旧结果不能误用。没有真实柜体时只能完成软件与合成链路验收。

以下为历史版本验证记录；当前多视角流程及最新结果见文末。

### 2026-10-21 开发机验证

通过 Python 单元测试、60 组几何回归、PICO 相机模型自检、原四角流程回归，以及新 CAD 运行时测试。新测试实际启动 Python 子进程执行 CAD 合成识别和三帧空白 JPEG 拒绝，并覆盖 1:1 / 1:3、相机移动下的世界坐标一致性、实际柜体锚点变换、重复应用、旧结果拒绝及取消清理。窗口截图检查了完整面板和真实识别叠加图。

StartMenu → ARSpace 回归使用一台本机 Server 与两个 `--testmode` Client，验证默认 CAD 入口、实际柜体锚点、连接和退出清理，流程断言通过。运行 `cabinet_scene_self_test.gd` 时 Server 附加 `--voice-role=server --hold-server`；两个 Client 各附加 `--testmode --voice-role=client --server-ip=127.0.0.1 --no-cabinet-receiver --hold-client`。测试专用 `--no-cabinet-receiver` 避免两个本机 SKY 进程争用同一个相机端口，不影响生产启动。

完整场景记录了 SubViewport、空材质、启动/退出时的 RPC 节点缓存错误，因此仅将场景流程断言记为通过，不记为无错误的完整网络/渲染验收。独立窗口测试只有复用 SubViewport 的 screen-transform 提示；无头测试还出现 dummy renderer 的空 mesh 提示。资源导入退出码为 0，没有脚本解析、资源缺失、autoload 或 GDExtension 加载失败，存在既有 progress-dialog / ObjectDB 退出日志。未启动真实 PICO 串流验收，未验证实柜识别率或厘米级误差。

### 2026-10-25 双模式验证

- Python 26 项测试通过：含默认尺寸、多个尺寸/视角、正方体对称性、噪声、多个目标拒绝、平面矩形/无内部棱边拒绝，以及没有 CAD 数据时的合成和三帧 JPEG 识别。
- Godot 几何 60 组、相机模型、旧四角回归、视觉坐标/采集测试均通过。旧演练改为按尺寸自动构图，避免新默认高度使模型超出画面。
- `cabinet_visual_runtime_self_test.gd -- --cad-worker --capture-ui` 和 `--cuboid-worker --capture-ui` 均通过；验证双模式真实子进程、厘米输入/按钮、目标模型显隐、尺寸修改清理、旧结果/重复应用拒绝与不缩放 XR 原点。两种模式的识别结果截图均已查看。
- 一台 Server、两台 `--testmode` Client 的 StartMenu → ARSpace、模式切换、默认尺寸和退出清理断言全部通过（参数同上）。场景测试现在按实际场景切换顺序先脱离场景树再延迟释放，避免在删除队列刷新前断言节点仍存在。
- 资源导入退出码 0，无脚本解析、资源缺失、autoload 或 GDExtension 加载失败；仍有既有 progress-dialog / ObjectDB 清理日志。场景和旧 UI 测试仍打印 SubViewport、dummy renderer 空材质/mesh 提示。

尚未做真实 PICO/实柜验收。手工检查：使用实际尺寸选择自定义柜体，让正面与侧面完整入镜，保持静止连续采集 8 秒；应显示贴合棱边的预览，检查后应用并走动观察。改尺寸/切 CAD 后旧应用按钮应失效；断连/recenter 后必须重新识别；只有正面矩形或两个相同目标时应拒绝。CAD 模式还需用对应真实实验柜验证识别和对齐，合成演练不替代这些检查。

### 2026-10-25 连续采集与融合修复

此前任意一帧未识别都会导致三帧整批失败；现改为限时序列采样、有效帧筛选、异常姿态剔除及世界空间融合。代表图像来自最终稳定组，不会显示被剔除异常帧的投影。失败时显示分析总数、有效数和歧义数；采集与识别阶段都可取消。

真机复测步骤及预期：

1. 输入实测宽高深，让白柜正面、侧面和顶部完整进入 Helper 预览，尽量避免柜顶杂物遮住棱边。点击开始后应先准备 3 秒，再显示 8 秒倒计时，采集数持续增加，不会在第 3 帧就结束。
2. 保持稳定；若需换角度，移动后停稳约 1.5 秒。画面短暂模糊或未检出可以被跳过，最终需要至少三帧稳定识别。持续无法检出时应显示数量及取景建议，不得启用应用。
3. 对同一柜体连续重试，检查代表图像的绿色边缘和空间线框。确认后再应用，走动、下蹲观察贴合，并独立测量误差。软件/合成测试不能确认这台实柜的识别率与精度。
4. 在倒计时和识别处理中分别取消、关闭面板、断开 Helper；旧结果不得弹回或启用应用。重新打开应能重新采集；两个匹配柜体或持续冲突的姿态应拒绝。

本次开发机验证：

- 上述 Python unittest 命令共 **29 项通过**，新增低对比度柜体、噪声拒绝、16 帧 JPEG 序列中 5 帧未检出仍保留 11 帧候选，以及高分辨率预览大小限制。
- 上述 Godot 视觉运行时命令（`--cad-worker --capture-ui`）通过：实际等待完整采集窗口，再由子进程处理空白序列；CAD 与自定义合成识别、取消、断连及结果截图均验证。独立无头运行时自检通过失败帧/离群姿态筛选、双稳定组拒绝、防止姿态链漂移、有效时间跨度、16 帧上限、世界坐标平移融合和 ±180° 四元数融合。
- `cabinet_geometry_self_test`（60 组）、`pico_camera_model_self_test`、`cabinet_calibration_self_test`、`cabinet_visual_self_test` 均退出 0。`--headless --import` 退出 0，无解析、资源、autoload 或 GDExtension 加载错误；保留既有 progress-dialog / ObjectDB 退出日志。
- 一台 Server 与两台 `--testmode` Client 的 `cabinet_scene_self_test` 均退出 0，场景流程断言通过；仍有 SubViewport 和 dummy renderer 提示。其中一台 Client 另报 `reconstruction_pipeline_controller.gd:969` 的 `multiplayer.is_server()` 空引用（该文件未改动），因此完整场景日志检查未通过，不能称为无错误网络验收。该错误不在本次柜体采集修改范围内。
- 未在真实 PICO / 此次照片中的实柜上验证；上面的真机步骤仍需执行。

### 2026-10-26 移动多视角与真实照片诊断

此前“连续采集”仍要求静止，并要求各帧单独检测成功，这不符合移动多视角扫描。当前产品入口改用 `capture_moving_frame()`，旧 `freeze_frame()` 只留给历史四角功能；新增部分柜面候选和共享三维位姿的联合求解，允许各帧的完整轮廓检测全部失败。

实际运行用户提供的 4284×5712 照片：缩放到 960×1280 做诊断，旧闭合轮廓提取出两个无关候选，在几组**假设**焦距下均为 `not_found`；这些假设不用于空间标定。新边线方法提取 21 个几何面候选，其中面积最大的候选覆盖右侧大柜面，已人工查看诊断叠加图。没有手工指定检测角点或在代码中写入这张照片的柜体坐标。检测候选中仍包含其他家具，不能据此宣称单图三维定位通过。

可复现照片诊断（照片和报告只留本机，不提交）：

```powershell
& $Python -B "$Project/tools/cabinet_calibration/diagnose_cuboid_photo.py" '<本机照片路径>' --output "$env:TEMP/cabinet-photo-diagnostic"
```

输出 `report.json` 和 `face-proposal.jpg`；报告明确 `metric_pose_valid=false`、`automatic_application_allowed=false`。单张普通照片缺少相机内参、同步头姿和多个视角，不能用于验收米制位姿或 XR 贴合精度。

自动验证新增：三个不同视角都有部分遮挡，单帧完整轮廓检测全部失败，联合求解仍恢复已知位姿；拒绝静止重复、只转头不平移、纯平面、明显错误尺寸、无边线与非刚体相机矩阵。Godot 自检覆盖移动头姿插值、禁止外推、过快移动/跟踪间断拒绝，以及支持帧身份、基线与视差验证。

真机步骤：重启天上端，在柜体标定选择自定义尺寸，开始后用 12 秒从正前方向斜侧方**缓慢横移**，建议覆盖约 0.5 米、保持目标在画面内。视角数应持续增加，停在原地时不应靠重复帧凑数。成功后从另一角度检查投影/线框贴合，再应用并走动观察；期间取消、关闭、断连或 recenter 后旧结果不能应用。若拒绝，先按提示区分移动不足、多个位置候选和边线不足。真实 CAD 模式也需移动视点，但仍要求该 CAD 的可匹配细节。此轮没有真实 PICO 多视角录制和曝光级同步验证，不能承诺照片中的柜体已经完成真机标定。

本轮实际验证结果：Python unittest **34 项通过**；Godot 视觉运行时、几何 60 组、相机模型、旧四角以及视觉采集自检全部退出 0。`--headless --import` 退出 0，无脚本解析、资源缺失、autoload 或 GDExtension 加载错误，仍有既有 progress-dialog / ObjectDB 退出日志。

另使用真实子进程做了带遮挡三视角 JPEG 到 VR 面板的集成测试（图像由已知相机位姿渲染，不是实拍 PICO）：完整等待 12 秒采集窗口，联合求解结果通过本地验证、显示投影并启用预览应用按钮，截图已查看。复现当前版本需用 `test_cuboid_multiview.sequence(timed=True)`（含静态背景纹理、已知时间偏差及头姿历史）生成 JSON `{"frames": frames}`，保存本机临时文件后执行：

```powershell
& $Godot --path $Project --xr-mode off --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_runtime_self_test.gd' -- --capture-ui "--multiview-fixture=$env:TEMP/cabinet-multiview-fixture.json"
```

`--cad-worker --capture-ui` 同时验证原 CAD 和自定义单视角合成路径、空白移动序列拒绝、关闭/取消清理，退出 0。一台 Server、两台 `--testmode` Client 的 StartMenu → ARSpace 场景断言均通过并退出 0；完整场景日志仍出现 SubViewport/dummy renderer 提示，以及未修改的 `player.gd:493`、`reconstruction_pipeline_controller.gd:969` 在退出时的空 multiplayer 引用，因此不记为无错误的网络验收。

### 2026-10-26 针对 11 帧 PICO 实拍的修复

本机抓取了一次真实运行的 11 张 960×720 JPEG 和请求中的相机矩阵。原请求实际选择了 CAD 模式，11 帧均未匹配；改用自定义柜体离线重放，旧版本同样拒绝。照片、完整请求和诊断报告仅保留本机临时目录，不进入仓库。

修复了两个提案问题：白色柜面边缘过弱，以及 18 px 的合并容差把柜边与邻近饰条/桌腿混合。现在先增强局部对比、按 4 px 合并共线片段，允许弱边的局部线段延伸，但仍用图像上的四条边验证候选；横边的覆盖和重叠提前检查，避免延伸导致组合数量膨胀。在原第 10 张 PICO 图上，已人工查看并确认正确大柜面进入自动候选。多个几何提案仍可能属于背景家具，这不是三维标定成功。

联合验证改为汇总不同视角的可见边证据，画面外样本不计入覆盖率，避免要求每个支持视角都有完整柜面。仍要求两面、不少于三个平移视角和重复边线证据；单平面、错误尺寸、重复视角和空白图继续拒绝。

更关键的实测问题是图像与记录头姿的几何不一致：40 对有足够匹配特征的图像，其原始相机矩阵对应的对极距离中位数约 **13.64 px**，未形成三视角一致组。新软件增加 0～400 ms 头姿历史及整批共同延迟选择；这是对可能固定时间偏差的补偿，不证明问题全由延迟造成，也不会修正未知内外参错误。旧 11 帧没有历史，最终仍正确返回 `image_pose_mismatch`，没有生成或应用现场对齐。UI 会区分图像/头姿错位、特征不足与柜体几何不足；CAD 未匹配时明确提示普通白柜应选择自定义模式。

本轮验证：上述 Python unittest 命令 **42 项通过**；包含已知 120 ms 时间偏差恢复、错误相机剔除、不接受仅相邻一致的帧链、真实 JPEG 特征匹配到延迟补偿再到柜体联合求解，以及不同裁切视角的互补。Godot 五项自检（视觉运行时、视觉采集、60 组几何、相机模型、旧四角）均退出 0；运行时覆盖完整历史采集、历史缺口、超范围延迟及本地历史索引验证。资源导入退出 0，无脚本解析、资源缺失、autoload 或 GDExtension 错误，保留既有退出清理日志。真实 Python 子进程集成已通过空白移动序列拒绝、CAD/自定义演练，以及带已知延迟和遮挡的三视角 JPEG 预览。

现场复测必须重启天上端 Godot，使新增头姿历史采集生效；不需要重新导出主工程或安装 Helper。选择“自定义长方体柜体”，核对宽 45、高 121、深 80 cm 是否为实测值，重新扫描 12 秒，缓慢从正面横移到斜侧面，让柜体和部分周围静态环境入镜。预期先完成图像/头姿校验，再显示共同支持视角的柜体预览；时间错位、特征不足和几何不足应给出不同提示，均不能启用应用。成功后仍须独立检查贴合、量测误差及移动/下蹲稳定性。新的固定延迟补偿尚未用重新采集的真实 PICO 历史验收，不能称为这台实柜已标定成功。


本轮窗口版集成（含 --cad-worker --capture-ui 及 timed=True 的 --multiview-fixture）退出 0，已查看 3/3 支持视角的合成预览截图。随后重新运行一台 Server、两台 --testmode Client 的场景回归，三者断言通过、退出码均为 0；仍记录 SubViewport/dummy renderer 日志，以及一个 Client 在 player.gd:493 退出时的既有空 multiplayer 引用，因此完整网络日志检查仍未通过。未改动该无关模块。


### 2026-10-26 实柜再次拒绝与诊断留存

用户再次测试，面板提示“可见边线不足或尺寸不匹配”。按当前执行路径，失败位于图像/头姿校验之后的柜体几何拟合，不是尺寸测量结论。该次 XR 已退出，旧任务文件已清理，日志没有识别结果，无法追溯到某条具体边。当前算法仍依赖直线候选和两面边线，白色弱边、饰条、遮挡仍是未解决的实柜问题；不能把新增留存功能称为识别修复成功。

新增最近一次实时扫描留存、离线 --replay、逐候选边线/视角指标和运行日志。验证命令 `python -B -m unittest discover -s GodotSpace/tools/cabinet_calibration -p 'test_*.py' -v`：45 项通过；另验证完整拟合诊断能序列化为 JSON。指定引擎执行 `--headless --path F:/GodotSpace/GodotSpace --script res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_runtime_self_test.gd -- --cad-worker` 退出 0，验证真实子进程失败后保留三帧输入和结果、临时任务清理不影响诊断、演练不覆盖现场记录；`--headless --import` 退出 0，无解析或资源加载错误，保留既有清理/渲染基线。测试诊断写到 TEMP，未覆盖用户现场记录。本轮没有新的真实 PICO 扫描，也未重新进行多端联调。下一次需重启天上端后留存一遍实际失败，再离线验证核心识别改进。

### 2026-10-26 新实拍数据的识别修复

取得 08:29 UTC 保存的完整扫描：8 张 960×720 JPEG，每帧含 41 个头姿历史样本。旧流程只保留 4 个视角且候选落在桌面附近，最终拒绝。新流程做了三项修复：

- 背景匹配图中，未能匹配的视角对视为未知；实际对极检验失败仍禁止共组。在一致关系的连通 2-core 中选择共同延迟，剔除悬挂链和互不连接的组。允许前后视角通过重叠视角连接，不要求所有照片看到同一片背景。新增重叠环、断开环、冲突和单链回归。
- 从一条实际横边与两条竖边产生已知尺寸候选，使用重力与射线深度比求解，不再要求候选阶段同时看到顶和底。初值仍需所有视角的图像证据验证。候选去重用向量化位置筛选，避免逐个矩阵比较造成额外等待。
- 使用方向匹配的距离场；一个完整柜面的四条边必须各自在至少两个视角具有 85% 覆盖。该数据中柜门横缝造成的向下偏移候选因此被拒绝，正确外轮廓候选保留。新增横缝/零散地面线的图像回归，并确认移除该检查会使回归失败。

完整 8 帧回放通过，统一延迟 80 ms，15 对背景匹配的对极距离中位数的均值约 0.98 px；8/8 视角支持同一柜体位置。逐帧查看两面轮廓叠加，未修改默认尺寸，未在识别代码中植入照片坐标。拟合支持分数约 0.96 只是内部边线指标，不是正确概率或物理精度。

同一批原始 JPEG、真实 K 和相机历史，经 Godot 的实际采集入口、Python 子进程和本地坐标验证，面板显示识别成功、8/8 支持并启用应用按钮；窗口截图已检查。自检支持每帧真实分辨率和 K，不再假定合成测试的 640×640。相机状态显示 Not started 是离线注入测试未连接 Helper 的预期状态，不代表进行了一次新的现场采集。

删去中间一帧后仍接受 4/7 视角，位姿相对完整批次约差 1.9 cm / 2.2°；这是重复性变化，不是实物真值误差。删去连接前后背景的首帧后，剩余视角分为两组，选中组缺少足够底边证据，仍拒绝。说明当前仍需要足够的视角覆盖，不承诺任意遮挡下都能成功。

复现命令（仓库根目录，真实记录仅留本机）：

```powershell
$Python = Join-Path $env:LOCALAPPDATA 'GodotSpace/cabinet-calibration-venv/Scripts/python.exe'
$Godot = 'D:/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe'
& $Python -B GodotSpace/tools/cabinet_calibration/visual_pose_worker.py --replay '<本机保存的 last_scan.json>' --output '<本机 result.json>' --artifacts GodotSpace/tools/cabinet_calibration/artifacts
& $Python -B -m unittest discover -s GodotSpace/tools/cabinet_calibration -p 'test_*.py' -v
# fixture 是扫描记录中的 request 对象，不是包含 request/result 的整个留存包。
& $Godot --path F:/GodotSpace/GodotSpace --script res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_runtime_self_test.gd -- --capture-ui '--multiview-fixture=<本机 request.json>'
& $Godot --headless --path F:/GodotSpace/GodotSpace --import
```

本轮未重新连接 PICO 采集，也未在头显中实际应用/量测。现场复测选择自定义柜体，确认尺寸后缓慢横移扫描；让至少两个视角看到顶、底边，保持一定静态背景重叠。应出现跨视角一致的实柜轮廓；应用后从侧面及不同高度检查位置与尺度。无需导出主工程或重装 Helper。照片、原始记录、诊断叠加图均不提交到仓库。

验证结果：上述 Python discovery 49 项通过；Godot 窗口集成、`cabinet_visual_self_test.gd`、`cabinet_geometry_self_test.gd`（60 组）、`pico_camera_model_self_test.gd`、`cabinet_calibration_self_test.gd` 均退出 0。四项脚本均用 `--headless --path F:/GodotSpace/GodotSpace --script res://Assets/ARSpace/Scripts/SpatialCalibration/<脚本名>` 执行。导入退出 0，无新增脚本解析、资源缺失、autoload 或 GDExtension 错误；仍出现既有 progress-dialog/tasks/ObjectDB 退出日志，窗口测试有既有 SubViewport 日志。本轮没有改网络协议，没有重新运行一 Server 两 Client 的多机联调。

### 2026-10-26 10:58 UTC 扫描的伪候选歧义修复

用户连续两次测试失败；旧版本只保存最后一次，本轮能取得最后一次 11 帧及完整头姿历史，前一次已覆盖，不能声称两次都已复现。最新记录通过图像/头姿校验（54 对匹配、统一延迟 80 ms、约 0.88 px），实际拒绝原因是 `ambiguous`。正确外轮廓已找到，但另一个向下偏移约 17 cm 的候选借用了柜门横缝和完整地砖缝，也满足此前的长边覆盖门槛。

`cuboid_multiview.py` 新增 `upright_junctions()`：按相机内参和头姿计算逐像素重力投影方向，用更精确的竖边方向过滤地砖斜线，再检查柜角附近短竖边的连续证据。横边的强支持需要至少一端实际接到竖边；完整柜面的四个端点在整次序列中都需实际观测，可由不同视角补全。保留原有重复边线、两面、基线、视差与多目标歧义约束。未改变输入尺寸、相机位姿或写入照片坐标。

新回放接受 9/11 个视角，正确候选四个端点都有证据，向下偏移候选只有三个，被排除。相同原始图像、K 和历史记录通过 Godot 实际采集入口、Python 子进程和本地校验，面板显示“识别成功，9/11 个视角共同支持该位置”，应用按钮可用；逐帧投影和面板截图已检查。将该序列隔帧抽成六视角仍接受 4/6。此前通过的八视角数据重跑仍为 8/8，位姿保持不变。

`diagnostic_capture.py` 改为最近五次不同请求的本地历史；同一次请求的 processing/final 原子更新同一哈希文件，首次升级迁移仍在的上一段扫描。最新 JSON 路径保持兼容，演练/重放不改历史，清理只作用于本工具的历史文件。已有用户现场记录在测试前后 SHA-256 一致，所有测试记录写入 TEMP。

验证：

- `python -B -m unittest discover -s GodotSpace/tools/cabinet_calibration -p 'test_*.py' -v`：52 项通过，新增完整地砖缝与缺失柜角的图像回归，确认移除端点完整性检查会复现歧义；覆盖五次上限、同请求更新、旧记录迁移、请求 ID 路径隔离及无关文件保留。
- 指定引擎执行 `--path F:/GodotSpace/GodotSpace --script res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_runtime_self_test.gd -- --cad-worker --capture-ui --multiview-fixture=<本机 request.json>`：退出 0，覆盖新实拍预览、空白序列拒绝、CAD/自定义演练、取消、空间失效及清理。
- `--headless --path F:/GodotSpace/GodotSpace --import`：退出 0，无脚本解析、资源缺失、autoload 或 GDExtension 加载错误；仍有既有 progress-dialog/tasks/ObjectDB 清理日志，窗口测试仍有既有 SubViewport 日志。

本轮未重新连接 PICO 采集、实际应用头显对齐或重跑多机联调。下一次扫描会启动新的 Python 识别器，无需主工程导出或重装 Helper；成功后从侧面及不同高度核对投影和实体贴合。持续遮挡整个柜角仍可能缺少足够证据而被拒绝。
