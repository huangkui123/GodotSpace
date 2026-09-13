$ErrorActionPreference = "Stop"

wsl.exe -d Ubuntu-20.04 -- pkill -f "uvicorn asr_service.app:app"
