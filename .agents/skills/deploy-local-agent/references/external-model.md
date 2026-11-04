# 接入甲方已有模型服务（external 模式）

此模式复用甲方已经运行的模型，只启动本机 Gateway；不会下载权重、启动 vLLM、配置 SSH 或修改甲方服务。模型可位于本机、受保护的局域网或其他获准网络。Godot Client → Godot Server → Gateway → 模型的链路不变，Client 不持有模型密钥。

## 首次配置

先向部署方取得 **API base URL、准确 model ID、认证方式**，确认允许发送语音转写、UI 上下文和检索证据。只支持 OpenAI-compatible Chat Completions，不代表调用 OpenAI 公有服务；部署方使用何种推理框架不重要，实际协议兼容性必须通过检查。

要求：`POST <base_url>/chat/completions`，支持非流式 `messages`、`tools`、`tool_choice="auto"` 和指定函数名，返回标准 `choices[].message.tool_calls[].function`。普通聊天端点、只有 Responses/厂商私有协议的端点不能直接接入；需要部署方提供适配层。模型必须理解中文指令并按工具 schema 返回参数，不仅仅是能聊天。

在本机忽略的 `Model/generated/local-agent-deploy/runtime.json` 中保留已有 ASR/TTS 设置，增加 `compute.external`：

```json
{
  "wsl_distro": "Ubuntu-20.04",
  "gateway_env": "/ABS/Model/.cache/local-agent-deploy/envs/gateway",
  "compute": {
    "external": {
      "base_url": "https://models.example.test/v1",
      "model_id": "customer-instruct-model",
      "api_key_env": "CUSTOMER_MODEL_API_KEY",
      "gateway_port": 7863,
      "health_check": "models",
      "json_mode": "prompt",
      "request_timeout_seconds": 20,
      "health_timeout_seconds": 5
    }
  }
}
```

示例不是可直接运行的配置，Codex 应使用实际获准地址和当前机器路径；不要覆盖现有 local/remote/asr/tts 字段。不需要下载 Qwen 或安装 vLLM/CUDA：独立 Python 3.12 Gateway 环境安装 `Model/requirements-agent.txt` 即可（Qwen-Agent 仍用于现有工具封装，但 external 的推理调用不依赖 Qwen 模型）。ASR/TTS 依赖按原部署配方安装。

密钥仅从命名环境变量读取，不写进 JSON、URL、命令行或报告。Windows Godot 进程需继承该环境变量；PowerShell 启动器仅把这个指定变量通过 WSLENV 传给 WSL。也可以预先在所选 WSL 的进程环境中提供密钥；注意非交互 `wsl.exe -- python3` 不保证读取交互 shell 配置。配置了 api_key_env 却没有值时明确失败，不匿名重试。无认证的可信 loopback 服务可省略 api_key_env；不要把无认证服务暴露公网。

先验证 **Gateway 所在 WSL** 能访问该地址；Windows 浏览器可访问不代表 WSL 可访问。甲方 API 若绑定另一台主机的 loopback，需要部署方提供获准的可达入口；API 若在当前 Windows 主机，WSL 的 `127.0.0.1` 是否指向它取决于实际网络模式，必须实测，不能猜地址或关闭防火墙。地址、端口、模型 ID 和证书链在能力检查前确定。

base_url 是 API 根路径，如 `/v1` 或 `/service/openai/v1`，不能填写 `/chat/completions`、URL 用户密码、query key 或 fragment。默认要求 HTTPS（loopback HTTP 除外）；只在部署方确认可信网络/传输风险后显式设 `allow_insecure_http: true` 才可使用非 loopback HTTP，不关闭 TLS 校验。自签发证书应配置受信任 CA。

所有 external 请求（健康、首轮工具选择、意图校验、确认、知识证据选择）使用相同认证和传输规则：无密钥时省略 Authorization，禁用自动重定向和 HTTP 自动重试，限制响应为 2 MiB。接口返回 301/302/307/308 时修正为最终 API base URL；不能依靠代理跳转。只有一条完整标准 function call 才可进入后续校验，截断、多个调用或畸形参数不作为执行授权。

## 一键使用与能力检查

Godot 菜单（简化启动页的“高级设置”中）选择 **模型算力：已有模型服务（兼容 API）**，启用自动准备智能助手。选择持久化保存；如果配置中只有 external 且没有历史选择，会默认使用它。历史选择永远优先，不因连接失败静默切换模式。

第一次启动新的 external Gateway 前自动运行 `Model/scripts/check_external_model.py`：

1. 检查模型身份或显式选定的聊天健康探测。
2. 使用真实工具选择适配器和 harness 处理合成问候，要求选择 respond_directly；不下发 Godot 操作。
3. 验证指定函数的 tool_choice 返回合法参数。
4. 按 json_mode 验证 JSON 输出。

这些是少量合成推理请求，可能消耗服务算力/额度；检查总限时 90 秒。失败会显示接入失败，Gateway 不启动；健康且配置一致的已有 Gateway 直接复用。该 smoke 只能确认接口和基本行为，不能证明甲方模型的业务正确率。

诊断入口仍为 `Model/scripts/start_local_agent_runtime.ps1 -Config ABS_RUNTIME_JSON -Status ABS_STATUS_JSON -Role server -Mode external`。与 Godot 一键启动完全相同；正常使用不需要手工设置 MODEL_*。服务身份和 Windows→WSL 可达性继续检查。

## 兼容选项与边界

- `health_check: "models"`（默认）：GET `<base_url>/models` 必须列出配置的 model ID。模型不存在、401 或 404 均失败，不猜模型名、不换模型。
- `health_check: "chat"`：仅当部署方不提供 models 接口时显式使用；发送短合成 Chat 请求检查指定 model 能否响应。它不能证明后端没有模型别名或服务端 fallback。每次 readiness 检查可能发推理请求，包括 Godot 的定期健康检查，需评估负载。
- `json_mode: "prompt"`（external 默认）：不要求服务端支持 response_format；提示模型输出符合 schema 的 JSON，后端照常解析并校验证据，非法输出不能执行或编造答案。
- `json_object` / `json_schema`：部署方明确支持时可启用对应 response_format。不会收到错误后自动降级重试别的协议。
- 首轮选择、意图验证、二次确认、知识证据选择使用同一 base_url/model/key。external 不继承 Qwen 的 chat_template_kwargs/enable_thinking 或原生提示格式；旧 local/remote 配置不变。
- `request_timeout_seconds` 支配单次模型请求；Gateway 原有整轮时限仍生效，设置更长单次时限不等于整轮无限等待。
- 仅支持标准 Bearer API key；Azure 专属 API-Version/API-Key、厂商签名、mTLS 等额外认证需要部署方代理或另做适配，不能宣称任意端点零配置兼容。
- 更换 base URL/model/参数使用独立 Gateway 端口，或先核实并停止旧 Gateway；不会自动抢端口。密钥轮换后也需重启 Gateway，可变更 `credential_revision` 标识避免误复用；记录中不包含密钥值或其散列。
- 升级仓库后核实 Gateway 进程启动时间与部署 commit；配置指纹不包含源代码版本，健康的旧进程不会因拉取代码自动重载。使用原部署停止入口核验 PID 后重启，或先在新端口验收。Godot 也要重启才能载入新的 GDScript。
- 切换模型来源时等新服务验证就绪；Godot 切换实际 WebSocket 连接，并使旧请求和待确认操作失效。切换后重新发起指令，不继续回答切换前的确认。

## 迁移验收

运行 Gateway 单测和默认 Godot 回归，再运行 `scripts/test_server_hosted.py --external-model-fixture --godot GODOT_EXE --project WINDOWS_PROJECT`，覆盖真实 Gateway/harness + 假模型 HTTP API + 三个 Godot 进程。它是协议集成回归，不是真实模型 benchmark。

拿到甲方环境后使用同一启动入口做真实 smoke，并实际验证“打开工作清单”“关闭工作手册→确认”“翻到第17页”“当前页力矩”“故障检索跳转”、否定/取消、错误参数和断线，记录 model ID、版本、时延和用例结果。还需从另一个已运行的模型模式切到 external，确认旧 Gateway 不再接收新指令、旧确认不能执行；只有 external 配置时则重启验证同一 Gateway 的复用。未拿到实际 endpoint/权限时只能报告兼容接口与 mock 集成通过，不虚报甲方模型已接通。
