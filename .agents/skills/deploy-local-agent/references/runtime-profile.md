# 一次部署后的日常启动配置

在当前仓库 `Model/generated/local-agent-deploy/runtime.json` 保存本机配置。该路径已被忽略；不得提交私有主机名、盘符、密钥。用 apply_patch 写入从当前机器探测到的真实路径，下面只是结构示例，不直接复制占位值。

```json
{
  "wsl_distro": "Ubuntu-20.04",
  "gateway_env": "/ABS/Model/.cache/local-agent-deploy/envs/model",
  "compute": {
    "local": {
      "env_dir": "/ABS/Model/.cache/local-agent-deploy/envs/model",
      "model_id": "Qwen/Qwen3-VL-8B-Instruct",
      "model_path": "/ABS/Model/models/local-agent/qwen3-vl-8b",
      "port": 8000,
      "gateway_port": 7861,
      "dtype": "bfloat16",
      "max_model_len": 8192,
      "gpu_memory_utilization": 0.75
    },
    "remote": {
      "ssh_host": "approved-compute-alias",
      "remote_port": 8000,
      "port": 18000,
      "gateway_port": 7862,
      "model_id": "EXACT-REMOTE-SERVED-MODEL-ID"
    }
  },
  "asr": {
    "env_dir": "/ABS/Model/.cache/local-agent-deploy/envs/asr",
    "asr_model": "/ABS/Model/models/funasr/ACTUAL-ASR-DIRECTORY",
    "vad_model": "/ABS/Model/models/funasr/ACTUAL-VAD-DIRECTORY",
    "asr_device": "cpu",
    "port": 8765
  },
  "tts": {
    "env_dir": "/ABS/Model/.cache/local-agent-deploy/envs/tts",
    "model_dir": "/ABS/Model/models/tts/kokoro-int8-multi-lang-v1_1",
    "model": "kokoro-int8-multi-lang-v1_1",
    "tts_device": "cpu",
    "speaker": 17,
    "port": 8767
  }
}
```

地面配置只需 wsl_distro/asr/tts，不创建 model 环境。天上远端模式需要 Gateway 依赖环境，但不必下载本地模型；未配置的 compute 模式选择后应明确失败。CPU/GPU ASR/TTS 选择遵守 deployment.md，必须让健康端点的实际 model/device/speaker 与配置一致。

SSH alias 在所选 WSL 用户的 SSH config 中一次配置；要求已有公钥登录和已验证 host key，不保存密码，不关闭 host key 检查。远端 vLLM 需已部署并在远端 loopback 运行；控制器只建立受保护转发和验证模型 ID，不登录远端安装/启动未知服务。不使用旧 4090 地址/GPU 编号作为新机器默认。未授权或不可达时报告失败，没有本地/云端 fallback。

Godot 菜单中勾选“启动智能助手服务”，Server 选择算力，点击启动；Client 自动准备本机语音服务。选择保存在 user://local_agent_runtime.cfg。服务状态显示在菜单，失败不进入协作场景；可明确取消勾选只启动协作。首次依赖、权重和 runtime.json 缺失会提示使用本 skill，不在每次启动时下载或安装。

`Model/scripts/start_local_agent_runtime.ps1 -Config ABS_RUNTIME_JSON -Status ABS_STATUS_JSON -Role server|client|server_voice -Mode local|remote` 是同一个诊断入口。Windows 隐藏启动，WSL 内 python3 只执行标准库控制器；推理服务使用各自配置的 venv。它验证 WSL 与 Windows 的服务身份/就绪，然后才把 endpoint 写入当前 Godot 进程环境，不修改系统环境变量。

启动器按 WSL 用户使用主机锁，复用健康匹配服务。Gateway 配置指纹覆盖模型 ID、模型端口和环境，远端 SSH 使用 PID/启动时间/配置指纹记录验证归属。模型冷启动默认等待上限 600 秒/服务，锁等待 650 秒；界面轮询不阻塞帧。冲突、超时和配置不符不杀进程。日志在 Model/logs/local-agent-deploy，状态/PID记录在 generated；不记录录音或对话。

退出 Godot 不停止服务，避免同机 Server/Sky Client 相互影响。日常切换模式使用不同的本地模型转发/Gateway 端口；旧服务可能继续占用内存，不能承诺切换自动释放显存。需要释放时用已验证 PID/启动时间/argv 的部署停止入口，确认没有其他客户端使用后操作。严禁按端口或进程名批量杀进程。

验收必须包含：两次启动复用、Server/Sky 同机启动不重复加载、错误模型 ID、占用端口、缺配置、远端不可达、Windows 转发失败，以及 Server 退出后 Client 提示不可用。只把某服务 URL 改成 LAN 不能代替本设计。
