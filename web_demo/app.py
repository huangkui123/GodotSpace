import asyncio
import base64
import binascii
import json
from io import BytesIO
from pathlib import Path
from typing import Any, Literal
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, HTMLResponse
from openai import OpenAI
from pydantic import BaseModel
from PIL import Image, UnidentifiedImageError

from examples.qwen3vl_tool_call_demo import build_agent, create_demo_image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GENERATED_DIR = PROJECT_ROOT / "generated"
UPLOAD_DIR = GENERATED_DIR / "uploads"
MODEL_SERVER = "http://127.0.0.1:8000/v1"
MODEL_NAME = "Qwen/Qwen3-VL-2B-Instruct"
MAX_UPLOAD_BYTES = 12 * 1024 * 1024
MAX_IMAGE_PIXELS = 1_000_000
MAX_IMAGE_EDGE = 1280

app = FastAPI(title="Qwen3-VL Local Vision and Agent Demo")


class CustomRunRequest(BaseModel):
    prompt: str
    image: str | None = None
    mode: Literal["vision", "agent"] = "vision"
    use_demo_image: bool = False


HTML = """<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Qwen3-VL Local Testbench</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f4f6f5;
      --panel: #ffffff;
      --ink: #17202a;
      --muted: #64717f;
      --line: #d6dde5;
      --soft: #eef3f2;
      --accent: #0f766e;
      --accent-strong: #115e59;
      --accent-ink: #ffffff;
      --warn: #9a3412;
      --ok: #116b3b;
      --shadow: 0 10px 28px rgba(22, 31, 43, 0.08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--ink);
    }
    button, input, textarea {
      font: inherit;
    }
    .app {
      width: min(1240px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 24px 0;
    }
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 18px;
      border-bottom: 1px solid var(--line);
      padding-bottom: 16px;
      margin-bottom: 18px;
    }
    h1 {
      margin: 0;
      font-size: 23px;
      font-weight: 760;
      letter-spacing: 0;
    }
    h2 {
      margin: 0;
      font-size: 16px;
      font-weight: 720;
      letter-spacing: 0;
    }
    .status {
      min-width: 220px;
      text-align: right;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.45;
    }
    .grid {
      display: grid;
      grid-template-columns: minmax(320px, 0.82fr) minmax(420px, 1.18fr);
      gap: 16px;
      align-items: start;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
      padding: 16px;
    }
    .panel-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 12px;
    }
    .media-box {
      width: 100%;
      aspect-ratio: 3 / 2;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #edf1f4;
      display: grid;
      place-items: center;
      overflow: hidden;
    }
    .media-box img {
      width: 100%;
      height: 100%;
      object-fit: contain;
      display: block;
    }
    .stack {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .field {
      display: flex;
      flex-direction: column;
      gap: 7px;
    }
    label, .label {
      color: #354151;
      font-size: 13px;
      font-weight: 680;
    }
    textarea {
      width: 100%;
      min-height: 136px;
      resize: vertical;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 11px 12px;
      color: var(--ink);
      line-height: 1.55;
      background: #fbfcfd;
    }
    input[type="file"] {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 9px;
      background: #fbfcfd;
      color: var(--muted);
    }
    .template-row {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 8px;
    }
    .segmented {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      border: 1px solid var(--line);
      border-radius: 6px;
      overflow: hidden;
      background: #f7f9fb;
    }
    .segmented label {
      min-height: 40px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      cursor: pointer;
      color: var(--muted);
      border-right: 1px solid var(--line);
    }
    .segmented label:last-child { border-right: 0; }
    .segmented input { accent-color: var(--accent); }
    .segmented label:has(input:checked) {
      background: var(--soft);
      color: var(--accent-strong);
    }
    button {
      min-height: 42px;
      border: 0;
      border-radius: 6px;
      background: var(--accent);
      color: var(--accent-ink);
      font-weight: 720;
      cursor: pointer;
      font-size: 14px;
      padding: 0 14px;
    }
    button:hover { background: var(--accent-strong); }
    button:disabled {
      cursor: wait;
      opacity: 0.65;
    }
    .secondary {
      background: #e7edf1;
      color: #203040;
      border: 1px solid #cbd5df;
    }
    .secondary:hover { background: #dce5eb; }
    .ghost {
      background: #fbfcfd;
      color: #243244;
      border: 1px solid var(--line);
      min-height: 36px;
      padding: 0 10px;
      font-size: 13px;
      font-weight: 650;
    }
    .ghost:hover { background: #edf3f4; }
    .actions {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
    }
    .results {
      grid-column: 1 / -1;
      display: grid;
      grid-template-columns: minmax(320px, 0.82fr) minmax(420px, 1.18fr);
      gap: 16px;
      align-items: start;
    }
    .answer {
      border-left: 4px solid var(--ok);
      padding: 12px 14px;
      background: #f0faf4;
      border-radius: 4px;
      min-height: 78px;
      font-size: 16px;
      line-height: 1.6;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .timeline {
      display: grid;
      gap: 10px;
    }
    .event {
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 10px 12px;
      background: #fbfcfd;
    }
    .event-title {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      color: #334155;
      font-size: 13px;
      font-weight: 720;
      margin-bottom: 8px;
    }
    .event-title span:last-child {
      color: var(--warn);
      text-align: right;
    }
    pre {
      margin: 0;
      overflow-x: auto;
      white-space: pre-wrap;
      word-break: break-word;
      color: #111827;
      font-size: 13px;
      line-height: 1.45;
    }
    details {
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #fbfcfd;
      padding: 10px 12px;
    }
    summary {
      cursor: pointer;
      color: var(--muted);
      font-weight: 680;
      font-size: 13px;
    }
    details pre { margin-top: 10px; }
    .empty {
      color: var(--muted);
      font-size: 14px;
      padding: 10px 0;
    }
    @media (max-width: 900px) {
      .app {
        width: min(100vw - 24px, 760px);
        padding: 16px 0;
      }
      header {
        align-items: flex-start;
        flex-direction: column;
      }
      .status { text-align: left; }
      .grid, .results {
        grid-template-columns: 1fr;
      }
      .template-row {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
    }
    @media (max-width: 520px) {
      .actions, .template-row, .segmented {
        grid-template-columns: 1fr;
      }
      .segmented label {
        border-right: 0;
        border-bottom: 1px solid var(--line);
      }
      .segmented label:last-child { border-bottom: 0; }
    }
  </style>
</head>
<body>
  <main class="app">
    <header>
      <h1>Qwen3-VL 本地测试台</h1>
      <div class="status" id="status">正在检查服务...</div>
    </header>

    <div class="grid">
      <section class="panel stack">
        <div class="panel-head">
          <h2>固定标签 Demo</h2>
        </div>
        <div class="media-box">
          <img id="demo-image" alt="inventory label" src="/api/demo-image">
        </div>
        <button id="run-demo" type="button">运行库存工具链</button>
      </section>

      <section class="panel stack">
        <div class="panel-head">
          <h2>自定义视觉测试</h2>
          <button class="secondary" id="use-demo" type="button">使用示例图</button>
        </div>
        <div class="media-box">
          <img id="custom-preview" alt="selected image" src="/api/demo-image">
        </div>
        <div class="field">
          <label for="image-input">图片</label>
          <input id="image-input" type="file" accept="image/*">
        </div>
        <div class="field">
          <div class="label">问题模板</div>
          <div class="template-row">
            <button class="ghost" type="button" data-prompt="请读取图片中所有可见文字，并按字段名和值输出。">全文 OCR</button>
            <button class="ghost" type="button" data-prompt="请提取图片中的关键信息，返回紧凑 JSON。">结构化 JSON</button>
            <button class="ghost" type="button" data-prompt="请描述图片里的主体、数量、颜色和位置关系。">画面理解</button>
            <button class="ghost" type="button" data-prompt="请读取图片中的 SKU 和目的地。先只用准确 SKU 调用库存工具；等待工具返回后，再用返回的 warehouse 和图片里的目的地调用配送估算工具。不要在同一轮同时调用两个工具，最后用中文总结。">工具调用</button>
          </div>
        </div>
        <div class="field">
          <label for="prompt">问题</label>
          <textarea id="prompt">请读取图片中所有可见文字，提取关键字段，并说明你看到了什么。</textarea>
        </div>
        <div class="segmented" aria-label="运行模式">
          <label><input type="radio" name="mode" value="vision" checked>视觉问答</label>
          <label><input type="radio" name="mode" value="agent">Agent + 工具</label>
        </div>
        <div class="actions">
          <button id="run-custom" type="button">运行自定义测试</button>
          <button class="secondary" id="clear-result" type="button">清空结果</button>
        </div>
      </section>

      <div class="results">
        <section class="panel stack">
          <div class="panel-head">
            <h2>回答</h2>
          </div>
          <div class="answer" id="answer">等待运行。</div>
          <details>
            <summary>Raw messages</summary>
            <pre id="raw">[]</pre>
          </details>
        </section>

        <section class="panel stack">
          <div class="panel-head">
            <h2>工具与事件</h2>
          </div>
          <div class="timeline" id="timeline">
            <div class="empty">事件会显示在这里。</div>
          </div>
        </section>
      </div>
    </div>
  </main>
  <script>
    const statusEl = document.getElementById("status");
    const answerEl = document.getElementById("answer");
    const timelineEl = document.getElementById("timeline");
    const rawEl = document.getElementById("raw");
    const runDemoButton = document.getElementById("run-demo");
    const runCustomButton = document.getElementById("run-custom");
    const clearButton = document.getElementById("clear-result");
    const useDemoButton = document.getElementById("use-demo");
    const imageInput = document.getElementById("image-input");
    const customPreview = document.getElementById("custom-preview");
    const promptEl = document.getElementById("prompt");
    const templateButtons = document.querySelectorAll("[data-prompt]");

    let customImageData = null;

    const pretty = (value) => {
      if (typeof value === "string") {
        try { return JSON.stringify(JSON.parse(value), null, 2); }
        catch { return value; }
      }
      return JSON.stringify(value, null, 2);
    };

    const setBusy = (busy) => {
      runDemoButton.disabled = busy;
      runCustomButton.disabled = busy;
    };

    const renderEvents = (events) => {
      timelineEl.innerHTML = "";
      if (!events || events.length === 0) {
        timelineEl.innerHTML = '<div class="empty">没有工具调用事件。</div>';
        return;
      }
      for (const event of events) {
        const node = document.createElement("div");
        const title = document.createElement("div");
        const kind = document.createElement("span");
        const name = document.createElement("span");
        const body = document.createElement("pre");

        node.className = "event";
        title.className = "event-title";
        kind.textContent = event.kind || "event";
        name.textContent = event.name || "";
        body.textContent = pretty(event.payload ?? "");

        title.appendChild(kind);
        title.appendChild(name);
        node.appendChild(title);
        node.appendChild(body);
        timelineEl.appendChild(node);
      }
    };

    const renderResult = (data) => {
      answerEl.textContent = data.answer || "没有返回内容。";
      renderEvents(data.events || []);
      rawEl.textContent = pretty(data.raw || data);
    };

    const clearResult = () => {
      answerEl.textContent = "等待运行。";
      timelineEl.innerHTML = '<div class="empty">事件会显示在这里。</div>';
      rawEl.textContent = "[]";
    };

    const checkHealth = async () => {
      try {
        const response = await fetch("/api/health");
        const data = await response.json();
        statusEl.textContent = data.ok ? `vLLM ready: ${data.model}` : `vLLM unavailable: ${data.error || "model not listed"}`;
      } catch {
        statusEl.textContent = "web api unavailable";
      }
    };

    imageInput.addEventListener("change", () => {
      const file = imageInput.files && imageInput.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = () => {
        customImageData = String(reader.result);
        customPreview.src = customImageData;
      };
      reader.readAsDataURL(file);
    });

    useDemoButton.addEventListener("click", () => {
      customImageData = null;
      imageInput.value = "";
      customPreview.src = `/api/demo-image?ts=${Date.now()}`;
    });

    templateButtons.forEach((button) => {
      button.addEventListener("click", () => {
        promptEl.value = button.dataset.prompt || "";
        if ((button.dataset.prompt || "").includes("工具")) {
          document.querySelector('input[name="mode"][value="agent"]').checked = true;
        }
      });
    });

    clearButton.addEventListener("click", clearResult);

    runDemoButton.addEventListener("click", async () => {
      setBusy(true);
      answerEl.textContent = "正在运行固定标签 demo...";
      timelineEl.innerHTML = '<div class="empty">agent 正在调用工具...</div>';
      try {
        const response = await fetch("/api/run-demo", { method: "POST" });
        const data = await response.json();
        if (!response.ok) throw new Error(data.detail || "request failed");
        renderResult(data);
      } catch (error) {
        answerEl.textContent = error.message;
        timelineEl.innerHTML = '<div class="empty">请求失败。</div>';
      } finally {
        setBusy(false);
      }
    });

    runCustomButton.addEventListener("click", async () => {
      setBusy(true);
      answerEl.textContent = "正在运行自定义测试...";
      timelineEl.innerHTML = '<div class="empty">模型正在处理...</div>';
      const mode = document.querySelector('input[name="mode"]:checked').value;
      try {
        const response = await fetch("/api/run-custom", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            prompt: promptEl.value,
            image: customImageData,
            mode,
            use_demo_image: customImageData === null
          })
        });
        const data = await response.json();
        if (!response.ok) throw new Error(data.detail || "request failed");
        renderResult(data);
      } catch (error) {
        answerEl.textContent = error.message;
        timelineEl.innerHTML = '<div class="empty">请求失败。</div>';
      } finally {
        setBusy(false);
      }
    });

    checkHealth();
  </script>
</body>
</html>
"""


def _image_data_url(path: Path) -> str:
    image_bytes = path.read_bytes()
    encoded = base64.b64encode(image_bytes).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def _save_data_url_image(data_url: str) -> Path:
    value = data_url.strip()
    if value.startswith("data:"):
        _, _, value = value.partition(",")
    try:
        raw = base64.b64decode(value, validate=True)
    except binascii.Error as exc:
        raise ValueError("图片不是有效的 base64 数据。") from exc

    if len(raw) > MAX_UPLOAD_BYTES:
        raise ValueError("图片过大，请使用 12MB 以下的图片。")

    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    output_path = UPLOAD_DIR / f"custom_{uuid4().hex}.png"

    try:
        with Image.open(BytesIO(raw)) as image:
            image.load()
            image = image.convert("RGB")
            if image.width * image.height > MAX_IMAGE_PIXELS or max(image.size) > MAX_IMAGE_EDGE:
                image.thumbnail((MAX_IMAGE_EDGE, MAX_IMAGE_EDGE))
            image.save(output_path)
    except UnidentifiedImageError as exc:
        raise ValueError("上传内容不是可识别的图片。") from exc

    return output_path


def _extract_events(messages: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], str]:
    events: list[dict[str, Any]] = []
    answer = ""
    for message in messages:
        if "function_call" in message:
            call = message["function_call"]
            events.append(
                {
                    "kind": "tool_call",
                    "name": call.get("name", ""),
                    "payload": call.get("arguments", ""),
                }
            )
        elif message.get("role") == "function":
            events.append(
                {
                    "kind": "tool_response",
                    "name": message.get("name", ""),
                    "payload": message.get("content", ""),
                }
            )
        elif message.get("role") == "assistant" and message.get("content"):
            answer = message["content"]
    return events, answer


def _run_agent_query(image_path: Path, prompt: str) -> dict[str, Any]:
    bot = build_agent()
    messages = [
        {
            "role": "user",
            "content": [
                {"image": str(image_path)},
                {"text": prompt},
            ],
        }
    ]

    final_response: list[dict[str, Any]] = []
    for response in bot.run(messages=messages):
        final_response = response

    events, answer = _extract_events(final_response)
    return {
        "mode": "agent",
        "answer": answer,
        "events": events,
        "raw": final_response,
        "image": _image_data_url(image_path),
    }


def _run_vision_query(image_path: Path, prompt: str) -> dict[str, Any]:
    client = OpenAI(base_url=MODEL_SERVER, api_key="EMPTY")
    completion = client.chat.completions.create(
        model=MODEL_NAME,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": _image_data_url(image_path)},
                    },
                    {"type": "text", "text": prompt},
                ],
            }
        ],
        temperature=0.1,
        max_tokens=384,
    )
    message = completion.choices[0].message
    raw = json.loads(completion.model_dump_json())
    return {
        "mode": "vision",
        "answer": message.content or "",
        "events": [
            {
                "kind": "vision_request",
                "name": "chat.completions",
                "payload": {"prompt": prompt, "image": image_path.name},
            }
        ],
        "raw": raw,
        "image": _image_data_url(image_path),
    }


def _run_agent_demo() -> dict[str, Any]:
    image_path = create_demo_image()
    prompt = (
        "Read the SKU and destination from the image. "
        "First call only query_inventory with the exact SKU. Wait for its tool "
        "result. Then call estimate_shipping_days with the exact returned "
        "warehouse and destination. Never call both tools in the same assistant "
        "turn. Reply with a concise Chinese answer."
    )
    return _run_agent_query(image_path, prompt)


def _run_custom_request(request: CustomRunRequest) -> dict[str, Any]:
    prompt = request.prompt.strip()
    if not prompt:
        raise ValueError("请输入问题。")

    image_path = create_demo_image() if request.use_demo_image or not request.image else _save_data_url_image(request.image)
    if request.mode == "agent":
        return _run_agent_query(image_path, prompt)
    return _run_vision_query(image_path, prompt)


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return HTML


@app.get("/api/health")
def health() -> dict[str, Any]:
    try:
        client = OpenAI(base_url=MODEL_SERVER, api_key="EMPTY")
        models = client.models.list()
        model_ids = [model.id for model in models.data]
        return {"ok": MODEL_NAME in model_ids, "model": MODEL_NAME, "models": model_ids}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


@app.get("/api/demo-image")
def demo_image() -> FileResponse:
    image_path = create_demo_image()
    return FileResponse(image_path, media_type="image/png")


@app.post("/api/run-demo")
async def run_demo() -> dict[str, Any]:
    try:
        return await asyncio.to_thread(_run_agent_demo)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/api/run-custom")
async def run_custom(request: CustomRunRequest) -> dict[str, Any]:
    try:
        return await asyncio.to_thread(_run_custom_request, request)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
