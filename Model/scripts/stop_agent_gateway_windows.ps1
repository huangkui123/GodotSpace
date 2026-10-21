$ErrorActionPreference = "Stop"

wsl.exe -d Ubuntu-20.04 -- pkill -f "uvicorn agent_service.app:app"
