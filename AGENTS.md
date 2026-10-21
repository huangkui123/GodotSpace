# AGENTS.md

本文件适用于整个仓库。若子目录以后新增更具体的 `AGENTS.md`，处理该子目录时同时遵守更深层文件中的约定。

## 1. 仓库与工程根目录

仓库根目录是本文件所在目录：

```text
F:\引擎\Godot项目\GodotSpace
```

真正的 Godot 工程位于下一层：

```text
F:\引擎\Godot项目\GodotSpace\GodotSpace
```

`project.godot`、`export_presets.cfg`、主场景和所有 `res://` 路径都以第二个目录为根。运行 Godot、解析 `res://` 路径或执行 Godot 自检时，`--path` 必须指向该目录。

推荐在 PowerShell 中先定义：

```powershell
$RepoRoot = 'F:\引擎\Godot项目\GodotSpace'
$Project = Join-Path $RepoRoot 'GodotSpace'
$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'
```

Godot 安装在 `D:\godot_modding\bin`。本仓库当前验证过的控制台程序为：

```text
D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe
```

当前引擎报告版本为 `4.4.dev.custom_build.76dfa79fb`。工程的 `config/features` 为 Godot 4.4 和 Mobile。不要擅自用其他 Godot 大版本保存场景或资源，版本差异可能批量改写 `.tscn`、`.tres`、`.res` 和导入元数据。

## 2. 项目概览

GodotSpace 是从 Unity 空间项目迁移而来的 Godot XR/MR 应用。当前主线功能包括：

- PC Server 与 XR Client 的 ENet 多人协作。
- OpenXR 头显、手柄、玩家位姿和 MR 透视。
- 三端语音、音频设备选择和腾讯云实时语音识别。
- 基于 DeepSeek OpenAI-compatible Chat Completions 的背景 LLM 助手。
- 图片、视频、工作清单、步骤动画和 3D 窗口交互。
- PC Server 接收 PICO helper 视频流的空间标定。
- 可选的 Apple Depth Pro 单点深度预测服务。
- 独立 Android companion app，用于 PICO 相机采集和帧流发送。

主场景入口：

```text
res://Assets/ARSpace/Scenes/StartMenu.tscn
```

进入协作空间后加载：

```text
res://Assets/ARSpace/Scenes/ARSpace.tscn
```

## 3. 目录职责

### 仓库根目录

- `README.md`：仓库简介，目前内容很少。
- `TODO.md`：需求和待办资料。读取时注意文件编码，不要在无关任务中重写整份文件。
- `LICENSE`：许可证。
- `GodotSpace/`：Godot 工程主体。
- `Model/`：本地 Qwen Agent Gateway、知识与工具调用 harness、FunASR 服务、benchmark 和服务生命周期脚本；该目录已通过非 squash subtree 纳入本仓库，不要在其中再初始化嵌套 Git 仓库。进入该目录工作时同时遵守 `Model/AGENTS.md`。

### Godot 工程目录

- `Assets/ARSpace/`：当前主线应用代码、场景、UI、数据和美术资源。功能修改通常从这里开始。
- `Assets/ARSpace/Scenes/`：启动菜单、主 ARSpace 场景、桌面玩家、XR 玩家和语音场景。
- `Assets/ARSpace/Prefabs/`：转换后的可复用场景，包含主要 3D UI 和交互组件。
- `Assets/ARSpace/Scripts/AI/`：LLM 服务、知识库、UI 接入和自检脚本。
- `Assets/ARSpace/Scripts/Network/`：ENet 多人、语音传输、音频采集播放和腾讯 ASR。
- `Assets/ARSpace/Scripts/SpatialCalibration/`：PICO 帧协议、标定面板、深度估计和挂载逻辑。
- `Assets/ARSpace/Scripts/UI/`：窗口缩放、统一面板和模型树交互。
- `Assets/ARSpace/Data/`：LLM 结构化知识和 Markdown 手册资料。
- `Assets/StreamingAssets/`：运行时直接枚举的图片、视频、工作清单或外投知识资料。改名会影响脚本拼接出的运行时路径。
- `XR_Main.gd`：PC Server、XR Client、测试模式、观察相机和 MR 透视的顶层运行时切换。
- `addons/`：Godot XR Tools、FFmpeg、TwoVoIP、Unidot、Orbital Tools、Starlight 等第三方或外部插件。
- `companion_app/pico_spatial_anchor_helper/`：独立 Kotlin/Android 工程。
- `tools/depth_prediction/depth_pro_server.py`：独立的 Depth Pro HTTP 包装服务。
- `Scene_Main/`、`scenes/`、`demo/`、`MyPrefab/`、`asset/`：卫星展示、UI 示例、历史场景和迁移资产。修改前先确认是否被主场景引用。
- `.godot/`：本地导入缓存，已被仓库忽略，不要提交。
- `android/`：本地 Godot Android 构建模板或生成目录，目前未纳入版本控制。除非任务明确要求，不要修改或提交。
- `Dabao/`：默认 Android 导出产物目录，目前未纳入版本控制。不要提交 APK 和临时导出文件。

## 4. 启动流程与全局服务

`project.godot` 中的主要 autoload：

- `XRToolsUserSettings`：XR Tools 用户设置。
- `XRToolsRumbleManager`：XR 手柄振动。
- `Global`：窗口和场景间共享引用。
- `NetworkHandler`：ENet 连接、角色选择、玩家和标注同步。
- `VoiceChat`：语音采集、播放、路由、转写和调试状态。
- `LLMAssistantService`：知识检索、语音唤醒、LLM 请求和问答历史。
- `OrbitalManager`：轨道工具管理器。

启动链路为：

1. `StartMenu.tscn` 加载 autoload 并显示网络、音频和角色相关控件。
2. PC Server 调用 `NetworkHandler.start_server()`，然后进入 `ARSpace.tscn`。
3. XR Client 初始化 OpenXR，调用 `NetworkHandler.start_client(server_ip)`，连接成功后进入 `ARSpace.tscn`。
4. `XR_Main.gd` 根据网络角色、`--xr-client`、`--voice-role` 和 `--testmode` 决定桌面观察端或 XR 端行为。
5. 空间标定面板只应在 Server 的 `ARSpace.tscn` 中显示。

修改 autoload、主场景、节点名或场景路径前，先搜索所有引用：

```powershell
rg -n 'NetworkHandler|VoiceChat|LLMAssistantService|ARSpace.tscn|StartMenu.tscn' $Project
```

这些名称和路径相当于跨模块接口，改名需要同步脚本、场景、测试和配置。

## 5. 常用运行命令

主 Godot 工程采用串流方式运行，不通过 Godot 导出产物部署或交付。PC Server 和 XR Client 都使用本仓库指定的 Godot 可执行程序直接启动，并在项目实际使用的 OpenXR/串流链路中联调。除非任务明确要求导出，否则：

- 不执行 `--export-debug`、`--export-release`，也不生成 Windows EXE、Android APK 或其他 Godot 导出产物。
- 不把 export templates、`rcedit`、Android Godot 导出环境或导出成功作为默认开发、验证和交付门禁。
- XR/MR、输入、画面和多端协作的最终验证应在实际串流运行拓扑中完成。
- `companion_app/pico_spatial_anchor_helper` 是独立 Android 工程；修改它时仍按第 14、16 节运行 Gradle 验证，但这不等同于导出主 Godot 工程。

打开编辑器：

```powershell
& $Godot --editor --path $Project
```

启动 PC Server：

```powershell
& $Godot --path $Project -- --voice-role=server
```

启动 XR Client：

```powershell
& $Godot --path $Project --xr-mode on -- --xr-client --voice-role=client --server-ip=<SERVER_IP>
```

没有头显时可用桌面测试模式启动 Client：

```powershell
& $Godot --path $Project -- --testmode --voice-role=client --server-ip=127.0.0.1
```

常用运行时参数：

- `--voice-role=server|client`：选择语音和网络角色。
- `--server-ip=<IP>`：Client 连接地址。
- `--xr-client`：强制 Client/XR 路径。
- `--xr-mode on`：Godot 引擎 OpenXR 模式，应放在项目参数分隔符 `--` 之前。
- `--testmode`：无需头显的玩家与位姿测试模式。
- `--voice-debug`：启用语音调试。
- `--voice-test-tone`：语音链路测试音。
- `--voice-log-path=<PATH>`：覆盖语音日志路径。
- `--voice-input=<DEVICE>`、`--voice-output=<DEVICE>`：覆盖音频设备。

PC Server 观察相机的主要手工检查包括右键转动视角、`W/A/S/D` 平移、`Q/E` 升降、`Shift` 加速和 `Esc` 释放鼠标。

## 6. GDScript 编码约定

- 遵循 Godot 4.4 GDScript 语法和当前文件风格。
- 缩进使用 Tab。不要在同一文件混入空格缩进。
- 文件名和历史 Unity 迁移命名可能不统一。新增通用脚本优先使用 `snake_case.gd`，已有脚本改名需要有明确收益并同步全部引用。
- 类名使用 `PascalCase`，可复用类型按需要声明 `class_name`。
- 函数、变量和信号使用 `snake_case`。常量使用 `UPPER_SNAKE_CASE`。
- 新增函数尽量写返回类型。新增成员、参数和局部变量在类型明确时使用静态类型。
- 稳定场景依赖优先使用 `preload()`。运行时可选资源再使用 `load()`，并处理加载失败。
- 编辑器可配置引用使用 `@export`。节点就绪后才能取得的引用使用带类型的 `@onready`。
- 连接信号前考虑重复挂载和场景重入。需要时使用 `is_connected()` 防止重复连接。
- 场景树和 UI 操作留在主线程。异步 HTTP、网络和音频流程要维护清晰的开始、完成、失败和取消状态。
- 正常可恢复问题使用 `push_warning()`，破坏功能的状态使用 `push_error()`。高频 `_process()` 和网络包处理中的日志应受调试开关或节流控制。
- 避免依赖绝对本机路径。Godot 资源使用 `res://`，可写运行时数据使用 `user://`，外部服务地址通过 ProjectSettings、环境变量或明确参数配置。
- 保持函数职责集中。迁移脚本已经较长时，新增独立协议解析、数据类型或 UI 辅助逻辑可以拆到同模块的小脚本。

## 7. 场景、资源与导入文件

- `.tscn`、`.tres`、`.res`、`.material`、`.mesh` 中的资源路径和 UID 都可能被其他场景引用。
- 小型文本场景可以谨慎编辑。大型 Unity 转换场景优先通过 Godot 编辑器修改，并在保存后检查 diff 是否出现无关重排。
- 不要手工编造 `.uid`。新增脚本或资源需要 UID 时，让当前项目指定的 Godot 版本生成。
- `.import` 是 Godot 导入旁车文件。不要手工改内部字段，不要批量删除。源资源发生实际变化并经过重新导入后，只提交必要的旁车变化。
- `.failed_import` 反映迁移资产的历史导入状态。除非任务包含资源修复，不要进行全局清理。
- 节点名、节点路径、组名、信号连接和 AnimationPlayer 轨道路径都可能是运行时接口。调整层级时搜索 `$NodePath`、`NodePath(...)`、`find_child()`、`get_node()` 和动画轨道引用。
- 中文、空格和括号路径在仓库中很常见。PowerShell 文件操作优先使用 `-LiteralPath`，脚本中使用完整 `res://` 路径。
- 移动源资产时连同它的相关导入元数据一起检查，并重新打开依赖场景确认没有丢失资源。
- 不要把 `.godot/`、`user://` 日志、本地缓存、APK、Gradle build 目录或模型权重加入提交。
- `.gitattributes` 当前仅对 `*.mp4` 和 `*.bin` 配置 Git LFS。新增大型二进制前先检查仓库约定和 LFS 状态，避免直接提交巨型文件。

## 8. 第三方插件与原生库

`addons/` 中包含已导入的第三方代码和原生二进制：

- `godot-xr-tools`：XR 交互基础设施。
- `ffmpeg`：视频解码 GDExtension，带 Windows 和 Linux 动态库。
- `twovoip`：语音编解码和音频相关 GDExtension。
- `unidot`：Unity 包和资产转换。
- `orbital_tools`、`starlight`：轨道与星空功能。

处理规则：

- 业务任务优先在 `Assets/ARSpace/` 做适配，尽量避免直接修改 vendored 插件。
- 任务明确要求修插件时，先阅读插件自身 README、版本文件、许可证和 `plugin.cfg` 或 `.gdextension`。
- 原生 DLL、SO、LIB、EXP 文件视为平台构建产物。不要用空文件替换，不要随意重命名，不要跨平台复制。
- 修改 `.gdextension` 后需要在对应平台验证加载。Godot 启动时出现库加载失败应视为关键错误。
- Godot 启动期间可能创建以 `~` 开头的临时原生库副本。进程退出后它们通常会清理，不要提交这些副本。

## 9. 多人网络约定

`NetworkHandler` 当前使用 ENet：

- 默认地址：`127.0.0.1`
- 游戏端口：`42069`
- 最大 Client 数：`8`
- ENet channel 数：`3`
- Server peer ID：`1`

修改网络代码时：

- 保持 Server 权威边界清晰。新增 `@rpc` 时明确 authority、call mode、reliability 和 channel。
- 接收 `any_peer` RPC 时校验发送方身份、角色、数据大小和允许状态。
- 需要同步到本机的 Server 行为要确认 `call_local` 语义，避免 Server 与 Client 表现分叉。
- 玩家、标记、高亮、窗口位置、标定预览和确认标注的创建与清理必须成对处理。
- Client 断开、Server 关闭、重连和场景切换都要释放旧 peer 和残留节点。
- 不要改变 `42069`、channel 编号或 RPC 参数顺序，除非同时更新全部发送端、接收端和测试说明。
- 网络功能至少进行一台 Server 和两台 Client 的手工回归。重点观察重复玩家、串角色、残留标记、RPC 权限错误和断线恢复。

## 10. XR、输入与 MR 约定

- OpenXR action map 位于 `openxr_action_map.tres`。
- XR 初始化由启动菜单和 `XR_Main.gd` 共同参与。改动任一处都要检查另一个入口，避免重复初始化或 Server 意外进入 XR。
- PC Server 应使用观察相机并关闭 XR。XR Client 应关闭观察相机并启用 XR viewport。
- `enable_passthrough` 控制 MR 透视。设备支持时优先使用 alpha blend，并保留 passthrough API 的兼容路径。
- 无头显自动化使用 `--testmode`。它只能覆盖基础玩家和网络逻辑，无法代替真实 OpenXR、手柄、透视和音频设备验证。
- 输入动作修改需要同步检查 `project.godot`、`openxr_action_map.tres`、XR Controller 脚本和 UI 按键冲突。
- 真实设备回归至少检查头部与双手位姿、射线点击、窗口拖拽、UI 显隐、透视、断开重连和长时间稳定性。

## 11. 语音与腾讯 ASR

语音主服务为 autoload `VoiceChat`，传输实现位于 `voice_transport_enet.gd`。音频包和控制状态使用不同的 ENet reliability/channel 组合，改动时不要把高频音频包改成可靠阻塞队列。

腾讯 ASR 所需环境变量：

```text
TENCENT_ASR_APP_ID
TENCENT_ASR_SECRET_ID
TENCENT_ASR_SECRET_KEY
```

规则：

- 凭据只从环境变量、本地未跟踪配置或运行时安全配置读取。
- 不要把真实凭据写入 `project.godot`、`.tscn`、测试、日志或提交说明。
- ASR 目标采样率为 16 kHz。修改采集采样率、声道或 PCM 格式时同步检查重采样、分包和服务端参数。
- 语音回归覆盖 Server 对 Client、Client 对 Server、两个 Client 同时讲话、开关语音、设备切换和掉线恢复。
- 调试日志默认写入 `user://voice_chat_debug.log`。提交前确认仓库中没有复制出来的真实日志或转写内容。

## 12. LLM 助手与知识库

LLM 配置位于 `project.godot` 的 `[arspace]`：

- 默认 endpoint：`https://api.deepseek.com/chat/completions`
- 默认 model：`deepseek-v4-pro`
- API key 环境变量名：`DEEPSEEK_API_KEY`
- 静态知识库：`res://Assets/ARSpace/Data/llm_knowledge_base.json`
- 文档知识目录：`res://Assets/ARSpace/Data/Knowledge`
- 额外目录：`res://Assets/StreamingAssets/Knowledge` 和 `user://llm_knowledge`

处理规则：

- 不要提交真实 API key，也不要在失败日志中打印 Authorization header。
- 知识 JSON 需要保持现有字段结构。Markdown 和 TXT 会按段落切分，标题、来源、标签和内容应便于检索。
- 专家任务上下文来自工作清单 UI。修改任务数据结构时同步验证 `get_task_context_entries()` 和当前步骤注入。
- 助手依赖 `VoiceChat.voice_transcript_received`，只处理最终转写，并按唤醒词和 listening 状态决定是否回答。
- 队列、取消、上下文轮数、来源列表、本地 fallback 和在线请求错误都要保持可观察状态。
- 调用日志位于 `user://llm_assistant_logs/deepseek_calls.jsonl`。日志不能包含 API key，新增字段也要继续遵守该约束。
- 在线自检会产生真实请求和可能的费用。只有用户明确允许且环境变量已配置时才运行。

## 13. 空间标定、帧协议与 Depth Pro

空间标定相关固定约定：

- PICO helper TCP 端口：`8787`
- 帧 magic：`PSA2`，整数值 `0x50534132`
- ACK magic：`PAA1`，整数值 `0x50414131`
- 帧头长度：`32` 字节
- ACK 长度：`8` 字节
- 单帧上限：`8 MiB`
- metadata 上限：`64 KiB`
- 默认深度 endpoint：`http://127.0.0.1:8765/predict`
- 深度 endpoint 环境变量：`GODOTSPACE_DEPTH_PREDICTION_ENDPOINT`

协议常量同时存在于：

```text
Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd
companion_app/pico_spatial_anchor_helper/app/src/main/java/com/picospatialanchor/helper/AnchorFrameProtocol.kt
```

任何协议改动都要同时更新 Godot 接收端、Android 发送端、单元测试和 `Assets/ARSpace/Scripts/SpatialCalibration/README.md`。优先采用带版本的新 magic，避免让旧包被新解析器误读。

标定流程要求：

- 面板只挂载到 Server 的 `ARSpace.tscn`。
- 点击预览图后可以请求深度，也能在服务不可用时手工调整。
- 预览点、确认点和清除操作需要同步到 Client。
- 收包逻辑必须限制长度、处理半包/粘包、坏 magic、断开和重连。
- metadata 当前用于调试和参考。最终反投影仍使用 Server 虚拟相机位姿，改动坐标来源需要真实设备标定验证。

启动 Depth Pro 服务示例：

```powershell
python "$Project\tools\depth_prediction\depth_pro_server.py" --device cuda --depth-pro-path <PATH_TO_ML_DEPTH_PRO> --checkpoint-path <PATH_TO_DEPTH_PRO_PT>
```

该工具依赖外部 `ml-depth-pro`、PyTorch、NumPy 和模型权重。不要把权重放进仓库。服务默认只绑定 `127.0.0.1`，远程 GPU 推荐通过 SSH 隧道连接。不要在缺少认证和访问控制时暴露到公网。

## 14. Android companion app

工程位置：

```text
GodotSpace/companion_app/pico_spatial_anchor_helper
```

主要配置：

- Android Gradle Plugin `8.9.0`
- Kotlin `2.0.21`
- Gradle Wrapper `8.11.1`
- `compileSdk` 和 `targetSdk` 为 `35`
- `minSdk` 为 `29`
- Java/Kotlin target 为 `11`
- application ID：`com.picospatialanchor.helper`
- 本地 AAR：PICO capture、ToB API 和 ToB service library

Android 端修改规则：

- Kotlin 使用现有 4 空格缩进和尾随逗号风格。
- 相机、前台服务、通知、网络和生命周期改动需要同时检查 `AndroidManifest.xml`。
- `ImageReader` 获得的 `Image` 必须在 `finally` 中关闭。
- 发送线程需要有容量上限和断线恢复，避免采集线程因网络阻塞。
- metadata JSON 字段和二进制帧头属于跨端协议，改名需要同步 Godot 解析端。
- `local.properties`、SDK 本机路径、签名文件和厂商凭据不得提交。

Gradle 验证：

```powershell
Set-Location "$Project\companion_app\pico_spatial_anchor_helper"
if (-not $env:ANDROID_HOME) {
    $env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
}
.\gradlew.bat test
.\gradlew.bat assembleDebug
```

截至 2026-07-15，仓库跟踪了 10 个位于 `app/src/main/res/mipmap-*` 的 `*.webp.import` 文件，Android resource merger 会因这些扩展名失败。遇到该基线时：

- 先确认失败文件确实是这些 Godot 旁车文件。
- 与 companion app 无关的任务只需如实报告，不要顺手改 Android 资源。
- 任务包含 Android 构建修复时，可以移除这些旁车文件，并添加足够窄的忽略规则防止 Godot 再次生成，然后重新运行完整 Gradle 验证。

真机验证还需要 PICO 设备、厂商 AAR 兼容环境、相机权限、通知权限和同一局域网内可访问的 Server `8787` 端口。

## 15. 自动化验证

### Godot 资源加载烟雾检查

```powershell
& $Godot --headless --path $Project --import
```

检查输出中的 parse error、缺失资源、GDExtension 加载失败和 autoload 初始化错误。该命令会更新被忽略的 `.godot/` 缓存，不应产生需要提交的文件。

当前定制 Godot 构建在 headless 导入退出时可能打印 `progress dialog`、`Scan thread aborted`、RID/resource leak 等清理阶段错误，同时仍返回退出码 `0`。只有在退出码为 `0`，且没有脚本解析、资源缺失、autoload 或 GDExtension 错误时，才可把这些已知清理日志单独记录为基线噪声。出现新的错误类型或非零退出码时按验证失败处理。

### LLM 离线自检

以下测试不需要真实 DeepSeek key：

```powershell
$LlmTests = @(
    'res://Assets/ARSpace/Scripts/AI/llm_assistant_self_test.gd',
    'res://Assets/ARSpace/Scripts/AI/llm_assistant_task_ui_self_test.gd',
    'res://Assets/ARSpace/Scripts/AI/llm_assistant_menu_entry_self_test.gd',
    'res://Assets/ARSpace/Scripts/AI/llm_assistant_queue_self_test.gd',
    'res://Assets/ARSpace/Scripts/AI/llm_assistant_http_self_test.gd',
    'res://Assets/ARSpace/Scripts/AI/llm_assistant_voice_panel_self_test.gd',
    'res://Assets/ARSpace/Scripts/AI/llm_assistant_feature_audit_self_test.gd'
)

foreach ($Test in $LlmTests) {
    & $Godot --headless --path $Project --script $Test
    if ($LASTEXITCODE -ne 0) {
        throw "Godot self-test failed: $Test"
    }
}
```

### LLM 在线自检

只有获得明确授权后执行：

```powershell
$env:DEEPSEEK_API_KEY = '<LOCAL_SECRET>'
$env:LLM_ASSISTANT_RUN_ONLINE_TEST = '1'
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_online_self_test.gd'
```

执行后不要在终端摘要、文档、截图或提交中暴露密钥。

### Python 语法检查

使用 `compile()` 可以避免生成 `__pycache__`：

```powershell
python -c "from pathlib import Path; p=Path(r'$Project\tools\depth_prediction\depth_pro_server.py'); compile(p.read_text(encoding='utf-8'), str(p), 'exec')"
```

Depth Pro 的端到端测试还需要外部仓库、权重和可用的 PyTorch 设备。可先检查 `/health`，再用真实 JPEG 请求 `/predict`。

## 16. 按改动范围选择验证

### 仅文档或注释

- 检查 Markdown、路径、命令和术语。
- 运行 `git diff --check`。
- 运行 `git status --short`，确认只有预期文件变化。

### 普通 GDScript 或场景

- 运行 Godot 资源加载烟雾检查。
- 打开直接受影响的场景。
- 覆盖新增逻辑的成功、失败和清理路径。
- 若改动影响 autoload 或主场景，至少走一遍 StartMenu 到 ARSpace。

### LLM、知识库或相关 UI

- 运行全部 7 个离线自检。
- 检查无 key 时的本地 fallback。
- 检查任务上下文、来源、连续追问、队列和语音面板。
- 在线测试保持显式 opt-in。

### 网络、玩家同步或 3D UI

- 启动一台 Server 和至少两台 Client。
- 验证连接顺序、掉线、重连和 Server 关闭。
- 验证头部/双手位姿、标记、高亮、窗口拖拽和清理。
- 持续观察 RPC 错误、重复信号、残留节点和 peer ID 混用。

### 语音或 ASR

- 使用真实输入和输出设备。
- 覆盖单人讲话、双人同时讲话、开关、设备切换和网络恢复。
- 检查 Server 与 Client 两种转写方向。
- 确认日志和调试状态中没有凭据。

### XR、输入或 MR

- 先用 `--testmode` 做基础回归。
- 再使用真实 OpenXR/PICO 设备验证 action map、透视、头手位姿、射线和 3D UI。
- PC Server 与 XR Client 都要检查，避免角色分支回归。

### 空间标定

- 启动 Server、至少一个 Client 和 PICO helper。
- 检查 `8787` 连接、收帧、ACK、断开重连和统计。
- 检查左键取点、深度请求、滚轮微调、右键确认和清除。
- 检查确认点在各 Client 的位置和生命周期。
- 修改协议后运行 Android 单元测试，并做真机互通。

### Android companion app

- 配置 Android SDK。
- 运行 `gradlew test` 和 `gradlew assembleDebug`。
- 处理或明确记录已知的 `*.webp.import` resource merger 基线。
- 真机验证权限、前台服务、PICO 相机、帧率、网络拥塞和停止服务。

### 视频、FFmpeg 或大型资源

- 验证插件成功加载。
- 播放、暂停、恢复、关闭并再次打开视频。
- 运行 2 至 3 分钟，观察黑屏、残留音频、资源泄漏和语音互相干扰。
- 检查 LFS 和二进制 diff，避免意外重编码整批资源。

## 17. Git 与交付检查

提交或交付前执行：

```powershell
Set-Location $RepoRoot
git status --short
git diff --check
git diff -- AGENTS.md
```

对代码任务还要检查完整 `git diff`。最终说明至少包含：

- 完成了什么。
- 关键实现位置。
- 实际运行的验证命令及结果。
- 因硬件、凭据、网络或当前基线未执行的验证。
- 仍存在的风险或后续建议。

以下内容不得出现在提交中：

- `.godot/`、Gradle `build/`、`__pycache__/` 和临时 `~` 原生库。
- `Dabao/` 中的 APK 或导出中间文件。
- API key、腾讯云密钥、签名文件、`local.properties` 和私有服务地址。
- `user://` 中的对话、转写、语音调试或 LLM 调用日志。
- 与任务无关的场景重存、资源重导入和格式化噪声。

完成标准以可复现为准。若某项只能在真实 PICO、XR 头显、多机局域网或云服务上确认，需要提供精确的手工验证步骤和预期结果。
