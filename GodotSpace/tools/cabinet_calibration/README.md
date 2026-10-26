# 实验柜纯视觉标定：CAD 工具与运行时接入

本工具直接读取打印模型，提取 Godot 虚拟柜几何，计算候选对齐，并生成不依赖深度、标签或人工选点的 RGB 位姿估计基线。**当前识别器仍未通过实柜验收。**

VR「柜体标定」现在还可选择 **自定义长方体柜体**：宽、高、深分别默认 **45 / 121 / 80 cm**。`cuboid_pose.py` 根据输入的实际米制尺寸生成模型，自动从完整六点轮廓、可见棱边和相机中的跟踪上方向求解姿态；无需 CAD 文件、模板库或手工点角。仍需同一 Python 依赖环境。正面矩形、棱边缺失、裁切和多个候选会拒绝；没有标记的对称柜体采用朝相机的宽面为正面，不能判断柜门语义朝向。实柜识别率及物理精度仍需验收。

2026-10-21 已通过 `visual_pose_worker.py` 接入头显「柜体标定」默认入口；现支持 8 秒连续采样、多帧融合、CAD 预览和用户应用空间对齐，默认比例 **1:1**。支持合成演练，无需实物或人工点选。模型准备仍使用以下工具，详见 [运行时部署与操作](../../Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_runtime.md)。原来的 `rgb_pose.py infer` 保持离线候选语义，不自行改变场景。

## 当前结果

- `789.rar`：84 个 STL，13,517,116 个三角面；零件处于分散打印排版。
- `Merge_of_储存版-白色哑光_w2.magics`：成功提取一个合并网格，1,554,511 个顶点、3,126,903 个三角面。按 `1e-7 m / 整数坐标单位` 解码后的范围为约 `1.339823 × 1.820001 × 0.888229 m`。已通过渲染确认是装配形态，不需要从 84 个零件重新拼装。
- 虚拟柜从实际 Godot `.mesh` 和预制场景导出 7 个部件；工具、提示 UI、替换样品和重复演示件不参与配准。
- 在 **1/3 打印的假设**下，完整模型的候选对齐：双向采样距离截尾 80% RMS 约 4.90 mm，全量 RMS 约 8.54 mm，P95 约 13.90 mm。这些数值同时受采样密度、部件姿态和模型差异影响，**不是实体标定精度**。
- 上部工作面板不同：打印模型有圆形开口，虚拟柜默认姿态有盖板。匹配到柜体并不意味着所有可动件应当重合。
- 72 个合成模板（15° 方位间隔、三个俯仰角）上的初步 RGB 基线，在三张改变视角、内参、照明、背景和噪声的合成图中接受 1 张，拒绝 2 张。接受样本误差约 5.50 mm / 1.37°，仅为已知真值的合成实验。
- 单元测试 14 项通过；Godot 坐标与采集自检通过。尚未验证实物图像、相机外参、时序、头显叠加、多端独立跟踪空间及 recenter 恢复。

当前 SIFT + PnP 基线覆盖率不足，不能以“合成图能识别”作为真机可用结论。下一阶段应比较专门的 RGB 模型位姿网络（例如 MegaPose 的 RGB 模式）、轮廓优化和多帧一致性验证。MegaPose 仍需检测框，自动目标定位不能省略。不会通过降低几何门槛强行接受白色无纹理背面。

## 文件与坐标

| 文件 | 职责 |
| --- | --- |
| `export_cabinet.gd` | 使用 Godot 原生资源读取器导出柜体和部件，不执行柜体动画 |
| `magics_mesh.py` | 读取 MT 容器、验证 ZIP CRC、解码定点顶点与三角面索引 |
| `prepare_model.py` | STL 清单、哈希、包围盒、固定框架候选配准 |
| `align_assembly.py` | 合并装配几何与虚拟柜的候选配准、全几何 PLY 和对比图 |
| `geometry.py` | 面积采样、轴向/PCA 多初值、刚体 ICP、双向距离报告 |
| `render_model.py` | CPU/Numba 离线渲染和 CAD XYZ 查找表 |
| `rgb_pose.py` | 合成模板、SIFT 对应、RANSAC PnP、歧义与几何质量拒绝 |
| `validate_synthetic.py` | 未加入模板库的视角实验，输出真值误差与叠加图 |
| `scene_smoke.gd` | StartMenu → 本地 Server → ARSpace → 新采集按钮烟雾测试 |
| `visual_pose_worker.py` | 本地有限时长任务：校验模型、逐帧解码限长序列、自动匹配、尺度换算及各帧叠加图；不监听网络 |
| `cuboid_pose.py` | 自定义尺寸长方体：自动轮廓、边线拟合、PnP、重力方向/可见边支持校验、对称姿态归一化与多目标拒绝 |

模型坐标以虚拟柜固定框架 `dashiyangui/MeshRenderer` 的局部坐标为参考，右手系、Y 向上。打印比例显式传入，转换到米后再进行刚体配准；不允许非均匀缩放掩盖几何差异。候选矩阵采用 **row-major、列向量、目标坐标 = T × 来源坐标**。装配配准矩阵的输入是已经乘过 `print_scale` 的 Magics 米坐标。

STL 不声明单位，`.magics` 的加密 `header.xml` 未解码。其内部单位解释参考 [SlicerHeart 对同类 Materialise 容器的格式记录](https://github.com/SlicerHeart/SlicerHeart/blob/master/Docs/ImportMimics.md)，并与本文件几何和 STL 缩比交叉核对；没有把格式文档中的医疗坐标约定套用到柜体上。物理打印的最终缩放仍须验收确认。

对薄壁模型的激进减面会破坏面板，所以最终工具保留完整打印几何，用编译后的 CPU 光栅化加速。**这些 PLY 是离线参考，不能直接把数百万三角面的模型挂到 XR 场景中。** 原件不修改，所有大型派生数据在 `artifacts/`，由 Git 和 Godot 导入器共同忽略。

## 复现

以下在仓库根目录运行。使用本机 Python 环境路径替换 `$Python`；依赖安装在独立环境，不能写入项目或系统 Python。

```powershell
$Project = Join-Path (Get-Location) 'GodotSpace'
$Tools = Join-Path $Project 'tools/cabinet_calibration'
$Artifacts = Join-Path $Tools 'artifacts'
$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'
$Python = Join-Path $env:LOCALAPPDATA 'GodotSpace/cabinet-calibration-venv/Scripts/python.exe'
# 尚未创建环境时，先使用可用的 Python 3.12 执行：
# python -m venv "$env:LOCALAPPDATA/GodotSpace/cabinet-calibration-venv"
& $Python -m pip install -r "$Tools/requirements.txt"

& $Godot --headless --path $Project --script 'res://tools/cabinet_calibration/export_cabinet.gd' -- "--output=$Artifacts/virtual"
& $Python "$Tools/magics_mesh.py" 'F:/材料/引擎材料/Merge_of_储存版-白色哑光_w2.magics' --output "$Artifacts/magics"
& $Python "$Tools/align_assembly.py" "$Artifacts/magics/magics_00_full.ply" --virtual-dir "$Artifacts/virtual" --output "$Artifacts/assembly" --print-scale 0.3333333333333333
& $Python "$Tools/rgb_pose.py" build --model "$Artifacts/assembly/printed_assembly.ply" --output "$Artifacts/templates"
& $Python "$Tools/validate_synthetic.py" --model "$Artifacts/assembly/printed_assembly.ply" --templates "$Artifacts/templates" --output "$Artifacts/synthetic_validation"
```

检查每条命令的退出码后再继续。主要输出：

- `assembly/comparison.png`：上排打印模型，下排虚拟参考，同一尺度和相机。
- `assembly/assembly_report.json`：四个独立方向候选、距离分布、来源哈希和未验证状态。
- `assembly/printed_assembly.ply`：完整打印模型在候选参考坐标中的几何。
- `synthetic_validation/validation.json`：逐张实验结果，失败视角也保留。
- `synthetic_validation/overlay_*.png`：黄色投影点叠加。

需要单独审计 `789.rar` 时，先解压到 `artifacts/print` 或仓库外目录，不要把零件导入 Godot：

```powershell
& 'D:/7-Zip/7z.exe' x 'F:/材料/引擎材料/789.rar' "-o$Artifacts/print"
& $Python "$Tools/prepare_model.py" --print-dir "$Artifacts/print" --virtual-dir "$Artifacts/virtual" --output "$Artifacts/frame_audit" --source-units-to-m 0.001 --print-scale 0.3333333333333333
```

默认按最大包围盒体积选出固定框架候选，并在报告中明确记录；可用 `--frame <STL>` 显式覆盖。不会把分散排版的总体包围盒当作柜体尺寸。

## PICO 图像验证

1. 正常启动 PC Server 和 Helper，进入空间标定面板，确认预览正在更新。
2. 点击 **保存纯视觉验证帧**。仅该操作会保存当前原始 JPEG 与同帧 `capture.json`，路径在状态栏显示，默认位于 `user://cabinet_calibration/captures/`。
3. 分别采集正面、斜前方和缺乏特征的侧/背面；柜体应完整可见，再测试遮挡和运动模糊。文件保留在本机，不自动上传。
4. 对实际输出图像验证相机内参和畸变。不得把 PC 观察相机 FOV 当作 PICO 内参，或者在裁剪/缩放图像后沿用未变换的 K。

推理需要明确的相机文件：

```json
{
  "width": 640,
  "height": 640,
  "K": [[720, 0, 320], [0, 710, 320], [0, 0, 1]],
  "distortion": [0, 0, 0, 0, 0]
}
```

**上例仅为合成测试内参，不可用于 PICO。** 只有已知无畸变/已校正图像才能填全零畸变；SDK metadata 需要核对单位、对应分辨率和是否已做校正。工具不会用缺失值自动补出一个“已标定”的相机。

```powershell
& $Python "$Tools/rgb_pose.py" infer --image '<采集目录>/image.jpg' --camera '<验证后的相机文件.json>' --templates "$Artifacts/templates" --model "$Artifacts/assembly/printed_assembly.ply" --output "$Artifacts/pico_evaluation"
```

输出 `not_found`、`ambiguous` 或 `candidate`。`candidate` 只代表当前图像中通过内部几何检查的候选；所有结果保持 `runtime_application_allowed=false`。需要以画面轮廓、孔位、独立测量以及多帧一致性检查它，不应直接送到头显原点。

## Godot 接入边界

`cabinet_visual_geometry.gd` 提供且已测试下面的坐标链：

```text
tracking_from_model =
    tracking_from_camera_at_capture × OpenCV_to_Godot × camera_from_model
world_from_tracking =
    world_from_model × inverse(tracking_from_model)
```

必须使用**拍摄时刻**的相机在头显跟踪空间中的位姿，并校验传感器外参方向与时间同步。模型尺寸差异在柜体内容根节点处理，不通过缩放 XROrigin 或玩家位移来伪装重合。

运行时现已加入限时采样序列在世界空间的稳定组筛选与姿态融合、本地空间映射、recenter/断连旧结果拒绝及合成结果隔离。尚未验收实柜 RGB 定位覆盖率、测量精度及真实设备失跟恢复；不支持连续追踪或失跟后自动重新定位。Depth Pro、点云重建与角色锚点继续使用原有流程。

## 验证命令

```powershell
& $Python -m unittest discover -s $Tools -p 'test_*.py' -v
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/SpatialCalibration/cabinet_visual_self_test.gd'
& $Godot --headless --path $Project --script 'res://tools/cabinet_calibration/scene_smoke.gd' -- --voice-role=server --testmode
& $Godot --headless --path $Project --import
git diff --check
```

场景烟雾会短暂启动本机 Server，要求端口空闲。检查到新按钮并验证无图像时的错误提示后退出。此定制引擎 headless 导入有既有 progress-dialog/退出资源日志；场景 headless 运行还出现 SubViewport 屏幕变换错误（原始面板对照也复现），一次退出出现 dummy renderer 的空材质错误。应区分流程断言通过与渲染环境无错误，真实串流显示仍需验收。
