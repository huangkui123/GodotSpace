# Unity → Godot 资产迁移台账

Unity 源工程：`F:\spaceproject-V2.0.2_NewPlayerModel\SpaceProject`

Godot 目标工程：`F:\GodotSpace\GodotSpace`

台账只记录业务需要的源资产、目标资产、格式处理和依赖。复制前先检查重复文件、Git LFS 和仓库体积；Unity `.meta` 不作为 Godot 运行资产复制，Godot `.uid` 和导入旁车由指定的 Godot 4.4 构建生成。

## 迁移规则

- 模型优先保留 FBX/GLB 原文件以及纹理；材质在 Godot 中重建并记录透明、双面和色彩空间差异。
- 图片优先保留 PNG/JPEG；视频保留原编码文件并通过仓库现有 `*.mp4` LFS 规则跟踪。
- 音频优先保留 WAV/OGG；步骤录音缺失时只记录缺口，不生成伪录音。
- 业务目标按 `Assets/ARSpace/` 的模块目录放置；运行时直接枚举的媒体继续放在 `Assets/StreamingAssets/`，不得随意改名。
- 大型二进制复制前执行 `git check-attr filter -- <file>` 和 `git count-objects -vH`。根规则覆盖 `*.mp4` 与 `*.bin`；航天员目录已增加只作用于 `Source/*.fbx` 的 LFS 规则，其他大型 FBX、贴图或音频仍需逐项决定。

## 资产清单

| 类别/用途 | Unity 源路径 | Godot 目标路径 | 当前状态 | 格式/依赖与后续动作 |
| --- | --- | --- | --- | --- |
| 无容器实验柜及工作效果 | `Assets/ARSpace/Models/dashiyangui/`、`xiaoshiyangui/`、`zhouxinjigou/`，以及 `Scripts/WorkListCanvas/Containerless/` | `Assets/ARSpace/Models/WorkEffect.prefab.tscn`、对应模型目录、`Scripts/WorkListCanvas/Containerless/` | 已迁移待逐步对齐 | 源目录约 168.75 MiB；当前 TGA 已有成功的 Godot 4.4 `.import`，但同时残留大型历史 `.failed_import` 副本；中文材质名需在场景引用层验证；清理重复文件必须另立资产治理任务 |
| 工作清单 UI 与图标 | `Assets/ARSpace/Scripts/WorkListCanvas/` 及其 prefab/StreamingAssets 图片 | `Assets/ARSpace/Scripts/WorkListCanvas/`、`Prefabs/UI/WorkListCanvas/`、`Assets/StreamingAssets/Images/` | 已迁移待对齐 | 任务 1—5 是基线；2—5 未配置；6—8 不复制到活动 UI；媒体路径在第二阶段逐项校验 |
| 步骤图片/视频 | Unity `StreamingAssets/Images/step*.png`、`StreamingAssets/Videos/` | `Assets/StreamingAssets/Images/step*.png`、`Assets/StreamingAssets/Videos/` | 图片已原样迁入，视频待取回 LFS/补迁 | Unity/Godot 图片目录均为 182 张、54.66 MiB，逐文件 SHA-256 一致；第 12、13、16—20 步仍需按 Unity 主线修正映射；MP4 已由 LFS 规则覆盖 |
| 步骤解说音频 | `Assets/Resources/Audios/1.mp3`—`20.mp3`，以及 `step1.mp3`—`step5.mp3` 和提示音 | 计划放入 `Assets/StreamingAssets/Audio/WorkList/` | 已确认源资产，第二阶段按需复制 | `WorkEffect.prefab` 的 20 个 `SoundCollider.soundName` 逐一引用 1—20；源目录 34 个 MP3、约 4.93 MiB；无录音时才使用平台 TTS 并保留文字降级 |
| UI 图标与窗口贴图 | `Assets/ARSpace` UI prefab、Sprites/Textures | `Assets/ARSpace/Textures/`、`Prefabs/UI/` | 大部分已迁移 | 保留可追溯文件名；检查中文/空格路径和重复贴图，不批量重导入 |
| 航天员全身模型、骨骼和纹理 | `Assets/ARSpace/Models/09_YuHangYuan 1/china_rig.fbx`、`Prefabs/china_rig.prefab`、`china_rig_VRIK.prefab`、同目录材质和纹理 | `Assets/ARSpace/Characters/Astronaut/` | 第一阶段已迁移 | FBX 走目录级 LFS；44 张纹理生成 1024 上限副本和 4 个导入别名，目标约 49.1 MiB；导入为 8 网格、33 骨骼、无动画；详情见 `astronaut_avatar_migration.md` |
| XR 手部/手势资产 | `china_rig` 手指骨骼、Unity XR Player/Animator 与输入脚本引用 | `Assets/ARSpace/Characters/Astronaut/` 与 `Player_XR.tscn` | 第一阶段已适配 | 自定义双骨 IK、单指链握拳/扣机、3 种主控模式和固定 7 字段网络状态已接入；未复制 Unity XR SDK 或 FinalIK；真实 PICO 视觉/输入待设备验收 |
| 工具模型 | `Assets/ARSpace/Models/gongju/newgongju.fbx` 及同目录材质/纹理 | 计划 `Assets/ARSpace/Models/Tools/` | 主模型已转换，依赖待核对 | 源目录约 41.41 MiB；目标已有 FBX/材质，源 Blend 与 TGA 未迁入；按步骤引用补依赖，避免整库机械复制 |
| 图片中心 | Unity `StreamingAssets/Images/` | `Assets/StreamingAssets/Images/` | 已迁移 | 运行时直接枚举，禁止随意改名；后续补缩略图和异常文件测试 |
| 视频中心 | Unity `StreamingAssets/Videos/` | `Assets/StreamingAssets/Videos/` | 已迁移 | FFmpeg GDExtension 播放；验证编码、释放和黑屏恢复；MP4 走 LFS |
| 可放置 3D 模型 | `Assets/ARSpace/Prefabs/3DModels/Fern`、`Pine_L`、`Red Bush`、`Grass Patch`、`Microscope`、`Pine_M`；入口 `Prefabs/UI/3DModelCanvas/` | 计划 `Assets/ARSpace/Models/Placeable/` | 已确认 6 个基线模型及 UI 顺序，第二阶段待复制 | 四种植被依赖 Visual Design Cafe shaderx/TIF 材质，显微镜依赖 `Laboratory_Interior/Models/Microscope.FBX` 和 4 张 PBR 贴图；Unity 抓取/描边组件必须在 Godot 重做 |
| 邮件、拍照和涂画 UI | Unity Capture/Mail prefab、脚本和图标 | 计划 `Assets/ARSpace/Prefabs/UI/Assistance/` 与相应脚本 | 第二阶段待迁移 | 只迁移 UI/业务资产，不复制真实作业图片、账号、服务地址或凭据 |
| 静态天气演示 | Unity 天气 prefab、固定图标和演示数据 | 计划 `Assets/ARSpace/Data/Weather/`、`Textures/Weather/` | 第三阶段待迁移 | 只做随包静态数据，不复制或引入真实天气 API 密钥 |

## 航天员资产明细

已确认的源入口：

- 模型：`Assets/ARSpace/Models/09_YuHangYuan 1/china_rig.fbx`（30,644,608 字节）。
- prefab：`Assets/ARSpace/Models/09_YuHangYuan 1/Prefabs/china_rig.prefab` 与 `china_rig_VRIK.prefab`。
- 依赖：同目录 8 个 Unity 材质、44 张 PNG/JPG 纹理；VRIK 组件依赖 RootMotion FinalIK。
- Unity importer：Humanoid，`importAnimation=0`。动作必须来自程序化 IK/手势骨骼或另行确认的动画，不能假定 FBX 内带动作。

复制时同时记录：

- 原始模型文件和 Unity importer 的比例、轴向、动画导入配置。
- 直接依赖的材质、基础色/法线/金属粗糙度/透明贴图。
- HMD、左右手目标需要驱动的头、颈、肩、上臂、前臂、手、脊柱和骨盆骨骼名称。
- 手势 Animator 参数或手指骨骼；不迁移 Unity 运行时 SDK DLL。
- Godot 目标文件、导入结果、材质重建差异和许可说明。

## 行为证据与发布物

2026-07-16 审计结果：

- 在 `F:\spaceproject-V2.0.2_NewPlayerModel` 全树未发现最终 `.exe`、`.apk`、`.aab` 或独立发布目录。
- Unity `ProjectSettings/EditorBuildSettings.asset` 唯一启用场景是 `Assets/ARSpace/Scenes/VRSpace.unity`（Unity 2021.3.15f1）；缺少发布包时，不能仅从该设置推断 AR 与 PC 最终发布行为。
- `Assets/StreamingAssets/Videos/Demo1.mp4`（27,002,298 字节）和 `SpaceTalk.mp4`（202,972,963 字节）是业务媒体，不应自动视为最终行为录屏。
- `Assets/Resources/2024-07-15 16-46-38.mp4`（154,512,295 字节）是录屏候选，尚需项目负责人观看确认后才能提升为最高优先级行为证据。
- Godot 工作树中的 `Assets/StreamingAssets/Videos/Demo1.mp4` 当前是 133 字节 Git LFS 指针；未取回 LFS 对象的开发机不能执行真实视频播放验收。

找到新证据后，在变更实现前先更新 `phase_1_replication_baseline.md` 的证据优先级结论和对应验收用例。
