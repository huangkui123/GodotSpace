# 实时重建

本模块把 PICO helper 的外部相机视频送到 `lab_4090` 上的 LingBot-Map，并将增量彩色点云传回 Godot。点云只用于视觉呈现，不生成碰撞、导航或交互几何。

## 运行拓扑

```text
PICO helper
  └─ PSA2/JPEG + 相机 metadata ─TCP 8787→ PC Ground Server
       ├─ 会话控制、配准、地图缓存与 .gsmap 持久化
       └─ PSA2 ─本机 18787/SSH→ lab_4090:8787
             └─ LingBot-Map ─PCCH─ lab_4090:8790/SSH→ 本机 18790
                    └─ PC Server 点云缓存 ─独立 TCP 8791→ VR Clients
```

控制状态继续使用项目现有 ENet/RPC。高带宽点云不占用 ENet channel。PC Server 是会话、已确认配准、地图版本、缓存和持久化的唯一权威端。`8791` 不接受匿名读取：PC Server 每次启动生成随机令牌，只通过已完成角色注册的 ENet 连接下发；VR 点云客户端再用 `PCDH v1` 提交令牌和 ENet peer ID，Server 同时确认其 `sky/ground_vr` 角色后才回放地图。

## 第一次启动

### 1. Lab 端

Lab 适配器位于：

```text
lab_4090:/home/admin/lingbot-map
branch: codex/realtime-reconstruction-adapter
commit: 1cc5b618e4609088005528a709d246f896578740
```

选择一张空闲 GPU 后启动：

```bash
ssh lab_4090
cd /home/admin/lingbot-map
CUDA_VISIBLE_DEVICES=<GPU_INDEX> \
  /home/admin/miniconda3/envs/lingbot-map/bin/python \
  e2e_io_streaming/demo.py \
  --model_path /home/admin/checkpoints/lingbot-map.pt \
  --host 127.0.0.1 \
  --pico_host 127.0.0.1 --pico_port 8787 \
  --point_stream_host 127.0.0.1 --point_stream_port 8790 \
  --pico_sample_fps 12 \
  --conf_threshold 1.5 \
  --downsample_factor 1 \
  --point_stream_max_points 100000 \
  --use_sdpa
```

上述参数是房间尺度实时重建的增密档，也是 Lab 适配器当前的默认值。置信度过滤后不再做固定步长抽稀，每个结果帧最多均匀发送 10 万点。不要先降低 `--conf_threshold 1.5`，否则通常会先增加漂浮噪点。每次修改这些参数后都要开始一次新的重建，旧 `.gsmap` 中已经被过滤掉的点无法恢复。

Lab 的输入和输出均只绑定 loopback，不应直接暴露到局域网或公网。

### 2. PC Server 的 SSH 隧道

在运行 Godot 的 PC 上保持以下命令运行：

```powershell
ssh -N `
  -L 18787:127.0.0.1:8787 `
  -L 18790:127.0.0.1:8790 `
  lab_4090
```

Godot 默认连接 `127.0.0.1:18787` 和 `127.0.0.1:18790`。可用以下环境变量覆盖：

```text
GODOTSPACE_LINGBOT_TUNNEL_HOST
GODOTSPACE_LINGBOT_INPUT_PORT
GODOTSPACE_LINGBOT_OUTPUT_PORT
```

### 3. Godot 与 PICO

1. 启动 PC Ground Server。
2. 在 PICO 本机手动启动 Spatial Anchor Helper，并让它连接 PC 的 `8787` 端口。
3. 启动天上 VR 和地面 VR 的 Godot 串流客户端。
4. 天上端从主面板点击“实时重建”。
5. 四项服务均就绪后点击“开始新的重建”。
6. 缓慢平移至少 30–50 cm，持续至少 5 秒，并做少量转头。
7. 在预览页检查点云和真实空间；必要时手动调整 XYZ、Yaw、统一尺度，高级模式可调整 Pitch/Roll。
8. 确认后点云对地面端发布。天上端默认隐藏点云，地面端默认显示。

`8787` 上已有 Helper 时，新的 TCP 连接不会再顶掉当前连接。部署在非隔离局域网时，建议在 PC Server 设置 `GODOTSPACE_PICO_HELPER_ALLOWED_HOST=<PICO_IP>`；不设置时保留任意来源首次连接的兼容行为，因此仍应把该端口限制在可信局域网。

退出实时重建工作区只返回 ARSpace，不会停止共享会话。停止按钮保留当前地图；停止后会等待 2–5 秒排空已提交到 GPU 的尾部点块，再允许导出最终文件。清空按钮才会撤销并删除当前运行时地图。

## 配准

自动配准按相同 `frame_id` 配对：

- PC Server 观察到的天上端 Godot 相机世界位姿；
- LingBot 输出的 `camera_to_lingbot_world`。

求解器从完整三维相机轨迹估计统一尺度、3D 旋转和平移，要求至少 6 对样本、5 秒时长和 0.3 m 平移。PICO 外参按 row-major 4×4 刚体矩阵解析，并同时评估 `camera→head`、逆方向和无外参回退；配对方向由整段轨迹残差选择。LingBot/OpenCV 与 Godot/PICO 的相机局部坐标差异作为固定旋转从配对朝向中估计。点本身始终保留 LingBot 原始坐标，自动 Sim(3) 和手动微调只应用到 `ReconstructionRoot.transform`。

PC Server 从远端玩家的 `NetworkHead` 取得天上端头姿并维护 5 秒历史。PICO 单调时钟通过最小到达延迟映射到 Server 时钟；每帧等待 100 ms 后选择最近的历史位姿，误差超过 250 ms 的配对不会进入求解。

位置 RMS 超过 8 cm 或校正固定相机坐标差异后的旋转 RMS 超过 15° 时，自动解算会被拒绝而不会进入确认阶段。当前仍不处理 OpenXR recenter、跟踪原点跳变和动态物体删除；时钟映射也不是硬件同步，因此仍必须由天上用户确认预览，并在真机上验收 5–10 cm 对齐目标。

每次新建地图都会关闭并重连 Lab 输入，使 LingBot KV/session 重新开始。PC 只接受新 `session_id` 且从 `chunk_id=1` 连续递增的点块；旧会话残包会被丢弃，跳号会中止本次流并要求重试。Lab 过滤后没有有效点的帧返回 `skipped_empty`，不编码 PCCH，也不消耗 chunk ID。

## 地图

地图自动保存到：

```text
user://reconstruction_maps/*.gsmap
```

新文件使用时间优先、类型后缀的命名方式：

```text
2026-07-28T12-34-56_已确认_自动保存.gsmap
2026-07-28_12-34-56_实时重建.gsmap
```

第一种是阶段性或最终自动保存，第二种是用户点击“导出地图”生成的文件。已有地图不会自动改名。

`.gsmap` 是带 SHA-256 校验的单文件容器，包含 manifest、原始 PCCH 点块和已确认配准，不包含原始视频。天上端的准备页会列出 PC Server 地图库；PC 可通过对应 `user://` 目录管理外部文件。

需要在 CloudCompare、MeshLab 等桌面软件中查看时，可以转换为带 RGB 的 PLY：

```powershell
python tools/realtime_reconstruction/gsmap_to_ply.py `
  "C:\path\map.gsmap"
```

默认生成同名二进制 PLY，并保留原始 `lingbot_world` 坐标。需要得到 Godot 中最终显示的配准坐标时添加 `--apply-registration`；需要文本 PLY、置信度字段或 manifest 旁车文件时，分别添加 `--ascii`、`--include-confidence`、`--write-manifest`。运行 `--help` 可查看全部参数。

导入会先完成包校验和配准校验，再原子替换并发布；失败时回滚旧地图。导入地图没有可恢复的 LingBot 在线状态，因此确认后不能“重新配准”；需要继续采集时应清空并开始一次新的实时重建。

PC 接收端以 `0.01` LingBot model unit 的体素网格保留每个空间单元的首个点，重复单元不会进入缓存或下发；append-only 地图上限为 200 万点。最终物理体素尺寸仍受自动尺度估计影响，可在 PointCloud runtime 的 `voxel_size_model_units` 调整。XR 点云使用显式不受光照影响的顶点色 shader；PCCH/PLY 中的相机颜色按非线性 sRGB8 保存，构建 GPU 批次时一次性转换为 Godot Mobile 3D 管线需要的线性 RGB。默认点尺寸为 4 像素；渲染尾批次限制为 1 万点，避免连续追加时反复上传过大的网格。

## 端口

| 端口 | 方向 | 协议 |
| --- | --- | --- |
| `42069/UDP` | PC ↔ Clients | 现有 ENet 控制/玩家同步 |
| `8787/TCP` | PICO helper → PC | PSA2 + PAA1 |
| `18787/TCP` | Godot PC → SSH tunnel | Lab PSA2 输入 |
| `18790/TCP` | SSH tunnel → Godot PC | Lab PCCH 输出 |
| `8791/TCP` | PC → VR Clients | 独立点云发布 |
| `8787/TCP` | Lab loopback | LingBot PSA2 输入 |
| `8790/TCP` | Lab loopback | LingBot PCCH 输出 |

## 专项自检

```powershell
$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'
$Project = 'F:\引擎\Godot项目\GodotSpace\GodotSpace'

$Tests = @(
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/Capture/pico_frame_receiver_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/lingbot_stream_bridge_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/point_cloud_data_channel_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/Session/reconstruction_session_state_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/Registration/reconstruction_registration_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/Persistence/realtime_point_cloud_core_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/reconstruction_point_cloud_runtime_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/UI/reconstruction_ui_self_test.gd',
  'res://Assets/ARSpace/Scripts/RealtimeReconstruction/reconstruction_pipeline_self_test.gd'
)

foreach ($Test in $Tests) {
  & $Godot --headless --path $Project --script $Test
  if ($LASTEXITCODE -ne 0) {
    throw "Realtime reconstruction self-test failed: $Test"
  }
}
```
