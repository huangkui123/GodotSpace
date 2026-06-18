# LLM 智能助手联调说明

## 知识库资料

- 结构化条目：放入 `res://Assets/ARSpace/Data/llm_knowledge_base.json` 或 `res://Assets/ARSpace/Data/Knowledge/*.json`。
- 手册/领域文档：放入 `res://Assets/ARSpace/Data/Knowledge/*.md` 或 `*.txt`，会按段落自动切分为检索条目。
- 现场投放资料：默认递归扫描 `res://Assets/StreamingAssets/Knowledge` 和 `user://llm_knowledge` 下的 `*.json`、`*.md`、`*.txt`。
- 当前专家任务：由 `WorkListUIView.get_task_context_entries()` 和 `WorkListInfoUIView.get_current_task_context_entries()` 注入运行时上下文；任务详情刷新和翻页时会同步当前步骤。

## 语音转写接入

`LLMAssistantService` 是全局 autoload，启动后会连接现有 `VoiceChat.voice_transcript_received(data)` 信号，不单独录音或调用 ASR。最终转写数据中 `is_final=true` 且文本包含唤醒词时，会触发问答；不需要打开智能助手页面。助手会保留最近几轮语音问题和助手回答，用于理解连续追问；保留轮数由 `llm_assistant/max_conversation_turns` 控制。

语音通话面板会显示助手的临时状态，例如“正在分析问题”，最终回复会作为 `智能助手` 的转写行写入同一个转写框和转写历史。

## 入口

- 主菜单工作页的“智能助手”入口会打开历史问答面板。
- 专家任务详情页顶部的 `AI` 按钮会打开同一历史问答面板。该面板每页显示一条问题/回答，可查看上一条和下一条。

## 项目配置

`project.godot` 的 `[arspace]` 下配置：

- `llm_assistant/endpoint_url`
- `llm_assistant/model`
- `llm_assistant/api_key_environment_name`
- `llm_assistant/require_wake_word`
- `llm_assistant/wake_words`
- `llm_assistant/max_context_entries`
- `llm_assistant/max_conversation_turns`
- `llm_assistant/use_local_fallback_when_unconfigured`
- `llm_assistant/knowledge_base_path`
- `llm_assistant/knowledge_directories`

默认在线 LLM 使用 DeepSeek OpenAI-compatible Chat Completions：

- endpoint: `https://api.deepseek.com/chat/completions`
- model: `deepseek-v4-pro`
- API key 环境变量名：`DEEPSEEK_API_KEY`

不要把真实密钥提交到工程文件。

在线 LLM 调用日志会写入 `user://llm_assistant_logs/deepseek_calls.jsonl`。日志为 JSONL 格式，每次调用包含一条 `request` 和一条 `response` 记录；不会记录 API key。

## 验证命令

下面命令中的 `$PROJECT` 指向 Godot 工程目录，例如 `F:\引擎\Godot项目\GodotSpace\GodotSpace`。

```powershell
$godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe'
$PROJECT = 'F:\引擎\Godot项目\GodotSpace\GodotSpace'

& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_self_test.gd'
& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_task_ui_self_test.gd'
& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_menu_entry_self_test.gd'
& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_queue_self_test.gd'
& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_http_self_test.gd'
& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_voice_panel_self_test.gd'
& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_feature_audit_self_test.gd'
```

在线 LLM 自检默认跳过。要真实调用 endpoint：

```powershell
$env:DEEPSEEK_API_KEY = '<your-deepseek-key>'
$env:LLM_ASSISTANT_RUN_ONLINE_TEST = '1'
& $godot --headless --path $PROJECT --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_online_self_test.gd'
```

现场联调时，详细状态可通过 `/root/LLMAssistantService.get_debug_state()` 查看；其中 `voice_debug.transcription_last_error` 会带出最近一次腾讯 ASR 错误。
