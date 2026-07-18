$ErrorActionPreference = "Stop"

wsl.exe -d Ubuntu-20.04 -- pkill -f "vllm serve|VLLM::EngineCore"

