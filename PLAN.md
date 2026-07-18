# GodotSpace 本地 Qwen 语音任务 Agent 计划

## 0. 当前状态与决策

- 阶段 1 Gateway 已实现 `/healthz`、`/readyz`、`/ws/godot`、Qwen-Agent、请求去重、取消入口和 Godot 工具 RPC；Ubuntu 20.04 WSL 中 27 项单测已通过。
- Godot Bridge、`open_album` 原型和 headless 自测位于 `feature/local-agent-voice-tools`。该分支是唯一 Agent 开发基线；不在 `codex/unity-to-godot` 上开发。
- Bridge 基础闭环成立，但进入阶段 3 前必须补齐：无状态请求、取消屏障、目标 Client 上下文、查询/写入分离和相对操作前置条件。
- 当前产品不使用视觉输入，不完全替换 DeepSeek，也不接入虚拟标注、视频、邮件、天气、3D、网络控制等扩展工具。

## 1. MVP 范围

MVP 只完成四件事：

1. Server 上的无状态单请求 Router。
2. “查询下一步”与“确认推进”严格分离。
3. 带原子前置条件的薄任务 Adapter。
4. 从说话者目标 Client 读取上下文并在同一 Client 执行工具。

首期只注册 ID 1“无容器样品实验流程”（20 步）。其他任务当前是禁用占位项，不进入模型工具 Schema。

### 1.1 目标交互

| 用户语音 | Router 权限 | 行为 | `page_index` |
| --- | --- | --- | ---: |
| “调出无容器样品实验指导书” | `OPEN_GUIDE` | 调用 `open_task_guide` | 设为第 1 步 |
| “下一步是什么？” | `READ_ONLY` | 返回下一步预览 | 不变 |
| “下一步应该做什么？” | `READ_ONLY` | 返回下一步预览 | 不变 |
| “这一步怎么做？” | `READ_ONLY` | 返回当前步骤，必要时交给 DeepSeek 解释 | 不变 |
| “进入下一步” | `ADVANCE_STEP` | 调用 `next_task_step` | 加 1 |
| “这一步做完了，继续” | `ADVANCE_STEP` | 调用 `next_task_step` | 加 1 |
| “我还没做完，不要继续” | `NONE` | 不调用状态变更工具 | 不变 |
| “下一步是不是拆操作盖？” | `READ_ONLY` | 只回答问题 | 不变 |

疑问、否定、条件句、引用示例或语义不明确时默认只读。模型不能仅凭生成 `next_task_step` 获得写权限。

### 1.2 MVP 工具

| 工具 | 模型参数 | 作用 |
| --- | --- | --- |
| `open_task_guide` | `task_id`，MVP 仅允许 `1` | 打开唯一启用的指导书；重复打开同一已显示任务时幂等返回当前状态 |
| `get_current_task_step` | 无 | 返回当前步骤，并附带下一步预览；绝不修改 UI |
| `next_task_step` | 无 | 只在 Router 授予 `ADVANCE_STEP` 时推进一步 |

上一步、重播动画和 TTS 朗读暂不作为 MVP 验收项，核心闭环稳定后再按真实需求增加。

## 2. 已有代码基础与缺口

当前 Godot 分支已经具备：

- `WorkListData.id/title/info_data_result` 和逐步 `step/title/info` 数据。
- `WorkListInfoUIView.next_click()`、`pre_click()`、`replay_current_step_animation()`、`play_current_step_voice()`。
- `get_current_task_context_entries()`，可向 DeepSeek 提供当前步骤和完整指导内容。
- 步骤切换会刷新 UI、工作模型动画和助手上下文。

不能直接把现有 View 私有字段当成跨模块 API。应按现有职责增加最小公开方法，不新建任务控制器：

```gdscript
# WorkListUIView：拥有任务目录
func open_task_by_id(task_id: int) -> Dictionary

# WorkListInfoUIView：拥有当前任务步骤 UI
func open_task(task_id: int, result: WorkListInfoDataResult) -> Dictionary
func get_task_snapshot(include_next: bool = true) -> Dictionary
func advance_if_index(
	operation_id: String,
	expected_task_id: int,
	expected_page_index: int
) -> Dictionary
```

`WorkListUIView.open_task_by_id()` 只在自身目录中查找启用任务，并把任务 ID 和步骤数据交给详情 View。详情 View 保存最小的 `_current_task_id`，其公开方法内部可以读取 `page_index`、`page_count` 和 `_info_save_list`；Tool Adapter 只能调用这些公开方法。

## 3. 目标链路

```text
VoiceChat final transcript
        |
        v
AssistantCommandRouter（PC Server 唯一消费者）
        |
        | request_id -> speaker_peer_id 仅保存在 Godot
        v
向目标 Client 请求最新 task snapshot（固定 RPC）
        |
        +-- 知识/步骤解释 --> DeepSeek + 该 snapshot
        |
        +-- 操作命令 --> 无状态 Qwen 请求
                           输入：当前文本 + 脱敏 snapshot + 本请求允许的工具
                           不含：speaker_peer_id、历史对话、NodePath、文件路径
                                  |
                                  v
                           白名单 tool call
                                  |
                                  v
Godot Router 查 request 映射并注入前置条件
        |
        v
目标 Client 固定 RPC -> WorkListInfoUIView 公开方法 -> 结构化结果
```

### 3.1 Router 请求上下文

Router 为每个请求保存短生命周期记录：

```text
request_id
speaker_peer_id
authorization: NONE | READ_ONLY | OPEN_GUIDE | ADVANCE_STEP
snapshot
status
created_at
```

- `speaker_peer_id` 只用于 Godot 端选择目标 Client，不发送给 Gateway 或模型。
- RPC 响应必须来自记录中的目标 peer；其他 Client 的同名响应直接拒绝。
- 请求结束、超时或断线后立即删除映射。
- Server 本地说话者走同一接口，但可使用本地调用代替网络 RPC。

### 3.2 无状态 Qwen 请求

现有 Gateway 的 `session_id` 同时承载连接、历史、锁和去重。MVP 调整为：

- `session_id` 仅表示 Godot 与 Gateway 的传输连接，不表示说话者或对话。
- 每次 Agent 运行只构造“系统提示 + 当前转写 + 最新 UI snapshot”，不读取或追加跨请求 Qwen 历史。
- 单次 Agent 内部的工具循环仍可保留；`assistant_final` 后全部运行上下文丢弃。
- 本地模型并发先保持 1。共享排队只是算力调度，不得共享历史、UI 快照或目标 Client。
- `request_id` 使用 Server 生成的 UUID，在连接范围内关联响应和取消。
- 以后确实需要多轮操作时，再显式拆分 `connection_id` 与 `conversation_id`，不复用当前 `session_id` 语义。

## 4. 查询与写入权限门控

Router 在调用 Qwen 前根据完整、规范化后的转写生成权限；默认 `NONE` 或 `READ_ONLY`：

- 明确“打开/调出 + 指导书名称”才能得到 `OPEN_GUIDE`。
- 明确“进入/继续下一步”或“本步完成 + 继续”才能得到 `ADVANCE_STEP`。
- “下一步是什么/应该做什么”始终是 `READ_ONLY`。
- 出现“不、不要、还没、先别、如果、是不是、是否”等否定、条件或疑问结构时，不授予推进权限。

权限实施两层防护：

1. Gateway 只向本次 Qwen 运行注册权限允许的工具；只读请求看不到 `next_task_step`。
2. Godot Router 在派发工具前再次检查 request 的授权；模型即使伪造工具名也会得到 `permission_denied`。

这里不设计通用确认令牌。MVP 没有删除或共享状态等高风险工具；授权只是 Server 内部请求上下文，不作为模型参数。

## 5. 薄任务 Adapter 与原子推进

`get_task_snapshot()` 返回最小、脱敏、可序列化状态：

```json
{
  "task_id": 1,
  "task_title": "无容器样品实验流程",
  "page_index": 3,
  "page_count": 20,
  "current_step": {"step": 3, "title": "操作准备", "info": "..."},
  "next_step_preview": {"step": 4, "title": "天地通话", "info": "..."}
}
```

`next_task_step` 的模型 Schema 无参数。Gateway/Godot 不信任模型提供相对操作前置条件，而由 Server 从该请求的 snapshot 注入：

```text
operation_id          Server 生成 UUID
expected_task_id      snapshot.task_id
expected_page_index   snapshot.page_index
```

目标 Client 在 Godot 主线程中原子执行：

1. 校验任务界面 ready、任务 ID 相同、当前页等于 `expected_page_index`。
2. 校验未到最后一步。
3. 调用现有 `next_click()`。
4. 验证页码恰好增加 1，返回新的 snapshot。

如果第一次已成功但结果丢失，重试携带旧页码会返回 `stale_state` 和当前 snapshot，不会再次推进。request/tool call 去重仍保留，但不再承担相对操作的最终安全保证。

## 6. 目标 Client RPC

最小 RPC 必须在阶段 3 实现，不能后移：

- `request_task_snapshot(request_id)`：Server 向说话者 Client 请求只读状态。
- `task_snapshot_result(request_id, snapshot)`：Client 回传；Server 校验发送 peer。
- `open_task_guide_rpc(request_id, operation_id, task_id)`：只发给绑定目标。
- `advance_task_step_rpc(request_id, operation_id, expected_task_id, expected_page_index)`：只发给绑定目标。
- `task_operation_result(request_id, operation_id, result)`：关联并回传 Gateway。

所有 RPC 名称和参数固定；不接受模型指定 peer、NodePath、Callable 或任意方法名。目标离线、场景不匹配或响应超时必须失败，不能转到其他 Client 执行。

“这一步怎么做”也先取得目标 Client snapshot，再将当前步骤作为运行时知识传给 DeepSeek，避免 Server 使用错误用户的步骤上下文。

## 7. 取消状态机

`asyncio.to_thread()` 无法强制终止正在运行的 Agent 线程，因此取消语义按副作用阶段定义：

| 状态 | 取消结果 | 约束 |
| --- | --- | --- |
| `queued` | `cancelled` | 从队列移除，不启动模型 |
| `model_running` | `cancel_requested` | 线程可继续，但输出被丢弃，后续工具派发被拒绝 |
| `tool_pending` | `cancelled` | 派发前再次检查状态，不发送 RPC |
| `tool_dispatched` | `too_late` | 已越过副作用边界，不能宣称取消成功 |
| `completed` | `too_late` | 返回实际最终状态 |

必须新增取消屏障：

- Gateway 的工具桥在创建和发送每个 `tool_call` 前检查 request 状态。
- Godot Router 在转发 RPC 前再次检查状态。
- Adapter 在真正修改 UI 前校验 operation 仍被允许；一旦进入原子提交段，取消返回 `too_late`。
- 晚到的 Agent final/tool call 只记录调试信息，不发送给 Godot、不发布助手结果。

测试必须使用“取消后仍尝试调用工具”的阻塞假 Agent，验证 UI 副作用为零；不能只断言收到 `run_error(cancelled)`。

## 8. 错误、配置与本机信任边界

### 8.1 两类错误

`run_error.code` 只描述协议、请求和 Agent 生命周期：

- `duplicate_request_id`
- `cancelled`
- `too_late`
- `gateway_not_ready`
- `agent_error`
- `run_timeout`

`tool_result.error.code` 只描述 Godot 业务执行：

- `invalid_arguments`
- `permission_denied`
- `no_active_task`
- `wrong_task`
- `stale_state`
- `already_last_step`
- `target_offline`
- `wrong_scene`
- `tool_timeout`
- `internal_error`

保留协议 envelope 校验错误，但不要再用 `godot_rpc_error` 包装所有业务失败；未知内部异常可以映射为稳定外部码并在脱敏日志中记录原因。

### 8.2 单一配置来源

所有运行限制只读取 `agent_service/config.py::Settings`。当前默认值保持：

- `max_tool_calls_per_run = 6`
- `tool_timeout_seconds = 5.0`
- `vllm_health_timeout_seconds = 2.0`

文档、测试和启动脚本不得再硬编码另一组默认值。MVP 实际只暴露最多 3 个任务工具，但全局调用上限仍由 Settings 控制。

### 8.3 本机信任边界

MVP 明确只信任本机进程：服务绑定 `127.0.0.1`，`session_id` 是路由键，不是认证身份。因此删除“拒绝恶意本机伪造 session”的验收承诺。

为避免意外连接互相顶替，仍应拒绝重复的活动 `session_id`，而不是静默替换旧连接。未来允许远程访问时再增加启动期随机令牌、TLS 和认证测试。

## 9. 实施阶段

### 阶段 0～1：环境与 Gateway 基线（已完成）

- WSL、CUDA、vLLM、Qwen-Agent 和 27 项 Gateway 单测已通过。
- 基础 WebSocket、工具 RPC、相册原型和错误返回已存在。

### 阶段 2B：阶段 3 前置修正（预计 2～3 天）

1. 禁用跨请求 Qwen 历史，改成无状态消息构造。
2. 实现 request 生命周期和取消屏障，拒绝晚到工具调用。
3. 分离 `run_error` 与 `tool_result.error` 枚举。
4. 统一使用 Settings 的 6 次调用、5 秒工具超时。
5. 拒绝重复活动 `session_id`，文档明确本机信任边界。
6. 给两个 WorkList View 增加上述最小公开接口和 headless 测试。

阶段门槛：上述项目及回归测试全部通过，才能开始正式语音 Router。

### 阶段 3：Router 与目标 Client 最小闭环（预计 3～4 天）

1. `AssistantCommandRouter` 成为 final transcript 的唯一消费者。
2. Godot 保存 `request_id -> speaker_peer_id`，Gateway/模型不可见 speaker。
3. 实现目标 Client snapshot 请求和固定操作 RPC。
4. 实现 `NONE/READ_ONLY/OPEN_GUIDE/ADVANCE_STEP` 权限门控。
5. DeepSeek 改由 Router 调用，并接收目标 Client 的当前步骤上下文。
6. 首先用 mock Agent 和一台 Server、一台 Client 验证读写目标一致。

阶段门槛：同一说话者的 snapshot、工具执行和结果必须来自同一 Client；目标离线不得执行。

### 阶段 4：三工具语音任务闭环（预计 2～3 天）

1. 注册 `open_task_guide`、`get_current_task_step`、`next_task_step`。
2. 工具 Schema 只包含任务 ID 1 及其标题/受控别名。
3. “下一步是什么”返回预览但不翻页。
4. “进入下一步”“本步完成，继续”使用前置条件原子推进。
5. Qwen、DeepSeek 和 VoiceChat 最终只发布一个回答。

阶段门槛：查询零写入、显式推进一次只加一页、重复/结果丢失不二次推进。

### 阶段 5：并发、取消与稳定性（预计 2～3 天）

1. 两个 Client 交替/同时说话，验证无历史、snapshot 和目标串线。
2. 覆盖断线、超时、Gateway 重启、取消竞态和晚到 Agent 线程。
3. 增加脱敏指标：路由权限、目标、工具、耗时、取消阶段和错误码。
4. 保留 `disabled/debug/enabled` 开关以及 DeepSeek 独立回退路径。

预计剩余工期：9～13 天。该估算不包含新任务内容制作和任何非任务工具。

## 10. 测试与量化验收

### 10.1 语义回归集

新增版本化 `task_intent_v1`，至少 100 条中文语音转写，覆盖：

- 下一步查询和当前步骤问答；
- 明确打开与明确推进；
- 否定、条件、反问、引用和 ASR 常见误字；
- 无活动任务、第一步和最后一步。

每次报告固定记录模型权重、Qwen-Agent 版本、系统提示版本、temperature、seed 和样本数。指标定义为：

- 所有未获 `ADVANCE_STEP` 的样本，真实页码变化必须为 `0/N`。
- 获得推进权限的样本，一次请求页码变化必须恰为 1。
- 固定回归集端到端正确路由率目标不低于 98%，不外推为开放场景准确率。

安全性由 Router 权限和 Adapter 前置条件保证，不把“模型统计上没出错”当作写安全边界。

### 10.2 必测场景

- 两名说话者连续请求时，第二次 Qwen 输入不包含第一次历史。
- 目标 Client snapshot 和工具结果来源 peer 一致。
- “下一步是什么”只读；“本步完成，继续”推进一次；否定句不推进。
- 同一 `operation_id` 重放、不同 ID 携带旧 `expected_page_index`、工具成功但结果丢失。
- Gateway 重启后使用旧前置条件重试，返回 `stale_state` 而非再次推进。
- queued/model_running/tool_pending/tool_dispatched 四个取消窗口。
- Qwen 不可用、Godot 未 ready、目标离线和 RPC 超时。
- 现有 27 项 Python 测试、Godot Bridge 自测和 DeepSeek 离线回归全部继续通过。

## 11. MVP 验收标准

1. “调出无容器样品实验指导书”在说话者 Client 打开第 1 步。
2. “下一步是什么/应该做什么”返回下一步内容，`page_index` 不变。
3. “进入下一步/本步完成，继续”只推进一步并返回新的当前步骤。
4. 否定、条件和疑问表达没有写权限，即使模型生成写工具也被拒绝。
5. 重试、结果丢失和 Gateway 重启不会造成连续推进。
6. 不同说话者不共享 Qwen 历史、UI snapshot 或工具目标。
7. “这一步怎么做”使用目标 Client 当前步骤交给 DeepSeek 回答。
8. 取消后不会产生晚到工具副作用；已派发操作明确返回 `too_late`。
9. Qwen/vLLM/Gateway 不可用时不阻塞 VoiceChat、Godot 和 DeepSeek 主链路。
10. 模型不能指定 peer、NodePath、文件路径、脚本、方法或任意 RPC。

## 12. 下一步

先执行阶段 2B，不开始新增业务工具：

1. 为无状态请求和取消屏障补 Python 回归测试，再修改 Gateway。
2. 在 `feature/local-agent-voice-tools` 上为两个 WorkList View 增加最小公开接口及 headless 测试。
3. 定义 task snapshot、权限和两类错误的协议 fixture。
4. 完成后运行 27 项现有测试、新增测试和 Godot Bridge 自测，再进入阶段 3。
