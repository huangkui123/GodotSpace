# SpatialCalibration

`SpatialCalibration` 将 PICO 4 Ultra Enterprise 的相机画面接入 GodotSpace。柜体标定由天上端本地完成；下文旧有单点深度标注仍由 Server 操作。

通过仓库根目录 `Start-GodotSpace.cmd` 启动时，采集和完整投屏默认使用 USB，不要求头显 Wi-Fi。启动器自动配置 SKY helper 的两个目标为 Android loopback `127.0.0.1:8789` / `127.0.0.1:8787`，再通过 ADB reverse 送到 SKY 接收端与 PC 转发服务；后者将相机帧和 ACK 转发到本机或远端 Server `8787`。两个发送队列及断线恢复互不阻塞，`PSA2/PAA1` 协议不变。完整虚实叠加投屏由独立 USB 编码通道提供，不占用相机帧协议。下文填写 IP、手动启动 helper 的步骤仅用于旧的手动入口；首次权限授权仍须在头显完成。

## 真实 CAD / 自定义柜体自动视觉标定

天上端进入 ARSpace 后，在头显主面板点击「柜体标定」。Helper 目标为天上端电脑 IP、端口 **8789**。顶部可选择真实 `.magics` CAD（默认 **1:1**）或自定义长方体（默认 **宽 45、高 121、深 80 cm**，可直接修改）。两种模式均在 3 秒准备后进行 12 秒移动多视角采集（最多 16 个视点）。自定义柜体从部分可见柜面/边线联合求解同一个三维位姿，真实 CAD 匹配特征后检查世界位姿一致性；重复静止视点不计入，成功后显示预览，不需要人工角点、检测框或深度服务。检查后点击应用，整体对齐虚拟世界与当前选定柜体。

两种模式均支持无实物合成演练，调用真实识别进程，但不允许应用到现场空间。都需要本机 Python 环境；自定义柜体无需 CAD/模板数据。当前识别器仍为实验性基线，实柜覆盖率与精度尚未验收。详细操作、取景要求、部署及验证见 [自动视觉标定](cabinet_visual_runtime.md)。[旧四角标定记录](cabinet_calibration.md)及下文单点深度标注保留原有实现。

CAD 现场取景使用 PICO 4 Ultra 的设备相机外参和已校正单眼图像；缺失时不采用头部近似回退。metadata、坐标转换和验证说明见 [相机参数说明](camera_model.md)。

## 旧有单点深度标注（Server / 8787）

1. 按常规方式启动 GodotSpace 的 server 和 client。
2. server 进入 `ARSpace.tscn`。场景里的 `SpatialCalibrationPanel` 只会在 server 进程中显示。
3. 在PICO端安装并启动配套 helper：`res://companion_app/pico_spatial_anchor_helper`。
4. 在 helper 里填写面板上显示的 server IP，端口使用 `8787`。
5. 可选：启动 Depth Pro 服务，用来在点击后先预测初始深度：
   `python tools/depth_prediction/depth_pro_server.py --depth-pro-path <path-to-ml-depth-pro>`
   如果权重文件不在 Depth Pro 仓库目录内，可以显式传入：
   `python tools/depth_prediction/depth_pro_server.py --depth-pro-path <path-to-ml-depth-pro> --checkpoint-path <path-to-depth_pro.pt>`
   如果要明确使用 GPU：
   `python tools/depth_prediction/depth_pro_server.py --device cuda --depth-pro-path <path-to-ml-depth-pro>`
   服务默认会在启动时预加载模型。只有在希望第一次点击时再懒加载模型时，才添加 `--no-preload`。
   如果把 Depth Pro 放在远端 GPU 服务器上运行，推荐让服务只绑定服务器本机回环地址，然后用 SSH 隧道转发：
   - 在 `lab_4090` 上运行：`python tools/depth_prediction/depth_pro_server.py --device cuda --host 127.0.0.1 --port 8765 --depth-pro-path <path-to-ml-depth-pro>`
   - 在运行 Godot 的 PC 上运行：`ssh -N -L 8765:127.0.0.1:8765 lab_4090`
   这样 Godot 仍然可以使用默认地址 `http://127.0.0.1:8765/predict`。如果确实需要绕过隧道并让 Godot 直连其他地址，可以设置环境变量 `GODOTSPACE_DEPTH_PREDICTION_ENDPOINT`，例如 `http://116.177.253.45:8765/predict`。
6. 在 server 面板中的 PICO 预览画面上点击一个点。面板会先等待深度预测；预测成功后，在三维场景中显示预览点。
7. 如有需要，用鼠标滚轮沿当前射线方向微调深度。
8. 用鼠标右键确认当前点。确认后的点会通过 `NetworkHandler.send_remote_annotation()` 同步到 client/VR 进程中显示。

## 交互方式

- 鼠标左键：选择一个视频画面中的像素点，并发起深度预测。
- 鼠标滚轮：沿当前射线方向手动调整深度；一旦手动调整，就会立即显示三维预览点。
- 鼠标右键：确认当前三维预览点，并把它固定到场景中。

## 说明

- 本节的单点深度标注仍使用 server 端虚拟相机位姿作为反投影依据；柜体四角标定使用本地 XRCamera 头姿及直连相机 metadata，二者坐标来源不同。
- 使用 `PSA2` 视频帧协议和 `PAA1` ACK 协议。
- 深度预测是 best-effort 的辅助功能。如果 HTTP 服务没有启动、加载失败或预测失败，面板仍然可以使用手动深度流程。
- 不建议把深度预测服务直接暴露到公网，除非你已经通过防火墙或反向代理做了访问控制。SSH 隧道方案可以让 HTTP 服务保持私有，同时让 Godot 继续使用 localhost 地址。
