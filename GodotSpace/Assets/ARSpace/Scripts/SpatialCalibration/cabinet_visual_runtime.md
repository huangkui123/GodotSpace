# CAD / 自定义柜体自动视觉标定

头显「工作页 → 柜体标定」提供 **真实 CAD 模型**和**自定义长方体柜体**两种自动视觉模式。前者使用 `.magics` 装配模型的合成特征与 RGB SIFT/PnP；后者从图像自动提取完整轮廓和可见棱边，并按输入尺寸估计长方体位姿。两种模式都不要求人工角点、检测框、标签或深度。**识别器仍为实验性基线，未完成实柜识别覆盖率及精度验收。** 三帧一致不等于物理精度已验证，成功后仍需检查预览并点击「应用对齐」。

## 操作

1. 使用仓库 `Start-GodotSpace.cmd` 进入天上端；USB Helper 继续把单眼相机图像送到本机 `8789`，无须改变串流流程。
2. 右手柄 A → 工作页 → 柜体标定。在顶部选择柜体类型。真实 CAD 默认 **1:1 原尺寸**，可切换 1:3；自定义柜体以 **厘米**设置宽、高、深，默认 **宽 45、高 121、深 80 cm**，可用射线点击加减按钮或编辑数值。自定义尺寸已经是实际物理尺寸，不再叠加 CAD 缩比。修改尺寸或切换类型会取消正在运行的任务并清除旧预览；旧四角流程保存的尺寸不参与初始化。
3. 看向实柜，点击「开始自动识别」。3 秒后自动采集三张不同时间戳的图像。保持头部及实物静止，系统仍要求设备外参、匹配分辨率的内参及高置信度本地跟踪。
4. 本地进程自动识别。图像上显示绿色模型投影点，空间里显示 CAD 点云或自定义柜体线框。失败、有歧义、三帧位姿相差超过 3 cm / 5° 时不提供应用按钮。
5. 从正面、斜前方与侧面检查，再点击「应用对齐」。真实 CAD 使用实际实验柜 `SpaceBox/SpaceBox/dashiyangui/dashiyangui/MeshRenderer` 锚点；自定义模式使用 `SharedSpaceOrigin/CalibrationCabinet` 正面左下角锚点，并按宽高深调整实体长方体。模式切换只改变当前客户端对应柜体的显示，应用时以刚体变换对齐本地 XR 原点，不缩放跟踪空间。

没有实物时，选择任一柜体类型，再切换「合成演练（无实物）」并开始。程序真实渲染相应模型后调用同一个图像识别器，显示识别投影；不会应用到 XR 原点。自定义模式无需 CAD 文件或模板库，可用于具有清晰棱边的真实长方体；真实 CAD 模式仍只匹配对应实验柜。

### 自定义柜体取景要求

柜体应直立，整件位于画面内，并能看清正面和侧面（最好同时看到顶部），棱边与背景有足够对比。算法使用跟踪空间的上方向校验姿态，自动拟合六点外轮廓，并检查可见面的内部交线；仅正面矩形、缺少棱边、裁切、遮挡或多个匹配目标会拒绝，不需要用户补点。尺寸范围为每轴 5–2000 cm；实际可识别范围仍受相机分辨率与取景距离限制。

无标记长方体在几何上无法区分前后，约定朝相机的宽面为正面；宽深相等时采用较朝向相机的面。跨越对称方向时可能需要重新取景，不能据此识别柜门的语义朝向。画面不能验证输入的绝对尺寸是否真实，必须输入实测值；同比例填错尺寸也会得到错误距离。三帧只用于一致性检查，不替代物理精度验证。演练与实景始终使用同一轮廓识别器。

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

请求和结果临时写入本机 `user://cabinet_visual_jobs/job_<进程>_<时间>/`；完成、取消、超时、退出时清理本次文件。异常断电可能留下临时图像。进程最多运行 120 秒，关闭面板会取消正在进行的识别；已完成预览可保留。不会打印相机图像或上传现场数据。

旧四角实现仍保留用于回归测试，但产品默认入口不显示人工选点控件。旧尺寸、四角快照不会参与 CAD 识别。

## 失效处理与边界

- 捕获时保存本地相机世界位姿，每一帧的相机到模型变换先转换到同一个世界空间，再比较三帧一致性。
- 断连、recenter、追踪丢失或场景切换后拒绝旧识别结果。Helper 断连不会撤销已经应用的空间映射。
- 已应用结果不能重复确认；清除只清理结果与预览，保留已应用映射。退出重进或系统重新定位后重新识别。
- 仅静止取景，现有最小传输延迟估计不是曝光级时钟同步。
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

尚未做真实 PICO/实柜验收。手工检查：使用实际尺寸选择自定义柜体，让正面与侧面完整入镜，保持静止自动取三帧；应显示贴合棱边的预览，检查后应用并走动观察。改尺寸/切 CAD 后旧应用按钮应失效；断连/recenter 后必须重新识别；只有正面矩形或两个相同目标时应拒绝。CAD 模式还需用对应真实实验柜验证识别和对齐，合成演练不替代这些检查。
