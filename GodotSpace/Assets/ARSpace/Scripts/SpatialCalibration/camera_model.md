# PICO 4 Ultra Enterprise 相机参数

## 数据来源与适用范围

Android Helper 从当前头显的 `PXRCapture.getCameraExtrinsics()` 读取左右相机原始矩阵，不把本次设备读数写死为所有设备的外参。当前支持该设备在 Helper 进程中报告的 `Build.MODEL=A9410`，去畸变左眼 `render_mode=0` 或右眼 `render_mode=1`。不支持 raw 鱼眼、双眼拼接或交错输出。

转换依据为 PICO Unity Integration SDK **3.4.0**，固定提交 `c93a59bab88d337fe0d54140499712897cedbe52`：

- [PXR_Enterprise.cs](https://github.com/Pico-Developer/PICO-Unity-Integration-SDK/blob/c93a59bab88d337fe0d54140499712897cedbe52/Enterprise/Scripts/PXR_Enterprise.cs)：`GetCameraExtrinsicsfor4U`、`GetCameraParametersNewfor4U` 及矩阵布局。
- [CameraRenderingPlugin.aar](https://github.com/Pico-Developer/PICO-Unity-Integration-SDK/blob/c93a59bab88d337fe0d54140499712897cedbe52/Enterprise/android/CameraRenderingPlugin.aar)：对其中 ARM64 `getCameraParametersNew` 的反汇编检查确认下面的矩阵乘法和 FOV 常量。不是将 Unity 包加入 Godot 工程，也不是在本工程调用该封装。
- AAR SHA-256：`d2d8caa83e740122216c01571a8781a236c8f5e03e5048e5178da7e7f0419846`。
- `libCameraRenderingPlugin.so` SHA-256：`757e911fbdea8f1fad3202c09219b8dd059c38d4091d1bd7504297ea7e5c4f07`。

SDK 或设备机型变更时应重新核对；不能假定所有 PICO 相机或任意处理后的画面使用相同参数。

## 变换约定

所有矩阵以下均按行排列，作用于列向量；平移单位为米。`raw` 是 capture SDK 返回的 4×4 矩阵。官方封装的参考系到头部转换为：

```text
C = [ 0 -1  0  0.05057
      1  0  0  0.01874
      0  0  1 -0.05194
      0  0  0  1       ]

head_from_camera_optical = C * raw
```

输入相机光学坐标为右、下、前。Godot 相机为右、上、后，所以相机侧再乘 `F=diag(1,-1,-1,1)`。来源 Client 网络头姿已经是 Godot/OpenXR 坐标，不再翻转一次。

```text
world_from_cabinet = world_from_head
                   * head_from_camera_optical
                   * F
                   * godot_camera_from_cabinet
```

不要直接使用 `raw` 或猜测其逆矩阵。`camera_to_head_primary/secondary` 已包含 `C`，接收端也不能重复应用 `C`。

## 内参与帧协议

官方去畸变输出模型使用水平 **76.35°**、垂直 **61.05°**。Helper 向 SDK 的 `getCameraIntrinsics(width,height,hfov,vfov)` 传入当前帧尺寸及这两个角度，SDK 返回顺序为 `cx,cy,fx,fy`。960×720 时本机读取 `fx=610.519156`、`fy=610.549382`、`cx=480`、`cy=360`。

这属于去畸变输出投影模型，不是用标定板重新测量的逐设备内参。改变 FOV、裁剪、缩放或图像旋转后须重新匹配内参。窗口仍允许输入经过实测的手动内参。

PSA2 / PAA1、端口、帧头和 `schema_version=1` 均不变，仅在 JSON metadata 中添加字段：

| 字段 | 含义 |
| --- | --- |
| `device_model`, `device_system` | Helper 进程读取的 Android Build 信息 |
| `camera_to_head_status` | `valid`、`unsupported_device`、`unsupported_image_mode`、`sdk_read_failed` 或 `invalid_extrinsics` |
| `camera_to_head_convention` | 成功时为 `pico_4_ultra_rectified_cv_to_head_openxr_v1` |
| `camera_to_head_units` | 成功时为 `metres` |
| `camera_to_head_primary`, `camera_to_head_secondary` | 成功时提供左右相机的 16 个行序数值，光学相机到头部变换 |
| `camera_intrinsics_source` | 官方默认 FOV 为 `pico_4_ultra_rectified_sdk_fov`，自定义为 `configured_fov` |

原始 `camera_extrinsics_primary/secondary` 继续保留用于诊断；返回码 `1` 才表示读取成功。接收端检查模式、相机索引、单位、有限数值、刚体矩阵和头部局部平移范围。旧 Helper 缺少新字段时提示更新，不静默使用头部近似。

## 本机验证与现场复核

2026-10-15，在系统 5.15.7 的这台头显上，生产 Helper 的 Android instrumentation 测试读取了左右相机参数；未打开相机、未采集图片。转换后左相机中心约为 `(-0.032382,-0.002040,-0.069121)` 米，右相机约为 `(0.031804,-0.002066,-0.069358)` 米。它们是此次设备读数，不是通用配置。ADB shell 报告 `A9210`，但 Helper 进程的 `Build.MODEL` 实际报告 `A9410`；程序按生成 metadata 的进程值检查。

该 JSON 同时经过 Godot 接收端自检，包括左右眼选择和 JSON 数值类型；几何测试覆盖 60 组姿态，窗口测试覆盖设备模式、快照回放、旧模式拒绝及 Server + 两个 Client。相关入口：

```text
Android: gradlew.bat test assembleDebug assembleDebugAndroidTest
Android: PicoCameraModelInstrumentedTest
Godot: pico_camera_model_self_test.gd [-- --metadata=<实际 Helper JSON>]
Godot: cabinet_geometry_self_test.gd
Godot: cabinet_calibration_self_test.gd
```

另通过了实际渲染器窗口检查和 `cabinet_scene_self_test.gd` 的 StartMenu → ARSpace → 柜体窗口检查。首次 `--headless --import` 在编辑器退出阶段崩溃；重跑退出码 0，无脚本解析或缺失资源错误，但仍有已记录的 progress dialog / ObjectDB 清理日志。完整场景自检仍打印此前存在的 SubViewport 层级与空材质消息。未把首次非零退出当作通过。

2026-10-15 随后完成实际 PC Server + 天上端 XR Client + PICO Helper 串流验证。日志确认使用新 FOV、OpenXR Stage 和来源头姿；按默认设备外参重新冻结、点选四角并预览后，佩戴者反馈「位置和角度都基本对齐」。这是现场目视确认，没有测量厘米级或角度误差。

后续现场复核步骤：重启 XR Client，在头显主面板打开「柜体标定」，Helper 直连天上端电脑的 8789；清除旧柜体，输入实测尺寸，保持头部静止约 1.5 秒后重新冻结，使用默认设备外参按顺序点选四角。从正面及侧面检查已知角点，记录距离和偏差，保存快照。不能用四角拟合的低像素误差替代实测空间误差。

天上端迁移后，冻结帧与本地 XRCamera 头姿依赖静止窗口降低 Helper 图像传输延迟误差，尚无曝光时间级同步。本次没有进行移动中标定、长时间漂移或定量精度验收。相机参数修复不改变 XR 视点高度和透传透明度。
