$ErrorActionPreference = "Stop"

wsl.exe -d Ubuntu-20.04 -- pkill -f "uvicorn web_demo.app:app"

