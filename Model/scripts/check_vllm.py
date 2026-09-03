import os

from openai import OpenAI


def main() -> None:
    base_url = os.getenv("MODEL_SERVER", "http://127.0.0.1:8000/v1")
    api_key = os.getenv("API_KEY", "EMPTY")
    client = OpenAI(base_url=base_url, api_key=api_key)
    models = client.models.list()
    print("vLLM endpoint is reachable.")
    for model in models.data:
        print("-", model.id)


if __name__ == "__main__":
    main()

