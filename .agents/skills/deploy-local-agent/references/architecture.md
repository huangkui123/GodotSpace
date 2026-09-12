# 当前构成与迁移边界

依据本分支源代码整理（2026-09-12）；配置变化后以源代码和运行时检查为准，不把此表当冻结配置。

| 组件 | 实现入口（相对仓库根） | 作用与默认接口 |
| --- | --- | --- |
| Godot 交互 | GodotSpace/Assets/ARSpace/Scripts/Network/voice_chat.gd、voice_chat_ui.gd | 采集/转写、普通语音历史、唤醒按钮、命令输入框和倒计时 |
| 命令与会话 | GodotSpace/Assets/ARSpace/Scripts/AI/LocalAgent/assistant_command_router.gd、local_agent_client.gd | 唤醒/确认状态、目标 peer、请求关联、Gateway WebSocket |
| Qwen 推理 | Model/scripts/start_vllm.sh | vLLM；127.0.0.1:8000/v1；本地脚本默认 Qwen/Qwen3-VL-2B-Instruct |
| Gateway/harness | Model/agent_service/app.py、agent_factory.py、knowledge_harness.py、tools/ | 7861/ws/godot；工具语义选择、执行意图判定、澄清确认、参数/证据验证与 Godot RPC |
| 流式 ASR | Model/asr_service/app.py、funasr_engine.py、session.py | 8765/ws/asr；paraformer-zh-streaming + fsmn-vad；16kHz 单声道 PCM16 |
| 轻量 TTS | Model/tts_service/、GodotSpace/Assets/ARSpace/Scripts/AI/LocalAgent/assistant_speech.gd | 8767/v1/speech；sherpa-onnx CPU + vits-icefall-zh-aishell3；约 30MB ONNX，8kHz PCM16，由目标 Client 播放到 PICO |

完整交互是：

麦克风 → FunASR → Godot 唤醒/输入状态 → Gateway harness → Qwen 结构化判断 → 安全检查 → Godot 指定 Client 工具 → 返回结果/当前页证据 → UI + TTS → Client 音频输出。

## 已支持的行为

- 语音或按钮唤醒，分段命令输入、倒计时、重新听写；普通转写与助手回复记录分开维护。
- 工作清单、相册等允许窗口的打开/关闭，工作清单翻页、步骤操作、当前页上下文与知识问答。最终能力集合以 Gateway 的 SUPPORTED_TOOL_NAMES 和 Godot 工具适配器为准，不能执行任意节点路径/方法。
- “工作手册”等不精确目标通过模型辅助澄清；待确认状态由 harness/Godot 维护，用户可续答“是/不是”。这不等同于无限制的模型聊天记忆。
- 唤醒等第一句话 10 秒；final 后静默提交 1.2 秒；partial 兜底 5 秒。它们是当前 router 常量，不是 ASR 网络延迟。
- 当前页问答使用 Godot 运行时 entries 和服务端可信证据；不能让客户端写 server-owned 字段，不能因部署缺资产而退回“工具执行完毕”。
- TTS 在请求所属 Client 播放；播报期间暂停该端 ASR 输入以降低自触发，播报后恢复确认窗口；按钮可打断。尚不是全双工语音打断或完整声学回声消除。

## 代码、权重、硬件三类依赖

1. **必须随仓库迁移**：完整 GodotSpace/ 与 Model/，Godot 的 Data/Knowledge、StreamingAssets、工作清单场景、native extensions，以及本 skill。Model 已是 monorepo 子目录，不能再次 git init。
2. **新机器下载/重建**：Python 环境，Qwen 权重，FunASR 与 VAD 权重，TTS 的模型/词典/FST。依赖和模型无需提交；首次下载后应可从本地缓存启动。Qwen/FunASR 记录实际解析的 revision 和文件校验值；TTS 下载器已经固定上游包 SHA256。
3. **不能凭仓库自动变出来**：Windows NVIDIA 驱动、WSL2、匹配 Godot 定制引擎、PICO 串流软件/OpenXR runtime、麦克风/扬声器路由。已验证引擎版本为 4.4.dev.custom_build.76dfa79fb；它的本机路径不是部署标准。

主工程通过 PC 运行和 PICO 串流，不需要导出 APK/EXE。不是在头显内运行 Qwen/ASR；“本地”指新电脑本机，无需旧远程 GPU 或系统中文朗读音色。

## 已发现的迁移陷阱

- 旧 bootstrap 会 clear .venv；旧 ASR 启动脚本使用 .venv，而已有机器实际可能用 .venv-asr。
- 部分 Godot smoke shell 写死旧盘符和引擎路径；先解析底层测试，再用新路径运行，不能把旧脚本无修改直接作为部署总入口。
- scripts/env.sh 会激活旧 .venv 并默认设 HF 镜像。隔离环境不要 source 它；按实际 venv 的 NVIDIA 库目录处理动态链接问题。
- 模型物理目录、served-model-name、Gateway MODEL_NAME 必须一致对应。远程旧脚本还有 8B/FP8/GPU 编号设置，不是新电脑默认。
- ASR 8765 与可选 Depth Pro 默认端口冲突；Depth Pro、视频空间标定、Web demo 7860 不是 Local Agent 必装组件。
- localhost 是各进程所在机器。Windows→WSL 转发必须实际验证；跨 PC 的 Client 不能自动使用另一台机器的 localhost TTS。多机方案需另行明确受保护的连接方式或在各 Client 主机部署 TTS。
- /readyz 的 model_found 不代表 Godot 已连接，更不证明真实工具执行。无模型/无资源时通过的 mock tests 也不代表真实部署通过。
- Git LFS 的 .bin/.mp4 必须是真文件，不是 pointer。虚拟环境、驱动和 native DLL 不可跨平台照搬。
- TTS 下载包未附独立模型许可文本；部署从上游下载，分发离线权重包前另行核对各模型许可，不推定代码许可证覆盖权重。
