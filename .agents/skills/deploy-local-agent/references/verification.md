# 分层验收：不能用“进程存在”代替功能正常

先记录测试前的服务和 Git 状态。所有日志/合成测试音放 Model/logs 或 generated；不用真实私密对话作测试材料。

## A. 安装与服务身份

三个环境分别 `python -m pip check`，然后在 Model cwd：

```text
MODEL_PY -m unittest discover -s agent_service/tests -v
ASR_PY -m unittest discover -s asr_service/tests -v
TTS_PY -m unittest discover -s tts_service/tests -v
```

MODEL_PY/ASR_PY/TTS_PY 为本次绝对路径。导入成功不证明 GPU 推理。

external 模式的 MODEL_PY 是独立 Gateway 环境的 Python；按 [external-model.md](external-model.md) 做兼容检查和真实接口验收，跳过下面要求本地 vLLM 四服务的 services/smoke。ASR/TTS 仍分别检查和实测；TTS 单测使用 TTS 环境，Gateway 环境通常没有 sherpa-onnx。

运行 `deployment_check.py services --model-id EXACT_ID`，默认 EXACT_ID 为 Qwen/Qwen3-VL-8B-Instruct（省略参数也是此值）。要求：
- vLLM /v1/models 正好包含部署选定 ID。
- Gateway /healthz 为 godotspace-local-agent，/readyz.status=ready、model=EXACT_ID、vllm/model_found/qwen_agent 均 true。
- ASR /health.status=ready、vad_loaded=true、warmed_up=true；核对实际模型/设备与计划一致。
- TTS /health.service=local-tts、status=ready；CPU 为 device=cpu/model=kokoro-int8-multi-lang-v1_1，GPU 为 device=cuda/model=kokoro-multi-lang-v1_1；speaker 默认 17、speed 默认 1.0。健康检查接受两种设备，但 Codex 必须核对实际值和本次选择一致，不能仅凭配置标签证明 GPU 推理。
- Godot 尚未连接时 godot_connected=false 合理，不能报告工具链已就绪。

WSL 和 Windows 都检查 localhost；只有 Windows Python 可用时可复用检查脚本，否则 PowerShell Invoke-RestMethod 核对同样字段。WSL 可访问、Windows 不可访问属于转发失败，不通过改成 0.0.0.0 或禁用防火墙规避。

## B. 真实模型与语音

运行 `deployment_check.py smoke --model-id EXACT_ID`，应得到真实模型非空文本和合法非静音 PCM。这不验证 harness，也不验证音色/声卡。

ASR 另做真实模型识别：
1. tts 环境运行 `Model/scripts/smoke_local_tts.py`（默认 8767；端口变化时创建只改 endpoint 的忽略目录副本）。有 5 次真实合成数据和 WAV。
2. 对 sample_2.wav（“你是否想打开工作清单？”）运行 asr 环境 `scripts/smoke_local_asr.py WAV --endpoint ws://127.0.0.1:ASR_PORT/ws/asr --auto-vad`，再运行一次不带 --auto-vad，分别覆盖静默和显式停止的 final。
3. 同法用 /v1/speech 合成“智能助手”“智能助手打开工作清单”“关闭工作手册”，按响应 X-Sample-Rate 包装单声道16bit WAV，再送 ASR smoke。不是把 PCM 当现成 WAV。
4. 检查 final 中的完整词尾（尤其“助手”）、无永久 partial、无重复/丢句。现有 ASR smoke 只要求非空 final，Codex 必须额外核对文本；合成音用例通过仍不代表真人麦克风通过。
   对 16kHz 单声道 PCM16 WAV，还需运行 Godot `res://Assets/ARSpace/Scripts/Network/local_funasr_e2e_self_test.gd`，传 `--local-asr-test-wav=PATH --local-asr-expected=智能助手 --local-asr-auto-vad`，再不带 auto-vad 重跑。它验证 Godot 真正收到了完整 final/finished；仅 Python WebSocket 通过不能覆盖 Godot 的连接关闭竞争。
5. 记录首 partial、final 等可测阶段及合成耗时，不把非实时快速喂音频脚本的耗时当用户端端到端时延。若 CPU ASR 太慢，报告测量结果后评估专属 CUDA ASR 环境，不抢占已运行模型显存。

TTS 音色/性能验收使用 `python scripts/benchmark_local_tts.py --model kokoro --speakers 17 18 --threads 2`，在 generated/tts_audition 下得到固定测试文本 WAV 和首次/缓存命中耗时。缓存命中不能冒充首次合成时延。CPU 实时系数 RTF>1 时下一句预加载不保证连续播放；报告真实等待，不承诺 Siri 级延迟。真实 PICO 试听确认数字/单位、否定句、自然停顿和音色；Godot 重启后才加载切句/预加载新代码，服务重启本身不更新已运行客户端。

## C. Godot→Gateway→真实模型→Godot 工具

从根 AGENTS.md 取实际项目/引擎运行方式，不直接运行写死旧盘符的 smoke shell。

1. 使用匹配引擎 `--headless --path PROJECT --import`。脚本解析、资源缺失、autoload、native extension 错误为失败；只可单独记录已知退出阶段噪声。
2. 运行 AGENTS.md 的 7 项 LLM 离线自检，另运行：
   - res://Assets/ARSpace/Scripts/AI/LocalAgent/assistant_command_router_self_test.gd
   - res://Assets/ARSpace/Scripts/AI/LocalAgent/local_endpoint_self_test.gd
   - res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_runtime_self_test.gd
   - res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_bridge_self_test.gd（含切换 Gateway 后连接、会话与工具缓存清理）
   - res://Assets/ARSpace/Scripts/AI/LocalAgent/assistant_speech_self_test.gd
   - res://Assets/ARSpace/Scripts/AI/LocalAgent/assistant_speech_live_smoke.gd
   先确认路径实际存在；上游改名时搜索相应测试，不编造 PASS。
3. 在当前真实 vLLM + Gateway 正常的前提下执行：
```powershell
& $Godot --headless --path $Project --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_e2e_self_test.gd' -- --local-agent-testmode
```
   非默认 Gateway 端口可附加 `--mock-gateway-port=PORT`；参数名历史上带 mock，但它只是覆盖 endpoint。核对该端口运行的确实是真实 Gateway，不是 mock。
   测试应实际推进/回退页码，并验证第17页问题得到当前步骤证据及 2.5N·m。检查退出码和明确 passed 标记，不能只看模型输出一段文字。
4. 默认拓扑运行 `MODEL_PY scripts/test_server_hosted.py --godot GODOT_EXE --project WINDOWS_PROJECT`（Model cwd，WSL 启动 Windows 引擎时项目参数使用 `F:/.../GodotSpace` 形式）。使用独立端口 18761、42869，占用时不杀旧进程。验证一个 Server/两个 Client 只产生一个 Gateway 连接、四次目标端 UI 工具往返、旧 epoch 不进入模型、ready 前不开始倒计时、普通文本分发、答案不串端、Server 断开后助手不可用。测试隔离场景复制，不代表真实角色分配/XR/麦克风/模型质量已通过。旧 local endpoint 和 server_relay 测试只是显式兼容模式，不能当作默认部署验收。
5. 可运行现有 benchmark 作额外回归，但报告实际 model ID、上下文、精度、GPU/运行库和用例数。不能将 mock、旧2B或远程8B/FP8分数套在本次5090的8B/BF16部署上。失败时查 harness trace、Godot状态、模型选择，不能用提高超时掩盖语义失败。

真实模型返回 `malformed_model_arguments` 时，用合成指令核对模型原始输出与解析后的参数。HTTP 200、正常 `finish_reason` 和非空回答仍可能包含未闭合 JSON；这种情况是工具能力验收失败。保留拒绝执行行为，不通过自动补括号或跳过语义校验把失败改成通过。

若部署要求 Sky 不依赖 Ground，额外运行同一个 `test_server_hosted.py` 的 `--sky-only` 和 `--sky-only --external-model-fixture` 两种模式；确认输出 `NO Ground process was started`。真机时在 Sky 上启动 Server + Sky Client + 后端，Ground 保持关闭，执行打开、翻页、确认及问答；随后让 Ground 加入再退出，重复 Sky 命令，结果应继续只返回 Sky。最后关闭 Sky 所在 Server，助手应明确不可用，不向 Ground 自动降级。

## D. 真实交互验收（需要用户/硬件）

启动 Server 和两个 Client，只有指定的 PICO Client 获得 XR 和播报：

| 操作 | 应看到/听到 |
| --- | --- |
| “智能助手”，暂停两秒，再说“打开工作清单” | 唤醒反馈、独立命令框/倒计时；完整指令执行 |
| 同时打开相册/工作清单，说“关闭工作手册”，再说“是” | 询问是否工作清单；只关闭它，不关闭相册 |
| 澄清后点击重新听写，再说“是” | 保留待确认上下文；问答历史合并为同一轮 |
| “翻到工作手册第17页”，确认后问力矩 | 正确页面及有来源的力矩；不把旧页当当前页 |
| 普通讲话后唤醒助手 | 历史按时间排列，不覆盖旧话或把蓝色回复插到中间 |
| 先说 A，立刻点输入语音，再说 B；重复点击重新听写 | 旧 A 的迟到结果只进普通历史，指令只含 B；不丢待确认动作；连接期间不提前消耗倒计时 |
| 天上 Server + Sky Client、地面 Client 同时运行 | 只有 Server 连接 Gateway；两 Client 的 ASR/TTS 各在本机，工具/确认/回复不串端 |
| 关闭天上 Server | 地面 Client 助手不可用并返回菜单；不自动转到地面推理，共享后端不被退出动作停止 |
| “智能助手”、含末尾短字的句子 | 词尾完整、光标最终结束；不是永久 partial |
| TTS 播报、点击停止、继续确认 | 目标 PICO 扬声器发声；不重复播报；恢复 ASR/确认状态 |
| 第二个 Client 发命令、断线重连 | 目标 peer 隔离，无串端操作或串音 |

没有 PICO 或真人讲话时写“硬件验收未执行”，不要写“完整功能全部正常”。未通过项给出具体失败阶段、日志、可复现命令和恢复办法。

最后停掉本次测试临时进程（身份核实），保留用户要求的正式后端；检查 git diff --check/status，不提交导入缓存、录音、日志或临时 DLL。
