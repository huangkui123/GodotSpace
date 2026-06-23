# SpatialCalibration

`SpatialCalibration` 用来把 PICO 4 UE端传回来的 2D 实时画面接入 GodotSpace，并在 server 端提供空间标定面板。

## 运行流程

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

- 当前版本使用 server 端虚拟相机位姿作为反投影依据。PICO metadata 仍会被解析并作为调试/参考信息保留，但不会作为最终标定坐标来源。
- 使用 `PSA2` 视频帧协议和 `PAA1` ACK 协议。
- 深度预测是 best-effort 的辅助功能。如果 HTTP 服务没有启动、加载失败或预测失败，面板仍然可以使用手动深度流程。
- 不建议把深度预测服务直接暴露到公网，除非你已经通过防火墙或反向代理做了访问控制。SSH 隧道方案可以让 HTTP 服务保持私有，同时让 Godot 继续使用 localhost 地址。
