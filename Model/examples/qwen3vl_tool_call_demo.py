import json
import os
from pathlib import Path

import json5
from PIL import Image, ImageDraw, ImageFont
from qwen_agent.agents import FnCallAgent
from qwen_agent.tools.base import BaseTool, register_tool
from qwen_agent.utils.output_beautify import typewriter_print


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GENERATED_DIR = PROJECT_ROOT / "generated"
DEMO_IMAGE = GENERATED_DIR / "inventory_label.png"


@register_tool("query_inventory")
class QueryInventory(BaseTool):
    description = (
        "Query local inventory by SKU. Use this when the user asks about stock, "
        "availability, or whether an item can be shipped."
    )
    parameters = [
        {
            "name": "sku",
            "type": "string",
            "description": "The SKU printed on the product label.",
            "required": True,
        }
    ]

    def call(self, params: str, **kwargs) -> str:
        args = json5.loads(params)
        sku = str(args["sku"]).upper().strip()
        inventory = {
            "QWEN-VL-2B-DEMO": {"stock": 17, "warehouse": "Shanghai-A1"},
            "MINIMAX-EDGE-DEMO": {"stock": 4, "warehouse": "Suzhou-B2"},
        }
        result = inventory.get(sku, {"stock": 0, "warehouse": "unknown"})
        return json.dumps({"sku": sku, **result}, ensure_ascii=False)


@register_tool("estimate_shipping_days")
class EstimateShippingDays(BaseTool):
    description = "Estimate shipping days from a warehouse to a city."
    parameters = [
        {
            "name": "warehouse",
            "type": "string",
            "description": "Warehouse code returned by query_inventory.",
            "required": True,
        },
        {
            "name": "city",
            "type": "string",
            "description": "Destination city.",
            "required": True,
        },
    ]

    def call(self, params: str, **kwargs) -> str:
        args = json5.loads(params)
        warehouse = str(args["warehouse"])
        city = str(args["city"])
        known_warehouses = {"Shanghai-A1", "Suzhou-B2"}
        if warehouse not in known_warehouses:
            return json.dumps(
                {
                    "warehouse": warehouse,
                    "city": city,
                    "error": "unknown_warehouse",
                    "hint": "Call query_inventory first and use the exact warehouse value it returns.",
                },
                ensure_ascii=False,
            )
        days = 1 if warehouse == "Shanghai-A1" and city in {"Shanghai", "杭州", "苏州"} else 3
        return json.dumps(
            {"warehouse": warehouse, "city": city, "estimated_days": days},
            ensure_ascii=False,
        )


def create_demo_image() -> Path:
    GENERATED_DIR.mkdir(exist_ok=True)
    image = Image.new("RGB", (768, 512), color=(245, 247, 250))
    draw = ImageDraw.Draw(image)
    font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    title_font = ImageFont.truetype(font_path, 48)
    body_font = ImageFont.truetype(font_path, 42)
    small_font = ImageFont.truetype(font_path, 30)

    draw.rectangle((34, 34, 734, 478), outline=(30, 40, 55), width=5)
    draw.text((64, 70), "PRODUCT LABEL", font=title_font, fill=(30, 40, 55))
    draw.text((64, 170), "SKU:", font=small_font, fill=(70, 80, 95))
    draw.text((64, 210), "QWEN-VL-2B-DEMO", font=body_font, fill=(0, 0, 0))
    draw.text((64, 310), "Destination:", font=small_font, fill=(70, 80, 95))
    draw.text((64, 350), "Shanghai", font=body_font, fill=(0, 0, 0))
    image.save(DEMO_IMAGE)
    return DEMO_IMAGE


def build_agent() -> FnCallAgent:
    model_name = os.getenv("MODEL_NAME", "Qwen/Qwen3-VL-2B-Instruct")
    model_server = os.getenv("MODEL_SERVER", "http://127.0.0.1:8000/v1")
    api_key = os.getenv("API_KEY", "EMPTY")

    llm_cfg = {
        "model_type": "qwenvl_oai",
        "model": model_name,
        "model_server": model_server,
        "api_key": api_key,
        "generate_cfg": {
            "temperature": 0.1,
            "top_p": 0.8,
            "max_tokens": 256,
            "fncall_prompt_type": "nous",
        },
    }

    return FnCallAgent(
        llm=llm_cfg,
        function_list=["query_inventory", "estimate_shipping_days"],
        name="Qwen3-VL-2B Tool Call Demo",
        system_message=(
            "You are a careful visual operations assistant. Read the label in the "
            "image, call tools when inventory or delivery information is needed, "
            "and give a concise final answer in Chinese. When delivery information "
            "is requested, first call query_inventory with the exact SKU, then call "
            "estimate_shipping_days using the warehouse returned by query_inventory "
            "and the destination city read from the image. Never call both tools in "
            "the same assistant turn. Do not invent warehouse codes."
        ),
    )


def main() -> None:
    image_path = create_demo_image()
    bot = build_agent()
    messages = [
        {
            "role": "user",
            "content": [
                {"image": str(image_path)},
                {
                    "text": (
                        "请读取图片中的 SKU 和目的地。然后调用工具查询库存，"
                        "再使用查询到的 warehouse 调用配送估算工具，最后给我一个简短结论。"
                    )
                },
            ],
        }
    ]

    print(f"Using demo image: {image_path}")
    print("Agent response:")
    response_plain_text = ""
    final_response = []
    for response in bot.run(messages=messages):
        final_response = response
        response_plain_text = typewriter_print(response, response_plain_text)

    print("\nRaw final messages:")
    print(json.dumps(final_response, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
