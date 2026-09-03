# Qwen 工具路由重构计划

## 目标

让 Qwen 根据用户原话、当前 UI 事实和完整工具定义自主选择工具，不再通过句式映射或
`next_*` 倾向提示替模型做语义决策。同时保留 Godot 动态授权、Gateway 严格校验和
Godot 执行前置条件，避免模型调用当前状态不可用的操作。

本轮不更换或训练模型，继续使用远端
`Qwen3-VL-2B-Instruct-FP8`，由本地 Gateway 通过 SSH 隧道访问。

## 设计边界

- Godot 提供相册、指导书、页码和可前进/后退等真实状态。
- Godot 根据真实状态产生允许工具名称，白名单只表达权限，不表达用户意图。
- Gateway 从受信任的 Python Tool 类生成名称、说明和参数 Schema。
- Qwen 根据用户文本、事实快照和本次完整工具目录，通过 Qwen-Agent 原生函数调用
  选择 UI 工具、任务知识查询、直接回答或澄清工具。
- Gateway 拒绝白名单外工具和非法参数；Godot 在实际修改 UI 前再次校验状态。
- 工具成功与否以 Godot 返回结果为准，模型不能提前宣称操作成功。

## 实施步骤

### 1. Gateway 工具目录与提示词

- 删除未使用的旧系统提示词和“某句式必须调用某工具”的硬编码规则。
- 将当前仅包含名称的 `allowed_tools` 提示改为完整工具目录：
  `name`、`description`、`parameters`。
- 工具说明使用简洁中文，明确操作对象、方向和副作用，不列举固定触发句。
- 使用 Qwen-Agent 原生函数调用传递完整工具定义；Gateway 拒绝一次请求选择多个
  不同工具。
- 将“直接回答”和“澄清 UI 对象”也建模为 Gateway 内部工具，使模型在同一工具
  目录中完成所有路由选择。
- 首次未选择工具时只做一次通用工具选择重试，不注入句式到工具的固定映射。
- 路由使用贪心解码，消除 UI 操作上的采样抖动。

### 2. 最小事实 UI 上下文

- 从 Godot 删除 `ui_routing_hint`、
  `page_turn_target_when_user_omits_target` 和完成句式提示。
- 只发送可见性、对象 ID/标题、当前页、总页数、`can_next` 和
  `can_previous`。
- 不向路由模型发送步骤正文和下一步预览；`query_task_knowledge` 可读取完整任务上下文并返回证据。
- 将允许工具按稳定中性顺序发送，避免列表位置暗示优先级。

### 3. 可观测性

- 保留 Gateway `assistant_final` 中的 `route` 和 `tool_name`。
- 在 Godot 调试事件中记录脱敏后的路由和工具名称，不记录语音原文。
- 测试失败时输出用户用例名称、预期工具、实际路由、实际工具和工具结果。

### 4. 无界面自动测试

提供统一入口 `scripts/test_qwen_tool_routing_headless.sh`，无需打开 Godot 编辑器或
进入 VR：

1. Python WebSocket 客户端模拟 Godot，验证真实 Qwen 的路由选择。
2. Godot `--headless` 实例化相册和指导书场景，验证工具执行后的真实页码。
3. 真实 Qwen + Gateway + headless Godot 完成端到端回归。

覆盖指导书和相册的上一页、下一页、指定页、关闭、两者同时可见时的明确对象和歧义
处理，以及否定、假设、普通问候和任务知识查询。

## 验收标准

- “上一页/前一步”不得调用任何 `next_*` 工具，方向错误为 `0`。
- “下一页/下一步”不得调用任何 `previous_*` 工具。
- 两个分页界面同时可见且用户未说明对象时，不得修改 UI。
- 否定、取消、假设和引用语句不得修改 UI。
- 工具执行后的真实页码与最终反馈一致。
- 白名单外工具和未知参数全部拒绝。
- Python 全量单测、Godot Router headless 测试及真实 Qwen headless 回归全部通过。

## 当前执行结果

- Python Gateway 全量单测：52 项通过。
- 真实 Qwen 路由矩阵：13/13，通过两轮完整运行。
- Godot Router、相册/指导书方向操作和语音面板 headless 测试通过。
- 真实 Qwen → 本地 Gateway → headless Godot 的下一步、上一页闭环通过。

## Git 交付

- 模型仓库仅在 `feature/task-agent-mvp` 上提交 Gateway、测试和本计划。
- GodotSpace 仅在 `feature/local-agent-voice-tools` 上提交 Router 与 headless 测试。
- 保留两个工作区已有的无关修改和 Godot 自动生成文件，不混入本次提交。
