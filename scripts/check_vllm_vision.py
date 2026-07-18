import base64
import os
from pathlib import Path

from openai import OpenAI


PROJECT_ROOT = Path(__file__).resolve().parents[1]
IMAGE_PATH = PROJECT_ROOT / "generated" / "inventory_label.png"


def main() -> None:
    base_url = os.getenv("MODEL_SERVER", "http://127.0.0.1:8000/v1")
    api_key = os.getenv("API_KEY", "EMPTY")
    model = os.getenv("MODEL_NAME", "Qwen/Qwen3-VL-2B-Instruct")

    image_bytes = IMAGE_PATH.read_bytes()
    image_b64 = base64.b64encode(image_bytes).decode("ascii")
    data_url = f"data:image/png;base64,{image_b64}"

    client = OpenAI(base_url=base_url, api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": data_url}},
                    {
                        "type": "text",
                        "text": "Read the SKU and destination from this label. Reply with JSON only.",
                    },
                ],
            }
        ],
        max_tokens=128,
        temperature=0,
        extra_body={"mm_processor_kwargs": {"max_pixels": 401408}},
    )
    print(response.choices[0].message.content)


if __name__ == "__main__":
    main()

